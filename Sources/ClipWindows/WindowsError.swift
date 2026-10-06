/// A Win32 failure, with a message that says what failed and the Windows error code.
/// clipctl prints `description` as is; the tray app shows its own copy instead.
public struct WindowsError: Error, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ message: String) { description = message }
}
