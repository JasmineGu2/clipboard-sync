#if os(Windows)
import WinSDK

/// "Start when I sign in": a value under HKCU\...\Run pointing at this exe. Per user, no admin rights needed.
/// Windows shows it in Settings > Apps > Startup, where it can also be turned off.
enum LaunchAtLogin {
    static let runKey = "Software\\Microsoft\\Windows\\CurrentVersion\\Run"
    static let valueName = "ClipSync"

    /// HKEY_CURRENT_USER is `(HKEY)(ULONG_PTR)(LONG)0x80000001`, a cast macro Swift can't import. The LONG cast
    /// sign-extends, so the 64-bit handle value is 0xFFFFFFFF80000001.
    static var currentUser: HKEY? {
        HKEY(bitPattern: Int(Int32(bitPattern: 0x8000_0001)))
    }

    static var isEnabled: Bool {
        runKey.withCString(encodedAs: UTF16.self) { key in
            valueName.withCString(encodedAs: UTF16.self) { value in
                // RRF_RT_REG_SZ; ERROR_SUCCESS is 0.
                RegGetValueW(currentUser, key, value, DWORD(RRF_RT_REG_SZ), nil, nil, nil) == 0
            }
        }
    }

    /// Returns the Windows error code, or nil on success.
    static func setEnabled(_ enabled: Bool) -> Int32? {
        let status: LSTATUS = runKey.withCString(encodedAs: UTF16.self) { key in
            valueName.withCString(encodedAs: UTF16.self) { value in
                if enabled {
                    // Quoted, because the path may contain spaces.
                    let command = Array("\"\(executablePath)\"".utf16) + [0]
                    return command.withUnsafeBytes { bytes in
                        RegSetKeyValueW(currentUser, key, value, DWORD(1) /* REG_SZ */, bytes.baseAddress, DWORD(bytes.count))
                    }
                }
                let result = RegDeleteKeyValueW(currentUser, key, value)
                return result == LSTATUS(ERROR_FILE_NOT_FOUND) ? 0 : result
            }
        }
        return status == 0 ? nil : Int32(status)
    }

    static var executablePath: String {
        var buffer = [WCHAR](repeating: 0, count: 32_768)
        let length = Int(GetModuleFileNameW(nil, &buffer, DWORD(buffer.count)))
        return String(decoding: buffer.prefix(length), as: UTF16.self)
    }
}
#endif
