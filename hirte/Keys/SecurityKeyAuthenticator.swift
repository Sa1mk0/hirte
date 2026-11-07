import AuthenticationServices
import HerdrKit
import UIKit

/// Talks to FIDO2 security keys (NFC, USB-C, Lightning) through WebAuthn.
///
/// The relying party is hirte.dev: the app's associated domain (`webcredentials:hirte.dev`), with
/// the app listed in https://hirte.dev/.well-known/apple-app-site-association. Without that,
/// iOS refuses every request.
final class SecurityKeyAuthenticator: NSObject {
    static let relyingParty = "hirte.dev"

    /// Creates a new (non-discoverable) ES256 credential on a security key.
    func register(name: String) async throws -> SecurityKeyRegistration {
        let provider = ASAuthorizationSecurityKeyPublicKeyCredentialProvider(relyingPartyIdentifier: Self.relyingParty)
        let request = provider.createCredentialRegistrationRequest(
            challenge: Self.randomBytes(32), displayName: name, name: name, userID: Self.randomBytes(16))
        request.credentialParameters = [ASAuthorizationPublicKeyCredentialParameters(algorithm: .ES256)]
        request.residentKeyPreference = .discouraged
        // As websites ask. With "discouraged", a YubiKey 5 with a PIN (over USB-C, iOS 27) got a
        // PIN prompt before any touch, and then iOS called the right PIN wrong.
        request.userVerificationPreference = .preferred
        request.attestationPreference = .none

        let credential = try await perform(request)
        guard let registration = credential as? ASAuthorizationSecurityKeyPublicKeyCredentialRegistration,
              let attestation = registration.rawAttestationObject
        else { throw SecurityKeyPromptError.failed("No security key credential came back.") }
        return try SecurityKeyRegistration(
            attestationObject: attestation, credentialID: registration.credentialID, relyingParty: Self.relyingParty)
    }

    /// Asks the security key holding `credentialID` to sign `challenge`.
    func assert(credentialID: Data, challenge: Data) async throws -> WebAuthnAssertion {
        let provider = ASAuthorizationSecurityKeyPublicKeyCredentialProvider(relyingPartyIdentifier: Self.relyingParty)
        let request = provider.createCredentialAssertionRequest(challenge: challenge)
        request.allowedCredentials = [ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor(
            credentialID: credentialID,
            transports: ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor.Transport.allSupported)]
        request.userVerificationPreference = .discouraged

        let credential = try await perform(request)
        guard let assertion = credential as? ASAuthorizationSecurityKeyPublicKeyCredentialAssertion,
              let authenticatorData = assertion.rawAuthenticatorData
        else { throw SecurityKeyPromptError.failed("No signature came back from the security key.") }
        return WebAuthnAssertion(
            authenticatorData: authenticatorData, clientDataJSON: assertion.rawClientDataJSON,
            signature: assertion.signature)
    }

    private func perform(_ request: ASAuthorizationRequest) async throws -> ASAuthorizationCredential {
        let controller = ASAuthorizationController(authorizationRequests: [request])
        let handler = Handler()
        controller.delegate = handler
        controller.presentationContextProvider = handler
        let credential = try await withCheckedThrowingContinuation { continuation in
            handler.continuation = continuation
            controller.performRequests()
        }
        // The controller holds its delegate weakly.
        withExtendedLifetime(handler) {}
        return credential
    }

    private static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }

    private final class Handler: NSObject, ASAuthorizationControllerDelegate,
        ASAuthorizationControllerPresentationContextProviding
    {
        var continuation: CheckedContinuation<ASAuthorizationCredential, any Error>?

        func authorizationController(
            controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization
        ) {
            continuation?.resume(returning: authorization.credential)
            continuation = nil
        }

        func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: any Error) {
            continuation?.resume(throwing: SecurityKeyPromptError(error))
            continuation = nil
        }

        func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let windows = scenes.flatMap(\.windows)
            // There is always a scene while the app is in front, which is when keys are used.
            return windows.first(where: \.isKeyWindow) ?? windows.first ?? UIWindow(windowScene: scenes[0])
        }
    }
}

enum SecurityKeyPromptError: LocalizedError {
    case cancelled
    case failed(String)

    init(_ error: any Error) {
        if let error = error as? ASAuthorizationError, error.code == .canceled {
            self = .cancelled
        } else {
            let nsError = error as NSError
            self = .failed("\(error.localizedDescription) (\(nsError.domain) \(nsError.code))")
        }
    }

    var errorDescription: String? {
        switch self {
        case .cancelled: "The security key wasn't used."
        case .failed(let message): "The security key couldn't be used: \(message)"
        }
    }
}
