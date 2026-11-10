import Foundation

// Push notifications when a main agent needs a decision. The app's half of the contract: it leaves
// its device token on each machine it is connected to, and opens the terminal a notification names.
// The sender's half runs on the machine (a watcher of herdr-core's events; `scripts/push-test.sh`
// shows the payload): it reads the token files below and notifies for terminals without a parent
// whose status becomes `blocked`. The app does not filter.

/// `~/.config/hirte/push/<installation-id>.json` on a machine: this app install's token for it.
///
/// ```json
/// {"v":1,"token":"<APNs device token, lowercase hex>","environment":"production"|"development",
///  "bundle_id":"<app bundle id>","host_id":"<this app's UUID for the machine>","device":"iPhone",
///  "updated_ms":<ms since the epoch>}
/// ```
public struct PushTokenFile: Codable, Equatable, Sendable {
    public var v = 1
    /// The APNs device token, lowercase hex.
    public var token: String
    /// `development` (Debug builds) or `production` (TestFlight, App Store): the build's `aps-environment`.
    public var environment: String
    public var bundleID: String
    /// The app's UUID for the machine the file is on; a notification carries it back as `host_id`.
    public var hostID: UUID
    /// The device's model, `iPhone` or `iPad`.
    public var device: String
    public var updatedMs: UInt64

    enum CodingKeys: String, CodingKey {
        case v, token, environment, device
        case bundleID = "bundle_id"
        case hostID = "host_id"
        case updatedMs = "updated_ms"
    }

    public init(token: String, environment: String, bundleID: String, hostID: UUID, device: String, updatedMs: UInt64) {
        self.token = token
        self.environment = environment
        self.bundleID = bundleID
        self.hostID = hostID
        self.device = device
        self.updatedMs = updatedMs
    }

    /// The file's bytes: one JSON object, UTF-8, keys sorted so the same facts give the same file.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

public enum RemotePush {
    /// Where the token files live: the login user's config, created `700` with `600` files.
    public static let directory = "$HOME/.config/hirte/push"

    /// Whether `id` is a file name as is: lowercase hex and dashes (a lowercased UUID string), so it
    /// needs no quoting in the commands below.
    public static func isInstallationID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64
            && id.unicodeScalars.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) || $0 == "-" }
    }

    /// The remote command: stores exactly `byteCount` bytes from stdin (the file from
    /// `PushTokenFile.encoded()`) as `<installationID>.json`, in place of an earlier one. It goes
    /// through a temporary file and `mv`, so a reader never sees a part; `head -c` stops at the count,
    /// so the channel needs no EOF, and the size check turns a line dropped mid-way into an error.
    /// Nothing of the file's content is in the command; `installationID` must pass
    /// `isInstallationID`, as it is not quoted.
    public static func writeCommand(installationID: String, byteCount: Int) -> String {
        precondition(isInstallationID(installationID), "installation IDs are lowercase hex and dashes")
        return "sh -c 'umask 077; d=\"\(directory)\"; mkdir -p \"$d\" && chmod 700 \"$d\" || exit 1; "
            + "t=\"$d/.\(installationID).tmp\"; head -c \(byteCount) > \"$t\" || exit 1; "
            + "[ \"$(wc -c < \"$t\" | tr -d \" \")\" = \(byteCount) ] || { rm -f \"$t\"; echo \"the token file stopped short\" >&2; exit 1; }; "
            + "mv -f \"$t\" \"$d/\(installationID).json\"'"
    }

    /// Removes this install's token file (and a temporary file a dropped line left) from the machine.
    public static func deleteCommand(installationID: String) -> String {
        precondition(isInstallationID(installationID), "installation IDs are lowercase hex and dashes")
        return "sh -c 'rm -f \"\(directory)/\(installationID).json\" \"\(directory)/.\(installationID).tmp\"'"
    }
}

/// Where a tapped notification leads, from the `hirte` object of the sender's payload:
///
/// ```json
/// {"aps":{"alert":{"title":"<terminal>","body":"<what it waits for>"},"sound":"default",
///  "thread-id":"<host_id>","interruption-level":"time-sensitive"},
///  "hirte":{"v":1,"host_id":"<host_id from the token file>","address":"t7","created_ms":<terminal created_ms>}}
/// ```
public struct PushRoute: Equatable, Sendable {
    public let hostID: UUID
    public let address: String
    /// The terminal's identity, when the sender knew it: nil or 0 means match by address only.
    public let createdMs: UInt64?

    public init(hostID: UUID, address: String, createdMs: UInt64?) {
        self.hostID = hostID
        self.address = address
        self.createdMs = createdMs
    }

    /// Nil unless `userInfo` carries a version 1 `hirte` object with a host UUID and an address.
    public init?(userInfo: [AnyHashable: Any]) {
        guard let hirte = userInfo["hirte"] as? [String: Any],
              let version = hirte["v"] as? Int, version == 1,
              let hostID = (hirte["host_id"] as? String).flatMap(UUID.init(uuidString:)),
              let address = hirte["address"] as? String,
              !address.isEmpty, address.count <= 200, !address.contains(where: \.isNewline)
        else { return nil }
        self.hostID = hostID
        self.address = address
        createdMs = (hirte["created_ms"] as? NSNumber).flatMap { $0.int64Value >= 0 ? $0.uint64Value : nil }
    }

    /// Whether `terminal` is the one the notification was about.
    public func matches(_ terminal: Terminal) -> Bool {
        guard address == terminal.address else { return false }
        if let createdMs, createdMs != 0, terminal.createdMs != createdMs { return false }
        return true
    }
}
