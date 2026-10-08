#if os(Windows)
import Foundation
import WinSDK

/// Decodes an image file into CF_DIB bytes (a BITMAPINFOHEADER, then 32-bit bottom-up pixels) with GDI+, Windows'
/// built-in decoder. Chromium apps (Figma, Chrome), Paint and OneNote paste images from CF_DIB, the format a native
/// screenshot carries, and ignore the registered "PNG" format or a copied file. GDI+'s flat C API is loaded from
/// gdiplus.dll at run time, since the WinSDK module doesn't import it.
public enum WindowsImage {
    /// Images whose pixels would take more than this aren't decoded (a 50 MB PNG can expand far past its size).
    public static let maxPixelBytes = 256 * 1024 * 1024

    private typealias Startup = @convention(c) (UnsafeMutablePointer<UInt>, UnsafeRawPointer, UnsafeMutableRawPointer?) -> Int32
    private typealias CreateFromFile = @convention(c) (UnsafePointer<UInt16>, UnsafeMutablePointer<OpaquePointer?>) -> Int32
    private typealias CreateHBITMAP = @convention(c) (OpaquePointer, UnsafeMutablePointer<HBITMAP?>, UInt32) -> Int32
    private typealias DisposeImage = @convention(c) (OpaquePointer) -> Int32

    private struct GDIPlus: @unchecked Sendable {
        let createFromFile: CreateFromFile
        let createHBITMAP: CreateHBITMAP
        let disposeImage: DisposeImage
    }

    /// Loaded and started once, for the life of the process; nil if gdiplus.dll or a function is missing.
    private static let gdiplus: GDIPlus? = {
        guard let module = "gdiplus.dll".withCString(encodedAs: UTF16.self, { LoadLibraryW($0) }) else { return nil }
        func function<T>(_ name: String, as type: T.Type) -> T? {
            guard let address = GetProcAddress(module, name) else { return nil }
            return unsafeBitCast(address, to: type)
        }
        guard let startup = function("GdiplusStartup", as: Startup.self),
              let createFromFile = function("GdipCreateBitmapFromFile", as: CreateFromFile.self),
              let createHBITMAP = function("GdipCreateHBITMAPFromBitmap", as: CreateHBITMAP.self),
              let disposeImage = function("GdipDisposeImage", as: DisposeImage.self) else { return nil }
        // GdiplusStartupInput on x64: UINT32 version (1), a callback pointer at 8, two BOOLs at 16 and 20, all zero.
        var input = [UInt8](repeating: 0, count: 24)
        input.withUnsafeMutableBytes { $0.storeBytes(of: UInt32(1), as: UInt32.self) }
        var token: UInt = 0
        let status = input.withUnsafeBytes { startup(&token, $0.baseAddress!, nil) }
        guard status == 0 else { return nil }
        return GDIPlus(createFromFile: createFromFile, createHBITMAP: createHBITMAP, disposeImage: disposeImage)
    }()

    /// The image at `url` as CF_DIB bytes, or nil if it can't be decoded or is too large. Transparent pixels come
    /// out over white, like most apps' own image copies.
    public static func dib(fromImageAt url: URL) -> Data? {
        guard let gdiplus else { return nil }
        let path = (url.withUnsafeFileSystemRepresentation { $0.map { String(cString: $0) } } ?? url.path)
            .replacingOccurrences(of: "/", with: "\\")
        var bitmap: OpaquePointer?
        let opened = path.withCString(encodedAs: UTF16.self) { gdiplus.createFromFile($0, &bitmap) }
        guard opened == 0, let bitmap else { return nil }
        var hbitmap: HBITMAP?
        let converted = gdiplus.createHBITMAP(bitmap, &hbitmap, 0xFFFF_FFFF)
        _ = gdiplus.disposeImage(bitmap)  // releases the file
        guard converted == 0, let hbitmap else { return nil }
        defer { DeleteObject(hbitmap) }

        var info = BITMAP()
        guard GetObjectW(hbitmap, Int32(MemoryLayout<BITMAP>.size), &info) != 0,
              info.bmWidth > 0, info.bmHeight > 0 else { return nil }
        let width = Int(info.bmWidth), height = Int(info.bmHeight)
        let pixelBytes = width * height * 4
        guard pixelBytes <= maxPixelBytes else { return nil }

        let headerSize = MemoryLayout<BITMAPINFOHEADER>.size
        var header = BITMAPINFOHEADER()
        header.biSize = DWORD(headerSize)
        header.biWidth = LONG(width)
        header.biHeight = LONG(height)  // positive: bottom-up rows, what CF_DIB readers expect
        header.biPlanes = 1
        header.biBitCount = 32
        header.biCompression = DWORD(BI_RGB)
        header.biSizeImage = DWORD(pixelBytes)

        var data = Data(count: headerSize + pixelBytes)
        guard let screen = GetDC(nil) else { return nil }
        defer { ReleaseDC(nil, screen) }
        let lines = data.withUnsafeMutableBytes { raw -> Int32 in
            raw.storeBytes(of: header, as: BITMAPINFOHEADER.self)
            let pixels = raw.baseAddress!.advanced(by: headerSize)
            return raw.baseAddress!.withMemoryRebound(to: BITMAPINFO.self, capacity: 1) { bitmapInfo in
                GetDIBits(screen, hbitmap, 0, UINT(height), pixels, bitmapInfo, UINT(DIB_RGB_COLORS))
            }
        }
        guard lines == Int32(height) else { return nil }
        return data
    }
}
#endif
