import SwiftUI
import WebKit

struct ParkingWebView: View {
    let title: String
    let url: URL

    @StateObject private var model = WebViewModel()

    var body: some View {
        VStack(spacing: 0) {
            ProgressView(value: max(model.progress, 0.02))
                .progressViewStyle(.linear)
                .tint(.accentColor)
                .opacity(model.isLoading ? 1 : 0)
                .animation(.easeOut(duration: 0.15), value: model.isLoading)
                .frame(height: 2)

            // Pass model without @ObservedObject so KVO/nav updates do not recreate the UIView.
            WebViewRepresentable(url: url, model: model)
                .ignoresSafeArea(edges: .bottom)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                Button {
                    model.goBack()
                } label: {
                    Image(systemName: "chevron.backward")
                }
                .disabled(!model.canGoBack)

                Button {
                    model.goForward()
                } label: {
                    Image(systemName: "chevron.forward")
                }
                .disabled(!model.canGoForward)

                Spacer()

                Button {
                    model.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }

                Button {
                    model.prefill()
                } label: {
                    Image(systemName: "wand.and.stars")
                }
                .disabled(model.webView == nil)

                ShareLink(item: model.currentURL ?? url) {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
    }
}

@MainActor
final class WebViewModel: ObservableObject {
    @Published var isLoading = false
    @Published var progress: Double = 0
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var currentURL: URL?

    weak var webView: WKWebView?

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func reload() { webView?.reload() }
    func prefill() {
        guard let webView else { return }
        BookingFormPrefill.inject(into: webView, trigger: .manual)
    }
}

struct WebViewRepresentable: UIViewRepresentable {
    let url: URL
    let model: WebViewModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeUIView(context: Context) -> WKWebView {
        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = true

        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences = preferences
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        // Isolate from other WebViews so one bad page cannot take down every tab.
        config.processPool = WKProcessPool()

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .automatic

        context.coordinator.bind(webView)
        model.webView = webView
        AppLog.log("WebView create \(url.absoluteString)")
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // Do not reload on SwiftUI refreshes.
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        AppLog.log("WebView dismantle")
        coordinator.unbind()
        uiView.stopLoading()
        uiView.navigationDelegate = nil
        uiView.uiDelegate = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private let model: WebViewModel
        private var observations: [NSKeyValueObservation] = []
        private var lastPublishedProgress: Double = -1
        private var prefillWorkItem: DispatchWorkItem?
        private var autoPrefillAttempts = 0

        init(model: WebViewModel) {
            self.model = model
        }

        func bind(_ webView: WKWebView) {
            unbind()
            // Progress only, throttled — navigation flags come from delegate callbacks.
            observations = [
                webView.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
                    let progress = view.estimatedProgress
                    DispatchQueue.main.async {
                        self?.publishProgress(progress)
                    }
                }
            ]
        }

        func unbind() {
            prefillWorkItem?.cancel()
            prefillWorkItem = nil
            autoPrefillAttempts = 0
            observations.forEach { $0.invalidate() }
            observations.removeAll()
        }

        private func scheduleAutoPrefill(for webView: WKWebView) {
            prefillWorkItem?.cancel()
            autoPrefillAttempts = 0
            enqueueAutoPrefill(for: webView, delay: 0.8)
        }

        private func enqueueAutoPrefill(for webView: WKWebView, delay: TimeInterval) {
            prefillWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self, weak webView] in
                guard let self, let webView else { return }
                self.autoPrefillAttempts += 1
                BookingFormPrefill.inject(into: webView, trigger: .auto) { outcome in
                    DispatchQueue.main.async {
                        let shouldRetry: Bool
                        switch outcome {
                        case .filled, .skipped, .error:
                            shouldRetry = false
                        case .captcha, .waiting, .unknown:
                            shouldRetry = self.autoPrefillAttempts < 40
                        }
                        if shouldRetry {
                            AppLog.log("Prefill retry \(self.autoPrefillAttempts)/40 after \(outcome.rawValue)")
                            self.enqueueAutoPrefill(for: webView, delay: 3.0)
                        }
                    }
                }
            }
            prefillWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }

        private func publishProgress(_ progress: Double) {
            // Skip tiny KVO chatter that forces SwiftUI body rebuilds.
            if abs(progress - lastPublishedProgress) < 0.04, progress < 1, lastPublishedProgress >= 0 {
                return
            }
            lastPublishedProgress = progress
            model.progress = progress
            model.isLoading = progress > 0 && progress < 1
        }

        private func publishNavigationState(from webView: WKWebView) {
            let canGoBack = webView.canGoBack
            let canGoForward = webView.canGoForward
            let currentURL = webView.url
            let isLoading = webView.isLoading
            let progress = webView.estimatedProgress
            DispatchQueue.main.async { [model] in
                model.canGoBack = canGoBack
                model.canGoForward = canGoForward
                model.currentURL = currentURL
                model.isLoading = isLoading
                model.progress = progress
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            AppLog.log("WebView load \(webView.url?.absoluteString ?? "(nil)")")
            prefillWorkItem?.cancel()
            prefillWorkItem = nil
            autoPrefillAttempts = 0
            publishNavigationState(from: webView)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            AppLog.log("WebView finish \(webView.url?.absoluteString ?? "(nil)")")
            publishNavigationState(from: webView)
            scheduleAutoPrefill(for: webView)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            AppLog.log("WebView fail \(error.localizedDescription)")
            publishNavigationState(from: webView)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            AppLog.log("WebView provisional fail \(error.localizedDescription)")
            publishNavigationState(from: webView)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            AppLog.log("WebView content process terminated — reloading")
            webView.reload()
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            decisionHandler(.allow)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
                webView.load(URLRequest(url: url))
            }
            return nil
        }
    }
}

#Preview {
    NavigationStack {
        ParkingWebView(
            title: "1525 Harbor Garage",
            url: Garage.harborWeehawken.reservationURL(from: .now)
        )
    }
}
