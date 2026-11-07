import CryptoKit
import Foundation

/// Blowfish, as far as bcrypt_pbkdf needs it (OpenBSD's blf.c).
///
/// The state lives in raw memory: with arrays, a debug build took seconds for ssh-keygen's
/// default 16 rounds.
final class Blowfish {
    /// P-array (18 words), then the four S-boxes (256 words each).
    private let state: UnsafeMutablePointer<UInt32>
    private let s: UnsafeMutablePointer<UInt32>

    init() {
        state = .allocate(capacity: 18 + 1024)
        s = state + 18
        let initial = Blowfish.initialP + Blowfish.initialS0 + Blowfish.initialS1 + Blowfish.initialS2 + Blowfish.initialS3
        initial.withUnsafeBufferPointer { state.initialize(from: $0.baseAddress!, count: initial.count) }
    }

    deinit { state.deallocate() }

    /// Reads the next big-endian word from `data`, wrapping around at its end.
    static func streamToWord(_ data: UnsafeBufferPointer<UInt8>, _ position: inout Int) -> UInt32 {
        var word: UInt32 = 0
        for _ in 0..<4 {
            if position >= data.count { position = 0 }
            word = word << 8 | UInt32(data[position])
            position += 1
        }
        return word
    }

    static func streamToWord(_ data: [UInt8], _ position: inout Int) -> UInt32 {
        data.withUnsafeBufferPointer { streamToWord($0, &position) }
    }

    @inline(__always)
    private func f(_ x: UInt32) -> UInt32 {
        ((s[Int(x >> 24)] &+ s[256 + Int((x >> 16) & 0xFF)]) ^ s[512 + Int((x >> 8) & 0xFF)])
            &+ s[768 + Int(x & 0xFF)]
    }

    @inline(__always)
    func encipher(_ left: inout UInt32, _ right: inout UInt32) {
        let p = state
        var l = left ^ p[0]
        var r = right
        var round = 1
        while round <= 16 {
            r ^= f(l) ^ p[round]
            l ^= f(r) ^ p[round + 1]
            round += 2
        }
        left = r ^ p[17]
        right = l
    }

    /// Blowfish_expandstate (with `data`, the salt) and Blowfish_expand0state (without).
    func expand(data: [UInt8]? = nil, key: [UInt8]) {
        key.withUnsafeBufferPointer { key in
            var position = 0
            for i in 0..<18 { state[i] ^= Self.streamToWord(key, &position) }
        }
        (data ?? []).withUnsafeBufferPointer { data in
            var position = 0
            var l: UInt32 = 0
            var r: UInt32 = 0
            for i in stride(from: 0, to: 18 + 1024, by: 2) {
                if data.count > 0 {
                    l ^= Self.streamToWord(data, &position)
                    r ^= Self.streamToWord(data, &position)
                }
                encipher(&l, &r)
                state[i] = l
                state[i + 1] = r
            }
        }
    }
}

/// OpenBSD's bcrypt_pbkdf, which OpenSSH uses to derive the key of passphrase-protected private keys.
enum BcryptPBKDF {
    private static let hashSize = 32

    static func derive(password: Data, salt: Data, rounds: Int, keyLength: Int) throws -> Data {
        guard rounds >= 1, !password.isEmpty, !salt.isEmpty, keyLength > 0,
              keyLength <= hashSize * hashSize
        else { throw PrivateKeyImportError.invalidKDF }

        let sha2pass = Array(SHA512.hash(data: password))
        let stride = (keyLength + hashSize - 1) / hashSize
        let amount = (keyLength + stride - 1) / stride
        var key = [UInt8](repeating: 0, count: keyLength)
        var remaining = keyLength

        var count: UInt32 = 1
        while remaining > 0 {
            var countSalt = salt
            withUnsafeBytes(of: count.bigEndian) { countSalt.append(contentsOf: $0) }
            var sha2salt = Array(SHA512.hash(data: countSalt))
            var tmp = hash(sha2pass: sha2pass, sha2salt: sha2salt)
            var out = tmp
            for _ in 1..<max(rounds, 1) {
                sha2salt = Array(SHA512.hash(data: tmp))
                tmp = hash(sha2pass: sha2pass, sha2salt: sha2salt)
                for j in 0..<out.count { out[j] ^= tmp[j] }
            }
            // Not PBKDF2: the output is spread over the key non-linearly.
            var written = 0
            for i in 0..<min(amount, remaining) {
                let destination = i * stride + Int(count - 1)
                if destination >= keyLength { break }
                key[destination] = out[i]
                written += 1
            }
            remaining -= written
            count += 1
        }
        return Data(key)
    }

    private static func hash(sha2pass: [UInt8], sha2salt: [UInt8]) -> [UInt8] {
        let state = Blowfish()
        state.expand(data: sha2salt, key: sha2pass)
        for _ in 0..<64 {
            state.expand(key: sha2salt)
            state.expand(key: sha2pass)
        }
        let magic = Array("OxychromaticBlowfishSwatDynamite".utf8)
        var position = 0
        var words = (0..<8).map { _ in Blowfish.streamToWord(magic, &position) }
        for _ in 0..<64 {
            for i in Swift.stride(from: 0, to: 8, by: 2) {
                var l = words[i], r = words[i + 1]
                state.encipher(&l, &r)
                words[i] = l
                words[i + 1] = r
            }
        }
        // Little-endian out, as OpenBSD does.
        return words.flatMap { word in (0..<4).map { UInt8(truncatingIfNeeded: word >> (8 * $0)) } }
    }
}
