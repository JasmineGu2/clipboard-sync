import ClipAppCore
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// One history row: headline, source device, age and tags (F4). Images show their thumbnail and files an icon,
/// with the size (F11, F12); a download for a copy shows its progress.
struct HistoryRow: View {
    let item: ClipItem
    var justCopied = false
    /// 0...1 while the image or file downloads for a copy.
    var downloading: Double?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if item.isFile {
                preview
            }
            details
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var preview: some View {
        Group {
            if let image = thumbnailImage {
                image
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: item.kind == .image ? "photo" : "doc")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel(item.kind == .image ? Strings.kindImage : Strings.kindFile)
    }

    private var thumbnailImage: Image? {
        guard let data = item.thumbnail else { return nil }
        #if os(macOS)
        return NSImage(data: data).map(Image.init(nsImage:))
        #else
        return UIImage(data: data).map(Image.init(uiImage:))
        #endif
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if item.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .accessibilityLabel(Strings.sectionPinned)
                }
                Text(item.headline)
                    .lineLimit(2)
                Spacer(minLength: 0)
                if justCopied {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.green)
                        .accessibilityLabel(Strings.copied)
                }
            }
            if let downloading {
                ProgressView(value: downloading)
                    .accessibilityLabel(Strings.downloading)
            }
            HStack(spacing: 6) {
                if let size = item.fileSize {
                    Text(size, format: .byteCount(style: .file))
                }
                Text(Strings.format(Strings.fromDevice, ["device": item.sourceDeviceName]))
                // A fixed format, not `.relative` style: that one re-renders every second (N4).
                Text(item.createdAt, format: .relative(presentation: .named))
                ForEach(item.tags, id: \.self) { tag in
                    Text(tag)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }
}

/// Create a vault or join one with a pairing code (F10).
struct OnboardingView: View {
    let app: ClipApp
    /// Called after create or join finishes (either way); the caller checks `app.state`.
    var onFinish: () -> Void = {}

    @State private var server = ""
    @State private var code = ""
    @State private var deviceName: String
    /// Which button ran last, so its error shows right under it. The form is taller than the Mac menu
    /// window, so an error at the bottom was out of sight and the button looked like it did nothing.
    @State private var lastAction: Action?

    private enum Action { case create, join }

    init(app: ClipApp, onFinish: @escaping () -> Void = {}) {
        self.app = app
        self.onFinish = onFinish
        // Prefilled with the platform default: "iPhone" on iOS, the computer name on the Mac.
        _deviceName = State(initialValue: app.deviceName)
    }

    var body: some View {
        Form {
            Section {
                Text(Strings.onboardingIntro)
            }
            Section(Strings.serverLabel) {
                // On macOS a Form shows a field's title as a side label, which squeezed the box to a sliver
                // beside the example URL. Hide the label (the section header names it) and show the example
                // inside the box instead.
                TextField(Strings.serverLabel, text: $server, prompt: Text(Strings.serverPlaceholder))
                    .labelsHidden()
                    .urlEntry()
                Text(Strings.serverHint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section(Strings.deviceNameLabel) {
                TextField(Strings.deviceNameLabel, text: $deviceName)
                    .labelsHidden()
                Text(Strings.deviceNameHint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section {
                Button(Strings.createVault) {
                    lastAction = .create
                    Task {
                        await app.createVault(server: server, deviceName: deviceName)
                        onFinish()
                    }
                }
                Text(Strings.createVaultHint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                errorText(for: .create)
            }
            Section(Strings.joinVault) {
                TextField(Strings.joinVault, text: $code, prompt: Text(Strings.codePlaceholder))
                    .labelsHidden()
                    .codeEntry()
                Button(Strings.joinVault) {
                    lastAction = .join
                    Task {
                        await app.joinVault(server: server, code: code, deviceName: deviceName)
                        onFinish()
                    }
                }
                Text(Strings.joinVaultHint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                errorText(for: .join)
            }
            if lastAction == nil, let message = app.message {
                Section {
                    Text(message.text)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .disabled(app.state == .working)
        .overlay {
            if app.state == .working {
                ProgressView(Strings.working)
            }
        }
    }

    @ViewBuilder
    private func errorText(for action: Action) -> some View {
        if lastAction == action, let message = app.message {
            Text(message.text)
                .foregroundStyle(.red)
        }
    }
}

/// Shows a one-time pairing code for a new device (F10).
struct PairView: View {
    let app: ClipApp
    var onDone: (() -> Void)?

    @State private var code: String?
    @State private var loading = false

    var body: some View {
        VStack(spacing: 16) {
            Text(Strings.pairTitle)
                .font(.headline)
            Text(Strings.pairInstructions)
                .multilineTextAlignment(.center)
            Group {
                if let code {
                    Text(code)
                        .font(.system(.title3, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .minimumScaleFactor(0.6)
                        .textSelection(.enabled)
                } else if loading {
                    ProgressView()
                } else if let message = app.message {
                    Text(message.text)
                        .foregroundStyle(.red)
                }
            }
            .frame(minHeight: 60)
            Text(Strings.pairExpiry)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack {
                Button(Strings.pairNewCode) {
                    Task { await load() }
                }
                .disabled(loading)
                if let onDone {
                    Button(Strings.done, action: onDone)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding()
        .task { await load() }
    }

    private func load() async {
        loading = true
        code = nil
        app.message = nil
        code = await app.startPairing()
        loading = false
    }
}

extension View {
    /// A text field for a server URL: no autocorrect or auto-capitalization.
    func urlEntry() -> some View {
        #if os(iOS)
        self.autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .keyboardType(.URL)
        #else
        self.autocorrectionDisabled()
        #endif
    }

    /// A text field for a pairing code.
    func codeEntry() -> some View {
        #if os(iOS)
        self.autocorrectionDisabled()
            .textInputAutocapitalization(.characters)
            .font(.system(.body, design: .monospaced))
        #else
        self.autocorrectionDisabled()
            .font(.system(.body, design: .monospaced))
        #endif
    }
}
