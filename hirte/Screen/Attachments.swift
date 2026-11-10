import HerdrKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// What gets sent to the machine: the bytes, a name for the file there and its extension.
struct Attachment {
    var data: Data
    var stem: String
    var ext: String

    /// Longest side above which an image is scaled down before it goes out.
    static let largestSide: CGFloat = 4096

    /// An image as a program on the machine can read it: JPEG and PNG (GIF, WebP) go as they are;
    /// HEIC and anything else a UIImage decodes become JPEG; only a huge one is scaled down.
    static func image(_ data: Data, stem: String) -> Attachment? {
        let known = RemoteUpload.imageExtension(data)
        if let known, known != "heic", let image = UIImage(data: data), max(image.size.width, image.size.height) <= largestSide {
            return Attachment(data: data, stem: stem, ext: known)
        }
        guard let image = UIImage(data: data) else { return nil }
        var fitted = image
        let longest = max(image.size.width, image.size.height)
        if longest > largestSide {
            let scale = largestSide / longest
            let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            fitted = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        }
        if known == "png", let png = fitted.pngData() { return Attachment(data: png, stem: stem, ext: "png") }
        guard let jpeg = fitted.jpegData(compressionQuality: 0.9) else { return nil }
        return Attachment(data: jpeg, stem: stem, ext: "jpg")
    }

    /// The image on the pasteboard, if there is one. Reading it is what the person asked for.
    static func pasteboardImage() -> Attachment? {
        let pasteboard = UIPasteboard.general
        guard pasteboard.hasImages else { return nil }
        for type in [UTType.png, .jpeg] {
            if let data = pasteboard.data(forPasteboardType: type.identifier), let image = image(data, stem: "pasted") { return image }
        }
        guard let png = pasteboard.image?.pngData() else { return nil }
        return image(png, stem: "pasted")
    }

    /// A picked photo. `.compatible` encoding already turned HEIC into JPEG; the sniffing covers
    /// the rest.
    static func photo(_ item: PhotosPickerItem) async -> Attachment? {
        guard let data = try? await item.loadTransferable(type: Data.self) else { return nil }
        return image(data, stem: "photo")
    }

    /// A picked file, read while its security scope is open. Keeps its name and extension.
    static func file(_ url: URL) throws -> Attachment {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        return Attachment(data: data, stem: url.deletingPathExtension().lastPathComponent, ext: url.pathExtension)
    }

    /// Text or an image from an item provider (the key bar's paste control): text wins.
    static func load(_ providers: [NSItemProvider]) async -> Loaded? {
        for provider in providers where provider.canLoadObject(ofClass: NSString.self) {
            if let text = try? await provider.loadObject(ofClass: NSString.self) { return .text(text as String) }
        }
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            if let data = try? await provider.loadDataRepresentation(for: .image), let image = image(data, stem: "pasted") {
                return .image(image)
            }
        }
        return nil
    }

    enum Loaded {
        case text(String)
        case image(Attachment)
    }
}

extension NSItemProvider {
    fileprivate func loadObject<T: NSItemProviderReading>(ofClass type: T.Type) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            _ = loadObject(ofClass: type) { object, error in
                if let object = object as? T { continuation.resume(returning: object) }
                else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
            }
        }
    }

    fileprivate func loadDataRepresentation(for type: UTType) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            _ = loadDataRepresentation(for: type) { data, error in
                if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
            }
        }
    }
}
