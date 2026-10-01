import ClipAppCore
import UIKit
import UniformTypeIdentifiers

/// F2 via the share sheet: takes shared text or a URL, adds it to the App Group database, syncs once with a
/// short timeout, shows the result for a moment, and closes. No storyboard, no SwiftUI, to stay small and quick.
final class ShareViewController: UIViewController {
    private let label = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var started = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        label.numberOfLines = 0
        label.textAlignment = .center
        label.font = .preferredFont(forTextStyle: .body)
        let stack = UIStackView(arrangedSubviews: [spinner, label])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.layoutMarginsGuide.trailingAnchor),
        ])
        spinner.startAnimating()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started else { return }
        started = true
        Task { await send() }
    }

    private func send() async {
        let result: SendResult
        if let text = await sharedText() {
            result = await ClipApp.sendOnce(
                text, home: AppPaths.home, keyStore: KeychainKeyStore.appDefault, timeout: .seconds(4))
        } else {
            result = .failed(.emptyText)
        }
        spinner.stopAnimating()
        spinner.isHidden = true
        label.text = result.text
        try? await Task.sleep(for: .milliseconds(result == .sent ? 600 : 1500))
        extensionContext?.completeRequest(returningItems: nil)
    }

    /// The first URL or plain text among the shared items. A URL wins, since Safari shares both.
    private func sharedText() async -> String? {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            if let url = await load(provider, UTType.url.identifier) { return url }
        }
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            if let text = await load(provider, UTType.plainText.identifier) { return text }
        }
        return nil
    }

    /// Loads one item as a string. The completion handler runs on a background queue; only a String leaves it.
    private func load(_ provider: NSItemProvider, _ type: String) async -> String? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type, options: nil) { item, _ in
                guard let item else {
                    continuation.resume(returning: nil)
                    return
                }
                switch item {
                case let url as URL: continuation.resume(returning: url.absoluteString)
                case let string as String: continuation.resume(returning: string)
                case let data as Data: continuation.resume(returning: String(data: data, encoding: .utf8))
                default: continuation.resume(returning: nil)
                }
            }
        }
    }
}
