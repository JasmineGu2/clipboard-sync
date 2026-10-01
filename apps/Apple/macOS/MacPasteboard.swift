import AppKit
import ClipAppCore

/// NSPasteboard.general behind the ClipAppCore protocols.
@MainActor
final class MacPasteboard: PasteboardWriter, PasteboardReader {
    private let pasteboard = NSPasteboard.general
    private let ownMarker = NSPasteboard.PasteboardType(CaptureFilter.ownMarkerType)

    var changeCount: Int { pasteboard.changeCount }

    /// Reads the type list first and only reads the text when no skip marker is present,
    /// so concealed secrets never enter this process's memory (F9).
    func read() -> PasteboardContents {
        let types = (pasteboard.types ?? []).map(\.rawValue)
        let skip = types.contains(CaptureFilter.ownMarkerType)
            || types.contains(where: CaptureFilter.concealedTypes.contains)
        return PasteboardContents(types: types, text: skip ? nil : pasteboard.string(forType: .string))
    }

    /// Writes the text plus ClipSync's marker type, so the watcher skips its own copy.
    func write(text: String) {
        pasteboard.clearContents()
        pasteboard.declareTypes([.string, ownMarker], owner: nil)
        pasteboard.setString(text, forType: .string)
        // One byte, not empty Data: some pasteboard readers drop types with no data.
        pasteboard.setData(Data([1]), forType: ownMarker)
    }
}
