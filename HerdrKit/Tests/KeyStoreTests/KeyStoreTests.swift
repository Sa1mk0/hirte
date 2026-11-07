import CryptoKit
import Foundation
import Testing
@testable import KeyStore

@Test func generateListRenameDelete() throws {
    let store = KeyStore(storage: InMemoryKeyStorage())
    let info = try store.generateKey(label: "phone")
    #expect(try store.keys().map(\.id) == [info.id])

    try store.rename(id: info.id, to: "iPhone")
    #expect(try store.keys().first?.label == "iPhone")

    let key = try store.signingKey(for: info.id)
    #expect(key.publicKeyBlob == info.publicKeyBlob)
    #expect(info.algorithm == .ecdsaP256)

    try store.deleteKey(id: info.id)
    #expect(try store.keys().isEmpty)
}

/// Keys saved before other key types existed only stored the P-256 point.
@Test func readsOldRecords() throws {
    let key = P256.Signing.PrivateKey()
    let old = """
        {"info":{"id":"\(UUID().uuidString)","label":"old","kind":"software","requiresBiometry":false,
        "createdAt":0,"publicKeyX963":"\(key.publicKey.x963Representation.base64EncodedString())"},
        "keyData":"\(key.rawRepresentation.base64EncodedString())"}
        """
    let storage = InMemoryKeyStorage()
    try storage.save(Data(old.utf8), account: "old")
    let store = KeyStore(storage: storage)
    let info = try #require(try store.keys().first)
    #expect(info.publicKeyBlob == OpenSSH.publicKeyBlob(key.publicKey))
    #expect(!info.isImported)
    guard case .p256(let loaded) = try store.signingKey(for: info.id) else {
        Issue.record("expected a P-256 key")
        return
    }
    let message = Data("hello".utf8)
    #expect(key.publicKey.isValidSignature(try loaded.signature(for: message), for: message))
}

@Test func ed25519KeySigns() throws {
    let store = KeyStore(storage: InMemoryKeyStorage())
    let info = try store.generateEd25519Key(label: "ed")
    #expect(info.algorithm == .ed25519)
    #expect(info.authorizedKeysLine.hasPrefix("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI"))
    guard case .ed25519(let key) = try store.signingKey(for: info.id) else {
        Issue.record("expected an Ed25519 key")
        return
    }
    let message = Data("hello".utf8)
    #expect(key.publicKey.isValidSignature(try key.signature(for: message), for: message))
}

@Test(.enabled(if: KeyStore.isSecureEnclaveAvailable))
func secureEnclaveKeySigns() throws {
    let store = KeyStore(storage: InMemoryKeyStorage())
    let info = try store.generateKey(label: "se", allowSoftwareFallback: false)
    #expect(info.kind == .secureEnclave)
    guard case .secureEnclave(let key) = try store.signingKey(for: info.id) else {
        Issue.record("expected a Secure Enclave key")
        return
    }
    let message = Data("hello".utf8)
    #expect(key.publicKey.isValidSignature(try key.signature(for: message), for: message))
}

@Test func rejectsWhatIsNotAPrivateKey() {
    #expect(throws: PrivateKeyImportError.notAPrivateKey) { try PrivateKeyParser.parse("hello") }
    #expect(throws: PrivateKeyImportError.publicKeyOnly) {
        try PrivateKeyParser.parse("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA me")
    }
}

// MARK: - Security keys

/// A software stand-in for a security key, answering like WebAuthn does on iOS.
struct FakeSecurityKey {
    let key = P256.Signing.PrivateKey()
    let credentialID = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
    let relyingParty = "hirte.dev"

    var attestationObject: Data {
        var cose = CBORWriter()
        cose.map(5)
        cose.int(1); cose.int(2)
        cose.int(3); cose.int(-7)
        cose.int(-1); cose.int(1)
        cose.int(-2); cose.bytes(key.publicKey.rawRepresentation.prefix(32))
        cose.int(-3); cose.bytes(key.publicKey.rawRepresentation.suffix(32))

        var authData = Data(SHA256.hash(data: Data(relyingParty.utf8)))
        authData.append(0x41)  // UP, AT
        authData.append(contentsOf: [0, 0, 0, 0])
        authData.append(Data(count: 16))  // AAGUID
        authData.append(contentsOf: [UInt8(credentialID.count >> 8), UInt8(credentialID.count & 0xFF)])
        authData.append(credentialID)
        authData.append(cose.data)

        var object = CBORWriter()
        object.map(3)
        object.text("fmt"); object.text("none")
        object.text("attStmt"); object.map(0)
        object.text("authData"); object.bytes(authData)
        return object.data
    }

    func assert(challenge: Data, counter: UInt32 = 7) throws -> WebAuthnAssertion {
        let encoded = challenge.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let clientData = Data(
            #"{"type":"webauthn.get","challenge":"\#(encoded)","origin":"https://\#(relyingParty)"}"#.utf8)
        var authData = Data(SHA256.hash(data: Data(relyingParty.utf8)))
        authData.append(0x01)  // UP
        withUnsafeBytes(of: counter.bigEndian) { authData.append(contentsOf: $0) }
        let signature = try key.signature(for: authData + Data(SHA256.hash(data: clientData)))
        return WebAuthnAssertion(
            authenticatorData: authData, clientDataJSON: clientData, signature: signature.derRepresentation)
    }
}

struct CBORWriter {
    var data = Data()
    private mutating func head(_ major: UInt8, _ value: UInt64) {
        if value < 24 { data.append(major << 5 | UInt8(value)) }
        else if value < 256 { data.append(contentsOf: [major << 5 | 24, UInt8(value)]) }
        else { data.append(contentsOf: [major << 5 | 25, UInt8(value >> 8), UInt8(value & 0xFF)]) }
    }
    mutating func int(_ value: Int) { value >= 0 ? head(0, UInt64(value)) : head(1, UInt64(-1 - value)) }
    mutating func bytes(_ value: Data) { head(2, UInt64(value.count)); data.append(value) }
    mutating func text(_ value: String) { head(3, UInt64(value.utf8.count)); data.append(contentsOf: value.utf8) }
    mutating func map(_ count: Int) { head(5, UInt64(count)) }
}

@Test func securityKeyRegistrationAndSignature() async throws {
    let fake = FakeSecurityKey()
    let registration = try SecurityKeyRegistration(
        attestationObject: fake.attestationObject, credentialID: fake.credentialID, relyingParty: "hirte.dev")
    #expect(registration.credentialID == fake.credentialID)

    let store = KeyStore(storage: InMemoryKeyStorage())
    let info = try store.addSecurityKey(registration, label: "yubikey")
    #expect(info.algorithm == .securityKeyP256)
    #expect(info.authorizedKeysLine.hasPrefix("sk-ecdsa-sha2-nistp256@openssh.com AAAA"))

    #expect(throws: KeyStoreError.self) { try store.signingKey(for: info.id) }
    let key = try store.signingKey(for: info.id) { id, challenge in
        #expect(id == fake.credentialID)
        return try fake.assert(challenge: challenge)
    }
    guard case .securityKey(let signer) = key else {
        Issue.record("expected a security key")
        return
    }
    #expect(signer.application == "hirte.dev")
    let body = try await signer.signatureBody(for: Data("ssh login".utf8))
    #expect(!body.isEmpty)
}

@Test func securityKeyRejectsForeignClientData() throws {
    let fake = FakeSecurityKey()
    let message = Data("ssh login".utf8)
    let good = try fake.assert(challenge: message)
    let other = try fake.assert(challenge: Data("something else".utf8))
    #expect(throws: SecurityKeyError.self) {
        try SecurityKeySigner.signatureBody(
            message: message, assertion: other, application: "hirte.dev", publicKey: fake.key.publicKey)
    }
    #expect(throws: SecurityKeyError.self) {
        try SecurityKeySigner.signatureBody(
            message: message, assertion: good, application: "example.com", publicKey: fake.key.publicKey)
    }
    #expect(throws: Never.self) {
        try SecurityKeySigner.signatureBody(
            message: message, assertion: good, application: "hirte.dev", publicKey: fake.key.publicKey)
    }
}

#if os(macOS)
// MARK: - Against ssh-keygen

private func run(_ tool: String, _ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw NSError(domain: tool, code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: output])
    }
    return output
}

private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hirte-keys-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

/// Our authorized_keys line and fingerprint must match what ssh-keygen says about it.
@Test func matchesSSHKeygen() throws {
    let store = KeyStore(storage: InMemoryKeyStorage())
    for info in [try store.generateKey(label: "my phone"), try store.generateEd25519Key(label: "my phone")] {
        let file = try temporaryDirectory().appendingPathComponent("key.pub")
        try info.authorizedKeysLine.write(to: file, atomically: true, encoding: .utf8)
        let out = try run("/usr/bin/ssh-keygen", ["-l", "-E", "sha256", "-f", file.path])
        // "256 SHA256:… my phone (ECDSA)"
        #expect(out.hasPrefix("256 \(info.fingerprint) my phone ("), "ssh-keygen said: \(out)")
    }
}

struct ImportCase: CustomTestStringConvertible, Sendable {
    let type: String
    let bits: String?
    let format: String?
    let passphrase: String?
    let cipher: String?
    var testDescription: String {
        [type, bits, format, passphrase == nil ? nil : "passphrase", cipher].compactMap(\.self).joined(separator: " ")
    }
}

private let importCases: [ImportCase] = [
    .init(type: "ed25519", bits: nil, format: nil, passphrase: nil, cipher: nil),
    .init(type: "ed25519", bits: nil, format: nil, passphrase: "correct horse", cipher: nil),
    .init(type: "ed25519", bits: nil, format: nil, passphrase: "pw", cipher: "aes256-gcm@openssh.com"),
    .init(type: "ed25519", bits: nil, format: nil, passphrase: "pw", cipher: "aes128-cbc"),
    .init(type: "ecdsa", bits: "256", format: nil, passphrase: nil, cipher: nil),
    .init(type: "ecdsa", bits: "384", format: nil, passphrase: "pw", cipher: nil),
    .init(type: "ecdsa", bits: "521", format: nil, passphrase: nil, cipher: nil),
    .init(type: "ecdsa", bits: "256", format: "PEM", passphrase: nil, cipher: nil),
    .init(type: "ecdsa", bits: "384", format: "PKCS8", passphrase: nil, cipher: nil),
    .init(type: "rsa", bits: "2048", format: nil, passphrase: nil, cipher: nil),
    .init(type: "rsa", bits: "3072", format: nil, passphrase: "pw", cipher: nil),
    .init(type: "rsa", bits: "2048", format: "PEM", passphrase: nil, cipher: nil),
    .init(type: "rsa", bits: "2048", format: "PKCS8", passphrase: nil, cipher: nil),
]

/// Keys made by ssh-keygen import with the same public key, and sign.
@Test(arguments: importCases)
func importsSSHKeygenKeys(_ c: ImportCase) throws {
    let file = try temporaryDirectory().appendingPathComponent("id")
    var arguments = ["-q", "-t", c.type, "-C", "laptop", "-N", c.passphrase ?? "", "-f", file.path, "-a", "4"]
    if let bits = c.bits { arguments += ["-b", bits] }
    if let format = c.format { arguments += ["-m", format] }
    if let cipher = c.cipher { arguments += ["-Z", cipher] }
    _ = try run("/usr/bin/ssh-keygen", arguments)

    let text = try String(contentsOf: file, encoding: .utf8)
    let publicLine = try String(contentsOf: file.appendingPathExtension("pub"), encoding: .utf8)
    #expect(PrivateKeyParser.needsPassphrase(text) == (c.passphrase != nil && c.format == nil))
    if c.passphrase != nil {
        #expect(throws: PrivateKeyImportError.passphraseRequired) { try PrivateKeyParser.parse(text) }
        #expect(throws: PrivateKeyImportError.wrongPassphrase) { try PrivateKeyParser.parse(text, passphrase: "nope") }
    }
    let parsed = try PrivateKeyParser.parse(text, passphrase: c.passphrase)
    #expect(parsed.fingerprint == OpenSSH.sha256Fingerprint(publicKeyLine: publicLine))
    if c.format == nil { #expect(parsed.comment == "laptop") }

    let store = KeyStore(storage: InMemoryKeyStorage())
    let info = try store.importKey(parsed, label: "laptop")
    #expect(info.isImported)
    #expect(info.authorizedKeysLine == publicLine.trimmingCharacters(in: .whitespacesAndNewlines))
    if let bits = c.bits, c.type == "rsa" { #expect(info.rsaBits == Int(bits)) }
    #expect(try store.signingKey(for: info.id).publicKeyBlob == info.publicKeyBlob)
}

@Test func importsOpenSSLEd25519() throws {
    let file = try temporaryDirectory().appendingPathComponent("ed.pem")
    guard FileManager.default.fileExists(atPath: "/opt/homebrew/bin/openssl") else { return }
    _ = try run("/opt/homebrew/bin/openssl", ["genpkey", "-algorithm", "ed25519", "-out", file.path])
    let parsed = try PrivateKeyParser.parse(try String(contentsOf: file, encoding: .utf8))
    #expect(parsed.algorithm == .ed25519)
}

/// ssh-keygen's default work factor (16 rounds) must not make importing slow.
@Test func bcryptDefaultRoundsAreQuickEnough() throws {
    let file = try temporaryDirectory().appendingPathComponent("id")
    _ = try run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "pw", "-f", file.path])
    let start = Date()
    _ = try PrivateKeyParser.parse(try String(contentsOf: file, encoding: .utf8), passphrase: "pw")
    let elapsed = Date().timeIntervalSince(start)
    #expect(elapsed < 10, "took \(elapsed)s")
    print("bcrypt_pbkdf, 16 rounds: \(elapsed)s")
}
#endif
