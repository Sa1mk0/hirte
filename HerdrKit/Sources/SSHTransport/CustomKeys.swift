import Crypto
import Foundation
import KeyStore
import NIOCore
@preconcurrency import NIOSSH
import _CryptoExtras

// swift-nio-ssh signs only Ed25519 and ECDSA keys itself. RSA (rsa-sha2-512) and security keys
// (webauthn-sk-ecdsa-sha2-nistp256@openssh.com) go through its custom-key hooks.
//
// For both, the algorithm named in the login request differs from the key type at the start of
// the key blob (`rsa-sha2-512` vs `ssh-rsa`). swift-nio-ssh uses one prefix for both: it writes
// `publicKeyPrefix` (the algorithm) and then calls `write(to:)` for the rest of the blob. So
// `write(to:)` steps back over that prefix and writes the real blob, and returns the byte count
// as if it hadn't (the caller sums the counts to get the blob's length).

/// A public key whose login algorithm name differs from its blob's key type.
protocol AlgorithmRenamingPublicKey: NIOSSHPublicKeyProtocol {
    var blob: Data { get }
}

extension AlgorithmRenamingPublicKey {
    var rawRepresentation: Data { blob }

    func write(to buffer: inout ByteBuffer) -> Int {
        let prefixLength = 4 + Self.publicKeyPrefix.utf8.count
        buffer.moveWriterIndex(to: buffer.writerIndex - prefixLength)
        buffer.writeBytes(blob)
        return blob.count - prefixLength
    }

    func isValidSignature<D: DataProtocol>(_ signature: NIOSSHSignatureProtocol, for data: D) -> Bool {
        false  // only used to sign
    }
}

struct UnsupportedKeyRead: Error {}

/// A signature that is already in SSH wire format, after its algorithm name.
struct PreparedSignature<Name: SignatureName>: NIOSSHSignatureProtocol {
    static var signaturePrefix: String { Name.value }
    let body: Data

    var rawRepresentation: Data { body }

    func write(to buffer: inout ByteBuffer) -> Int {
        buffer.writeBytes(body)
    }

    static func read(from buffer: inout ByteBuffer) throws -> Self { throw UnsupportedKeyRead() }
}

protocol SignatureName { static var value: String { get } }

// MARK: RSA

enum RSASHA512: SignatureName { static let value = "rsa-sha2-512" }

struct RSAPublicKey: AlgorithmRenamingPublicKey {
    static let publicKeyPrefix = RSASHA512.value
    let blob: Data
    static func read(from buffer: inout ByteBuffer) throws -> Self { throw UnsupportedKeyRead() }
}

struct RSAPrivateKey: NIOSSHPrivateKeyProtocol {
    static let keyPrefix = RSASHA512.value
    let key: _RSA.Signing.PrivateKey
    let blob: Data

    var publicKey: NIOSSHPublicKeyProtocol { RSAPublicKey(blob: blob) }

    func signature<D: DataProtocol>(for data: D) throws -> NIOSSHSignatureProtocol {
        let signature = try key.signature(for: SHA512.hash(data: Data(data)), padding: .insecurePKCS1v1_5)
        // string(blob), where the blob is the raw signature: rsa-sha2-512 has no further structure.
        var body = ByteBuffer()
        body.writeInteger(UInt32(signature.rawRepresentation.count))
        body.writeBytes(signature.rawRepresentation)
        return PreparedSignature<RSASHA512>(body: Data(body.readableBytesView))
    }
}

// MARK: Security keys

enum WebAuthnSignature: SignatureName { static let value = SecurityKeySigner.signatureAlgorithm }

struct SecurityKeyPublicKey: AlgorithmRenamingPublicKey {
    static let publicKeyPrefix = SecurityKeySigner.signatureAlgorithm
    let blob: Data
    static func read(from buffer: inout ByteBuffer) throws -> Self { throw UnsupportedKeyRead() }
}

struct SecurityKeyPrivateKey: NIOSSHPrivateKeyProtocol {
    static let keyPrefix = SecurityKeySigner.signatureAlgorithm
    let signer: SecurityKeySigner

    var publicKey: NIOSSHPublicKeyProtocol { SecurityKeyPublicKey(blob: signer.publicKeyBlob) }

    /// swift-nio-ssh asks for the signature synchronously, on its event loop, but the security key
    /// answers only after the user taps it. So this blocks the event loop thread until it does.
    /// Other connections on that loop stall for that time; Hirte rarely has more than one opening.
    func signature<D: DataProtocol>(for data: D) throws -> NIOSSHSignatureProtocol {
        let message = Data(data)
        let result = BlockingResult<Data>()
        let signer = signer
        Task.detached {
            do { result.finish(.success(try await signer.signatureBody(for: message))) }
            catch { result.finish(.failure(error)) }
        }
        return PreparedSignature<WebAuthnSignature>(body: try result.wait())
    }
}

final class BlockingResult<Value: Sendable>: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private var result: Result<Value, any Error>?

    func finish(_ result: Result<Value, any Error>) {
        self.result = result
        semaphore.signal()
    }

    func wait() throws -> Value {
        semaphore.wait()
        return try result!.get()
    }
}

extension SigningKey {
    var nioSSHKey: NIOSSHPrivateKey {
        switch self {
        case .secureEnclave(let key): NIOSSHPrivateKey(secureEnclaveP256Key: key)
        case .p256(let key): NIOSSHPrivateKey(p256Key: key)
        case .p384(let key): NIOSSHPrivateKey(p384Key: key)
        case .p521(let key): NIOSSHPrivateKey(p521Key: key)
        case .ed25519(let key): NIOSSHPrivateKey(ed25519Key: key)
        case .rsa(let key): NIOSSHPrivateKey(custom: RSAPrivateKey(key: key, blob: publicKeyBlob))
        case .securityKey(let signer): NIOSSHPrivateKey(custom: SecurityKeyPrivateKey(signer: signer))
        }
    }
}
