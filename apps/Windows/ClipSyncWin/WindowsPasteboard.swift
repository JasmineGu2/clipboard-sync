#if os(Windows)
import ClipAppCore
import ClipWindows
import Foundation

/// The Win32 clipboard behind ClipAppCore's `PasteboardWriter` (copies from history, receiving the newest copy
/// from another device). `WindowsClipboard.write` adds ExcludeClipboardContentFromMonitorProcessing, so the
/// capture listener skips our own writes the same way it skips a password manager's.
@MainActor
final class WindowsPasteboard: PasteboardWriter {
    /// Called when the clipboard couldn't be written (another app held it through every retry).
    var onFailure: (@MainActor () -> Void)?

    func write(text: String) {
        do {
            try WindowsClipboard.write(text)
        } catch {
            onFailure?()
        }
    }

    func write(fileAt url: URL, contentType: String?) {
        do {
            // Images also go on as image data, like a native screenshot (docs/decisions.md, 2026-10-08).
            let isImage = contentType?.hasPrefix("image/") == true
            let png = contentType == "image/png" ? try? Data(contentsOf: url) : nil
            let dib = isImage ? WindowsImage.dib(fromImageAt: url) : nil
            try WindowsClipboard.write(fileAt: url, png: png, dib: dib)
        } catch {
            onFailure?()
        }
    }
}
#endif
