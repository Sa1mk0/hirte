import Foundation

/// Builds SSH wire-format data (RFC 4251: uint32, string, mpint).
struct SSHWriter {
    private(set) var data = Data()

    mutating func uint8(_ value: UInt8) { data.append(value) }

    mutating func uint32(_ value: UInt32) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }

    mutating func string(_ bytes: some DataProtocol) {
        uint32(UInt32(bytes.count))
        data.append(contentsOf: bytes)
    }

    mutating func string(_ text: String) { string(Data(text.utf8)) }

    /// A non-negative big-endian integer: leading zeros dropped, a zero byte added if the top bit is set.
    mutating func mpint(_ magnitude: some DataProtocol) {
        var bytes = Array(magnitude.drop { $0 == 0 })
        if let first = bytes.first, first & 0x80 != 0 { bytes.insert(0, at: 0) }
        string(bytes)
    }
}

/// Reads SSH wire-format data.
struct SSHReader {
    private let data: Data
    private(set) var offset: Int

    init(_ data: Data) {
        self.data = Data(data)
        offset = 0
    }

    var remaining: Int { data.count - offset }
    var isAtEnd: Bool { remaining == 0 }
    var rest: Data { data[(data.startIndex + offset)...] }

    mutating func bytes(_ count: Int) throws -> Data {
        guard count >= 0, count <= remaining else { throw SSHWireError.truncated }
        let start = data.startIndex + offset
        offset += count
        return Data(data[start..<start + count])
    }

    mutating func uint8() throws -> UInt8 { try bytes(1)[0] }

    mutating func uint32() throws -> UInt32 {
        try bytes(4).reduce(0) { $0 << 8 | UInt32($1) }
    }

    mutating func string() throws -> Data { try bytes(Int(try uint32())) }

    mutating func text() throws -> String {
        guard let text = String(data: try string(), encoding: .utf8) else { throw SSHWireError.invalidText }
        return text
    }

    /// An mpint's magnitude, without the sign byte.
    mutating func mpint() throws -> Data {
        Data(try string().drop { $0 == 0 })
    }
}

enum SSHWireError: Error {
    case truncated
    case invalidText
}
