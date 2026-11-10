import Foundation
import SSHTransport

/// Sending a photo or file to the machine a terminal runs on, into `~/.cache/hirte/uploads`
/// there, so its path can be handed to the program (a coding agent reads the screenshot).
public enum RemoteUpload {
    /// Where uploads land: the login user's cache, created `700` with `600` files.
    public static let directory = "$HOME/.cache/hirte/uploads"

    /// `<stem>-<yyyyMMdd-HHmmss>-<nonce>.<ext>`: unique, and made of letters, digits, `-`, `_` and
    /// the one `.`, so it needs no quoting in `command(fileName:byteCount:)`. The extension is kept
    /// (lowercased) because programs recognize the type by it.
    public static func fileName(stem: String, extension ext: String, date: Date = .now, nonce: UInt16 = .random(in: 0...0xffff)) -> String {
        var safeStem = ""
        for scalar in stem.unicodeScalars {
            let plain = scalar.isASCII && (scalar.properties.isAlphabetic || ("0"..."9").contains(scalar) || scalar == "_")
            if plain { safeStem.unicodeScalars.append(scalar) } else if !safeStem.hasSuffix("-") { safeStem.append("-") }
        }
        safeStem = String(safeStem.trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(40))
        if safeStem.isEmpty { safeStem = "file" }
        let safeExt = String(ext.lowercased().unicodeScalars.filter { $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0)) }.prefix(8))
        let stamp = Self.stampFormatter.string(from: date)
        let suffix = String(format: "%04x", nonce)
        return "\(safeStem)-\(stamp)-\(suffix)" + (safeExt.isEmpty ? "" : ".\(safeExt)")
    }

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    /// The remote command: stores exactly `byteCount` bytes from stdin as `fileName` and prints the
    /// absolute path. `head -c` stops at the count, so the channel needs no EOF; the size check
    /// turns a line dropped mid-way into an error instead of a truncated file whose path gets
    /// pasted. `fileName` must come from `fileName(stem:extension:)`: it is not quoted.
    public static func command(fileName: String, byteCount: Int) -> String {
        "sh -c 'umask 077; d=\"\(directory)\"; mkdir -p \"$d\" || exit 1; f=\"$d/\(fileName)\"; "
            + "head -c \(byteCount) > \"$f\" || exit 1; "
            + "[ \"$(wc -c < \"$f\" | tr -d \" \")\" = \(byteCount) ] || { rm -f \"$f\"; echo \"the upload stopped short\" >&2; exit 1; }; "
            + "printf \"%s\\n\" \"$f\"'"
    }

    /// The path the command printed; nil unless its output is one absolute path.
    public static func path(fromOutput output: String) -> String? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/"), !trimmed.contains(where: \.isNewline) else { return nil }
        return trimmed
    }

    /// The path as a shell takes it in one word: as is when it only has safe characters, else
    /// in single quotes (a `'` inside becomes `'\''`).
    public static func shellQuoted(_ path: String) -> String {
        let safe = path.unicodeScalars.allSatisfy {
            $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0) || "/._-+:@%".unicodeScalars.contains($0))
        }
        if safe, !path.isEmpty { return path }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// What goes into the terminal after an upload: the path and a space, no Enter, so the person
    /// finishes the line. A program with bracketed paste gets the path as is; a plain shell gets it
    /// quoted, as it would read the line.
    public static func pasteText(path: String, bracketed: Bool) -> String {
        (bracketed ? path : shellQuoted(path)) + " "
    }

    /// An image's format by its first bytes (`jpg`, `png`, `gif`, `webp`, `heic`), nil for anything else.
    public static func imageExtension(_ data: Data) -> String? {
        let head = [UInt8](data.prefix(12))
        guard head.count >= 12 else { return nil }
        if head[0] == 0xFF, head[1] == 0xD8, head[2] == 0xFF { return "jpg" }
        if Array(head[0..<8]) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] { return "png" }
        if head.starts(with: "GIF8".utf8) { return "gif" }
        if head.starts(with: "RIFF".utf8), head[8..<12].elementsEqual("WEBP".utf8) { return "webp" }
        if head[4..<8].elementsEqual("ftyp".utf8) {
            let brand = String(decoding: head[8..<12], as: UTF8.self)
            if ["heic", "heix", "hevc", "hevx", "mif1", "msf1"].contains(brand) { return "heic" }
        }
        return nil
    }
}

public enum UploadError: LocalizedError {
    /// The command ran but didn't print the path: something on the machine wrote to stdout instead.
    case unexpectedOutput(String)

    public var errorDescription: String? {
        switch self {
        case .unexpectedOutput(let output):
            output.isEmpty ? "The machine didn't say where it stored the file." : "Unexpected answer from the machine: \(output)"
        }
    }
}

extension SSHConnection {
    /// Stores `data` as `fileName` in `RemoteUpload.directory` over this connection, on a channel of
    /// its own, and returns the absolute path. `progress` gets the bytes sent so far.
    public func upload(
        _ data: Data, fileName: String, progress: @escaping @Sendable (Int) -> Void = { _ in }
    ) async throws -> String {
        let pipe = try await openExec(RemoteUpload.command(fileName: fileName, byteCount: data.count))
        // Cancelled (the screen went away): closing the channel ends `head -c` short, and the
        // command's size check removes the partial file instead of leaving it behind.
        return try await withTaskCancellationHandler {
            defer { pipe.close() }
            // Read while writing: the command can end early (no home, disk full), and its reason is
            // in its stderr, which arrives on the output stream's failure.
            let reading = Task {
                var output = Data()
                for try await chunk in pipe.output { output.append(chunk) }
                return output
            }
            var sent = 0
            do {
                while sent < data.count {
                    try Task.checkCancellation()
                    let end = min(sent + 128 * 1024, data.count)
                    try await pipe.write(data.subdata(in: sent..<end))
                    sent = end
                    progress(sent)
                }
            } catch {
                if case .failure(let ended) = await reading.result, !(ended is CancellationError) { throw ended }
                throw error
            }
            let output = String(decoding: try await reading.value, as: UTF8.self)
            guard let path = RemoteUpload.path(fromOutput: output) else {
                throw UploadError.unexpectedOutput(output.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return path
        } onCancel: {
            pipe.close()
        }
    }
}
