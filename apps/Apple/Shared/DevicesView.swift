import ClipAppCore
import ClipSync
import SwiftUI

/// F13: the vault's devices, with Remove for a lost one. Shared by the Mac menu and the iOS sheet.
struct DevicesView: View {
    let app: ClipApp
    var onDone: (() -> Void)?

    @State private var loading = false
    @State private var removing: VaultDevice?
    @State private var confirming: VaultDevice?
    @State private var removedName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Strings.devicesTitle)
                .font(.headline)
            Text(Strings.devicesIntro)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            List {
                ForEach(app.devices) { device in
                    row(device)
                }
            }
            .listStyle(.plain)
            .frame(minHeight: 160)
            .overlay {
                if loading && app.devices.isEmpty {
                    ProgressView(Strings.devicesLoading)
                }
            }

            if let removedName {
                Text(Strings.format(Strings.deviceRemoved, ["device": removedName]))
                    .font(.callout)
            }
            if let message = app.message {
                Text(message.text)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(Strings.devicesMissingHint)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let onDone {
                HStack {
                    Spacer()
                    Button(Strings.done, action: onDone)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding()
        .task { await load() }
        // `presenting:` hands the device to the buttons; the dialog clears `confirming` before they run.
        .confirmationDialog(
            confirming.map { Strings.format(Strings.removeDeviceTitle, ["device": $0.name]) } ?? "",
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            titleVisibility: .visible,
            presenting: confirming
        ) { device in
            Button(Strings.removeDeviceConfirm, role: .destructive) {
                Task { await remove(device) }
            }
            Button(Strings.cancel, role: .cancel) {}
        } message: { _ in
            Text(Strings.removeDeviceMessage)
        }
    }

    private func row(_ device: VaultDevice) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                if device.isThisDevice {
                    Text(Strings.deviceThis)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if removing == device {
                ProgressView()
                    .controlSize(.small)
            } else if !device.isThisDevice {
                Button(Strings.actionRemoveDevice, role: .destructive) {
                    confirming = device
                }
                .disabled(removing != nil)
            }
        }
    }

    private func load() async {
        loading = true
        app.message = nil
        await app.loadDevices()
        loading = false
    }

    private func remove(_ device: VaultDevice) async {
        removing = device
        removedName = nil
        if await app.removeDevice(device) {
            removedName = device.name
        }
        removing = nil
    }
}
