import CryptoKit
import Foundation

/// OpenSSH wire-format helpers for public keys.
public enum OpenSSH {
    public static let ecdsaP256KeyType = "ecdsa-sha2-nistp256"

    /// The SSH public key blob of a P-256 key: string(type) || string("nistp256") || string(Q).
    public static func publicKeyBlob(_ key: P256.Signing.PublicKey) -> Data {
        ecdsaBlob(type: SSHKeyAlgorithm.ecdsaP256, point: key.x963Representation)
    }

    static func ecdsaBlob(type: SSHKeyAlgorithm, point: Data) -> Data {
        var blob = SSHWriter()
        blob.string(type.rawValue)
        blob.string(type.curveName!)
        blob.string(point)
        return blob.data
    }

    static func ed25519Blob(_ key: Curve25519.Signing.PublicKey) -> Data {
        var blob = SSHWriter()
        blob.string(SSHKeyAlgorithm.ed25519.rawValue)
        blob.string(key.rawRepresentation)
        return blob.data
    }

    /// `ssh-rsa`: string(type) || mpint(e) || mpint(n).
    static func rsaBlob(n: Data, e: Data) -> Data {
        var blob = SSHWriter()
        blob.string(SSHKeyAlgorithm.rsa.rawValue)
        blob.mpint(e)
        blob.mpint(n)
        return blob.data
    }

    /// `sk-ecdsa-sha2-nistp256@openssh.com`: like ECDSA, followed by string(application).
    static func securityKeyBlob(point: Data, application: String) -> Data {
        var blob = SSHWriter()
        blob.string(SSHKeyAlgorithm.securityKeyP256.rawValue)
        blob.string("nistp256")
        blob.string(point)
        blob.string(application)
        return blob.data
    }

    /// The key type named at the start of a blob, e.g. `ssh-ed25519`.
    static func keyType(ofBlob blob: Data) -> String? {
        var reader = SSHReader(blob)
        return try? reader.text()
    }

    /// A line for `authorized_keys`: `ecdsa-sha2-nistp256 AAAA… comment`.
    public static func authorizedKeysLine(_ key: P256.Signing.PublicKey, comment: String?) -> String {
        authorizedKeysLine(blob: publicKeyBlob(key), comment: comment)
    }

    /// A line for `authorized_keys` from any public key blob.
    public static func authorizedKeysLine(blob: Data, comment: String?) -> String {
        var line = "\(keyType(ofBlob: blob) ?? "unknown") \(blob.base64EncodedString())"
        if let comment, !comment.isEmpty {
            // Comments may hold spaces, but not line breaks.
            line += " " + comment.replacingOccurrences(of: "\n", with: " ")
        }
        return line
    }

    /// `SHA256:…` as `ssh-keygen -l` prints it.
    public static func sha256Fingerprint(blob: Data) -> String {
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
        return "SHA256:" + digest.trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    /// Fingerprint of any OpenSSH public key line (`type base64 [comment]`), or nil if malformed.
    public static func sha256Fingerprint(publicKeyLine: String) -> String? {
        let parts = publicKeyLine.split(separator: " ")
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else { return nil }
        return sha256Fingerprint(blob: blob)
    }
}
