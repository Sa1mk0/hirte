import Foundation
import HerdrKit
import Testing
import UIKit
@testable import hirte

@MainActor
struct AttachmentTests {
    private func png(width: Int, height: Int) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).pngData { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    @Test func knownFormatsGoOutAsTheyAre() throws {
        let data = png(width: 40, height: 30)
        let image = try #require(Attachment.image(data, stem: "shot"))
        #expect(image.ext == "png")
        #expect(image.data == data)
        #expect(image.stem == "shot")
    }

    private func jpeg(width: Int, height: Int) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).jpegData(withCompressionQuality: 0.8) { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    @Test func hugeImagesAreScaledDownAndKeepPNG() throws {
        let image = try #require(Attachment.image(png(width: 6000, height: 300), stem: "wide"))
        #expect(image.ext == "png")
        let scaled = try #require(UIImage(data: image.data))
        #expect(scaled.size.width == 4096)
        #expect(abs(scaled.size.height - 205) <= 1)
        // A camera-sized JPEG stays JPEG, at most 4096 px a side.
        let photo = try #require(Attachment.image(jpeg(width: 5000, height: 2500), stem: "photo"))
        #expect(photo.ext == "jpg")
        let fitted = try #require(UIImage(data: photo.data))
        #expect(fitted.size.width == 4096)
        #expect(abs(fitted.size.height - 2048) <= 1)
    }

    private func temporaryFile(_ name: String, _ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hirte-attachment-\(UUID().uuidString)-\(name)")
        try data.write(to: url)
        return url
    }

    /// A file from Files that is an image gets the photo treatment; anything else goes as it is.
    @Test func filesThatAreImagesAreConvertedLikePhotos() throws {
        let wide = try Attachment.file(try temporaryFile("export.png", png(width: 6000, height: 300)))
        #expect(wide.ext == "png")
        #expect(wide.stem == "export")
        #expect(try #require(UIImage(data: wide.data)).size.width == 4096)
        let text = try Attachment.file(try temporaryFile("notes.md", Data("# notes\n".utf8)))
        #expect(text.ext == "md")
        #expect(text.data == Data("# notes\n".utf8))
    }

    @Test func undecodableBytesAreNoImage() {
        #expect(Attachment.image(Data("not an image at all, really".utf8), stem: "x") == nil)
    }

    /// The demo machine "stores" uploads and the path gets typed, quoted for a plain shell only.
    @Test func demoUploadTypesThePath() async throws {
        let session = HostSession(host: Host.makeDemo())
        let terminal = try VirtualTerminal(cols: 60, rows: 5)
        let model = TerminalScreenModel(theme: TerminalTheme.find(TerminalTheme.defaultDark, dark: true), terminal: terminal)
        var input: [Data] = []
        model.sentInputForTesting = { input.append($0) }
        model.startForTesting(session: session, address: "t5")
        await model.attach(png(width: 4, height: 4), stem: "shot", extension: "png")
        #expect(model.attachment == nil)
        let typed = String(decoding: try #require(input.last), as: UTF8.self)
        #expect(typed.hasPrefix("/Users/demo/.cache/hirte/uploads/shot-"))
        #expect(typed.hasSuffix(".png "))

        await model.attach(Data(), stem: "empty", extension: "txt")
        #expect(model.attachment == .failed("The file is empty."))
        model.dismissAttachmentFailure()
        #expect(model.attachment == nil)
        #expect(input.count == 1, "a failed upload types nothing")

        // A terminal on a machine the core added: our line doesn't reach it.
        model.startForTesting(session: session, address: "box/t7")
        await model.attach(png(width: 4, height: 4), stem: "shot", extension: "png")
        guard case .failed(let message) = model.attachment else {
            Issue.record("another machine is a clear error")
            return
        }
        #expect(message.contains("box"))
        #expect(input.count == 1)
    }
}
