import UIKit
import UniformTypeIdentifiers

/// "Decently Fluent" in another app's share sheet: takes the shared web page (a link, or text with a link in it)
/// and opens it in the app's browser through a decentlyfluent://open?url=… link.
final class ShareViewController: UIViewController {
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Task { await share() }
    }

    private func share() async {
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let providers = items.flatMap { $0.attachments ?? [] }
        var page: URL?
        for p in providers where page == nil {
            if p.hasItemConformingToTypeIdentifier(UTType.url.identifier),
               let u = try? await p.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL,
               ["http", "https"].contains(u.scheme?.lowercased() ?? "") {
                page = u
            } else if p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                      let text = try? await p.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
                page = Self.firstLink(in: text)
            }
        }
        if page == nil, let text = items.compactMap({ $0.attributedContentText?.string }).first {
            page = Self.firstLink(in: text)
        }
        guard let page, var c = URLComponents(string: "decentlyfluent://open") else {
            extensionContext?.cancelRequest(withError: NSError(domain: "DecentlyFluent", code: 1))
            return
        }
        c.queryItems = [URLQueryItem(name: "url", value: page.absoluteString)]
        if let link = c.url { open(link) }
        extensionContext?.completeRequest(returningItems: nil)
    }

    private static func firstLink(in text: String) -> URL? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..., in: text)
        return detector?.matches(in: text, range: range).compactMap(\.url)
            .first { ["http", "https"].contains($0.scheme?.lowercased() ?? "") }
    }

    /// Extensions can't open other apps directly; the application object further up the responder chain can.
    /// Its open method is hidden from extensions at compile time, so it is called through the runtime.
    private func open(_ url: URL) {
        let sel = NSSelectorFromString("openURL:options:completionHandler:")
        var r: UIResponder? = self
        while let next = r {
            if next.responds(to: sel) {
                // UIApplication takes an options dictionary and UIScene an options object: both accept none
                typealias Open = @convention(c) (NSObject, Selector, NSURL, AnyObject?, AnyObject?) -> Void
                let f = unsafeBitCast(next.method(for: sel), to: Open.self)
                f(next, sel, url as NSURL, nil, nil)
                return
            }
            r = next.next
        }
    }
}
