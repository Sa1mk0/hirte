import Foundation
import Testing
@testable import HerdrKit

private let fixedDate = Date(timeIntervalSince1970: 1_762_765_812)  // 2026-11-10 09:10:12 UTC

@Test func uploadFileNamesAreUniqueShellSafeAndKeepTheExtension() {
    let name = RemoteUpload.fileName(stem: "IMG 0042 (Mo's) äöü", extension: "HEIC", date: fixedDate, nonce: 0xbeef)
    #expect(name.hasPrefix("IMG-0042-Mo-s-"))
    #expect(name.hasSuffix("-beef.heic"))
    #expect(name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." })
    #expect(name.filter { $0 == "." }.count == 1)
    // The stamp is the local time: 15 digits with the dash, between the stem and the nonce.
    let parts = name.dropLast(10).split(separator: "-")
    #expect(parts.suffix(2).map(\.count) == [8, 6])

    #expect(RemoteUpload.fileName(stem: "", extension: "", date: fixedDate, nonce: 1).hasPrefix("file-"))
    #expect(!RemoteUpload.fileName(stem: "---", extension: "../x", date: fixedDate, nonce: 1).contains("/"))
    #expect(RemoteUpload.fileName(stem: String(repeating: "a", count: 80), extension: "png", date: fixedDate, nonce: 1).count
            == 40 + 1 + 15 + 1 + 4 + 4)
}

@Test func uploadCommandStoresExactlyTheBytesAndPrintsThePath() {
    let command = RemoteUpload.command(fileName: "shot-20261110-091012-beef.png", byteCount: 12345)
    #expect(command.hasPrefix("sh -c '"))
    #expect(command.hasSuffix("'"))
    #expect(command.contains("umask 077"))
    #expect(command.contains("mkdir -p \"$d\""))
    #expect(command.contains("f=\"$d/shot-20261110-091012-beef.png\""))
    #expect(command.contains("head -c 12345 > \"$f\""))
    // A short upload (the line dropped) must fail and leave no file, never a path to paste.
    #expect(command.contains("= 12345 ] || { rm -f \"$f\""))
    #expect(command.contains("printf \"%s\\n\" \"$f\""))
    // The outer quotes hold: no stray single quote inside.
    #expect(command.dropFirst(7).dropLast().filter { $0 == "'" }.isEmpty)
}

@Test func uploadOutputMustBeOneAbsolutePath() {
    #expect(RemoteUpload.path(fromOutput: "/home/me/.cache/hirte/uploads/a.png\n") == "/home/me/.cache/hirte/uploads/a.png")
    #expect(RemoteUpload.path(fromOutput: "") == nil)
    #expect(RemoteUpload.path(fromOutput: "motd\n/home/me/a.png\n") == nil)
    #expect(RemoteUpload.path(fromOutput: "a.png") == nil)
}

@Test func pastedPathsAreQuotedForAPlainShellOnly() {
    let plain = "/Users/me/.cache/hirte/uploads/shot-20261110-091012-beef.png"
    #expect(RemoteUpload.shellQuoted(plain) == plain)
    #expect(RemoteUpload.shellQuoted("/Users/Simon Kopp/a.png") == "'/Users/Simon Kopp/a.png'")
    #expect(RemoteUpload.shellQuoted("/tmp/it's.png") == "'/tmp/it'\\''s.png'")
    #expect(RemoteUpload.shellQuoted("/tmp/$HOME;rm") == "'/tmp/$HOME;rm'")
    #expect(RemoteUpload.pasteText(path: plain, bracketed: true) == plain + " ")
    #expect(RemoteUpload.pasteText(path: "/Users/Simon Kopp/a.png", bracketed: false) == "'/Users/Simon Kopp/a.png' ")
    #expect(RemoteUpload.pasteText(path: "/Users/Simon Kopp/a.png", bracketed: true) == "/Users/Simon Kopp/a.png ")
}

@Test func imageFormatsAreRecognizedByTheirFirstBytes() {
    func data(_ bytes: [UInt8]) -> Data { Data(bytes + [UInt8](repeating: 0, count: 16)) }
    #expect(RemoteUpload.imageExtension(data([0xFF, 0xD8, 0xFF, 0xE0])) == "jpg")
    #expect(RemoteUpload.imageExtension(data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) == "png")
    #expect(RemoteUpload.imageExtension(data(Array("GIF89a".utf8))) == "gif")
    #expect(RemoteUpload.imageExtension(data(Array("RIFF".utf8) + [0, 0, 0, 0] + Array("WEBP".utf8))) == "webp")
    #expect(RemoteUpload.imageExtension(data([0, 0, 0, 0x18] + Array("ftypheic".utf8))) == "heic")
    #expect(RemoteUpload.imageExtension(data([0, 0, 0, 0x18] + Array("ftypmif1".utf8))) == "heic")
    #expect(RemoteUpload.imageExtension(data(Array("%PDF-1.7".utf8))) == nil)
    #expect(RemoteUpload.imageExtension(Data([0xFF, 0xD8])) == nil)
}
