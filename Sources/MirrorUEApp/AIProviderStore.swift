import Foundation
import Security

protocol AIProviderCredentialStoring: Sendable {
    func token(for profileID: UUID) throws -> String?
    func setToken(_ token: String, for profileID: UUID) throws
    func removeToken(for profileID: UUID) throws
}

enum AIProviderCredentialError: LocalizedError {
    case invalidTokenEncoding
    case unexpectedData
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidTokenEncoding:
            return "The API token could not be encoded."
        case .unexpectedData:
            return "Keychain returned an invalid API token."
        case let .keychain(status):
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
            return "Keychain error: \(detail)"
        }
    }
}

/// Stores one generic-password item per provider profile. The stable service
/// name keeps credentials available if the executable or bundle display name
/// changes.
final class AIProviderKeychain: AIProviderCredentialStoring, @unchecked Sendable {
    static let shared = AIProviderKeychain()

    private let service: String

    init(service: String = "app.mirrorue.ai-provider-token") {
        self.service = service
    }

    func token(for profileID: UUID) throws -> String? {
        var query = baseQuery(for: profileID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw AIProviderCredentialError.keychain(status)
        }
        guard let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else {
            throw AIProviderCredentialError.unexpectedData
        }
        return token
    }

    func setToken(_ token: String, for profileID: UUID) throws {
        guard let data = token.data(using: .utf8) else {
            throw AIProviderCredentialError.invalidTokenEncoding
        }

        let query = baseQuery(for: profileID)
        let attributes = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if updateStatus == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw AIProviderCredentialError.keychain(addStatus)
            }
            return
        }

        guard updateStatus == errSecSuccess else {
            throw AIProviderCredentialError.keychain(updateStatus)
        }
    }

    func removeToken(for profileID: UUID) throws {
        let status = SecItemDelete(baseQuery(for: profileID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AIProviderCredentialError.keychain(status)
        }
    }

    private func baseQuery(for profileID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID.uuidString.lowercased(),
        ]
    }
}

enum AIProviderTokenUpdate: Sendable {
    case unchanged
    case replace(String)
    case remove
}

struct AIProviderStoredSelection: Sendable {
    let profile: AIProviderProfile
    let token: String?
    let revision: UInt64
}

extension Notification.Name {
    static let aiProviderStoreDidChange = Notification.Name("MirrorUE.AIProviderStoreDidChange")
}

/// Persists non-secret profile data in UserDefaults. API tokens are delegated
/// to AIProviderCredentialStoring and never enter the encoded state.
final class AIProviderStore: @unchecked Sendable {
    static let shared = AIProviderStore()

    private struct PersistedState: Codable {
        var schemaVersion: Int
        var selectedProfileID: UUID?
        var profiles: [AIProviderProfile]
    }

    private let defaults: UserDefaults
    private let credentials: any AIProviderCredentialStoring
    private let storageKey: String
    private let lock = NSLock()
    private let mutationLock = NSLock()
    private var state: PersistedState
    private var revision: UInt64 = 0

    init(
        defaults: UserDefaults = .standard,
        credentials: any AIProviderCredentialStoring = AIProviderKeychain.shared,
        storageKey: String = "MirrorUE.AIProviderProfiles.v1"
    ) {
        self.defaults = defaults
        self.credentials = credentials
        self.storageKey = storageKey

        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode(PersistedState.self, from: data),
           !decoded.profiles.isEmpty {
            state = decoded
        } else {
            let profile = AIProviderProfile.lmStudio()
            state = PersistedState(schemaVersion: 1, selectedProfileID: profile.id, profiles: [profile])
            persist(state)
        }
    }

    var profiles: [AIProviderProfile] {
        withLock { state.profiles }
    }

    var selectedProfileID: UUID? {
        withLock { state.selectedProfileID }
    }

    var selectedProfile: AIProviderProfile? {
        withLock {
            guard let selectedID = state.selectedProfileID else { return nil }
            return state.profiles.first { $0.id == selectedID }
        }
    }

    func profile(id: UUID) -> AIProviderProfile? {
        withLock { state.profiles.first { $0.id == id } }
    }

    func token(for profileID: UUID) throws -> String? {
        try credentials.token(for: profileID)
    }

    /// Atomically snapshots profile metadata and its credential relative to
    /// provider-store writes. The revision lets runtime caches include
    /// token-only updates, even though secrets are absent from profile equality.
    func selectedRuntimeSelection() throws -> AIProviderStoredSelection? {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        guard let profile = selectedProfile else { return nil }
        return AIProviderStoredSelection(
            profile: profile,
            token: try credentials.token(for: profile.id),
            revision: withLock { revision }
        )
    }

    /// Writes the credential first so a Keychain failure cannot leave a profile
    /// claiming to be configured while its requested credential was discarded.
    @discardableResult
    func upsert(
        _ profile: AIProviderProfile,
        tokenUpdate: AIProviderTokenUpdate = .unchanged,
        select: Bool = true
    ) throws -> AIProviderProfile {
        var shouldNotify = false
        mutationLock.lock()
        defer {
            mutationLock.unlock()
            if shouldNotify { notifyChange() }
        }

        let profile = profile.sanitized()
        try profile.validate()

        switch tokenUpdate {
        case .unchanged:
            break
        case let .replace(token):
            let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
            if token.isEmpty {
                try credentials.removeToken(for: profile.id)
            } else {
                try credentials.setToken(token, for: profile.id)
            }
        case .remove:
            try credentials.removeToken(for: profile.id)
        }

        withLock {
            if let index = state.profiles.firstIndex(where: { $0.id == profile.id }) {
                state.profiles[index] = profile
            } else {
                state.profiles.append(profile)
            }
            if select || state.selectedProfileID == nil {
                state.selectedProfileID = profile.id
            }
            revision &+= 1
            persist(state)
        }
        shouldNotify = true
        return profile
    }

    func select(profileID: UUID) throws {
        var shouldNotify = false
        mutationLock.lock()
        defer {
            mutationLock.unlock()
            if shouldNotify { notifyChange() }
        }

        let found = withLock { () -> Bool in
            guard state.profiles.contains(where: { $0.id == profileID }) else { return false }
            state.selectedProfileID = profileID
            revision &+= 1
            persist(state)
            return true
        }
        guard found else { throw AIProviderStoreError.profileNotFound }
        shouldNotify = true
    }

    func remove(profileID: UUID, removeCredential: Bool = true) throws {
        var shouldNotify = false
        mutationLock.lock()
        defer {
            mutationLock.unlock()
            if shouldNotify { notifyChange() }
        }

        guard profile(id: profileID) != nil else {
            throw AIProviderStoreError.profileNotFound
        }
        if removeCredential {
            try credentials.removeToken(for: profileID)
        }

        let removed = withLock { () -> Bool in
            guard let index = state.profiles.firstIndex(where: { $0.id == profileID }) else {
                return false
            }
            state.profiles.remove(at: index)
            if state.selectedProfileID == profileID {
                state.selectedProfileID = state.profiles.first?.id
            }
            revision &+= 1
            persist(state)
            return true
        }
        guard removed else { throw AIProviderStoreError.profileNotFound }
        shouldNotify = true
    }

    /// Re-reads non-secret data. Useful if another settings surface writes to
    /// the same suite while the application is running.
    func reload() {
        var shouldNotify = false
        mutationLock.lock()
        defer {
            mutationLock.unlock()
            if shouldNotify { notifyChange() }
        }

        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(PersistedState.self, from: data) else {
            return
        }
        withLock {
            state = decoded
            revision &+= 1
        }
        shouldNotify = true
    }

    private func persist(_ snapshot: PersistedState) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(snapshot) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private func notifyChange() {
        if Thread.isMainThread {
            NotificationCenter.default.post(name: .aiProviderStoreDidChange, object: self)
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                NotificationCenter.default.post(name: .aiProviderStoreDidChange, object: self)
            }
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

enum AIProviderStoreError: LocalizedError {
    case profileNotFound

    var errorDescription: String? {
        switch self {
        case .profileNotFound:
            return "The AI provider profile no longer exists."
        }
    }
}
