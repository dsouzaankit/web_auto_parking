import SwiftUI
import WebKit

struct ParkingWebView: View {
    let title: String
    let url: URL
    var prefillContext: PrefillContext = .standard

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
            WebViewRepresentable(url: url, model: model, prefillContext: prefillContext)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .alert("ParkChirp sign-in", isPresented: $model.showParkChirpKeychainHint) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Tap Email Address, then Passwords or the key icon on the keyboard to fill from Keychain. The app cannot pull passwords itself. Automation continues after you sign in.")
        }
        .toolbar {
            // Keep controls in the nav bar (not a bottom toolbar).
            // Trailing only so a pushed garage screen still has room for the system Back.
            ToolbarItemGroup(placement: .topBarTrailing) {
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

                Button {
                    model.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }

                Button {
                    model.prefill(context: prefillContext)
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
    @Published var showParkChirpKeychainHint = false

    weak var webView: WKWebView?

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func reload() { webView?.reload() }
    func prefill(context: PrefillContext = .standard) {
        guard let webView else { return }
        BookingFormPrefill.inject(into: webView, trigger: .manual, context: context)
    }
}

struct WebViewRepresentable: UIViewRepresentable {
    let url: URL
    let model: WebViewModel
    var prefillContext: PrefillContext = .standard

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model, prefillContext: prefillContext)
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
        config.userContentController.add(context.coordinator, name: Coordinator.bridgeName)
        // Reliable XHR capture for LAN — Safari Web Inspector Network domain is unavailable via iwdp on Windows.
        config.userContentController.addUserScript(XHRCapture.userScript())
        // ParkMobile zone prefill uses navigator.geolocation; stub with native Core Location.
        config.userContentController.addUserScript(
            GeolocationBridge.userScript(
                latitude: prefillContext.latitude,
                longitude: prefillContext.longitude
            )
        )

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .automatic
        // Opt-in for Safari Web Inspector / ios-webkit-debug-proxy (iOS 16.4+).
        if #available(iOS 16.4, *) {
            webView.isInspectable = true
        }

        context.coordinator.bind(webView)
        context.coordinator.noteInitialGeolocation(prefillContext)
        model.webView = webView
        AppLog.log(
            "WebView create \(url.absoluteString) geo=\(prefillContext.latitude.map { String(format: "%.5f", $0) } ?? "nil"),\(prefillContext.longitude.map { String(format: "%.5f", $0) } ?? "nil")"
        )
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.prefillContext = prefillContext
        context.coordinator.applyNativeGeolocation(to: webView)
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        AppLog.log("WebView dismantle")
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: Coordinator.bridgeName)
        coordinator.unbind()
        uiView.stopLoading()
        uiView.navigationDelegate = nil
        uiView.uiDelegate = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        static let bridgeName = "parkingBridge"

        private let model: WebViewModel
        var prefillContext: PrefillContext
        private var observations: [NSKeyValueObservation] = []
        private var lastPublishedProgress: Double = -1
        private var prefillWorkItem: DispatchWorkItem?
        private var autoPrefillAttempts = 0
        private var lastPrefillURL: String?
        private var lastNativeGeoKey: String?
        private var createdWithoutNativeGeo = false
        private var didReloadForNativeGeo = false

        init(model: WebViewModel, prefillContext: PrefillContext) {
            self.model = model
            self.prefillContext = prefillContext
        }

        func noteInitialGeolocation(_ context: PrefillContext) {
            createdWithoutNativeGeo = context.latitude == nil || context.longitude == nil
            if let lat = context.latitude, let lng = context.longitude {
                lastNativeGeoKey = String(format: "%.5f,%.5f", lat, lng)
            }
        }

        /// Push Core Location into navigator.geolocation; reload zone entry once if first load lacked coords.
        func applyNativeGeolocation(to webView: WKWebView) {
            guard let lat = prefillContext.latitude, let lng = prefillContext.longitude else { return }
            let key = String(format: "%.5f,%.5f", lat, lng)
            webView.evaluateJavaScript(GeolocationBridge.installJS(latitude: lat, longitude: lng), completionHandler: nil)
            let path = webView.url?.path.lowercased() ?? ""
            let onZoneEntry = path.contains("/search")
                || path.contains("/zone/start")
                || path.hasSuffix("/zone")
                || path.hasSuffix("/zone/")
            if key != lastNativeGeoKey {
                lastNativeGeoKey = key
            }
            if onZoneEntry, createdWithoutNativeGeo, !didReloadForNativeGeo, prefillContext.mode == .parkMobileZone {
                didReloadForNativeGeo = true
                AppLog.log("WebView reload for native geolocation stub \(key)")
                webView.reload()
            }
        }

        func bind(_ webView: WKWebView) {
            unbind()
            // Progress + URL + history — ParkMobile SPA often changes URL via History API
            // without didFinish, so canGoBack/Forward must be KVO'd (not only nav callbacks).
            observations = [
                webView.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
                    let progress = view.estimatedProgress
                    DispatchQueue.main.async {
                        self?.publishProgress(progress)
                    }
                },
                webView.observe(\.canGoBack, options: [.new]) { [weak self] view, _ in
                    DispatchQueue.main.async { self?.publishNavigationState(from: view) }
                },
                webView.observe(\.canGoForward, options: [.new]) { [weak self] view, _ in
                    DispatchQueue.main.async { self?.publishNavigationState(from: view) }
                },
                webView.observe(\.url, options: [.new]) { [weak self] view, _ in
                    let url = view.url
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.publishNavigationState(from: view)
                        let key = url?.absoluteString
                        guard let key, key != self.lastPrefillURL else { return }
                        guard BookingFormPrefill.shouldInject(for: url, trigger: .auto) else { return }
                        // Ignore transient same-host noise; only restart when path/query meaningfully changes.
                        AppLog.log("WebView URL changed \(key)")
                        self.lastPrefillURL = key
                        self.scheduleAutoPrefill(for: view)
                    }
                }
            ]
        }

        func unbind() {
            prefillWorkItem?.cancel()
            prefillWorkItem = nil
            autoPrefillAttempts = 0
            lastPrefillURL = nil
            observations.forEach { $0.invalidate() }
            observations.removeAll()
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == Self.bridgeName,
                  let body = message.body as? [String: Any]
            else { return }
            DispatchQueue.main.async {
                let type = body["type"] as? String ?? ""
                if type == "log" {
                    let text = body["message"] as? String ?? "\(body)"
                    AppLog.log("Prefill bridge \(text)")
                } else if type == "parkChirpKeychain" {
                    AppLog.log("Prefill bridge parkChirpKeychain prompt")
                    self.model.showParkChirpKeychainHint = true
                } else if type == "xhr" {
                    let method = body["method"] as? String ?? "?"
                    let url = body["url"] as? String ?? "?"
                    let status = self.intValue(body["status"])
                    let ms = self.intValue(body["ms"])
                    let kind = body["kind"] as? String ?? "xhr"
                    let req = body["requestBody"] as? String ?? ""
                    let res = body["responseBody"] as? String ?? ""
                    let line = "XHR \(kind) \(method) \(status) \(ms)ms \(url)"
                    AppLog.log(line)
                    var detail = line
                    if !req.isEmpty { detail += "\n  req: \(req)" }
                    if !res.isEmpty { detail += "\n  res: \(res)" }
                    XHRCapture.append(detail)
                }
            }
        }

        private func intValue(_ any: Any?) -> Int {
            if let n = any as? Int { return n }
            if let n = any as? Int64 { return Int(n) }
            if let n = any as? Double { return Int(n) }
            if let n = any as? NSNumber { return n.intValue }
            return 0
        }

        private func scheduleAutoPrefill(for webView: WKWebView) {
            prefillWorkItem?.cancel()
            autoPrefillAttempts = 0
            lastPrefillURL = webView.url?.absoluteString
            enqueueAutoPrefill(for: webView, delay: 0.8)
        }

        private func enqueueAutoPrefill(for webView: WKWebView, delay: TimeInterval) {
            prefillWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self, weak webView] in
                guard let self, let webView else { return }
                self.autoPrefillAttempts += 1
                BookingFormPrefill.inject(into: webView, trigger: .auto, context: self.prefillContext) { outcome in
                    DispatchQueue.main.async {
                        let shouldRetry: Bool
                        switch outcome {
                        case .filled, .error:
                            shouldRetry = false
                        case .skipped:
                            shouldRetry = false
                        case .advanced, .captcha, .waiting, .unknown:
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

        @available(iOS 15.0, *)
        func webView(
            _ webView: WKWebView,
            requestGeolocationPermissionForOrigin origin: WKSecurityOrigin,
            initiatedByFrame frame: WKFrameInfo,
            decisionHandler: @escaping (WKPermissionDecision) -> Void
        ) {
            AppLog.log("WebView geolocation grant for \(origin.host)")
            decisionHandler(.grant)
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
