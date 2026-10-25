import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The share extension's principal class (`NSExtensionPrincipalClass`). Hosts the
/// SwiftUI sheet and hands it the first web link in what was shared.
final class ShareViewController: UIViewController {
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = UIColor(RN.Palette.paper3)

        model.onFinish = { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
        model.onCancel = { [weak self] in
            self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
        }

        let sheet = ShareCaptureView(model: model) { [weak self] unsaved in
            self?.isModalInPresentation = unsaved
        }
        let host = UIHostingController(rootView: sheet)
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(host)
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        host.didMove(toParent: self)

        let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        let model = model
        Task {
            let link = await SharedLinkReader.firstLink(in: items)
            await model.start(link: link)
        }
    }
}

/// Finds the first http(s) link in shared items: a URL attachment, then text
/// (some apps share "Song by Artist https://…"), then the item's own text.
enum SharedLinkReader {
    static func firstLink(in items: [NSExtensionItem]) async -> String? {
        let providers = items.flatMap { $0.attachments ?? [] }
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            if let url = await loadURL(from: provider), let link = webLink(url) { return link }
        }
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            if let text = await loadText(from: provider), let link = firstWebLink(in: text) { return link }
        }
        for item in items {
            if let text = item.attributedContentText?.string, let link = firstWebLink(in: text) { return link }
        }
        return nil
    }

    // Nonisolated so the provider's completion handlers, which run on a background
    // queue, are not treated as main-actor closures.
    private nonisolated static func loadURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                let url: URL? = switch item {
                case let url as URL: url
                case let string as String: URL(string: string)
                case let data as Data: URL(dataRepresentation: data, relativeTo: nil)
                default: nil
                }
                continuation.resume(returning: url)
            }
        }
    }

    private nonisolated static func loadText(from provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                let text: String? = switch item {
                case let string as String: string
                case let attributed as NSAttributedString: attributed.string
                case let data as Data: String(data: data, encoding: .utf8)
                default: nil
                }
                continuation.resume(returning: text)
            }
        }
    }

    private nonisolated static func firstWebLink(in text: String) -> String? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        for match in detector.matches(in: text, range: range) {
            if let url = match.url, let link = webLink(url) { return link }
        }
        return nil
    }

    private nonisolated static func webLink(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", url.host() != nil else { return nil }
        return url.absoluteString
    }
}
