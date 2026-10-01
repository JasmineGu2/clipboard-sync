// Entry point. The commands live in ClipCtl.swift; usage notes in content/clipctl.md.
// Top-level code picks the synchronous `main()`/`run()` overloads (which only print help for async
// commands), so dispatch through an async function where the async `run()` wins overload resolution.
import ArgumentParser

func runAsync(_ command: inout some AsyncParsableCommand) async throws {
    try await command.run()
}

do {
    var command = try ClipCtl.parseAsRoot()
    if var asyncCommand = command as? any AsyncParsableCommand {
        try await runAsync(&asyncCommand)
    } else {
        try command.run()
    }
} catch {
    ClipCtl.exit(withError: error)
}
