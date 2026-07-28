import SwiftUI
import WebKit

struct ParkingWebView: View {
    let title: String
    let url: URL

    @StateObject private var model = WebViewModel()

    var body: some View {
        VStack(spacing: 0) {
            if model.isLoading {
                ProgressView(value: model.progress)
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
            }

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
}

struct WebViewRepresentable: UIViewRepresentable {
    let url: URL
    @ObservedObject var model: WebViewModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.websiteDataStore = .default()

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .automatic

        context.coordinator.attach(to: webView)
        model.webView = webView
        AppLog.log("WebView create \(url.absoluteString)")
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // Keep the same session; only load if nothing is loaded yet.
        if webView.url == nil, !webView.isLoading {
            webView.load(URLRequest(url: url))
        }
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        AppLog.log("WebView dismantle")
        coordinator.detach()
        uiView.stopLoading()
        uiView.navigationDelegate = nil
        uiView.uiDelegate = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private let model: WebViewModel
        private var observations: [NSKeyValueObservation] = []
        private weak var webView: WKWebView?

        init(model: WebViewModel) {
            self.model = model
        }

        func attach(to webView: WKWebView) {
            detach()
            self.webView = webView
            observations = [
                webView.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
                    let progress = view.estimatedProgress
                    self?.onMain {
                        self?.model.progress = progress
                        self?.model.isLoading = progress < 1
                    }
                },
                webView.observe(\.canGoBack, options: [.new]) { [weak self] view, _ in
                    let value = view.canGoBack
                    self?.onMain { self?.model.canGoBack = value }
                },
                webView.observe(\.canGoForward, options: [.new]) { [weak self] view, _ in
                    let value = view.canGoForward
                    self?.onMain { self?.model.canGoForward = value }
                },
                webView.observe(\.url, options: [.new]) { [weak self] view, _ in
                    let url = view.url
                    self?.onMain { self?.model.currentURL = url }
                },
                webView.observe(\.isLoading, options: [.new]) { [weak self] view, _ in
                    let loading = view.isLoading
                    self?.onMain { self?.model.isLoading = loading }
                },
            ]
            sync(webView)
        }

        func detach() {
            observations.forEach { $0.invalidate() }
            observations.removeAll()
            webView = nil
        }

        private func onMain(_ work: @escaping @MainActor () -> Void) {
            Task { @MainActor in
                work()
            }
        }

        private func sync(_ webView: WKWebView) {
            let canGoBack = webView.canGoBack
            let canGoForward = webView.canGoForward
            let currentURL = webView.url
            let isLoading = webView.isLoading
            let progress = webView.estimatedProgress
            onMain {
                model.canGoBack = canGoBack
                model.canGoForward = canGoForward
                model.currentURL = currentURL
                model.isLoading = isLoading
                model.progress = progress
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            AppLog.log("WebView load \(webView.url?.absoluteString ?? "(nil)")")
            sync(webView)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            AppLog.log("WebView finish \(webView.url?.absoluteString ?? "(nil)")")
            sync(webView)
            // Prefill must run on the main thread with a live web view.
            Task { @MainActor [weak webView] in
                guard let webView else { return }
                BookingFormPrefill.inject(into: webView)
                AppLog.log("Prefill inject ran")
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            AppLog.log("WebView fail \(error.localizedDescription)")
            sync(webView)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            AppLog.log("WebView provisional fail \(error.localizedDescription)")
            sync(webView)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            // Open target=_blank links in the same web view.
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
