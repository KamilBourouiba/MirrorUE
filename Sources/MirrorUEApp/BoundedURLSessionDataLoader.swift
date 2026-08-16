import Foundation

enum BoundedURLSessionDataError: LocalizedError, Equatable {
    case responseTooLarge(limit: Int)
    case missingResponse

    var errorDescription: String? {
        switch self {
        case .responseTooLarge(let limit):
            return "Provider response exceeds the \(limit / 1_024) KiB safety limit."
        case .missingResponse:
            return "Provider returned no HTTP response."
        }
    }
}

/// Streams URLSession chunks into a bounded buffer and cancels the data task as
/// soon as either Content-Length or received bytes exceed the configured cap.
/// This avoids `URLSession.data(for:)` buffering an untrusted response before a
/// post-hoc size check.
final class BoundedURLSessionDataLoader: @unchecked Sendable {
    private final class TaskBox: @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionTask?
        private var cancelled = false

        func set(_ task: URLSessionTask) {
            lock.lock()
            self.task = task
            let shouldCancel = cancelled
            lock.unlock()
            if shouldCancel { task.cancel() }
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let task = task
            lock.unlock()
            task?.cancel()
        }
    }

    private final class Delegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private final class State {
            let limit: Int
            let continuation: CheckedContinuation<(Data, URLResponse), Error>
            var data = Data()
            var response: URLResponse?

            init(
                limit: Int,
                continuation: CheckedContinuation<(Data, URLResponse), Error>
            ) {
                self.limit = limit
                self.continuation = continuation
            }
        }

        private let lock = NSLock()
        private var states: [Int: State] = [:]

        func start(
            request: URLRequest,
            session: URLSession,
            limit: Int,
            taskBox: TaskBox,
            continuation: CheckedContinuation<(Data, URLResponse), Error>
        ) {
            let task = session.dataTask(with: request)
            let state = State(limit: limit, continuation: continuation)
            lock.lock()
            states[task.taskIdentifier] = state
            lock.unlock()
            taskBox.set(task)
            task.resume()
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            var rejected: State?
            lock.lock()
            if let state = states[dataTask.taskIdentifier] {
                let expected = response.expectedContentLength
                if expected > Int64(state.limit) {
                    rejected = states.removeValue(forKey: dataTask.taskIdentifier)
                } else {
                    state.response = response
                    if expected > 0 {
                        state.data.reserveCapacity(Int(expected))
                    }
                }
            }
            lock.unlock()

            if let rejected {
                completionHandler(.cancel)
                dataTask.cancel()
                rejected.continuation.resume(
                    throwing: BoundedURLSessionDataError.responseTooLarge(
                        limit: rejected.limit
                    )
                )
            } else {
                completionHandler(.allow)
            }
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive data: Data
        ) {
            var rejected: State?
            lock.lock()
            if let state = states[dataTask.taskIdentifier] {
                if data.count > state.limit - state.data.count {
                    rejected = states.removeValue(forKey: dataTask.taskIdentifier)
                } else {
                    state.data.append(data)
                }
            }
            lock.unlock()

            if let rejected {
                dataTask.cancel()
                rejected.continuation.resume(
                    throwing: BoundedURLSessionDataError.responseTooLarge(
                        limit: rejected.limit
                    )
                )
            }
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            // Provider credentials are scoped to the configured origin. Do not
            // let an HTTP redirect forward Authorization/custom API headers to
            // a different endpoint (or silently change transport policy).
            completionHandler(nil)
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            didCompleteWithError error: Error?
        ) {
            lock.lock()
            let state = states.removeValue(forKey: task.taskIdentifier)
            lock.unlock()
            guard let state else { return }

            if let error {
                state.continuation.resume(throwing: error)
            } else if let response = state.response {
                state.continuation.resume(returning: (state.data, response))
            } else {
                state.continuation.resume(
                    throwing: BoundedURLSessionDataError.missingResponse
                )
            }
        }
    }

    private let delegate: Delegate
    private let session: URLSession

    init(configuration: URLSessionConfiguration) {
        let delegate = Delegate()
        self.delegate = delegate
        self.session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
    }

    convenience init(copying session: URLSession) {
        self.init(configuration: session.configuration)
    }

    deinit {
        session.invalidateAndCancel()
    }

    func data(
        for request: URLRequest,
        maximumBytes: Int
    ) async throws -> (Data, URLResponse) {
        precondition(maximumBytes > 0)
        let taskBox = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.start(
                    request: request,
                    session: session,
                    limit: maximumBytes,
                    taskBox: taskBox,
                    continuation: continuation
                )
            }
        } onCancel: {
            taskBox.cancel()
        }
    }
}
