import Foundation
import XCTest
@testable import ClipAppCore

/// Keeps `Strings` and content/app.md in step (CLAUDE.md: copy lives in content/).
final class StringsTests: XCTestCase {
    var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // ClipAppCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()
    }

    /// Lines shaped like "- `key`: value".
    func contentEntries(_ file: String = "content/app.md") throws -> [String: String] {
        let text = try String(contentsOf: repoRoot.appendingPathComponent(file), encoding: .utf8)
        var entries: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard line.hasPrefix("- `"), let close = line.range(of: "`: ") else { continue }
            let key = String(line[line.index(line.startIndex, offsetBy: 3)..<close.lowerBound])
            XCTAssertNil(entries[key], "duplicate key \(key) in \(file)")
            entries[key] = String(line[close.upperBound...])
        }
        return entries
    }

    func testStringsMatchContentFile() throws {
        let content = try contentEntries()
        XCTAssertFalse(content.isEmpty)
        for (key, value) in Strings.all {
            XCTAssertEqual(content[key], value, "content/app.md `\(key)`")
        }
        for key in content.keys where Strings.all[key] == nil {
            XCTFail("content/app.md has `\(key)`, which Strings doesn't")
        }
    }

    func testWindowsStringsMatchContentFile() throws {
        let content = try contentEntries("content/windows.md")
        XCTAssertFalse(content.isEmpty)
        for (key, value) in WinStrings.all {
            XCTAssertEqual(content[key], value, "content/windows.md `\(key)`")
        }
        for key in content.keys where WinStrings.all[key] == nil {
            XCTFail("content/windows.md has `\(key)`, which WinStrings doesn't")
        }
        // One file per key: a Windows string that repeats a shared one belongs in content/app.md.
        for key in WinStrings.all.keys {
            XCTAssertNil(Strings.all[key], "`\(key)` is in both content files")
        }
    }

    func testIntentLiteralsMatchStrings() throws {
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("apps/Apple/Shared/SendClipboardIntent.swift"), encoding: .utf8)
        let literals = [
            Strings.intentTitle, Strings.intentDescription, Strings.intentTextParameter, Strings.intentTextPrompt,
            Strings.intentShortTitle,
        ]
        for value in literals {
            XCTAssertTrue(source.contains("\"\(value)\""), "SendClipboardIntent.swift should contain \"\(value)\"")
        }
    }

    func testFormat() {
        XCTAssertEqual(Strings.format(Strings.fromDevice, ["device": "iPhone"]), "From iPhone")
        XCTAssertEqual(Strings.format(Strings.actionRemoveTag, ["tag": "work"]), "Remove tag work")
    }
}
