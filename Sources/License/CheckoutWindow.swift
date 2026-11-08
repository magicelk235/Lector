import AppKit
import WebKit

/// Polar's embedded checkout, in a window of Lector's own.
///
/// The page is Polar's embed script around a checkout link, loaded as if it came from
/// magicelklabs.com: Polar only lets the hosts listed under its Embedding settings frame a
/// checkout, and the site is one of them. After payment the checkout moves on to Polar's
/// customer portal, where the buyer gets the key with the code Polar emails them.
@MainActor
final class CheckoutWindow: NSObject, NSWindowDelegate, WKScriptMessageHandler, WKUIDelegate {
    private static var open: CheckoutWindow?
    private static let origin = URL(string: "https://magicelklabs.com/lector/")!
    /// How long the checkout gets to appear before the link opens in the browser instead.
    private static let loadTimeout: Duration = .seconds(20)

    private let window: NSWindow
    private let webView: WKWebView
    private let checkout: URL
    private var loaded = false

    /// Opens `checkout`, a Polar checkout link, replacing any checkout already open.
    static func show(_ checkout: URL, title: String) {
        open?.window.close()
        let controller = CheckoutWindow(checkout: checkout, title: title)
        open = controller
        NSApp.activate()
        controller.window.makeKeyAndOrderFront(nil)
    }

    private init(checkout: URL, title: String) {
        self.checkout = checkout
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 480, height: 760),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        configuration.userContentController.add(WeakMessageHandler(self), name: "checkout")
        webView.uiDelegate = self
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentMinSize = CGSize(width: 400, height: 560)
        window.contentView = webView
        window.delegate = self
        window.center()
        webView.loadHTMLString(Self.page(checkout: checkout, dark: Self.isDark), baseURL: Self.origin)
        Task { [weak self] in
            try? await Task.sleep(for: Self.loadTimeout)
            guard let self, !loaded, Self.open === self else { return }
            openInBrowser()
        }
    }

    private static var isDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// The embed script inline, then a checkout opened with it. The script's own overlay
    /// fills the window, and its close button closes the window too.
    private static func page(checkout: URL, dark: Bool) -> String {
        let script = Bundle.main.url(forResource: "polar-checkout", withExtension: "js")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        let link = (try? JSONSerialization.data(withJSONObject: [checkout.absoluteString]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return """
        <!doctype html>
        <html><head><meta charset="utf-8"><meta name="color-scheme" content="\(dark ? "dark" : "light")">
        <style>html, body { margin: 0; height: 100%; background: \(dark ? "#0b0b0b" : "#ffffff"); }</style>
        <script>\(script)</script>
        </head><body><script>
        (async () => {
          const post = (message) => window.webkit.messageHandlers.checkout.postMessage(message);
          try {
            const checkout = await window.Polar.EmbedCheckout.create(\(link)[0], {
              theme: "\(dark ? "dark" : "light")",
              onLoaded: () => post({ event: "loaded" }),
            });
            document.querySelectorAll("iframe").forEach((frame) => { frame.style.backgroundColor = "transparent"; });
            checkout.addEventListener("close", () => post({ event: "close" }));
          } catch (error) {
            post({ event: "failed" });
          }
        })();
        </script></body></html>
        """
    }

    // MARK: Messages from the page

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let event = body["event"] as? String else { return }
        switch event {
        case "loaded": loaded = true
        case "close": window.close()
        case "failed": openInBrowser()
        default: break
        }
    }

    private func openInBrowser() {
        NSWorkspace.shared.open(checkout)
        window.close()
    }

    // MARK: Windows the checkout opens

    /// Links the checkout opens in a new window, such as Polar's terms, go to the browser.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { NSWorkspace.shared.open(url) }
        return nil
    }

    func windowWillClose(_ notification: Notification) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "checkout")
        if Self.open === self { Self.open = nil }
    }
}

/// WKUserContentController holds its handlers strongly; this keeps it from holding the window.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?

    init(_ target: any WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
