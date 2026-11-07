import CommonCrypto
import CryptoKit
import Foundation
import _CryptoExtras

public enum PrivateKeyImportError: Error, LocalizedError, Equatable {
    case notAPrivateKey
    case publicKeyOnly
    case passphraseRequired
    case wrongPassphrase
    case unsupportedCipher(String)
    case unsupportedKeyType(String)
    case securityKeyFile
    case encryptedPEM
    case invalidKDF
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case .notAPrivateKey:
            "This isn't a private key. Hirte reads OpenSSH private keys (-----BEGIN OPENSSH PRIVATE KEY-----) and PEM keys."
        case .publicKeyOnly:
            "This is a public key. Import the private key instead (the file without .pub)."
        case .passphraseRequired: "This key is protected by a passphrase."
        case .wrongPassphrase: "The passphrase is wrong."
        case .unsupportedCipher(let name): "Keys encrypted with \(name) aren't supported."
        case .unsupportedKeyType(let name): "\(name) keys aren't supported."
        case .securityKeyFile:
            "This file belongs to a FIDO security key made with ssh-keygen; it can only be used with that key on a computer. Create a security key in Hirte instead."
        case .encryptedPEM:
            "Encrypted PEM keys aren't supported. Convert the key to the OpenSSH format first: ssh-keygen -p -f <file>"
        case .invalidKDF: "The key's passphrase settings are invalid."
        case .malformed(let detail): "The key is damaged (\(detail))."
        }
    }
}

/// A private key read from text, ready for `KeyStore.importKey`.
public struct ParsedPrivateKey: Sendable {
    public let algorithm: SSHKeyAlgorithm
    public let publicKeyBlob: Data
    /// The format `PrivateKeyParser.signingKey(algorithm:keyData:)` reads.
    let keyData: Data
    /// The comment stored with an OpenSSH key, if any.
    public let comment: String?

    public var fingerprint: String { OpenSSH.sha256Fingerprint(blob: publicKeyBlob) }
}

/// Reads private keys in the OpenSSH format (optionally passphrase-protected) and unencrypted
/// PEM (PKCS#1, SEC1, PKCS#8): Ed25519, ECDSA P-256/384/521 and RSA.
public enum PrivateKeyParser {
    /// Whether `text` is a passphrase-protected OpenSSH key.
    public static func needsPassphrase(_ text: String) -> Bool {
        guard let data = try? openSSHPayload(text) else { return false }
        var reader = SSHReader(data)
        _ = try? reader.bytes(openSSHMagic.count)
        return (try? reader.text()).map { $0 != "none" } ?? false
    }

    public static func parse(_ text: String, passphrase: String? = nil) throws -> ParsedPrivateKey {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.contains("BEGIN OPENSSH PRIVATE KEY") {
            return try parseOpenSSH(try openSSHPayload(text), passphrase: passphrase)
        }
        if text.contains("Proc-Type: 4,ENCRYPTED") || text.contains("BEGIN ENCRYPTED PRIVATE KEY") {
            throw PrivateKeyImportError.encryptedPEM
        }
        if text.contains("-----BEGIN") && text.contains("PRIVATE KEY-----") {
            return try parsePEM(text)
        }
        if text.hasPrefix("PuTTY-User-Key-File") {
            throw PrivateKeyImportError.malformed("PuTTY keys aren't supported; export it in the OpenSSH format")
        }
        if let type = text.split(separator: " ").first, SSHKeyAlgorithm(rawValue: String(type)) != nil {
            throw PrivateKeyImportError.publicKeyOnly
        }
        throw PrivateKeyImportError.notAPrivateKey
    }

    // MARK: Loading stored keys

    /// Turns stored key data back into a signing key. The format per algorithm:
    /// Ed25519 and ECDSA: CryptoKit's `rawRepresentation`; RSA: PKCS#1 DER.
    static func signingKey(algorithm: SSHKeyAlgorithm?, keyData: Data) throws -> SigningKey {
        switch algorithm {
        case .ecdsaP256: .p256(try P256.Signing.PrivateKey(rawRepresentation: keyData))
        case .ecdsaP384: .p384(try P384.Signing.PrivateKey(rawRepresentation: keyData))
        case .ecdsaP521: .p521(try P521.Signing.PrivateKey(rawRepresentation: keyData))
        case .ed25519: .ed25519(try Curve25519.Signing.PrivateKey(rawRepresentation: keyData))
        case .rsa: .rsa(try _RSA.Signing.PrivateKey(unsafeDERRepresentation: keyData))
        case .securityKeyP256, nil: throw PrivateKeyImportError.unsupportedKeyType(algorithm?.rawValue ?? "unknown")
        }
    }

    // MARK: OpenSSH format (PROTOCOL.key)

    private static let openSSHMagic = Data("openssh-key-v1\0".utf8)

    private static func openSSHPayload(_ text: String) throws -> Data {
        let body = text
            .components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("-----") }
            .joined()
            .filter { !$0.isWhitespace }
        guard let data = Data(base64Encoded: body), data.starts(with: openSSHMagic) else {
            throw PrivateKeyImportError.malformed("not base64 or no openssh-key-v1 header")
        }
        return data
    }

    private static func parseOpenSSH(_ data: Data, passphrase: String?) throws -> ParsedPrivateKey {
        do {
            var reader = SSHReader(data)
            _ = try reader.bytes(openSSHMagic.count)
            let cipherName = try reader.text()
            let kdfName = try reader.text()
            let kdfOptions = try reader.string()
            guard try reader.uint32() == 1 else { throw PrivateKeyImportError.malformed("more than one key") }
            let publicBlob = try reader.string()
            var encrypted = try reader.string()

            if cipherName != "none" {
                guard let cipher = OpenSSHCipher(rawValue: cipherName) else {
                    throw PrivateKeyImportError.unsupportedCipher(cipherName)
                }
                guard kdfName == "bcrypt" else { throw PrivateKeyImportError.invalidKDF }
                guard let passphrase, !passphrase.isEmpty else { throw PrivateKeyImportError.passphraseRequired }
                var options = SSHReader(kdfOptions)
                let salt = try options.string()
                let rounds = Int(try options.uint32())
                let derived = try BcryptPBKDF.derive(
                    password: Data(passphrase.utf8), salt: salt, rounds: rounds,
                    keyLength: cipher.keyLength + cipher.ivLength)
                let key = derived.prefix(cipher.keyLength)
                let iv = derived.suffix(cipher.ivLength)
                let tag = cipher.tagLength > 0 ? try reader.bytes(cipher.tagLength) : Data()
                encrypted = try cipher.decrypt(encrypted, key: Data(key), iv: Data(iv), tag: tag)
            }

            var section = SSHReader(encrypted)
            let check1 = try section.uint32()
            let check2 = try section.uint32()
            guard check1 == check2 else {
                throw cipherName == "none"
                    ? PrivateKeyImportError.malformed("check bytes differ") : PrivateKeyImportError.wrongPassphrase
            }
            let parsed = try parseOpenSSHPrivate(&section)
            let comment = try section.text()
            guard parsed.publicKeyBlob == publicBlob else {
                throw PrivateKeyImportError.malformed("public and private key differ")
            }
            return ParsedPrivateKey(
                algorithm: parsed.algorithm, publicKeyBlob: parsed.publicKeyBlob,
                keyData: parsed.keyData, comment: comment.isEmpty ? nil : comment)
        } catch is SSHWireError {
            throw PrivateKeyImportError.malformed("truncated")
        }
    }

    private static func parseOpenSSHPrivate(_ reader: inout SSHReader) throws -> ParsedPrivateKey {
        let type = try reader.text()
        guard let algorithm = SSHKeyAlgorithm(rawValue: type) else {
            if type.hasPrefix("sk-") { throw PrivateKeyImportError.securityKeyFile }
            throw PrivateKeyImportError.unsupportedKeyType(type)
        }
        switch algorithm {
        case .ed25519:
            _ = try reader.string()  // public key
            let secret = try reader.string()  // seed || public key
            guard secret.count == 64 else { throw PrivateKeyImportError.malformed("Ed25519 key size") }
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: secret.prefix(32))
            return parsed(.ed25519(key), algorithm: algorithm)
        case .ecdsaP256, .ecdsaP384, .ecdsaP521:
            guard try reader.text() == algorithm.curveName else {
                throw PrivateKeyImportError.malformed("curve doesn't match the key type")
            }
            _ = try reader.string()  // public point
            let scalar = try reader.mpint()
            let key: SigningKey = switch algorithm {
            case .ecdsaP256: .p256(try P256.Signing.PrivateKey(rawRepresentation: leftPad(scalar, to: 32)))
            case .ecdsaP384: .p384(try P384.Signing.PrivateKey(rawRepresentation: leftPad(scalar, to: 48)))
            default: .p521(try P521.Signing.PrivateKey(rawRepresentation: leftPad(scalar, to: 66)))
            }
            return parsed(key, algorithm: algorithm)
        case .rsa:
            let n = try reader.mpint()
            let e = try reader.mpint()
            let d = try reader.mpint()
            _ = try reader.mpint()  // iqmp
            let p = try reader.mpint()
            let q = try reader.mpint()
            let key = try _RSA.Signing.PrivateKey(n: n, e: e, d: d, p: p, q: q)
            return parsed(.rsa(key), algorithm: algorithm)
        case .securityKeyP256:
            throw PrivateKeyImportError.securityKeyFile
        }
    }

    // MARK: PEM

    private static func parsePEM(_ text: String) throws -> ParsedPrivateKey {
        if let key = try? P256.Signing.PrivateKey(pemRepresentation: text) { return parsed(.p256(key), algorithm: .ecdsaP256) }
        if let key = try? P384.Signing.PrivateKey(pemRepresentation: text) { return parsed(.p384(key), algorithm: .ecdsaP384) }
        if let key = try? P521.Signing.PrivateKey(pemRepresentation: text) { return parsed(.p521(key), algorithm: .ecdsaP521) }
        if let key = try? _RSA.Signing.PrivateKey(unsafePEMRepresentation: text) { return parsed(.rsa(key), algorithm: .rsa) }
        if let key = ed25519FromPKCS8(text) { return parsed(.ed25519(key), algorithm: .ed25519) }
        if let key = ecdsaFromSEC1(text) { return parsed(key, algorithm: key.algorithm) }
        throw PrivateKeyImportError.unsupportedKeyType("This PEM key's")
    }

    /// PKCS#8 Ed25519 (`openssl genpkey -algorithm ed25519`): a fixed 16-byte header and the 32-byte seed.
    private static func ed25519FromPKCS8(_ text: String) -> Curve25519.Signing.PrivateKey? {
        let body = text.components(separatedBy: .newlines).filter { !$0.hasPrefix("-----") }.joined()
        guard let der = Data(base64Encoded: body) else { return nil }
        let header = Data([0x30, 0x2E, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2B, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20])
        guard der.count == 48, der.starts(with: header) else { return nil }
        return try? Curve25519.Signing.PrivateKey(rawRepresentation: der.suffix(32))
    }

    /// SEC1 (`-----BEGIN EC PRIVATE KEY-----`) with the curve spelled out as parameters rather
    /// than named, as LibreSSL's `ssh-keygen -m PEM` writes it; CryptoKit only takes named curves.
    /// SEQUENCE { INTEGER 1, OCTET STRING privateKey, … }: the curve follows from the key's length.
    private static func ecdsaFromSEC1(_ text: String) -> SigningKey? {
        guard text.contains("BEGIN EC PRIVATE KEY") else { return nil }
        let body = text.components(separatedBy: .newlines).filter { !$0.hasPrefix("-----") }.joined()
        guard let der = Data(base64Encoded: body) else { return nil }
        var reader = DERReader(Array(der))
        guard let sequence = reader.element(tag: 0x30) else { return nil }
        var inner = DERReader(sequence)
        guard inner.element(tag: 0x02) == [1], let scalar = inner.element(tag: 0x04) else { return nil }
        let raw = Data(scalar)
        return switch raw.count {
        case 32: (try? P256.Signing.PrivateKey(rawRepresentation: raw)).map(SigningKey.p256)
        case 48: (try? P384.Signing.PrivateKey(rawRepresentation: raw)).map(SigningKey.p384)
        case 66: (try? P521.Signing.PrivateKey(rawRepresentation: raw)).map(SigningKey.p521)
        default: nil
        }
    }

    // MARK: Helpers

    private static func parsed(_ key: SigningKey, algorithm: SSHKeyAlgorithm) -> ParsedPrivateKey {
        let keyData: Data = switch key {
        case .p256(let key): key.rawRepresentation
        case .p384(let key): key.rawRepresentation
        case .p521(let key): key.rawRepresentation
        case .ed25519(let key): key.rawRepresentation
        case .rsa(let key): key.derRepresentation
        case .secureEnclave, .securityKey: preconditionFailure("not a software key")
        }
        return ParsedPrivateKey(algorithm: algorithm, publicKeyBlob: key.publicKeyBlob, keyData: keyData, comment: nil)
    }

    private static func leftPad(_ data: Data, to length: Int) throws -> Data {
        guard data.count <= length else { throw PrivateKeyImportError.malformed("private scalar too long") }
        return Data(repeating: 0, count: length - data.count) + data
    }
}

/// Reads DER elements (definite lengths only).
private struct DERReader {
    let bytes: [UInt8]
    var position = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    mutating func element(tag: UInt8) -> [UInt8]? {
        guard position + 2 <= bytes.count, bytes[position] == tag else { return nil }
        var length = Int(bytes[position + 1])
        position += 2
        if length & 0x80 != 0 {
            let count = length & 0x7F
            guard count <= 3, position + count <= bytes.count else { return nil }
            length = bytes[position..<position + count].reduce(0) { $0 << 8 | Int($1) }
            position += count
        }
        guard position + length <= bytes.count else { return nil }
        defer { position += length }
        return Array(bytes[position..<position + length])
    }
}

/// The ciphers ssh-keygen encrypts private keys with.
private enum OpenSSHCipher: String {
    case aes128ctr = "aes128-ctr", aes192ctr = "aes192-ctr", aes256ctr = "aes256-ctr"
    case aes128cbc = "aes128-cbc", aes192cbc = "aes192-cbc", aes256cbc = "aes256-cbc"
    case aes128gcm = "aes128-gcm@openssh.com", aes256gcm = "aes256-gcm@openssh.com"

    var keyLength: Int {
        switch self {
        case .aes128ctr, .aes128cbc, .aes128gcm: 16
        case .aes192ctr, .aes192cbc: 24
        case .aes256ctr, .aes256cbc, .aes256gcm: 32
        }
    }

    var ivLength: Int {
        switch self {
        case .aes128gcm, .aes256gcm: 12
        default: 16
        }
    }

    var tagLength: Int {
        switch self {
        case .aes128gcm, .aes256gcm: 16
        default: 0
        }
    }

    func decrypt(_ data: Data, key: Data, iv: Data, tag: Data) throws -> Data {
        switch self {
        case .aes128gcm, .aes256gcm:
            do {
                let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: iv), ciphertext: data, tag: tag)
                return try AES.GCM.open(box, using: SymmetricKey(data: key))
            } catch {
                throw PrivateKeyImportError.wrongPassphrase
            }
        case .aes128ctr, .aes192ctr, .aes256ctr:
            return try commonCrypto(mode: CCMode(kCCModeCTR), data, key: key, iv: iv)
        case .aes128cbc, .aes192cbc, .aes256cbc:
            return try commonCrypto(mode: CCMode(kCCModeCBC), data, key: key, iv: iv)
        }
    }

    private func commonCrypto(mode: CCMode, _ data: Data, key: Data, iv: Data) throws -> Data {
        guard data.count % kCCBlockSizeAES128 == 0 else { throw PrivateKeyImportError.malformed("encrypted length") }
        var cryptor: CCCryptorRef?
        let created = key.withUnsafeBytes { key in
            iv.withUnsafeBytes { iv in
                CCCryptorCreateWithMode(
                    CCOperation(kCCDecrypt), mode, CCAlgorithm(kCCAlgorithmAES), CCPadding(ccNoPadding),
                    iv.baseAddress, key.baseAddress, key.count, nil, 0, 0,
                    mode == CCMode(kCCModeCTR) ? CCModeOptions(kCCModeOptionCTR_BE) : 0, &cryptor)
            }
        }
        guard created == kCCSuccess, let cryptor else { throw PrivateKeyImportError.malformed("cipher setup") }
        defer { CCCryptorRelease(cryptor) }
        var output = Data(count: data.count)
        var moved = 0
        let status = output.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in
                CCCryptorUpdate(cryptor, input.baseAddress, input.count, out.baseAddress, out.count, &moved)
            }
        }
        guard status == kCCSuccess, moved == data.count else { throw PrivateKeyImportError.malformed("decryption") }
        return output
    }
}

/// RSA keys for SSH: the public blob and rsa-sha2-256/512 signatures.
enum OpenSSHRSA {
    static func publicKeyBlob(_ key: _RSA.Signing.PrivateKey) -> Data {
        // The primitives of a key we built ourselves are always available.
        let primitives = try! key.publicKey.getKeyPrimitives()
        return OpenSSH.rsaBlob(n: primitives.modulus, e: primitives.publicExponent)
    }
}
