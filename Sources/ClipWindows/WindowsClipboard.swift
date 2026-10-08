#if os(Windows)
import Foundation
import WinSDK

/// The Win32 clipboard: reading for capture (`clipctl watch`, the tray app), writing for `clipctl copy` and
/// copies from history. See docs/design.md §5 (F9).
public enum WindowsClipboard {
    /// Text over this many UTF-8 bytes is never captured.
    public static let maxCaptureBytes = 1024 * 1024

    /// Set by password managers and by us (on `copy`): monitors must ignore the content.
    static let excludeFormat = register("ExcludeClipboardContentFromMonitorProcessing")
    /// Older convention for the same thing.
    static let viewerIgnoreFormat = register("Clipboard Viewer Ignore")
    /// DWORD 0 means "keep out of clipboard history / cloud clipboard".
    static let historyFormat = register("CanIncludeInClipboardHistory")
    static let cloudFormat = register("CanUploadToCloudClipboard")
    /// The registered "PNG" format, which browsers, Office, chat apps and Paint read as an image.
    static let pngFormat = register("PNG")

    public enum Capture: Sendable {
        case text(String)
        /// A concealed-content marker is present; the name says which.
        case concealed(String)
        case tooLarge
        /// No text on the clipboard (an image, files, or empty).
        case noText
        /// Another process held the clipboard through every retry.
        case busy
    }

    public static var sequenceNumber: DWORD { GetClipboardSequenceNumber() }

    /// Reads the clipboard text unless it's marked concealed or too large.
    public static func readForCapture() -> Capture {
        guard open(owner: nil) else { return .busy }
        defer { CloseClipboard() }

        if let reason = concealedReason() { return .concealed(reason) }
        guard IsClipboardFormatAvailable(UINT(CF_UNICODETEXT)),
              let handle = GetClipboardData(UINT(CF_UNICODETEXT)) else { return .noText }
        // UTF-16 bytes over 2 MiB always means more than 1 MiB of UTF-8; skip before decoding a huge buffer.
        let byteSize = Int(GlobalSize(handle))
        if byteSize > 2 * maxCaptureBytes + 2 { return .tooLarge }
        guard let raw = GlobalLock(handle) else { return .noText }
        defer { GlobalUnlock(handle) }
        let units = raw.assumingMemoryBound(to: UInt16.self)
        let capacity = byteSize / 2
        var length = 0
        while length < capacity, units[length] != 0 { length += 1 }
        let text = String(decoding: UnsafeBufferPointer(start: units, count: length), as: UTF16.self)
        if text.utf8.count > maxCaptureBytes { return .tooLarge }
        return .text(text)
    }

    /// Call with the clipboard open.
    private static func concealedReason() -> String? {
        if excludeFormat != 0, IsClipboardFormatAvailable(excludeFormat) {
            return "ExcludeClipboardContentFromMonitorProcessing"
        }
        if viewerIgnoreFormat != 0, IsClipboardFormatAvailable(viewerIgnoreFormat) {
            return "Clipboard Viewer Ignore"
        }
        for (format, name) in [(historyFormat, "CanIncludeInClipboardHistory"), (cloudFormat, "CanUploadToCloudClipboard")] {
            if format != 0, IsClipboardFormatAvailable(format), dwordValue(format) == 0 {
                return "\(name)=0"
            }
        }
        return nil
    }

    private static func dwordValue(_ format: UINT) -> DWORD? {
        guard let handle = GetClipboardData(format), GlobalSize(handle) >= MemoryLayout<DWORD>.size,
              let raw = GlobalLock(handle) else { return nil }
        defer { GlobalUnlock(handle) }
        return raw.loadUnaligned(as: DWORD.self)
    }

    /// Puts text on the clipboard, marked so monitors (our own watcher included) don't capture it again.
    public static func write(_ text: String) throws {
        let units = Array(text.utf16) + [0]
        try replaceContents {
            try set(UINT(CF_UNICODETEXT), bytes: units.count * 2) { destination in
                units.withUnsafeBytes { source in destination.copyMemory(from: source.baseAddress!, byteCount: source.count) }
            }
        }
    }

    /// Puts a file on the clipboard as CF_HDROP, like copying it in Explorer, so pasting into Explorer or a chat
    /// app pastes the file. For an image, `dib` (from `WindowsImage`) and `png` (a PNG file's bytes) go on first,
    /// like a native screenshot, so pasting into Figma, a browser, Office or Paint pastes the picture. Marked the
    /// same way as text.
    public static func write(fileAt url: URL, png: Data? = nil, dib: Data? = nil) throws {
        let path = url.withUnsafeFileSystemRepresentation { $0.map { String(cString: $0) } } ?? url.path
        // DROPFILES, then the path list: each path NUL-terminated, the list ended by one more NUL.
        let units = Array(path.replacingOccurrences(of: "/", with: "\\").utf16) + [0, 0]
        let header = MemoryLayout<DROPFILES>.size
        try replaceContents {
            // Image formats first: apps that take the first format they know should take the picture.
            if let png, !png.isEmpty, pngFormat != 0 {
                try set(pngFormat, bytes: png.count) { destination in
                    png.withUnsafeBytes { source in destination.copyMemory(from: source.baseAddress!, byteCount: source.count) }
                }
            }
            if let dib, !dib.isEmpty {
                try set(UINT(CF_DIB), bytes: dib.count) { destination in
                    dib.withUnsafeBytes { source in destination.copyMemory(from: source.baseAddress!, byteCount: source.count) }
                }
            }
            try set(UINT(CF_HDROP), bytes: header + units.count * 2) { destination in
                var drop = DROPFILES()
                drop.pFiles = DWORD(header)
                drop.fWide = true
                destination.storeBytes(of: drop, as: DROPFILES.self)
                units.withUnsafeBytes { source in
                    destination.advanced(by: header).copyMemory(from: source.baseAddress!, byteCount: source.count)
                }
            }
        }
    }

    /// Empties the clipboard, lets `fill` add the content, then adds the exclude marker.
    private static func replaceContents(_ fill: () throws -> Void) throws {
        // SetClipboardData fails after EmptyClipboard if the clipboard was opened without an owner window,
        // so own it with a message-only window.
        let window = "STATIC".withCString(encodedAs: UTF16.self) { className in
            CreateWindowExW(0, className, nil, 0, 0, 0, 0, 0, HWND(bitPattern: -3) /* HWND_MESSAGE */,
                            nil, GetModuleHandleW(nil), nil)
        }
        defer { if let window { DestroyWindow(window) } }

        guard open(owner: window) else { throw WindowsError("The clipboard is busy (another app has it open). Try again.") }
        defer { CloseClipboard() }
        guard EmptyClipboard() else { throw WindowsError("Couldn't empty the clipboard (Windows error \(GetLastError())).") }

        try fill()
        if excludeFormat != 0 {
            let marker: DWORD = 1
            try set(excludeFormat, bytes: MemoryLayout<DWORD>.size) { $0.storeBytes(of: marker, as: DWORD.self) }
        }
    }

    private static func set(_ format: UINT, bytes: Int, fill: (UnsafeMutableRawPointer) -> Void) throws {
        guard let memory = GlobalAlloc(UINT(GMEM_MOVEABLE), SIZE_T(bytes)) else {
            throw WindowsError("Out of memory writing the clipboard.")
        }
        guard let pointer = GlobalLock(memory) else {
            GlobalFree(memory)
            throw WindowsError("Couldn't lock clipboard memory (Windows error \(GetLastError())).")
        }
        fill(pointer)
        GlobalUnlock(memory)
        // On success the system owns the memory; only free it on failure.
        guard SetClipboardData(format, memory) != nil else {
            GlobalFree(memory)
            throw WindowsError("Couldn't set clipboard data (Windows error \(GetLastError())).")
        }
    }

    /// OpenClipboard fails while another app holds it; retry for about half a second.
    private static func open(owner: HWND?) -> Bool {
        for attempt in 0..<10 {
            if OpenClipboard(owner) { return true }
            if attempt < 9 { Sleep(50) }
        }
        return false
    }

    private static func register(_ name: String) -> UINT {
        name.withCString(encodedAs: UTF16.self) { RegisterClipboardFormatW($0) }
    }
}
#endif
