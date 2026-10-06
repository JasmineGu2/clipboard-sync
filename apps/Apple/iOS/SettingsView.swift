import ClipAppCore
import SwiftUI

/// The iPhone's settings sheet. F14 expiry for now.
struct SettingsView: View {
    let app: ClipApp
    let done: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(Strings.expiryTitle, selection: Binding(
                        get: { app.expiryDays },
                        set: { days in Task { await app.setExpiryDays(days) } }
                    )) {
                        ForEach(ExpiryChoices.options(current: app.expiryDays), id: \.self) { days in
                            Text(ExpiryChoices.label(days)).tag(days)
                        }
                    }
                } footer: {
                    Text(Strings.expiryHint)
                }
            }
            .navigationTitle(Strings.settingsTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(Strings.done, action: done)
                }
            }
        }
    }
}
