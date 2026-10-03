import InboxPlusBridge
import SwiftUI
import WebKit

/// Hosts the network's own sign-in page and captures the cookies the bridge asked for.
///
/// The password is typed into the network's real page inside this view. Inbox+ never sees it, never
/// stores it, and never sends it anywhere: what leaves this view is the specific cookies the bridge
/// declared it needs, and nothing else.
#if os(iOS)
typealias NativeWebRepresentable = UIViewRepresentable
#else
typealias NativeWebRepresentable = NSViewRepresentable
#endif
struct CookieLoginWebView: NativeWebRepresentable {
    let parameters: BridgeLoginCookiesParams
    /// Fires whenever the captured set changes, so the surrounding view can enable "Continue" the
    /// moment every required cookie is present.
    let onCookiesCaptured: ([String: String]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parameters: parameters, onCookiesCaptured: onCookiesCaptured)
    }

    #if os(iOS)
    func makeUIView(context: Context) -> WKWebView { makeWebView(context: context) }
    func updateUIView(_ view: WKWebView, context: Context) {}
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) { coordinator.stop() }
    #else
    func makeNSView(context: Context) -> WKWebView { makeWebView(context: context) }
    #endif
    func makeWebView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // A non-persistent store keeps this login out of any shared cookie jar: the session belongs
        // to the bridge once captured, and nothing should be left behind in the app afterwards.
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        // Without a UI delegate, `window.open` returns null and nothing happens. Every
        // "Sign in with Google" and "Continue with Apple" button is a popup, so omitting this
        // makes those buttons silently dead — they look clickable and do nothing at all.
        webView.uiDelegate = context.coordinator
        if let userAgent = parameters.userAgent, !userAgent.isEmpty {
            webView.customUserAgent = userAgent
        }
        if let url = URL(string: parameters.url) {
            webView.load(URLRequest(url: url))
        }
        context.coordinator.webView = webView
        return webView
    }

    #if os(macOS)
    func updateNSView(_ nsView: WKWebView, context: Context) {}

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        coordinator.stop()
    }

    #endif
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        /// Loads a popup in the same view rather than opening a second window.
        ///
        /// Returning a new web view would give it a separate cookie store, and the captured
        /// session would then live somewhere this view never reads. Navigating in place keeps
        /// one store, which is the thing cookie capture depends on.
        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if let url = navigationAction.request.url {
                webView.load(URLRequest(url: url))
            }
            return nil
        }

        private let parameters: BridgeLoginCookiesParams
        private let onCookiesCaptured: ([String: String]) -> Void
        private var pollTimer: Timer?
        weak var webView: WKWebView?

        init(
            parameters: BridgeLoginCookiesParams,
            onCookiesCaptured: @escaping ([String: String]) -> Void
        ) {
            self.parameters = parameters
            self.onCookiesCaptured = onCookiesCaptured
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            capture(from: webView)
            // Instagram completes its sign-in with in-page navigation that fires no further
            // delegate callbacks, so a short poll is what actually notices the session cookie
            // appearing. It stops as soon as the required set is complete.
            startPolling()
        }

        private func startPolling() {
            guard pollTimer == nil else { return }
            let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let webView = self.webView else { return }
                    self.capture(from: webView)
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            pollTimer = timer
        }

        func stop() {
            pollTimer?.invalidate()
            pollTimer = nil
        }

        private func capture(from webView: WKWebView) {
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self else { return }
                let captured = CookieMatcher.match(cookies: cookies, to: self.parameters)
                MainActor.assumeIsolated {
                    self.onCookiesCaptured(captured)
                    let required = Set(self.parameters.requiredFieldIDs)
                    if required.isSubset(of: Set(captured.keys)) { self.stop() }
                }
            }
        }

    }
}

/// Maps live cookies onto the field IDs a bridge declared.
///
/// Deliberately its own type rather than a member of the view's coordinator: `NSViewRepresentable`
/// is main-actor isolated and that isolation reaches its nested types, but matching cookies is pure
/// and belongs nowhere near an actor.
enum CookieMatcher {
    /// Honours each field's own declared sources rather than assuming the field ID equals the
    /// cookie name, and takes nothing the bridge did not ask for.
    static func match(
        cookies: [HTTPCookie],
        to parameters: BridgeLoginCookiesParams
    ) -> [String: String] {
        var captured: [String: String] = [:]
        for field in parameters.fields {
            let sources = field.sources.isEmpty
                ? [BridgeLoginCookieFieldSource(type: "cookie", name: field.id)]
                : field.sources
            for source in sources where source.type == "cookie" {
                guard let cookie = cookies.first(where: {
                    $0.name == source.name && domainMatches($0.domain, source.cookieDomain)
                }) else { continue }
                captured[field.id] = cookie.value
                break
            }
        }
        return captured
    }

    /// Cookie domains arrive with and without the leading dot, and a declared domain should also
    /// match its subdomains — `instagram.com` must accept `.www.instagram.com` but never
    /// `instagram.com.evil.example`.
    static func domainMatches(_ cookieDomain: String, _ declared: String?) -> Bool {
        guard let declared, !declared.isEmpty else { return true }
        let actual = cookieDomain.hasPrefix(".") ? String(cookieDomain.dropFirst()) : cookieDomain
        let expected = declared.hasPrefix(".") ? String(declared.dropFirst()) : declared
        return actual == expected || actual.hasSuffix("." + expected)
    }
}
