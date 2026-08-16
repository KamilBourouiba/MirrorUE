import AppKit
import Foundation

struct AgentActionApprovalRequest: Sendable, Equatable {
    let title: String
    let detail: String
}

/// A small local safety layer above structural tool validation.
///
/// Semantic UI understanding is necessarily heuristic, so this policy focuses
/// on high-signal cases and fails toward asking the phone owner: credential/
/// payment fields, taps on consequential labels, and batches that type and then
/// tap (which can submit a form or message).
enum AgentActionApprovalPolicy {
    private static let consequentialTerms = [
        "buy", "purchase", "subscribe", "pay", "transfer", "send", "post",
        "publish", "delete", "erase", "remove account", "confirm order",
        "place order", "sign out", "log out", "install", "allow access",
        "acheter", "achat", "abonner", "payer", "paiement", "transferer",
        "envoyer", "publier", "supprimer", "effacer", "confirmer",
        "commander", "deconnexion", "installer", "autoriser",
    ]

    private static let sensitiveFieldTerms = [
        "password", "passcode", "one-time code", "verification code", "security code",
        "credit card", "card number", "cvv", "cvc", "pin",
        "mot de passe", "code unique", "code de verification", "code de securite",
        "carte bancaire", "numero de carte",
    ]

    static func approvalRequest(
        for actions: [AgentPhoneAction],
        recognizedText: [AgentRecognizedText]
    ) -> AgentActionApprovalRequest? {
        guard !actions.isEmpty else { return nil }
        let screenText = normalized(recognizedText.map(\.text).joined(separator: " "))
        let hasTypedAction = actions.contains {
            if case .type = $0 { return true }
            return false
        }
        let hasTapAction = actions.contains {
            if case .tap = $0 { return true }
            return false
        }
        let typesSubmissionKey = actions.contains { action in
            guard case .type(let text) = action else { return false }
            return text.contains("\n") || text.contains("\r")
        }

        if typesSubmissionKey {
            return AgentActionApprovalRequest(
                title: "Allow text submission?",
                detail: typedSummary(actions)
                    + "\n\nThe text includes a Return key and can submit a form or send content."
            )
        }

        if hasTypedAction,
           sensitiveFieldTerms.contains(where: { screenText.contains($0) }) {
            return AgentActionApprovalRequest(
                title: "Allow sensitive text entry?",
                detail: typedSummary(actions)
                    + "\n\nThe current screen appears to contain a credential, verification, or payment field."
            )
        }

        if hasTypedAction && hasTapAction {
            return AgentActionApprovalRequest(
                title: "Allow text entry and tap?",
                detail: typedSummary(actions)
                    + "\n\nThis batch can submit a form or send content. Check the iPhone before allowing it."
            )
        }

        for action in actions {
            guard case .tap(let x, let y) = action,
                  let target = nearestText(toX: x, y: y, rows: recognizedText) else {
                continue
            }
            let normalizedTarget = normalized(target)
            if consequentialTerms.contains(where: { normalizedTarget.contains($0) }) {
                return AgentActionApprovalRequest(
                    title: "Allow consequential tap?",
                    detail: "The model wants to tap near “\(String(target.prefix(100)))”. This may send, buy, publish, install, or delete something."
                )
            }
        }

        return nil
    }

    private static func typedSummary(_ actions: [AgentPhoneAction]) -> String {
        let counts = actions.compactMap { action -> Int? in
            guard case .type(let text) = action else { return nil }
            return text.count
        }
        let total = counts.reduce(0, +)
        return "The model wants to type \(total) character\(total == 1 ? "" : "s") on the phone."
    }

    private static func nearestText(
        toX x: Double,
        y: Double,
        rows: [AgentRecognizedText]
    ) -> String? {
        rows.compactMap { row -> (distance: Double, text: String)? in
            let dx = max(max(row.x - x, 0), x - (row.x + row.width))
            let dy = max(max(row.y - y, 0), y - (row.y + row.height))
            let distance = hypot(dx, dy)
            guard distance <= 0.065 else { return nil }
            return (distance, row.text)
        }
        .min { $0.distance < $1.distance }?
        .text
    }

    private static func normalized(_ text: String) -> String {
        text.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).lowercased()
    }
}

/// Cancellation-aware sheet wrapper. If the agent is stopped while approval
/// is pending, the sheet closes and the action batch is denied.
@MainActor
final class AgentApprovalSession: @unchecked Sendable {
    private weak var hostWindow: NSWindow?
    private let alert = NSAlert()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var finished = false

    init(request: AgentActionApprovalRequest, hostWindow: NSWindow) {
        self.hostWindow = hostWindow
        alert.alertStyle = .warning
        alert.messageText = request.title
        alert.informativeText = request.detail
        alert.addButton(withTitle: "Allow Once")
        alert.addButton(withTitle: "Deny & Stop")
    }

    func present() async -> Bool {
        guard !Task.isCancelled, let hostWindow else { return false }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            alert.beginSheetModal(for: hostWindow) { [weak self] response in
                self?.finish(response == .alertFirstButtonReturn)
            }
        }
    }

    nonisolated func cancel() {
        Task { @MainActor [weak self] in
            guard let self, !self.finished else { return }
            if let parent = self.alert.window.sheetParent {
                parent.endSheet(self.alert.window, returnCode: .abort)
            } else {
                self.finish(false)
            }
        }
    }

    private func finish(_ approved: Bool) {
        guard !finished else { return }
        finished = true
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(returning: approved)
    }
}
