import Foundation
import WebKit

/// Latest WebView HTML snapshot for LAN `/html` — one file, overwritten in place.
/// `/hooks.txt` is a compact tag inventory so ParkMobile frontend updates are visible without grepping the blob.
enum HTMLCapture {
    private static let queue = DispatchQueue(label: "com.webautoparking.html-capture")
    private static let maxChars = 1_500_000
    private static let minInterval: TimeInterval = 8
    private static var dumpInFlight = false
    private static var lastDumpAt: Date?
    private static var snapshot = "<!-- no html dump yet -->\n"
    private static var hooksText = "(no html dump yet)\n"

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static var pageURL: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = root.appendingPathComponent("logs", isDirectory: true)
        return dir.appendingPathComponent("page.html")
    }

    static var hooksURL: URL {
        pageURL.deletingLastPathComponent().appendingPathComponent("hooks.txt")
    }

    static func clear() {
        queue.sync {
            snapshot = "<!-- no html dump yet -->\n"
            hooksText = "(no html dump yet)\n"
            dumpInFlight = false
            lastDumpAt = nil
            ensureDirectoryLocked()
            try? snapshot.write(to: pageURL, atomically: true, encoding: .utf8)
            try? hooksText.write(to: hooksURL, atomically: true, encoding: .utf8)
        }
    }

    static func readHTML() -> String {
        queue.sync {
            if let data = try? Data(contentsOf: pageURL),
               let text = String(data: data, encoding: .utf8),
               !text.isEmpty {
                return text
            }
            return snapshot
        }
    }

    static func readHooks() -> String {
        queue.sync {
            if let data = try? Data(contentsOf: hooksURL),
               let text = String(data: data, encoding: .utf8),
               !text.isEmpty {
                return text
            }
            return hooksText
        }
    }

    /// Prefill / navigation posts `{ type: "htmlDump", reason, url }` (no HTML in the bridge).
    /// Always overwrites the same `page.html` + `hooks.txt` so a hang shows the latest FE.
    static func requestDump(from webView: WKWebView, reason: String, pageURL page: String) {
        let now = Date()
        var skip = false
        queue.sync {
            if dumpInFlight { skip = true }
            else if let last = lastDumpAt, now.timeIntervalSince(last) < minInterval { skip = true }
            else { dumpInFlight = true }
        }
        guard !skip else { return }

        let js = """
        (function() {
          function clip(s, n) {
            s = String(s || '').replace(/\\s+/g, ' ').trim();
            return s.length > n ? s.slice(0, n) : s;
          }
          var pmtest = [];
          var seen = {};
          var nodes = document.querySelectorAll('[data-pmtest-id], [data-testid]');
          for (var i = 0; i < nodes.length && pmtest.length < 80; i++) {
            var el = nodes[i];
            var id = el.getAttribute('data-pmtest-id') || el.getAttribute('data-testid') || '';
            if (!id || seen[id]) continue;
            seen[id] = true;
            pmtest.push(id);
          }
          var buttons = [];
          var btns = document.querySelectorAll('button, a[role=\"button\"], [role=\"button\"]');
          for (var j = 0; j < btns.length && buttons.length < 40; j++) {
            var b = btns[j];
            var img = b.querySelector('img');
            buttons.push({
              tag: String(b.tagName || '').toLowerCase(),
              type: b.getAttribute('type') || '',
              pmtest: b.getAttribute('data-pmtest-id') || '',
              testid: b.getAttribute('data-testid') || '',
              text: clip(b.innerText || b.textContent || '', 48),
              img: img ? clip(img.getAttribute('alt') || '', 40) : '',
              disabled: !!(b.disabled || b.getAttribute('aria-disabled') === 'true')
            });
          }
          var html = '';
          try {
            html = (document.documentElement && document.documentElement.outerHTML)
              || (document.body && document.body.outerHTML)
              || '';
          } catch (e) {}
          var stepper = '';
          try {
            var stepRoot = document.querySelector('[data-pmtest-id=\"guest-checkout-stepper\"], [data-pmtest-id*=\"checkout-stepper\"], [data-pmtest-id*=\"stepper\"]');
            stepper = clip((stepRoot && stepRoot.innerText) || '', 400);
          } catch (e2) {}
          var iframes = [];
          var frames = document.querySelectorAll('iframe');
          for (var f = 0; f < frames.length && iframes.length < 4; f++) {
            var frame = frames[f];
            var inner = '';
            var same = false;
            try {
              var doc = frame.contentDocument;
              if (doc && doc.documentElement) {
                same = true;
                inner = clip(doc.documentElement.outerHTML || '', 4000);
              }
            } catch (e3) {}
            iframes.push({
              src: clip(frame.getAttribute('src') || '', 160),
              title: clip(frame.getAttribute('title') || '', 48),
              pmtest: frame.getAttribute('data-pmtest-id') || '',
              sameOrigin: same,
              html: inner
            });
          }
          var shadows = 0;
          try {
            var all = document.querySelectorAll('*');
            for (var s = 0; s < all.length && s < 2500; s++) {
              if (all[s].shadowRoot) shadows += 1;
            }
          } catch (e4) {}
          return {
            html: html,
            title: String(document.title || ''),
            stepper: stepper,
            shadows: shadows,
            iframes: iframes,
            pmtest: pmtest,
            buttons: buttons
          };
        })()
        """
        webView.evaluateJavaScript(js) { result, error in
            let dict = result as? [String: Any]
            let html = dict?["html"] as? String ?? (result as? String ?? "")
            let title = dict?["title"] as? String ?? ""
            let stepper = dict?["stepper"] as? String ?? ""
            let shadows: Int = {
                if let n = dict?["shadows"] as? Int { return n }
                if let n = dict?["shadows"] as? NSNumber { return n.intValue }
                if let n = dict?["shadows"] as? Double { return Int(n) }
                return 0
            }()
            let pmtest = dict?["pmtest"] as? [String] ?? []
            let iframeRows = (dict?["iframes"] as? [[String: Any]] ?? []).map { row -> String in
                let src = row["src"] as? String ?? ""
                let iframeTitle = row["title"] as? String ?? ""
                let pm = row["pmtest"] as? String ?? ""
                let same = (row["sameOrigin"] as? Bool)
                    ?? (row["sameOrigin"] as? NSNumber)?.boolValue
                    ?? false
                let inner = row["html"] as? String ?? ""
                var line = "src=\(src.isEmpty ? "(none)" : src)"
                if !iframeTitle.isEmpty { line += " title=\(iframeTitle)" }
                if !pm.isEmpty { line += " pmtest=\(pm)" }
                line += " sameOrigin=\(same)"
                if !inner.isEmpty { line += " html=\(inner)" }
                return line
            }
            let buttonRows = (dict?["buttons"] as? [[String: Any]] ?? []).map { row -> String in
                let tag = row["tag"] as? String ?? "el"
                let type = row["type"] as? String ?? ""
                let pm = row["pmtest"] as? String ?? ""
                let text = row["text"] as? String ?? ""
                let img = row["img"] as? String ?? ""
                let disabled = (row["disabled"] as? Bool)
                    ?? (row["disabled"] as? NSNumber)?.boolValue
                    ?? false
                var line = "<\(tag)"
                if !type.isEmpty { line += " type=\(type)" }
                if !pm.isEmpty { line += " pmtest=\(pm)" }
                if disabled { line += " disabled" }
                line += ">"
                if !text.isEmpty { line += " text=\(text)" }
                if !img.isEmpty { line += " img=\(img)" }
                return line
            }
            let stamp = isoFormatter.string(from: Date())
            var hooks = "dumped \(stamp)\nreason=\(reason)\nurl=\(page)\ntitle=\(title)\n"
            if !stepper.isEmpty {
                hooks += "stepper:\n  \(stepper)\n"
            }
            hooks += "shadowRoots: \(shadows)\n"
            hooks += "iframes:\n"
            if iframeRows.isEmpty {
                hooks += "  (none)\n"
            } else {
                for line in iframeRows { hooks += "  \(line)\n" }
            }
            hooks += "pmtest:\n"
            if pmtest.isEmpty {
                hooks += "  (none)\n"
            } else {
                for id in pmtest { hooks += "  \(id)\n" }
            }
            hooks += "buttons:\n"
            if buttonRows.isEmpty {
                hooks += "  (none)\n"
            } else {
                for line in buttonRows { hooks += "  \(line)\n" }
            }

            queue.async {
                dumpInFlight = false
                lastDumpAt = Date()
                var body = html
                var note = ""
                if body.count > maxChars {
                    note = " truncated"
                    body = String(body.prefix(maxChars)) + "\n<!-- truncated \(html.count) chars -->\n"
                }
                snapshot = "<!-- dumped \(stamp) reason=\(reason) url=\(page) chars=\(html.count)\(note) -->\n" + body
                hooksText = hooks
                ensureDirectoryLocked()
                try? snapshot.write(to: pageURL, atomically: true, encoding: .utf8)
                try? hooksText.write(to: hooksURL, atomically: true, encoding: .utf8)
            }
            DispatchQueue.main.async {
                if let error {
                    AppLog.log("HTML dump error: \(error.localizedDescription)")
                }
                let preview = buttonRows.prefix(6).joined(separator: " | ")
                AppLog.log(
                    "HTML dump reason=\(reason) chars=\(html.count) /html /hooks.txt"
                    + (preview.isEmpty ? "" : " buttons=\(preview)")
                )
            }
        }
    }

    private static func ensureDirectoryLocked() {
        let dir = pageURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
}
