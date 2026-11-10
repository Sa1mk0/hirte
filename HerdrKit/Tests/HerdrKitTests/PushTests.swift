import Foundation
import Testing
@testable import HerdrKit

private let hostID = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!

@Test func tokenFileIsTheContractsJSON() throws {
    let file = PushTokenFile(
        token: "a1b2c3", environment: "development", bundleID: "io.github.sa1mk0.hirte.dev",
        hostID: hostID, device: "iPhone", updatedMs: 1_762_765_812_000)
    let json = String(decoding: try file.encoded(), as: UTF8.self)
    #expect(json == #"{"bundle_id":"io.github.sa1mk0.hirte.dev","device":"iPhone","environment":"development","#
            + #""host_id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","token":"a1b2c3","updated_ms":1762765812000,"v":1}"#)
    // What a sender reads back is the same file.
    #expect(try JSONDecoder().decode(PushTokenFile.self, from: file.encoded()) == file)
}

@Test func installationIDsAreLowercaseHexAndDashes() {
    #expect(RemotePush.isInstallationID("6f9619ff-8b86-d011-b42d-00c04fc964ff"))
    #expect(RemotePush.isInstallationID("abc-123"))
    #expect(!RemotePush.isInstallationID(""))
    #expect(!RemotePush.isInstallationID("6F9619FF-8B86-D011-B42D-00C04FC964FF"))
    #expect(!RemotePush.isInstallationID("../x"))
    #expect(!RemotePush.isInstallationID("a'; rm -rf ~ '"))
    #expect(!RemotePush.isInstallationID("a b"))
    #expect(!RemotePush.isInstallationID(String(repeating: "a", count: 65)))
}

@Test func writeCommandStoresTheFileAtomicallyWithoutItsContent() {
    let id = "6f9619ff-8b86-d011-b42d-00c04fc964ff"
    let command = RemotePush.writeCommand(installationID: id, byteCount: 321)
    #expect(command.hasPrefix("sh -c '"))
    #expect(command.hasSuffix("'"))
    #expect(command.contains("umask 077"))
    #expect(command.contains("d=\"$HOME/.config/hirte/push\""))
    #expect(command.contains("mkdir -p \"$d\" && chmod 700 \"$d\""))
    #expect(command.contains("t=\"$d/.\(id).tmp\""))
    // A symlink left at the temporary path would be followed by `>`: it goes first.
    #expect(command.contains("rm -f \"$t\"; head -c 321 > \"$t\""))
    // A short write (the line dropped) must fail and leave no file behind.
    #expect(command.contains("= 321 ] || { rm -f \"$t\""))
    #expect(command.contains("mv -f \"$t\" \"$d/\(id).json\""))
    // The outer quotes hold: no stray single quote inside. The content goes through stdin: nothing
    // but the id and the count varies, whatever the file says.
    #expect(command.dropFirst(7).dropLast().filter { $0 == "'" }.isEmpty)
    #expect(command == RemotePush.writeCommand(installationID: id, byteCount: 321))
    #expect(command.components(separatedBy: id).count == 3)
    #expect(command.components(separatedBy: "321").count == 3)
}

@Test func deleteCommandRemovesTheFileAndItsTemporary() {
    let command = RemotePush.deleteCommand(installationID: "abc-123")
    #expect(command == "sh -c 'rm -f \"$HOME/.config/hirte/push/abc-123.json\" \"$HOME/.config/hirte/push/.abc-123.tmp\"'")
}

private func userInfo(_ json: String) throws -> [AnyHashable: Any] {
    let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
    return try #require(object as? [AnyHashable: Any])
}

private let payload = #"""
{"aps":{"alert":{"title":"shop-api","body":"Run the database migration?"},"sound":"default",
 "thread-id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","interruption-level":"time-sensitive"},
 "hirte":{"v":1,"host_id":"6f9619ff-8b86-d011-b42d-00c04fc964ff","address":"t7","created_ms":1762763352000}}
"""#

@Test func payloadParsesIntoARoute() throws {
    let route = try #require(PushRoute(userInfo: try userInfo(payload)))
    #expect(route.hostID == hostID)
    #expect(route.address == "t7")
    #expect(route.createdMs == 1_762_763_352_000)
    // A machine of another core's: the address keeps its prefix.
    let nested = try #require(PushRoute(userInfo: try userInfo(
        #"{"hirte":{"v":1,"host_id":"6f9619ff-8b86-d011-b42d-00c04fc964ff","address":"rohan/t7"}}"#)))
    #expect(nested.address == "rohan/t7")
    #expect(nested.createdMs == nil)
}

@Test func malformedPayloadsGiveNoRoute() throws {
    #expect(PushRoute(userInfo: try userInfo(#"{"aps":{"alert":"hi"}}"#)) == nil)
    #expect(PushRoute(userInfo: try userInfo(#"{"hirte":{"v":2,"host_id":"6f9619ff-8b86-d011-b42d-00c04fc964ff","address":"t7"}}"#)) == nil)
    #expect(PushRoute(userInfo: try userInfo(#"{"hirte":{"v":1,"host_id":"not-a-uuid","address":"t7"}}"#)) == nil)
    #expect(PushRoute(userInfo: try userInfo(#"{"hirte":{"v":1,"host_id":"6f9619ff-8b86-d011-b42d-00c04fc964ff","address":""}}"#)) == nil)
    #expect(PushRoute(userInfo: try userInfo(#"{"hirte":{"v":1,"host_id":"6f9619ff-8b86-d011-b42d-00c04fc964ff","address":7}}"#)) == nil)
    #expect(PushRoute(userInfo: try userInfo(#"{"hirte":{"v":1,"address":"t7"}}"#)) == nil)
    #expect(PushRoute(userInfo: try userInfo(#"{"hirte":"t7"}"#)) == nil)
    // A negative or non-numeric created_ms is unknown, not a reason to drop the route.
    let odd = try #require(PushRoute(userInfo: try userInfo(
        #"{"hirte":{"v":1,"host_id":"6f9619ff-8b86-d011-b42d-00c04fc964ff","address":"t7","created_ms":"soon"}}"#)))
    #expect(odd.createdMs == nil)
}

@Test func routeMatchesTheTerminalByAddressAndIdentity() throws {
    func terminal(_ address: String, created: UInt64) throws -> Terminal {
        try JSONDecoder().decode(Terminal.self, from: Data(#"{"address":"\#(address)","created_ms":\#(created),"state":"live"}"#.utf8))
    }
    let route = PushRoute(hostID: hostID, address: "t7", createdMs: 1_000)
    #expect(route.matches(try terminal("t7", created: 1_000)))
    #expect(!route.matches(try terminal("t7", created: 2_000)), "another terminal took the address")
    #expect(!route.matches(try terminal("t8", created: 1_000)))
    // Without an identity on either side, the address decides.
    #expect(PushRoute(hostID: hostID, address: "t7", createdMs: nil).matches(try terminal("t7", created: 2_000)))
    #expect(PushRoute(hostID: hostID, address: "t7", createdMs: 0).matches(try terminal("t7", created: 2_000)))
}
