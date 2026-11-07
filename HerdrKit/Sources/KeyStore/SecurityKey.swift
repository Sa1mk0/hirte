import CryptoKit
import Foundation

// FIDO2 security keys, used through WebAuthn (iOS doesn't let apps speak CTAP to them directly).
//
// The SSH key is an OpenSSH `sk-ecdsa-sha2-nistp256@openssh.com` key whose application is the
// relying party (`hirte.dev`). WebAuthn can't sign the SSH data directly: it signs
// authenticatorData || SHA-256(clientDataJSON), where clientDataJSON holds the data as its
// challenge. OpenSSH accepts exactly that as a `webauthn-sk-ecdsa-sha2-nistp256@openssh.com`
// signature (PROTOCOL.u2f), but only if the server allows it:
// `PubkeyAcceptedAlgorithms +webauthn-sk-ecdsa-sha2-nistp256@openssh.com` in sshd_config.

public enum SecurityKeyError: Error, LocalizedError {
    case malformedAttestation(String)
    case unsupportedAlgorithm
    case unexpectedClientData
    case wrongRelyingParty
    case invalidSignature

    public var errorDescription: String? {
        switch self {
        case .malformedAttestation(let detail): "The security key's answer couldn't be read (\(detail))."
        case .unsupportedAlgorithm: "The security key didn't create an ECDSA P-256 key."
        case .unexpectedClientData: "iOS signed data in a form OpenSSH can't check."
        case .wrongRelyingParty: "The security key signed for a different site."
        case .invalidSignature: "The security key's signature doesn't match its key."
        }
    }
}

/// What a WebAuthn assertion returns.
public struct WebAuthnAssertion: Sendable {
    public let authenticatorData: Data
    public let clientDataJSON: Data
    /// ECDSA signature, DER-encoded.
    public let signature: Data

    public init(authenticatorData: Data, clientDataJSON: Data, signature: Data) {
        self.authenticatorData = authenticatorData
        self.clientDataJSON = clientDataJSON
        self.signature = signature
    }
}

/// A new credential on a security key, read from its WebAuthn registration.
public struct SecurityKeyRegistration: Sendable {
    public let credentialID: Data
    public let publicKeyBlob: Data

    /// - Parameters:
    ///   - attestationObject: The registration's raw attestation object (CBOR).
    ///   - relyingParty: The WebAuthn relying party ID; it becomes the SSH key's application.
    public init(attestationObject: Data, credentialID: Data, relyingParty: String) throws {
        guard case .map(let object) = try CBOR.decode(attestationObject),
              case .bytes(let authData) = object[.text("authData")]
        else { throw SecurityKeyError.malformedAttestation("no authData") }

        // rpIdHash(32) flags(1) signCount(4) aaguid(16) credentialIdLength(2) credentialId publicKey(COSE)
        guard authData.count > 55 else { throw SecurityKeyError.malformedAttestation("authData too short") }
        guard Data(authData.prefix(32)) == Data(SHA256.hash(data: Data(relyingParty.utf8))) else {
            throw SecurityKeyError.wrongRelyingParty
        }
        guard authData[authData.startIndex + 32] & 0x40 != 0 else {
            throw SecurityKeyError.malformedAttestation("no attested credential")
        }
        let lengthIndex = authData.startIndex + 53
        let idLength = Int(authData[lengthIndex]) << 8 | Int(authData[lengthIndex + 1])
        let idStart = lengthIndex + 2
        guard authData.endIndex >= idStart + idLength else {
            throw SecurityKeyError.malformedAttestation("credential ID")
        }
        let embeddedID = Data(authData[idStart..<idStart + idLength])
        guard embeddedID == credentialID || credentialID.isEmpty else {
            throw SecurityKeyError.malformedAttestation("credential IDs differ")
        }
        guard case .map(let cose) = try CBOR.decode(Data(authData[(idStart + idLength)...]), allowTrailing: true)
        else { throw SecurityKeyError.malformedAttestation("no public key") }

        // COSE_Key: kty(1) = EC2(2), alg(3) = ES256(-7), crv(-1) = P-256(1), x(-2), y(-3)
        guard cose[.int(1)] == .int(2), cose[.int(3)] == .int(-7), cose[.int(-1)] == .int(1),
              case .bytes(let x) = cose[.int(-2)], case .bytes(let y) = cose[.int(-3)],
              x.count == 32, y.count == 32
        else { throw SecurityKeyError.unsupportedAlgorithm }
        let point = Data([0x04]) + x + y
        _ = try P256.Signing.PublicKey(x963Representation: point)  // a valid point

        self.credentialID = embeddedID
        publicKeyBlob = OpenSSH.securityKeyBlob(point: point, application: relyingParty)
    }
}

/// Signs SSH logins with a security key.
public struct SecurityKeySigner: Sendable {
    /// Asks the security key with this credential ID to sign `challenge`.
    public typealias Assert = @Sendable (_ credentialID: Data, _ challenge: Data) async throws -> WebAuthnAssertion

    public static let signatureAlgorithm = "webauthn-sk-ecdsa-sha2-nistp256@openssh.com"

    public let publicKeyBlob: Data
    public let credentialID: Data
    /// The relying party, also the SSH key's application.
    public let application: String
    private let publicKey: P256.Signing.PublicKey
    private let assert: Assert

    public init(publicKeyBlob: Data, credentialID: Data, assert: @escaping Assert) throws {
        var reader = SSHReader(publicKeyBlob)
        guard try reader.text() == SSHKeyAlgorithm.securityKeyP256.rawValue,
              try reader.text() == "nistp256"
        else { throw SecurityKeyError.unsupportedAlgorithm }
        publicKey = try P256.Signing.PublicKey(x963Representation: try reader.string())
        application = try reader.text()
        self.publicKeyBlob = publicKeyBlob
        self.credentialID = credentialID
        self.assert = assert
    }

    /// Signs `message` (the SSH user-auth data) and returns the signature as SSH sends it,
    /// without the leading algorithm name.
    public func signatureBody(for message: Data) async throws -> Data {
        let assertion = try await assert(credentialID, message)
        return try Self.signatureBody(
            message: message, assertion: assertion, application: application, publicKey: publicKey)
    }

    /// Checks the assertion the way sshd will, then encodes it (PROTOCOL.u2f):
    /// string(ecdsa signature) byte(flags) uint32(counter) string(origin) string(clientData) string(extensions).
    static func signatureBody(
        message: Data, assertion: WebAuthnAssertion, application: String, publicKey: P256.Signing.PublicKey
    ) throws -> Data {
        let authData = assertion.authenticatorData
        guard authData.count >= 37 else { throw SecurityKeyError.malformedAttestation("authenticatorData too short") }
        guard Data(authData.prefix(32)) == Data(SHA256.hash(data: Data(application.utf8))) else {
            throw SecurityKeyError.wrongRelyingParty
        }
        let flags = authData[authData.startIndex + 32]
        let counter = authData[(authData.startIndex + 33)..<(authData.startIndex + 37)]
            .reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let extensions = Data(authData.dropFirst(37))

        // sshd rebuilds the start of clientDataJSON and insists on this exact prefix.
        guard let json = try? JSONSerialization.jsonObject(with: assertion.clientDataJSON) as? [String: Any],
              let origin = json["origin"] as? String, !origin.contains("\"")
        else { throw SecurityKeyError.unexpectedClientData }
        let challenge = message.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let prefix = #"{"type":"webauthn.get","challenge":"\#(challenge)","origin":"\#(origin)""#
        guard assertion.clientDataJSON.starts(with: Data(prefix.utf8)) else {
            throw SecurityKeyError.unexpectedClientData
        }

        let signature = try P256.Signing.ECDSASignature(derRepresentation: assertion.signature)
        let signed = authData + Data(SHA256.hash(data: assertion.clientDataJSON))
        guard publicKey.isValidSignature(signature, for: signed) else { throw SecurityKeyError.invalidSignature }

        var ecdsa = SSHWriter()
        ecdsa.mpint(signature.rawRepresentation.prefix(32))
        ecdsa.mpint(signature.rawRepresentation.suffix(32))

        var body = SSHWriter()
        body.string(ecdsa.data)
        body.uint8(flags)
        body.uint32(counter)
        body.string(origin)
        body.string(assertion.clientDataJSON)
        body.string(extensions)
        return body.data
    }
}

// MARK: - CBOR

/// Just enough CBOR (RFC 8949) for attestation objects and COSE keys.
indirect enum CBOR: Hashable {
    case int(Int)
    case bytes(Data)
    case text(String)
    case array([CBOR])
    case map([CBOR: CBOR])
    case bool(Bool)
    case null
    case other

    static func decode(_ data: Data, allowTrailing: Bool = false) throws -> CBOR {
        var parser = Parser(bytes: Array(data))
        let value = try parser.value(depth: 0)
        guard allowTrailing || parser.position == parser.bytes.count else {
            throw SecurityKeyError.malformedAttestation("trailing CBOR data")
        }
        return value
    }

    private struct Parser {
        let bytes: [UInt8]
        var position = 0

        mutating func byte() throws -> UInt8 {
            guard position < bytes.count else { throw SecurityKeyError.malformedAttestation("truncated CBOR") }
            defer { position += 1 }
            return bytes[position]
        }

        mutating func argument(_ info: UInt8) throws -> UInt64 {
            switch info {
            case 0..<24: return UInt64(info)
            case 24...27:
                var value: UInt64 = 0
                for _ in 0..<(1 << (info - 24)) { value = value << 8 | UInt64(try byte()) }
                return value
            default: throw SecurityKeyError.malformedAttestation("unsupported CBOR length")
            }
        }

        mutating func take(_ count: UInt64) throws -> [UInt8] {
            guard count <= UInt64(bytes.count - position) else {
                throw SecurityKeyError.malformedAttestation("truncated CBOR")
            }
            defer { position += Int(count) }
            return Array(bytes[position..<position + Int(count)])
        }

        mutating func value(depth: Int) throws -> CBOR {
            guard depth < 16 else { throw SecurityKeyError.malformedAttestation("CBOR nested too deep") }
            let initial = try byte()
            let major = initial >> 5
            let info = initial & 0x1F
            switch major {
            case 0:
                let value = try argument(info)
                guard value <= UInt64(Int.max) else { return .other }
                return .int(Int(value))
            case 1:
                let value = try argument(info)
                guard value < UInt64(Int.max) else { return .other }
                return .int(-1 - Int(value))
            case 2: return .bytes(Data(try take(try argument(info))))
            case 3:
                guard let text = String(bytes: try take(try argument(info)), encoding: .utf8) else {
                    throw SecurityKeyError.malformedAttestation("invalid CBOR text")
                }
                return .text(text)
            case 4:
                let count = try argument(info)
                guard count <= UInt64(bytes.count) else { throw SecurityKeyError.malformedAttestation("CBOR array") }
                return .array(try (0..<count).map { _ in try value(depth: depth + 1) })
            case 5:
                let count = try argument(info)
                guard count <= UInt64(bytes.count) else { throw SecurityKeyError.malformedAttestation("CBOR map") }
                var map: [CBOR: CBOR] = [:]
                for _ in 0..<count {
                    let key = try value(depth: depth + 1)
                    map[key] = try value(depth: depth + 1)
                }
                return .map(map)
            case 6:
                _ = try argument(info)  // tag: ignore it, keep the value
                return try value(depth: depth + 1)
            default:
                switch info {
                case 20: return .bool(false)
                case 21: return .bool(true)
                case 22: return .null
                case 24: _ = try byte(); return .other
                case 25: _ = try take(2); return .other
                case 26: _ = try take(4); return .other
                case 27: _ = try take(8); return .other
                default: return .other
                }
            }
        }
    }
}
