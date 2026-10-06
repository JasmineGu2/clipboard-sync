import ClipAppCore
import SwiftUI

/// Shown instead of the history once another device removed this one (F13). "Set up again" moves the old
/// vault's files aside and goes back to onboarding (`ClipApp.setUpAgain()`).
struct RemovedView: View {
    let app: ClipApp
    /// Runs after a successful reset (the Mac stops its clipboard watcher here).
    var onSetUpAgain: () -> Void = {}

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.crop.circle.badge.xmark")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(Strings.removedTitle)
                .font(.headline)
            Text(Strings.removedBody)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(Strings.removedKeepsHistory)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(Strings.setUpAgain) {
                if app.setUpAgain() { onSetUpAgain() }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            if let message = app.message {
                Text(message.text)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
        .padding()
    }
}
