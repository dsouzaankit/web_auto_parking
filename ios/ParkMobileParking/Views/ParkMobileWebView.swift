import SwiftUI
import WebKit

struct ParkMobileWebView: View {
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

        model.webView = webView
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // Keep the same session; only reload if the requested URL changed externally.
        if webView.url == nil {
            webView.load(URLRequest(url: url))
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private let model: WebViewModel
        private var observations: [NSKeyValueObservation] = []

        init(model: WebViewModel) {
            self.model = model
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            model.isLoading = true
            bind(webView)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            model.isLoading = false
            model.progress = 1
            sync(webView)
            BookingFormPrefill.inject(into: webView)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            model.isLoading = false
            sync(webView)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            model.isLoading = false
            sync(webView)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            // Open target=_blank links in the same web view.
            if navigationAction.targetFrame == nil, let request = navigationAction.request.url.map(URLRequest.init) {
                webView.load(request)
            }
            return nil
        }

        private func bind(_ webView: WKWebView) {
            guard observations.isEmpty else {
                sync(webView)
                return
            }
            observations = [
                webView.observe(\.estimatedProgress) { [weak self] view, _ in
                    Task { @MainActor in
                        self?.model.progress = view.estimatedProgress
                        self?.model.isLoading = view.estimatedProgress < 1
                    }
                },
                webView.observe(\.canGoBack) { [weak self] view, _ in
                    Task { @MainActor in self?.model.canGoBack = view.canGoBack }
                },
                webView.observe(\.canGoForward) { [weak self] view, _ in
                    Task { @MainActor in self?.model.canGoForward = view.canGoForward }
                },
                webView.observe(\.url) { [weak self] view, _ in
                    Task { @MainActor in self?.model.currentURL = view.url }
                }
            ]
            sync(webView)
        }

        private func sync(_ webView: WKWebView) {
            model.canGoBack = webView.canGoBack
            model.canGoForward = webView.canGoForward
            model.currentURL = webView.url
        }
    }
}

#Preview {
    NavigationStack {
        ParkMobileWebView(
            title: "1525 Harbor Garage",
            url: Garage.harborWeehawken.reservationURL(from: .now)
        )
    }
}
