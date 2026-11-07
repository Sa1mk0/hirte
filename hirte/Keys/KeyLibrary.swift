import Foundation
import HerdrKit
import LocalAuthentication
import Observation

/// SwiftUI-facing wrapper around `KeyStore`.
@Observable
final class KeyLibrary {
    private(set) var keys: [SSHKeyInfo] = []
    var lastError: String?

    private let store: KeyStore
    let securityKeys = SecurityKeyAuthenticator()

    init(store: KeyStore = KeyStore()) {
        self.store = store
        reload()
    }

    var hasSecureEnclave: Bool { KeyStore.isSecureEnclaveAvailable }

    func key(id: UUID?) -> SSHKeyInfo? {
        keys.first { $0.id == id }
    }

    /// What `generate` can make.
    enum NewKeyType: String, CaseIterable, Identifiable {
        case secureEnclave, ed25519, securityKey
        var id: Self { self }
    }

    @discardableResult
    func generate(_ type: NewKeyType, label: String, requireBiometry: Bool) async -> SSHKeyInfo? {
        do {
            let info: SSHKeyInfo
            switch type {
            case .secureEnclave:
                info = try store.generateKey(label: label, requireBiometry: requireBiometry && hasSecureEnclave)
            case .ed25519:
                info = try store.generateEd25519Key(label: label, requireBiometry: requireBiometry)
            case .securityKey:
                let registration = try await securityKeys.register(name: label)
                info = try store.addSecurityKey(registration, label: label)
            }
            reload()
            return info
        } catch SecurityKeyPromptError.cancelled {
            return nil
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func importKey(_ key: ParsedPrivateKey, label: String, requireBiometry: Bool) -> SSHKeyInfo? {
        do {
            let info = try store.importKey(key, label: label, requireBiometry: requireBiometry)
            reload()
            return info
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func rename(_ key: SSHKeyInfo, to label: String) {
        do {
            try store.rename(id: key.id, to: label)
            reload()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func delete(_ key: SSHKeyInfo) {
        do {
            try store.deleteKey(id: key.id)
            reload()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Loads the private key, asking for Face ID first if the key needs it, so the
    /// prompt does not appear in the middle of the SSH handshake. A security key is
    /// asked to sign during the handshake itself.
    func signingKey(for key: SSHKeyInfo) async throws -> SigningKey {
        var context: LAContext?
        if key.requiresBiometry {
            let unlock = LAContext()
            try await unlock.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: "Unlock “\(key.label)” to connect")
            context = unlock
        }
        let securityKeys = securityKeys
        return try store.signingKey(for: key.id, authenticationContext: context) { credentialID, challenge in
            try await securityKeys.assert(credentialID: credentialID, challenge: challenge)
        }
    }

    private func reload() {
        do {
            keys = try store.keys()
        } catch {
            lastError = error.localizedDescription
        }
    }
}
