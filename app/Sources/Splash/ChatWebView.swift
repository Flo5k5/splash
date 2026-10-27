import SwiftUI
import WebKit

/// The server's own chat page. It stays on the server's origin, where its chats are saved; links
/// open in the browser, and it reloads when a model (re)starts, to learn what the model takes.
struct ChatWebView: NSViewRepresentable {
    let url: URL
    let generation: Int

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        let coordinator = context.coordinator
        guard coordinator.origin != url || coordinator.generation != generation else { return }
        coordinator.origin = url
        coordinator.generation = generation
        view.load(URLRequest(url: url))
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var origin: URL?
        var generation: Int?

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async
            -> WKNavigationActionPolicy {
            guard let target = action.request.url else { return .cancel }
            if target.host() == origin?.host() && target.port == origin?.port && target.scheme == origin?.scheme {
                return .allow
            }
            // Links leave for the browser; anything else, a dropped file for one, goes nowhere.
            if action.navigationType == .linkActivated, ["http", "https"].contains(target.scheme) {
                NSWorkspace.shared.open(target)
            }
            return .cancel
        }

        // target="_blank" links.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let target = action.request.url, ["http", "https"].contains(target.scheme) {
                NSWorkspace.shared.open(target)
            }
            return nil
        }

        func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                     initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = parameters.allowsMultipleSelection
            panel.allowedContentTypes = [.image]
            return await panel.begin() == .OK ? panel.urls : nil
        }

        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo) async -> Bool {
            let alert = NSAlert()
            alert.messageText = message
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
            return alert.runModal() == .alertFirstButtonReturn
        }
    }
}
