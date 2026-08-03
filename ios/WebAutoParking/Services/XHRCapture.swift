import Foundation
import WebKit

/// In-app fetch/XHR capture for LAN debugging when Safari Web Inspector Network is unavailable.
enum XHRCapture {
    private static let queue = DispatchQueue(label: "com.webautoparking.xhr-capture")
    private static let maxBytes = 512 * 1024
    private static var buffer = ""

    static var logURL: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = root.appendingPathComponent("logs", isDirectory: true)
        return dir.appendingPathComponent("xhr.txt")
    }

    static func clear() {
        queue.sync {
            buffer = ""
            ensureDirectoryLocked()
            try? "".write(to: logURL, atomically: true, encoding: .utf8)
        }
    }

    static func append(_ line: String) {
        queue.sync {
            ensureDirectoryLocked()
            truncateIfNeededLocked()
            let stamp = ISO8601DateFormatter().string(from: Date())
            buffer += "\(stamp) \(line)\n"
            flushLocked()
        }
    }

    static func readAllText() -> String {
        queue.sync {
            flushLocked()
            guard let data = try? Data(contentsOf: logURL),
                  let text = String(data: data, encoding: .utf8),
                  !text.isEmpty
            else { return "(empty xhr log)\n" }
            return text
        }
    }

    /// Injected at document start so ParkMobile SPA traffic is wrapped early.
    static func userScript() -> WKUserScript {
        let source = """
        (function() {
          if (window.__parkingXhrHookInstalled) return;
          window.__parkingXhrHookInstalled = true;
          var MAX = 4000;
          function clip(v) {
            if (v == null) return '';
            var s = (typeof v === 'string') ? v : (function() {
              try { return JSON.stringify(v); } catch (e) { return String(v); }
            })();
            if (s.length > MAX) return s.slice(0, MAX) + '…[truncated ' + s.length + ']';
            return s;
          }
          function post(entry) {
            try {
              if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.parkingBridge) {
                window.webkit.messageHandlers.parkingBridge.postMessage(Object.assign({ type: 'xhr' }, entry));
              }
            } catch (e) {}
          }
          function interesting(url) {
            try {
              var u = String(url || '');
              return /parkmobile|arrive|zone|api\\//i.test(u);
            } catch (e) { return true; }
          }

          var origFetch = window.fetch;
          if (typeof origFetch === 'function') {
            window.fetch = function(input, init) {
              var url = (typeof input === 'string') ? input : ((input && input.url) || '');
              var method = ((init && init.method) || (input && input.method) || 'GET').toUpperCase();
              var body = init && init.body != null ? clip(init.body) : '';
              var started = Date.now();
              return origFetch.apply(this, arguments).then(function(res) {
                if (!interesting(url)) return res;
                try {
                  var clone = res.clone();
                  clone.text().then(function(text) {
                    post({
                      kind: 'fetch',
                      method: method,
                      url: String(url),
                      status: res.status,
                      ms: Date.now() - started,
                      requestBody: body,
                      responseBody: clip(text)
                    });
                  }).catch(function() {
                    post({
                      kind: 'fetch',
                      method: method,
                      url: String(url),
                      status: res.status,
                      ms: Date.now() - started,
                      requestBody: body,
                      responseBody: ''
                    });
                  });
                } catch (e) {}
                return res;
              }, function(err) {
                if (interesting(url)) {
                  post({
                    kind: 'fetch',
                    method: method,
                    url: String(url),
                    status: 0,
                    ms: Date.now() - started,
                    requestBody: body,
                    responseBody: 'ERROR ' + String(err && err.message || err)
                  });
                }
                throw err;
              });
            };
          }

          var XO = window.XMLHttpRequest;
          if (!XO || !XO.prototype) return;
          var open = XO.prototype.open;
          var send = XO.prototype.send;
          XO.prototype.open = function(method, url) {
            this.__parkingMethod = String(method || 'GET').toUpperCase();
            this.__parkingUrl = String(url || '');
            return open.apply(this, arguments);
          };
          XO.prototype.send = function(body) {
            var xhr = this;
            var method = xhr.__parkingMethod || 'GET';
            var url = xhr.__parkingUrl || '';
            var reqBody = body != null ? clip(body) : '';
            var started = Date.now();
            xhr.addEventListener('loadend', function() {
              if (!interesting(url)) return;
              post({
                kind: 'xhr',
                method: method,
                url: url,
                status: xhr.status || 0,
                ms: Date.now() - started,
                requestBody: reqBody,
                responseBody: clip(xhr.responseText || '')
              });
            });
            return send.apply(this, arguments);
          };
        })();
        """
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }

    private static func ensureDirectoryLocked() {
        let dir = logURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private static func flushLocked() {
        guard let data = buffer.data(using: .utf8), !data.isEmpty else { return }
        let url = logURL
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forUpdating: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: url, options: .atomic)
            }
            buffer = ""
        } catch {
            buffer = ""
        }
    }

    private static func truncateIfNeededLocked() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path),
              let size = attrs[.size] as? NSNumber,
              size.intValue > maxBytes,
              let data = try? Data(contentsOf: logURL),
              let text = String(data: data, encoding: .utf8)
        else { return }
        let keep = String(text.suffix(maxBytes / 2))
        try? ("… truncated …\n" + keep).write(to: logURL, atomically: true, encoding: .utf8)
    }
}
