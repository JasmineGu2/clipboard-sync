import AppKit
import ClipAppCore
import UniformTypeIdentifiers

/// NSPasteboard.general behind the ClipAppCore protocols.
@MainActor
final class MacPasteboard: PasteboardWriter, PasteboardReader {
    private let pasteboard = NSPasteboard.general
    private let ownMarker = NSPasteboard.PasteboardType(CaptureFilter.ownMarkerType)
    private static let jpeg = NSPasteboard.PasteboardType(UTType.jpeg.identifier)

    var changeCount: Int { pasteboard.changeCount }

    /// Reads the type list first and only reads contents when no skip marker is present, so concealed secrets
    /// never enter this process's memory (F9). File URLs and text come next; image bytes only when there's
    /// neither, so an ordinary text copy never loads a picture.
    func read() -> PasteboardContents {
        let types = (pasteboard.types ?? []).map(\.rawValue)
        let skip = types.contains(CaptureFilter.ownMarkerType)
            || types.contains(where: CaptureFilter.concealedTypes.contains)
        guard !skip else { return PasteboardContents(types: types, text: nil) }
        let files = pasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let text = files.isEmpty ? pasteboard.string(forType: .string) : nil
        let image = files.isEmpty && text == nil ? readImage() : nil
        return PasteboardContents(types: types, text: text, fileURLs: files, image: image)
    }

    /// PNG or JPEG as they are; TIFF (what many apps put up) re-encoded as PNG, which is far smaller.
    ///
    /// The 50 MB cap (`CaptureFilter.maxImageBytes`) is checked on each representation the moment it arrives, before
    /// anything copies, decodes or keeps it. NSPasteboard has no public call that reports a type's size without
    /// transferring the data, so "before reading" can't go earlier than this. An over-cap PNG or JPEG ends the
    /// capture: the other representations are the same picture, so trying them would only read more bytes.
    private func readImage() -> PasteboardImage? {
        for (type, mime) in [(NSPasteboard.PasteboardType.png, "image/png"), (Self.jpeg, "image/jpeg")] {
            guard let data = pasteboard.data(forType: type) else { continue }
            guard data.count <= CaptureFilter.maxImageBytes else { return nil }
            return PasteboardImage(data: data, contentType: mime)
        }
        if let tiff = pasteboard.data(forType: .tiff), tiff.count <= CaptureFilter.maxImageBytes * 4,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            return PasteboardImage(data: png, contentType: "image/png")
        }
        return nil
    }

    /// Writes the text plus ClipSync's marker type, so the watcher skips its own copy.
    func write(text: String) {
        pasteboard.clearContents()
        pasteboard.declareTypes([.string, ownMarker], owner: nil)
        pasteboard.setString(text, forType: .string)
        // One byte, not empty Data: some pasteboard readers drop types with no data.
        pasteboard.setData(Data([1]), forType: ownMarker)
    }

    /// Writes the file's URL (Finder pastes the file) and, for images, the image itself (Messages, Notes and
    /// editors paste the picture), plus the marker.
    func write(fileAt url: URL, contentType: String?) {
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        if let contentType, contentType.hasPrefix("image/"),
           let type = UTType(mimeType: contentType),
           let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
           size <= CaptureFilter.maxImageBytes,
           let data = try? Data(contentsOf: url) {
            item.setData(data, forType: NSPasteboard.PasteboardType(type.identifier))
        }
        item.setData(Data([1]), forType: ownMarker)
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }
}
