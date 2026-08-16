import Foundation
import WebKit

enum BookingFormPrefill {
    enum Trigger: String {
        case auto
        case manual
    }

    /// Auto-inject on checkout pages; recaptcha pages are detected and skipped.
    static var autoInjectEnabled = true

    enum Outcome: String {
        case filled
        case advanced
        case waiting
        case captcha
        case skipped
        case error
        case unknown
    }

    /// Prefill on checkout / login-to-checkout pages (ParkMobile often redirects reservation → login).
    static func shouldInject(for url: URL?, trigger: Trigger) -> Bool {
        guard trigger == .manual || autoInjectEnabled else { return false }
        guard let url,
              let host = url.host?.lowercased()
        else { return false }

        let isParkingHost =
            host.contains("parkmobile")
            || host.contains("spothero")
            || host.contains("parkme")
            || host.contains("parkchirp")
        guard isParkingHost else { return false }

        // Paid guest meter / confirmation — do not let automation navigate away.
        if ParkingSessionStore.isProtectedURL(url) { return false }

        let path = url.path.lowercased()
        let query = (url.query ?? "").lowercased()
        let haystack = path + "?" + query

        return haystack.contains("reservation")
            || haystack.contains("purchase")
            || haystack.contains("checkout")
            || haystack.contains("payment")
            || haystack.contains("/book")
            || haystack.contains("facilities")
            || haystack.contains("search")
            || path.contains("/zone")
            || path.contains("login")
            || path.contains("signin")
            || path.contains("sign-in")
            || path.contains("guest")
            || path.contains("account")
    }

    /// Applies `BookingConfig.json` field values into visible form inputs.
    static func inject(
        into webView: WKWebView,
        config: BookingConfig = .load(),
        trigger: Trigger = .auto,
        context: PrefillContext = .standard,
        completion: ((Outcome) -> Void)? = nil
    ) {
        guard shouldInject(for: webView.url, trigger: trigger) else {
            AppLog.log("Prefill skipped (\(trigger.rawValue)) for \(webView.url?.absoluteString ?? "(nil)")")
            completion?(.skipped)
            return
        }
        AppLog.log("Prefill inject (\(trigger.rawValue)) \(webView.url?.absoluteString ?? "(nil)") mode=\(context.mode.rawValue)")
        webView.evaluateJavaScript(script(config: config, context: context)) { result, error in
            if let error {
                AppLog.log("Prefill JS error: \(error.localizedDescription)")
                completion?(.error)
                return
            }
            let text = result as? String ?? ""
            if !text.isEmpty {
                AppLog.log("Prefill JS \(text)")
            } else {
                AppLog.log("Prefill JS ok")
            }
            completion?(outcome(from: text))
        }
    }

    private static func outcome(from jsResult: String) -> Outcome {
        if jsResult.contains("\"status\":\"filled\"") { return .filled }
        if jsResult.contains("\"status\":\"advanced\"") { return .advanced }
        if jsResult.contains("\"status\":\"captcha\"") { return .captcha }
        if jsResult.contains("\"status\":\"waiting\"") { return .waiting }
        if jsResult.contains("\"status\":\"error\"") { return .error }
        return .unknown
    }

    private static func script(config: BookingConfig, context: PrefillContext = .standard) -> String {
        let email = jsonString(config.normalizedEmail)
        let phone = jsonString(config.normalizedPhone)
        let address = jsonString(config.normalizedAddress)
        let makeModel = jsonString(config.vehicle.normalizedMakeAndModel)
        let plate = jsonString(config.vehicle.normalizedLicensePlate)
        let country = jsonString(config.vehicle.normalizedCountry)
        let state = jsonString(config.vehicle.normalizedState)
        let preferGuest = config.preferGuestCheckout ? "true" : "false"
        let payment = jsonString(config.prefersApplePay ? "applePay" : config.paymentMethod)
        let zoneMode = context.mode == .parkMobileZone ? "true" : "false"
        let zoneAuto = context.zoneAutomationEnabled ? "true" : "false"
        let latJS = context.latitude.map { String($0) } ?? "null"
        let lngJS = context.longitude.map { String($0) } ?? "null"
        let maxDur = max(1, context.maxDurationMinutes)
        // Today…current+2 × 5:30…11:00 → 11:30 — walk until SPA accepts (or cap).
        let parkChirpCandidates = SessionWindow.parkChirpEveningCandidates()
        let parkChirpCandidatesJSON: String = {
            let pairs = parkChirpCandidates.map { window in
                [
                    "startSec": SessionWindow.unixParkChirpWallSeconds(window.start),
                    "endSec": SessionWindow.unixParkChirpWallSeconds(window.end)
                ]
            }
            guard let data = try? JSONSerialization.data(withJSONObject: pairs),
                  let text = String(data: data, encoding: .utf8)
            else { return "[]" }
            return text
        }()

        // Intentionally conservative: no continuous MutationObserver (that looped on SPAs and crashed WKWebView).
        return """
        (function() {
          var cfg = {
            email: \(email),
            phone: \(phone),
            address: \(address),
            makeAndModel: \(makeModel),
            licensePlateNumber: \(plate),
            country: \(country),
            state: \(state),
            preferGuestCheckout: \(preferGuest),
            paymentMethod: \(payment),
            parkChirpCandidates: \(parkChirpCandidatesJSON),
            parkMobileZoneMode: \(zoneMode),
            zoneAutomationEnabled: \(zoneAuto),
            lat: \(latJS),
            lng: \(lngJS),
            maxDurationMinutes: \(maxDur)
          };

          function norm(s) { return (s || '').toLowerCase().replace(/[^a-z0-9]+/g, ''); }
          function visible(el) {
            if (!el) return false;
            try {
              var style = window.getComputedStyle(el);
              if (style.display === 'none' || style.visibility === 'hidden' || style.opacity === '0') return false;
              var r = el.getBoundingClientRect();
              return r.width > 0 && r.height > 0;
            } catch (e) { return false; }
          }
          /// Only nudge scroll when mostly off-screen. `block:'center'` was yanking to Continue/submit every tick.
          function ensureInView(el) {
            if (!el) return;
            try {
              var r = el.getBoundingClientRect();
              var vh = window.innerHeight || document.documentElement.clientHeight || 0;
              var vw = window.innerWidth || document.documentElement.clientWidth || 0;
              if (vh <= 0 || vw <= 0) return;
              var margin = 12;
              var inView = r.bottom > margin && r.top < vh - margin && r.right > margin && r.left < vw - margin;
              if (inView) return;
              el.scrollIntoView({ block: 'nearest', inline: 'nearest' });
            } catch (e) {}
          }
          function click(el, opts) {
            if (!el || !visible(el)) return false;
            var doScroll = !opts || opts.scroll !== false;
            if (doScroll) ensureInView(el);
            try { el.click(); } catch (e) {}
            return true;
          }
          function setNativeValue(el, value) {
            if (!el || value == null || value === '') return false;
            if (el.disabled || el.readOnly) return false;
            // Do not scroll/focus on fill — automation retries were jumping the viewport every few seconds.
            var tag = (el.tagName || '').toUpperCase();
            if (tag === 'SELECT') return setSelectValue(el, value);
            try {
              var proto = el instanceof HTMLTextAreaElement
                ? HTMLTextAreaElement.prototype
                : HTMLInputElement.prototype;
              var last = el.value;
              var setter = Object.getOwnPropertyDescriptor(proto, 'value');
              if (setter && setter.set) setter.set.call(el, value);
              else el.value = value;
              try {
                var tracker = el._valueTracker;
                if (tracker && typeof tracker.setValue === 'function') tracker.setValue(last);
              } catch (e2) {}
              el.dispatchEvent(new Event('input', { bubbles: true }));
              el.dispatchEvent(new Event('change', { bubbles: true }));
              el.dispatchEvent(new Event('blur', { bubbles: true }));
              return true;
            } catch (e) { return false; }
          }
          function setSelectValue(el, value) {
            var want = norm(value);
            var aliases = [want];
            // Full names ↔ ISO codes used by ParkMobile selects.
            if (want === 'unitedstates' || want === 'usa' || want === 'america') aliases.push('us');
            if (want === 'us') aliases.push('unitedstates');
            if (want === 'canada') aliases.push('ca');
            if (want === 'ca') aliases.push('canada');
            if (want === 'mexico') aliases.push('mx');
            if (want === 'mx') aliases.push('mexico');
            if (want === 'newjersey') aliases.push('nj');
            if (want === 'nj') aliases.push('newjersey');
            var options = el.options || [];
            var match = null;
            for (var a = 0; a < aliases.length && !match; a++) {
              var alias = aliases[a];
              for (var i = 0; i < options.length; i++) {
                var opt = options[i];
                var val = norm(opt.value || '');
                var text = norm(opt.text || '');
                var key = norm((opt.value || '') + ' ' + (opt.text || '') + ' ' + (opt.label || ''));
                if (!key) continue;
                if (val === alias || text === alias || key === alias) { match = opt; break; }
                if (key.indexOf(alias) !== -1 || alias.indexOf(val) !== -1) {
                  match = opt;
                  if (val === alias || text === alias) break;
                }
              }
            }
            if (!match) return false;
            el.value = match.value;
            el.dispatchEvent(new Event('input', { bubbles: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
            return true;
          }
          function firstVisible(selector) {
            var nodes = document.querySelectorAll(selector);
            for (var i = 0; i < nodes.length; i++) {
              if (visible(nodes[i])) return nodes[i];
            }
            return null;
          }
          function labelText(el) {
            var t = '';
            if (el.labels && el.labels.length) {
              t = Array.prototype.map.call(el.labels, function(l) { return l.textContent; }).join(' ');
            }
            return norm(
              t + ' ' + (el.getAttribute('aria-label') || '') + ' ' + (el.placeholder || '') + ' ' +
              (el.name || '') + ' ' + (el.id || '') + ' ' + (el.autocomplete || '')
            );
          }
          function classify(el) {
            // Prefer id/name — ParkMobile vehicle selects concatenate label+id+name so
            // /^country$/ never matched \"country country country\".
            var id = norm(el.id || '');
            var name = norm(el.name || '');
            if (id === 'vrn' || name === 'vrn') return 'plate';
            if (id === 'email' || name === 'email') return 'email';
            if (id === 'phone' || name === 'phone') return 'phone';
            if (id === 'country' || name === 'country') return 'country';
            if (id === 'state' || name === 'state') return 'state';
            var key = labelText(el);
            if (!key) return null;
            if (key.indexOf('email') !== -1 || key.indexOf('mailaddress') !== -1) return 'email';
            if (key.indexOf('phone') !== -1 || key.indexOf('mobile') !== -1 || key.indexOf('tel') !== -1) return 'phone';
            if (key.indexOf('licenseplate') !== -1 || key.indexOf('platenumber') !== -1
                || key.indexOf('vehicleplate') !== -1 || key === 'plate' || key.indexOf('lpnumber') !== -1) return 'plate';
            if ((key.indexOf('makeandmodel') !== -1 || key.indexOf('vehiclemake') !== -1
                || key.indexOf('make') !== -1 || key.indexOf('model') !== -1)
                && key.indexOf('payment') === -1 && key.indexOf('card') === -1) return 'makeModel';
            if (key.indexOf('country') !== -1 && key.indexOf('phonecountry') === -1) return 'country';
            if ((key.indexOf('state') !== -1 || key.indexOf('province') !== -1)
                && key.indexOf('statement') === -1) return 'state';
            if ((key.indexOf('address') !== -1 || key.indexOf('street') !== -1)
                && key.indexOf('email') === -1 && key.indexOf('phone') === -1) return 'address';
            return null;
          }
          function textOf(el) {
            return norm((el.innerText || el.textContent || '') + ' ' + (el.getAttribute('aria-label') || '') + ' ' + (el.value || ''));
          }
          function findByText(selectors, re) {
            var nodes = document.querySelectorAll(selectors);
            for (var i = 0; i < Math.min(nodes.length, 200); i++) {
              var el = nodes[i];
              if (!visible(el)) continue;
              if (re.test(textOf(el)) || re.test(labelText(el))) return el;
            }
            return null;
          }
          function applyKind(el, kind) {
            if (kind === 'email') return setNativeValue(el, cfg.email);
            if (kind === 'phone') return setNativeValue(el, cfg.phone);
            if (kind === 'address') return setNativeValue(el, cfg.address);
            if (kind === 'makeModel') return setNativeValue(el, cfg.makeAndModel);
            if (kind === 'plate') return setNativeValue(el, cfg.licensePlateNumber);
            if (kind === 'country') return setNativeValue(el, cfg.country);
            if (kind === 'state') return setNativeValue(el, cfg.state);
            return false;
          }

          // Only block on a *visible challenge*. ParkMobile embeds a permanent
          // reCAPTCHA badge iframe; treating that as captcha permanently skipped fill.
          function hasBlockingCaptcha() {
            try {
              var challenge = document.querySelector(
                'iframe[src*=\"recaptcha/api2/bframe\"], iframe[title*=\"recaptcha challenge\" i], iframe[src*=\"hcaptcha.com/challenge\"]'
              );
              if (challenge && visible(challenge)) return true;
              var modal = document.querySelector(
                '[class*=\"captcha-modal\" i], [id*=\"captcha-modal\" i], [aria-modal=\"true\"][class*=\"captcha\" i]'
              );
              if (modal && visible(modal)) return true;
              return false;
            } catch (e) {
              return false;
            }
          }

          function dismissCookieBanner() {
            var accept = findByText('button, a, [role=\"button\"]', /^(accept|agree|allowall|acceptall|gotit)$/);
            if (accept) return click(accept);
            try {
              document.querySelectorAll('#onetrust-banner-sdk, .onetrust-pc-dark-filter, #onetrust-consent-sdk')
                .forEach(function(el) { el.remove(); });
            } catch (e) {}
            return false;
          }

          function fillFields() {
            var filled = 0;
            var nodes = document.querySelectorAll('input, textarea, select');
            for (var i = 0; i < nodes.length; i++) {
              var el = nodes[i];
              if (!visible(el)) continue;
              var type = (el.type || '').toLowerCase();
              if (type === 'hidden' || type === 'password' || type === 'checkbox' || type === 'radio'
                  || type === 'submit' || type === 'button' || type === 'file') continue;
              // Never touch promo codes.
              if (/promo/i.test(el.id || '') || /promo/i.test(el.name || '')) continue;
              if (el.tagName !== 'SELECT' && el.value && String(el.value).trim() !== '') continue;
              if (el.tagName === 'SELECT' && el.value && String(el.value).trim() !== '' && el.selectedIndex > 0) continue;
              var kind = classify(el);
              if (!kind) continue;
              if (applyKind(el, kind)) filled += 1;
            }
            filled += fillContactFields();
            // ParkMobile vehicle block: always target *visible* #vrn/#country/#state
            // (page mounts hidden duplicates that break querySelector).
            filled += fillParkMobileVehicleFields();
            if (cfg.makeAndModel) {
              var makeEl = firstVisible(
                'input[name*=\"make\" i], input[id*=\"make\" i], input[name*=\"model\" i], input[id*=\"vehicle\" i], textarea[name*=\"vehicle\" i]'
              );
              if (makeEl && !String(makeEl.value || '').trim() && setNativeValue(makeEl, cfg.makeAndModel)) filled += 1;
            }
            return filled;
          }

          function emailInputSelector() {
            return '#email, input[name=\"email\"], input[type=\"email\"], input[autocomplete=\"email\"], input[autocomplete=\"username\"], [data-testid=\"email-input\"], [data-pmtest-id*=\"email\"], input[id*=\"email\" i], input[name*=\"email\" i]';
          }

          function phoneInputSelector() {
            return '#phone, input[name=\"phone\"], input[type=\"tel\"], input[autocomplete=\"tel\"], [data-testid=\"phone-input\"], [data-pmtest-id*=\"phone\"], input[id*=\"phone\" i], input[name*=\"phone\" i]';
          }

          /// Force email/phone from BookingConfig (overwrite guest temp emails like pm-test…@email.com).
          function fillContactFields() {
            var filled = 0;
            if (cfg.email) {
              var emailEl = firstVisible(emailInputSelector());
              if (emailEl) {
                var cur = String(emailEl.value || '').trim();
                if (norm(cur) !== norm(cfg.email) && setNativeValue(emailEl, cfg.email)) filled += 1;
              }
            }
            if (cfg.phone) {
              var phoneEl = firstVisible(phoneInputSelector());
              if (phoneEl) {
                var curPhone = String(phoneEl.value || '').trim().replace(/\\D+/g, '');
                var wantPhone = String(cfg.phone || '').replace(/\\D+/g, '');
                if (curPhone !== wantPhone && setNativeValue(phoneEl, cfg.phone)) filled += 1;
              }
            }
            if (filled > 0) window.__parkingContactFilledAt = Date.now();
            return filled;
          }

          /// Guest checkout often collapses Contact with a throwaway pm-test…@email.com.
          /// Receipts go there unless we Edit and overwrite BookingConfig email before pay.
          function isParkMobileCheckoutFlow() {
            var host = location.hostname || '';
            if (!/parkmobile/i.test(host)) return false;
            var path = location.pathname || '';
            var q = location.search || '';
            return /\\/checkout/i.test(path)
              || /\\/zone\\/(auth|vehicle|payment|contact|confirm|review|summary)/i.test(path)
              || /(?:^|[?&])checkoutState=/i.test(q);
          }

          function isGuestTempEmail(email) {
            var e = String(email || '').toLowerCase();
            if (!e || e.indexOf('@') === -1) return false;
            if (cfg.email && norm(e) === norm(cfg.email)) return false;
            if (/pm[-_]?test/.test(e)) return true;
            if (/(^|[.+_\\-])(guest|temp|noreply)[.+_\\-].*@/.test(e)) return true;
            if (/@(email\\.com|parkmobile\\.(io|com)|example\\.com)$/.test(e)
                && /(test|guest|temp|pm|noreply)/.test(e)) return true;
            return false;
          }

          function firstEmailInText(text) {
            var m = String(text || '').match(/[A-Z0-9._%+\\-]+@[A-Z0-9.\\-]+\\.[A-Z]{2,}/i);
            return m ? m[0] : '';
          }

          function contactStepRoot() {
            var sels = [
              '[data-pmtest-id=\"guest-contact-step-card\"]',
              '[data-pmtest-id=\"user-contact-step-card\"]',
              '[data-pmtest-id*=\"contact-step\"]',
              '[data-pmtest-id*=\"guest-contact\"]',
              '[data-pmtest-id*=\"user-contact\"]',
              '[data-testid*=\"Contact\"]'
            ];
            for (var s = 0; s < sels.length; s++) {
              var el = firstVisible(sels[s]);
              if (el) return el;
            }
            var cards = document.querySelectorAll(
              '[data-pmtest-id*=\"step-card\"], [data-pmtest-id*=\"step\"], [data-testid*=\"step\"]'
            );
            for (var i = 0; i < cards.length; i++) {
              var c = cards[i];
              if (!visible(c)) continue;
              var tid = ((c.getAttribute('data-pmtest-id') || '') + ' ' + (c.getAttribute('data-testid') || '')).toLowerCase();
              if (/vehicle|payment|duration/.test(tid)) continue;
              var t = norm((c.innerText || '').slice(0, 400));
              if (/contactinformation|contactdetails|emailaddress|accountinfo/.test(t)) return c;
            }
            return null;
          }

          function displayedContactEmail() {
            var input = firstVisible(emailInputSelector());
            if (input && visible(input) && String(input.value || '').trim()) {
              return String(input.value || '').trim();
            }
            var root = contactStepRoot();
            if (root) {
              var fromCard = firstEmailInText(root.innerText || '');
              if (fromCard) return fromCard;
            }
            var cards = document.querySelectorAll('[data-pmtest-id*=\"step-card\"], [data-pmtest-id*=\"contact\"]');
            for (var i = 0; i < cards.length; i++) {
              if (!visible(cards[i])) continue;
              var tid = ((cards[i].getAttribute('data-pmtest-id') || '') + ' ' + (cards[i].getAttribute('data-testid') || '')).toLowerCase();
              if (/vehicle|payment/.test(tid)) continue;
              var e = firstEmailInText(cards[i].innerText || '');
              if (e) return e;
            }
            return '';
          }

          function contactEmailMatchesConfig() {
            if (!cfg.email) return true;
            var input = firstVisible(emailInputSelector());
            if (input && visible(input)) {
              return norm(String(input.value || '')) === norm(cfg.email);
            }
            var shown = displayedContactEmail();
            if (shown) return norm(shown) === norm(cfg.email);
            return true;
          }

          function contactNeedsEmailFix() {
            if (!cfg.email || !isParkMobileCheckoutFlow()) return false;
            var input = firstVisible(emailInputSelector());
            if (input && visible(input) && norm(String(input.value || '')) !== norm(cfg.email)) return true;
            var shown = displayedContactEmail();
            if (shown && (norm(shown) !== norm(cfg.email) || isGuestTempEmail(shown))) return true;
            if (contactStepRoot() && !shown) return true;
            return false;
          }

          function contactJustFilled() {
            return !!(window.__parkingContactFilledAt && (Date.now() - window.__parkingContactFilledAt) < 800);
          }

          function contactReadyForPayment() {
            if (!cfg.email || !isParkMobileCheckoutFlow()) return true;
            if (contactJustFilled()) return false;
            var input = firstVisible(emailInputSelector());
            if (input && visible(input) && norm(String(input.value || '')) !== norm(cfg.email)) return false;
            var shown = displayedContactEmail();
            if (shown && (norm(shown) !== norm(cfg.email) || isGuestTempEmail(shown))) return false;
            return true;
          }

          function logContactDiagnostics() {
            var now = Date.now();
            if (window.__parkingContactDiagAt && (now - window.__parkingContactDiagAt) < 8000) return;
            window.__parkingContactDiagAt = now;
            var input = firstVisible(emailInputSelector());
            var root = contactStepRoot();
            var shown = displayedContactEmail();
            bridge({
              type: 'log',
              message: 'contactDiag want=' + (cfg.email || '')
                + ' input=' + (input ? (String(input.value || '').trim() || 'empty') : 'missing')
                + ' shown=' + (shown || 'none')
                + ' match=' + contactEmailMatchesConfig()
                + ' needFix=' + contactNeedsEmailFix()
                + ' root=' + (root ? (((root.getAttribute('data-pmtest-id') || root.getAttribute('data-testid') || root.tagName) || '').slice(0, 40)) : 'none')
            });
          }

          function clickParkMobileContactEdit() {
            if (!contactNeedsEmailFix()) return false;
            if (firstVisible(emailInputSelector())) return false;
            // Don't collapse an open vehicle form to edit contact.
            if (vehiclePlateInput()) return false;
            var now = Date.now();
            if (window.__parkingContactEditAt && (now - window.__parkingContactEditAt) < 2500) return false;
            var root = contactStepRoot();
            var scopes = root ? [root, document] : [document];
            for (var s = 0; s < scopes.length; s++) {
              var scope = scopes[s];
              var nodes = scope.querySelectorAll('button, a, [role=\"button\"]');
              for (var i = 0; i < nodes.length; i++) {
                var el = nodes[i];
                if (!visible(el) || el.disabled) continue;
                var t = norm((el.innerText || el.textContent || '') + ' ' + (el.getAttribute('aria-label') || ''));
                if (t !== 'edit' && t !== 'change' && t.indexOf('editcontact') === -1) continue;
                var tid = ((el.getAttribute('data-pmtest-id') || '') + ' ' + (el.getAttribute('data-testid') || '')).toLowerCase();
                if (/vehicle|payment/.test(tid)) continue;
                if (root && scope === document && !root.contains(el)) {
                  var near = el.closest('[data-pmtest-id*=\"step-card\"], [data-pmtest-id*=\"contact\"], section, form');
                  var nearTid = near ? ((near.getAttribute('data-pmtest-id') || '') + ' ' + (near.getAttribute('data-testid') || '')).toLowerCase() : '';
                  if (/vehicle|payment/.test(nearTid)) continue;
                }
                if (!click(el, { scroll: false })) continue;
                window.__parkingContactEditAt = now;
                bridge({ type: 'log', message: 'contact Edit tapped shown=' + (displayedContactEmail() || 'none') });
                return true;
              }
            }
            return false;
          }

          function clickParkMobileContactContinue() {
            var now = Date.now();
            if (window.__parkingLastSaveAt && (now - window.__parkingLastSaveAt) < 2500) return false;
            if (contactJustFilled()) return false;
            var email = firstVisible(emailInputSelector());
            var phone = firstVisible(phoneInputSelector());
            if (!email && !phone) return false;
            if (cfg.email && email && visible(email) && norm(String(email.value || '')) !== norm(cfg.email)) return false;
            if (email && visible(email) && !String(email.value || '').trim()) return false;
            if (cfg.phone && phone && visible(phone)) {
              var curPhone = String(phone.value || '').replace(/\\D+/g, '');
              var wantPhone = String(cfg.phone || '').replace(/\\D+/g, '');
              if (wantPhone && curPhone !== wantPhone) return false;
            }
            var btn = findByText(
              'button, a, [role=\"button\"], input[type=\"button\"], input[type=\"submit\"]',
              /saveandcontinue|savecontinue/
            );
            if (!btn) {
              btn = findByText(
                'button, a, [role=\"button\"], input[type=\"button\"], input[type=\"submit\"]',
                /^(continue|next|save)$/
              );
            }
            if (!btn || !visible(btn) || btn.disabled) return false;
            if (/continue with apple|apple pay|complete purchase|buy with|log in|sign up|sign in|guest/i.test(
              ((btn.innerText || '') + ' ' + (btn.getAttribute('aria-label') || ''))
            )) return false;
            if (!click(btn, { scroll: false })) return false;
            window.__parkingLastSaveAt = now;
            return true;
          }

          function selectMatchesValue(el, value) {
            if (!el || !value) return false;
            var want = norm(value);
            var curVal = norm(el.value || '');
            var curText = '';
            try {
              if (el.selectedIndex >= 0 && el.options && el.options[el.selectedIndex]) {
                curText = norm(el.options[el.selectedIndex].text || '');
              }
            } catch (e) {}
            if (!curVal && el.selectedIndex <= 0) return false;
            if (curVal === want || curText === want) return true;
            if (want === 'us' && (curVal === 'unitedstates' || curText.indexOf('unitedstates') !== -1)) return true;
            if (want === 'unitedstates' && curVal === 'us') return true;
            if (want === 'nj' && (curVal === 'newjersey' || curText.indexOf('newjersey') !== -1 || curText === 'nj')) return true;
            if (want === 'newjersey' && curVal === 'nj') return true;
            return false;
          }

          function vehiclePlateInput() {
            var el = firstVisible(
              '#vrn, input[name=\"vrn\"], #licensePlate, #license-plate, #plate, input[name*=\"plate\" i], input[id*=\"plate\" i], input[name*=\"license\" i], input[name*=\"lpn\" i], [data-testid=\"Vehicle-input-plate\"], [data-pmtest-id*=\"vehicle\"][data-pmtest-id*=\"plate\"], [data-pmtest-id*=\"license\"]'
            );
            if (el) return el;
            // Last resort: maxlength input near a plate/vehicle label (avoid random autocomplete=off fields).
            var inputs = document.querySelectorAll('input[autocomplete=\"off\"][maxlength], input[type=\"text\"][maxlength]');
            for (var i = 0; i < inputs.length; i++) {
              var cand = inputs[i];
              if (!visible(cand)) continue;
              var meta = labelText(cand) + ' ' + norm((cand.closest('form,section,div') || {}).innerText || '').slice(0, 120);
              if (/licenseplate|platenumber|vehicleplate|\\bvrn\\b|\\bplate\\b/.test(meta)) return cand;
            }
            return null;
          }

          function vehiclePlateMatches() {
            var plateEl = vehiclePlateInput();
            if (!plateEl) return false;
            var cur = String(plateEl.value || '').trim();
            if (!cur) return false;
            if (cfg.licensePlateNumber && norm(cur) !== norm(cfg.licensePlateNumber)) return false;
            return true;
          }

          /// Accordion checkout: prefer the Vehicle Details card that owns the plate field.
          function vehicleStepRoot() {
            var plate = vehiclePlateInput();
            if (plate) {
              var node = plate;
              for (var up = 0; up < 8 && node; up++) {
                var tid = ((node.getAttribute && (node.getAttribute('data-pmtest-id') || node.getAttribute('data-testid'))) || '').toLowerCase();
                if (/vehicle/.test(tid) && (/step|card|form|section|info/.test(tid) || node.querySelector('button, [role=\"button\"]'))) {
                  return node;
                }
                node = node.parentElement;
              }
              var form = plate.closest('form');
              if (form) return form;
              var section = plate.closest('section, [class*=\"vehicle\" i], [id*=\"vehicle\" i]');
              if (section) return section;
            }
            var cards = document.querySelectorAll(
              '[data-pmtest-id*=\"vehicle\" i], [data-testid*=\"Vehicle\"], [data-testid*=\"vehicle\"]'
            );
            for (var c = 0; c < cards.length; c++) {
              if (visible(cards[c])) return cards[c];
            }
            return null;
          }

          function isGarageCheckoutVehicleStep() {
            if (!/\\/checkout\\/reservation/i.test(location.pathname || '')) return false;
            if (vehiclePlateInput()) return true;
            var body = norm(document.body ? document.body.innerText : '');
            return /vehicledetails|addvehicle|licenseplate/.test(body);
          }

          /// Force plate + country + state from BookingConfig (overwrite wrong defaults like AL / partial plate).
          function fillParkMobileVehicleFields(opts) {
            var force = !!(opts && opts.force);
            var filled = 0;
            if (cfg.licensePlateNumber) {
              var plateEl = vehiclePlateInput();
              if (plateEl) {
                var curPlate = String(plateEl.value || '').trim();
                if ((force || norm(curPlate) !== norm(cfg.licensePlateNumber))
                    && setNativeValue(plateEl, cfg.licensePlateNumber)) {
                  filled += 1;
                  nudgeVehicleFormValidation(plateEl);
                }
              }
            }
            if (cfg.country) {
              var countryEl = firstVisible(
                'select#country, select[name=\"country\"], select[name*=\"country\" i], select[id*=\"country\" i], [data-testid=\"Vehicle-input-country\"]'
              );
              if (countryEl && (force || !selectMatchesValue(countryEl, cfg.country))
                  && setNativeValue(countryEl, cfg.country)) {
                filled += 1;
              } else if (!countryEl) {
                var countryCombo = comboboxDisplayMatches(/country|nation/i, cfg.country);
                if (force || !countryCombo) {
                  filled += pickComboboxOption(/country|nation/i, cfg.country) ? 1 : 0;
                }
              }
            }
            if (cfg.state) {
              var stateEl = firstVisible(
                'select#state, select[name=\"state\"], select[name*=\"state\" i], select[id*=\"state\" i], select[name*=\"province\" i], [data-testid=\"Vehicle-input-state\"]'
              );
              if (stateEl && (force || !selectMatchesValue(stateEl, cfg.state))
                  && setNativeValue(stateEl, cfg.state)) {
                filled += 1;
              } else if (!stateEl) {
                var stateCombo = comboboxDisplayMatches(/state|province/i, cfg.state);
                if (force || !stateCombo) {
                  filled += pickComboboxOption(/state|province/i, cfg.state) ? 1 : 0;
                }
              }
            }
            return filled;
          }

          function comboboxDisplayMatches(labelRe, value) {
            if (!value) return false;
            var want = norm(value);
            var combos = document.querySelectorAll('[role=\"combobox\"], button[aria-haspopup=\"listbox\"]');
            for (var i = 0; i < combos.length; i++) {
              var c = combos[i];
              if (!visible(c)) continue;
              var meta = ((c.getAttribute('aria-label') || '') + ' ' + (c.id || '') + ' ' + (c.name || '')).replace(/\\s+/g, ' ');
              if (!labelRe.test(meta) && !labelRe.test(c.innerText || '')) continue;
              var shown = norm((c.innerText || '') + ' ' + (c.getAttribute('aria-label') || '') + ' ' + (c.value || ''));
              if (shown.indexOf(want) !== -1) return true;
              if (want === 'nj' && shown.indexOf('newjersey') !== -1) return true;
              if (want === 'us' && (shown.indexOf('unitedstates') !== -1 || shown === 'usa')) return true;
            }
            return false;
          }

          function pickComboboxOption(labelRe, value) {
            if (!value) return false;
            var want = norm(value);
            var combos = document.querySelectorAll('[role=\"combobox\"], button[aria-haspopup=\"listbox\"], select');
            var target = null;
            for (var i = 0; i < combos.length; i++) {
              var c = combos[i];
              if (!visible(c) || (c.tagName || '').toUpperCase() === 'SELECT') continue;
              var meta = ((c.getAttribute('aria-label') || '') + ' ' + (c.id || '') + ' ' + (c.name || '')
                + ' ' + (c.innerText || '')).replace(/\\s+/g, ' ');
              if (labelRe.test(meta)) { target = c; break; }
            }
            if (!target) return false;
            if (!click(target)) return false;
            var opts = document.querySelectorAll('[role=\"option\"], li[role=\"option\"], [data-value]');
            for (var j = 0; j < opts.length; j++) {
              var opt = opts[j];
              if (!visible(opt)) continue;
              var key = norm((opt.getAttribute('data-value') || '') + ' ' + (opt.innerText || '') + ' ' + (opt.getAttribute('aria-label') || ''));
              if (!key) continue;
              if (key === want || key.indexOf(want) !== -1 || want.indexOf(key) !== -1) {
                return click(opt);
              }
            }
            return false;
          }

          function clickParkMobileAddVehicle() {
            var now = Date.now();
            if (window.__parkingPmAddVehicleAt && (now - window.__parkingPmAddVehicleAt) < 2500) return false;
            // Form already open — nothing to open.
            if (firstVisible('#vrn, input[name=\"vrn\"], input[name*=\"plate\" i], input[id*=\"plate\" i]')) return false;
            var btn = findByText(
              'button, a, [role=\"button\"], input[type=\"button\"], input[type=\"submit\"]',
              /^(addvehicle|addavehicle|add)$/
            );
            if (!btn || !visible(btn) || btn.disabled) return false;
            var tid = ((btn.getAttribute('data-testid') || '') + ' ' + (btn.getAttribute('data-pmtest-id') || '')).toLowerCase();
            if (/payment/i.test(tid)) return false;
            if (!click(btn)) return false;
            window.__parkingPmAddVehicleAt = now;
            return true;
          }

          function findParkMobileVehicleContinueButton() {
            var selectors = [
              'button[type=\"submit\"]',
              'input[type=\"submit\"]',
              'button, a, [role=\"button\"], input[type=\"button\"]'
            ];
            var root = vehicleStepRoot();
            var scopes = root ? [root, document] : [document];
            // Prefer Save & Continue (garage Vehicle Details) over bare Continue.
            var saveBtn = null;
            var continueBtn = null;
            var fallback = null;
            for (var scopeIdx = 0; scopeIdx < scopes.length; scopeIdx++) {
              var scope = scopes[scopeIdx];
              var seen = [];
              for (var s = 0; s < selectors.length; s++) {
                var nodes = [];
                try { nodes = scope.querySelectorAll(selectors[s]); } catch (e) { continue; }
                for (var i = 0; i < nodes.length; i++) {
                  var b = nodes[i];
                  if (!b || seen.indexOf(b) !== -1 || !visible(b)) continue;
                  seen.push(b);
                  var tid = ((b.getAttribute('data-pmtest-id') || '') + ' ' + (b.getAttribute('data-testid') || '')).toLowerCase();
                  var t = ((b.innerText || b.textContent || '') + ' ' + (b.getAttribute('aria-label') || '')
                    + ' ' + (b.value || '') + ' ' + tid).toLowerCase().replace(/\\s+/g, ' ').trim();
                  var key = norm(t);
                  if (!key && (b.type || '').toLowerCase() !== 'submit') continue;
                  if (/continue with apple|apple pay|complete purchase|buy with|log in|sign up|sign in|guest/.test(t)) continue;
                  if (/payment|contact|email/.test(tid) && tid.indexOf('vehicle') === -1) continue;
                  // Contact Continue above the vehicle accordion — skip when we have a vehicle root.
                  if (root && scope === document) {
                    var inVehicle = root.contains(b);
                    if (!inVehicle && (key === 'continue' || key.indexOf('continue') === 0)
                        && key.indexOf('save') === -1) continue;
                  }
                  if (key === 'saveandcontinue' || key === 'savecontinue'
                      || (tid.indexOf('save') !== -1 && tid.indexOf('continue') !== -1)) {
                    if (!saveBtn) saveBtn = b;
                    continue;
                  }
                  if (tid.indexOf('vehiclesubmit') !== -1
                      || (tid.indexOf('vehicle') !== -1 && tid.indexOf('confirm') !== -1)) {
                    if (!continueBtn) continueBtn = b;
                    continue;
                  }
                  if (key === 'continue' || key === 'next' || key === 'confirm'
                      || (key.indexOf('continue') === 0 && key.length < 32)
                      || tid.indexOf('continue') !== -1) {
                    if (!continueBtn) continueBtn = b;
                    continue;
                  }
                  if (key === 'save' || key === 'addvehicle') {
                    if (!continueBtn) continueBtn = b;
                    continue;
                  }
                  if ((b.type || '').toLowerCase() === 'submit') {
                    fallback = fallback || b;
                  }
                }
              }
              if (saveBtn) return saveBtn;
              if (continueBtn) return continueBtn;
              if (fallback) return fallback;
            }
            return saveBtn || continueBtn || fallback;
          }

          function logVehicleFormDiagnostics() {
            var now = Date.now();
            if (window.__parkingVehicleDiagAt && (now - window.__parkingVehicleDiagAt) < 8000) return;
            window.__parkingVehicleDiagAt = now;
            var plate = vehiclePlateInput();
            var country = firstVisible('select#country, select[name=\"country\"], select[name*=\"country\" i]');
            var state = firstVisible('select#state, select[name=\"state\"], select[name*=\"state\" i]');
            var btn = findParkMobileVehicleContinueButton() || findZoneContinueButton();
            var root = vehicleStepRoot();
            bridge({
              type: 'log',
              message: 'vehicleDiag plate=' + (plate ? String(plate.value || '').trim() : 'missing')
                + ' countrySel=' + (country ? (country.value || '') : 'none')
                + ' stateSel=' + (state ? (state.value || '') : 'none')
                + ' countryCombo=' + comboboxDisplayMatches(/country|nation/i, cfg.country)
                + ' stateCombo=' + comboboxDisplayMatches(/state|province/i, cfg.state)
                + ' ready=' + (!!vehicleFormReady())
                + ' root=' + (root ? (((root.getAttribute('data-pmtest-id') || root.getAttribute('data-testid') || root.tagName) || '').slice(0, 40)) : 'none')
                + ' btn=' + (btn ? ((btn.innerText || '').trim().slice(0, 24) + (btn.disabled ? ':disabled' : '')) : 'missing')
            });
          }

          /// Zone /vehicle: plate match is enough to force Continue (React often leaves selects flaky).
          function clickZoneVehicleContinueAggressive() {
            var now = Date.now();
            if (window.__parkingLastSaveAt && (now - window.__parkingLastSaveAt) < 2200) return false;
            if (contactJustFilled()) return false;
            var email = firstVisible(emailInputSelector());
            if (cfg.email && email && visible(email) && norm(String(email.value || '')) !== norm(cfg.email)) return false;
            if (!vehiclePlateMatches()) return false;
            var plate = vehiclePlateInput();
            nudgeVehicleFormValidation(plate);
            var btn = findParkMobileVehicleContinueButton() || findZoneContinueButton();
            if (!btn) {
              if (!window.__parkingVehicleContinueMissLogged) {
                window.__parkingVehicleContinueMissLogged = true;
                bridge({ type: 'log', message: 'vehicle Continue button not found (zone)' });
              }
              return false;
            }
            if (!forceClickDisabled(btn)) return false;
            window.__parkingLastSaveAt = now;
            bridge({ type: 'log', message: 'vehicle Continue forced (zone)' });
            return true;
          }

          function hasLabeledCombobox(labelRe) {
            var combos = document.querySelectorAll('[role=\"combobox\"], button[aria-haspopup=\"listbox\"]');
            for (var i = 0; i < combos.length; i++) {
              if (!visible(combos[i])) continue;
              var meta = ((combos[i].getAttribute('aria-label') || '') + ' ' + (combos[i].innerText || '')).toLowerCase();
              if (labelRe.test(meta)) return true;
            }
            return false;
          }

          function vehicleFormReady() {
            var plate = vehiclePlateInput();
            if (!plate || !visible(plate) || !String(plate.value || '').trim()) return null;
            if (cfg.licensePlateNumber && norm(String(plate.value || '')) !== norm(cfg.licensePlateNumber)) return null;
            var country = firstVisible('select#country, select[name=\"country\"], select[name*=\"country\" i]');
            var state = firstVisible('select#state, select[name=\"state\"], select[name*=\"state\" i], select[name*=\"province\" i]');
            var hasCountryCombo = hasLabeledCombobox(/country|nation/i);
            var hasStateCombo = hasLabeledCombobox(/state|province/i);
            if (cfg.country && country && visible(country) && !selectMatchesValue(country, cfg.country)) return null;
            if (cfg.state && state && visible(state) && !selectMatchesValue(state, cfg.state)) return null;
            if (cfg.country && !country && hasCountryCombo
                && !comboboxDisplayMatches(/country|nation/i, cfg.country)) return null;
            if (cfg.state && !state && hasStateCombo
                && !comboboxDisplayMatches(/state|province/i, cfg.state)) return null;
            // Garage accordion often mounts plate first; wait for country/state controls before Continue.
            if (isGarageCheckoutVehicleStep() && cfg.state && !state && !hasStateCombo) {
              if (!window.__parkingVehicleStateWaitAt) window.__parkingVehicleStateWaitAt = Date.now();
              if ((Date.now() - window.__parkingVehicleStateWaitAt) < 5000) return null;
            } else {
              window.__parkingVehicleStateWaitAt = 0;
            }
            if (isGarageCheckoutVehicleStep() && cfg.country && !country && !hasCountryCombo) {
              if (!window.__parkingVehicleCountryWaitAt) window.__parkingVehicleCountryWaitAt = Date.now();
              if ((Date.now() - window.__parkingVehicleCountryWaitAt) < 5000) return null;
            } else {
              window.__parkingVehicleCountryWaitAt = 0;
            }
            return { plate: plate, country: country, state: state };
          }

          function nudgeVehicleFormValidation(plate) {
            if (!plate) return;
            try {
              plate.focus();
              plate.dispatchEvent(new Event('input', { bubbles: true }));
              plate.dispatchEvent(new Event('change', { bubbles: true }));
              plate.dispatchEvent(new Event('blur', { bubbles: true }));
            } catch (e) {}
          }

          function forceClickDisabled(el) {
            if (!el) return false;
            try {
              if (el.disabled) el.disabled = false;
              if (el.getAttribute('aria-disabled') === 'true') el.setAttribute('aria-disabled', 'false');
              el.removeAttribute('disabled');
            } catch (e) {}
            return click(el, { scroll: false });
          }

          function clickParkMobileVehicleContinue() {
            var now = Date.now();
            if (window.__parkingLastSaveAt && (now - window.__parkingLastSaveAt) < 2500) return false;
            if (contactJustFilled()) return false;
            var email = firstVisible(emailInputSelector());
            if (cfg.email && email && visible(email) && norm(String(email.value || '')) !== norm(cfg.email)) return false;
            var form = vehicleFormReady();
            if (!form) return false;
            nudgeVehicleFormValidation(form.plate);
            var btn = findParkMobileVehicleContinueButton();
            if (!btn) {
              if (!window.__parkingVehicleContinueMissLogged) {
                window.__parkingVehicleContinueMissLogged = true;
                bridge({ type: 'log', message: 'vehicle Continue button not found' });
              }
              return false;
            }
            var btnLabel = ((btn.innerText || btn.textContent || '') + '').trim().replace(/\\s+/g, ' ').slice(0, 32);
            var ariaDisabled = btn.getAttribute('aria-disabled') === 'true';
            if (btn.disabled || ariaDisabled) {
              // React often keeps Continue disabled until a real input cycle; nudge then force.
              nudgeVehicleFormValidation(form.plate);
              if (!forceClickDisabled(btn)) return false;
              bridge({ type: 'log', message: 'vehicle Continue forced (disabled) btn=' + btnLabel });
            } else if (!click(btn, { scroll: false })) {
              return false;
            } else {
              bridge({ type: 'log', message: 'vehicle Continue tapped btn=' + btnLabel });
            }
            window.__parkingLastSaveAt = now;
            return true;
          }

          /// Garage checkout: after fields look ready (or state controls never appear), force Continue.
          function clickGarageVehicleContinueAggressive() {
            if (!isGarageCheckoutVehicleStep()) return false;
            var now = Date.now();
            if (window.__parkingLastSaveAt && (now - window.__parkingLastSaveAt) < 2200) return false;
            if (!vehiclePlateMatches()) return false;
            var ready = vehicleFormReady();
            if (!ready) {
              // Only escalate once we've waited long enough for country/state to mount.
              var waitedState = window.__parkingVehicleStateWaitAt
                && (now - window.__parkingVehicleStateWaitAt) >= 5000;
              var waitedCountry = window.__parkingVehicleCountryWaitAt
                && (now - window.__parkingVehicleCountryWaitAt) >= 5000;
              if (!waitedState && !waitedCountry) return false;
            }
            var plate = vehiclePlateInput();
            nudgeVehicleFormValidation(plate);
            var btn = findParkMobileVehicleContinueButton();
            if (!btn) return false;
            if (!forceClickDisabled(btn)) return false;
            window.__parkingLastSaveAt = now;
            bridge({ type: 'log', message: 'vehicle Continue forced (garage)' });
            return true;
          }

          function preferGuestCheckout() {
            if (!cfg.preferGuestCheckout) return false;
            var guestBtn = findByText(
              'button, a, [role=\"button\"], input[type=\"button\"], input[type=\"submit\"]',
              /continueasa?guest|continueasguest|checkoutasguest|guestcheckout|without(an)?account|payasguest|bookasguest/
            );
            if (!guestBtn) return false;
            if (!click(guestBtn)) return false;
            window.__parkingGuestAt = Date.now();
            window.__parkingContactFilledAt = 0;
            return true;
          }

          function clickSpotHeroContactContinue() {
            var btn = document.querySelector('[data-testid=\"ContactInfo-button-confirm\"]');
            if (!btn || !visible(btn) || btn.disabled) return false;
            var email = document.querySelector('#email, [data-testid=\"email-input\"]');
            var phone = document.querySelector('#phone, [data-testid=\"phone-input\"]');
            if (email && visible(email) && !String(email.value || '').trim()) return false;
            if (phone && visible(phone) && !String(phone.value || '').trim()) return false;
            if (!email && !phone) return false;
            return click(btn, { scroll: false });
          }

          function clickSpotHeroVehicleAdd() {
            var now = Date.now();
            if (window.__parkingSpotHeroAddAt && (now - window.__parkingSpotHeroAddAt) < 2500) return false;
            var btn = document.querySelector('[data-testid=\"VehicleInfo-button-add-vehicle\"]');
            if (!btn || !visible(btn)) {
              // Fallback: Add near Vehicle label, but never Payment Add.
              btn = findByText('button, a, [role=\"button\"]', /^add$/);
              if (btn) {
                var tid = btn.getAttribute('data-testid') || '';
                if (/payment/i.test(tid)) btn = null;
              }
            }
            if (!btn || !visible(btn) || btn.disabled) return false;
            if (!click(btn)) return false;
            window.__parkingSpotHeroAddAt = now;
            return true;
          }

          function spotHeroMakeModelRoot() {
            return document.querySelector(
              '[data-testid=\"AddVehicle-autosuggest-vehicle\"], [data-testid=\"Vehicle-autosuggest-vehicle\"]'
            );
          }

          function spotHeroMakeModelInput() {
            var named = firstVisible('#addVehicleInfoId');
            if (named) return named;
            var root = spotHeroMakeModelRoot();
            if (root) {
              var input = root.querySelector('input');
              if (input && visible(input)) return input;
            }
            var labeled = Array.prototype.find.call(
              document.querySelectorAll('input'),
              function(el) {
                if (!visible(el)) return false;
                return /makeandmodel|makemodel/.test(labelText(el));
              }
            );
            return labeled || null;
          }

          function spotHeroSelectedMakeModel() {
            var root = spotHeroMakeModelRoot();
            if (!root) return '';
            var single = root.querySelector('.fe-ui-async-select__single-value, [class*=\"single-value\"]');
            return single ? String(single.textContent || '').trim() : '';
          }

          function selectSpotHeroMakeModelOption(want) {
            var wantKey = norm(want);
            var options = document.querySelectorAll(
              '.fe-ui-async-select__option, [id^=\"react-select-\"][id*=\"-option-\"], [role=\"option\"]'
            );
            var best = null;
            var bestScore = -1;
            for (var i = 0; i < Math.min(options.length, 40); i++) {
              var el = options[i];
              if (!visible(el)) continue;
              var raw = String(el.innerText || el.textContent || '').trim();
              var t = norm(raw);
              if (!t || /vehiclenotlisted/.test(t)) continue;
              var score = 0;
              if (t === wantKey) score = 100;
              else if (t.indexOf(wantKey) === 0) score = 80;
              else if (t.indexOf(wantKey) !== -1) score = 60;
              else if (wantKey.indexOf(t) !== -1 && t.length >= 6) score = 40;
              if (score > bestScore) { bestScore = score; best = el; }
            }
            if (!best || bestScore < 40) return false;
            return click(best);
          }

          function fillSpotHeroVehicleModal() {
            var modal = document.querySelector('[data-testid=\"AddVehicle\"], [data-testid=\"VehicleInfo-modal-button-confirm\"]');
            if (!modal && !spotHeroMakeModelInput() && !firstVisible('#addVehicleLicensePlate, [data-testid=\"AddVehicle-input-plate\"]')) {
              return 0;
            }
            var filled = 0;

            // 1) Make and Model — must pick a dropdown option (typed text alone is not enough).
            var selected = spotHeroSelectedMakeModel();
            var makeInput = spotHeroMakeModelInput();
            if (cfg.makeAndModel && makeInput && norm(selected).indexOf(norm(cfg.makeAndModel)) === -1) {
              try { makeInput.focus(); makeInput.click(); } catch (e) {}
              if (setNativeValue(makeInput, cfg.makeAndModel)) filled += 1;
              try {
                makeInput.dispatchEvent(new InputEvent('input', { bubbles: true, data: cfg.makeAndModel, inputType: 'insertText' }));
              } catch (e) {}
              if (selectSpotHeroMakeModelOption(cfg.makeAndModel)) filled += 1;
            }

            // 2) License plate — AddVehicle modal uses AddVehicle-input-plate / #addVehicleLicensePlate.
            if (cfg.licensePlateNumber) {
              var plate = firstVisible(
                '#addVehicleLicensePlate, [data-testid=\"AddVehicle-input-plate\"], [data-testid=\"Vehicle-input-plate\"]'
              );
              if (plate && !String(plate.value || '').trim() && setNativeValue(plate, cfg.licensePlateNumber)) filled += 1;
            }

            // 3) State / Province — AddVehicle-input-state / #addVehicleState (no Country on SpotHero modal).
            if (cfg.state) {
              var state = firstVisible(
                '#addVehicleState, [data-testid=\"AddVehicle-input-state\"], [data-testid=\"Vehicle-input-state\"]'
              );
              if (state) {
                var needsState = !String(state.value || '').trim() || state.selectedIndex <= 0
                  || norm(state.value) !== norm(cfg.state);
                if (needsState && setNativeValue(state, cfg.state)) filled += 1;
              }
            }

            // 4) Country if a variant ever shows it.
            if (cfg.country) {
              var country = firstVisible(
                '#addVehicleCountry, [data-testid=\"AddVehicle-input-country\"], [data-testid=\"Vehicle-input-country\"], select[name*=\"country\" i]'
              );
              if (country && country.closest('[data-testid=\"AddVehicle\"], [role=\"dialog\"], .chakra-modal__content')) {
                var needsCountry = !String(country.value || '').trim() || country.selectedIndex <= 0
                  || norm(country.value) !== norm(cfg.country);
                if (needsCountry && setNativeValue(country, cfg.country)) filled += 1;
              }
            }
            return filled;
          }

          function spotHeroVehicleModalReady() {
            var selected = spotHeroSelectedMakeModel();
            var hasMake = !!(selected && selected.length > 0);
            // Require dropdown selection — typed text in the input does NOT count.
            if (cfg.makeAndModel && !hasMake) return false;

            var plate = firstVisible(
              '#addVehicleLicensePlate, [data-testid=\"AddVehicle-input-plate\"], [data-testid=\"Vehicle-input-plate\"]'
            );
            if (cfg.licensePlateNumber) {
              if (!plate || !String(plate.value || '').trim()) return false;
            }

            var state = firstVisible(
              '#addVehicleState, [data-testid=\"AddVehicle-input-state\"], [data-testid=\"Vehicle-input-state\"]'
            );
            if (cfg.state) {
              if (!state || !String(state.value || '').trim() || state.selectedIndex <= 0) return false;
            }

            var country = firstVisible(
              '#addVehicleCountry, [data-testid=\"AddVehicle-input-country\"], [data-testid=\"Vehicle-input-country\"]'
            );
            if (country && visible(country) && cfg.country) {
              if (!String(country.value || '').trim() || country.selectedIndex <= 0) return false;
            }

            // Don't confirm while the make/model menu is still open.
            if (document.querySelector('.fe-ui-async-select__menu')) return false;
            return hasMake || !cfg.makeAndModel;
          }

          function clickSpotHeroVehicleConfirm() {
            var now = Date.now();
            if (window.__parkingSpotHeroConfirmAt && (now - window.__parkingSpotHeroConfirmAt) < 2500) return false;
            if (!spotHeroVehicleModalReady()) return false;

            var btn = document.querySelector('[data-testid=\"VehicleInfo-modal-button-confirm\"]');
            if (!btn || !visible(btn)) {
              var dialogs = document.querySelectorAll('[role=\"dialog\"], .chakra-modal__content');
              btn = null;
              for (var i = 0; i < dialogs.length; i++) {
                var dlg = dialogs[i];
                if (!visible(dlg)) continue;
                if (/payment/i.test(dlg.innerText || '')) continue;
                if (!/(makeandmodel|licenseplate|stateorprovince|vehiclenotlisted)/.test(norm(dlg.innerText || ''))) continue;
                var cand = Array.prototype.find.call(dlg.querySelectorAll('button,[role=\"button\"]'), function(el) {
                  return visible(el) && /^confirm$/i.test((el.innerText || '').trim());
                });
                if (cand) { btn = cand; break; }
              }
            }
            if (!btn || !visible(btn) || btn.disabled) return false;
            if (!click(btn)) return false;
            window.__parkingSpotHeroConfirmAt = now;
            return true;
          }

          function expectedStartFromUrl() {
            try {
              var u = new URL(location.href);
              var raw = u.searchParams.get('startDate') || u.searchParams.get('start_at')
                || u.searchParams.get('starts');
              if (!raw) return null;
              var m = String(raw).match(/T(\\d{2}):(\\d{2})/);
              if (!m) return null;
              return { hour: parseInt(m[1], 10), minute: parseInt(m[2], 10), raw: raw };
            } catch (e) { return null; }
          }

          function timeTextMatches(text, hour24, minute) {
            var n = norm(text);
            if (!n) return false;
            var hour12 = hour24 % 12;
            if (hour12 === 0) hour12 = 12;
            var mm = minute < 10 ? ('0' + minute) : String(minute);
            var ampm = hour24 < 12 ? 'am' : 'pm';
            // \"9:30 AM\" → 930am after norm; also allow 0930.
            if (n.indexOf(String(hour12) + mm + ampm) !== -1) return true;
            if (n.indexOf((hour24 < 10 ? ('0' + hour24) : String(hour24)) + mm) !== -1) return true;
            return false;
          }

          function reservationStartMatchesUrl() {
            var exp = expectedStartFromUrl();
            if (!exp) return true;
            var matched = false;
            var inputs = document.querySelectorAll('input');
            for (var i = 0; i < inputs.length; i++) {
              var el = inputs[i];
              if (!visible(el)) continue;
              var label = (el.getAttribute('aria-label') || '') + ' ' + (el.name || '') + ' ' + (el.id || '');
              if (!/start/i.test(label)) continue;
              if (timeTextMatches(el.value || '', exp.hour, exp.minute)) { matched = true; break; }
            }
            return matched;
          }

          function clickReserveParkHere() {
            if (window.__parkingDidReserve) return false;
            var btn = findByText(
              'button, a, [role=\"button\"], input[type=\"button\"], input[type=\"submit\"]',
              /reserve.*parkhere|parkhere|reserveyourspot|reservethisspot/
            );
            if (!btn || btn.disabled) return false;

            // ParkMobile applies startDate/endDate asynchronously. Clicking Reserve too early
            // sends a wrong window (often original end → end+duration) into checkout.
            if (!reservationStartMatchesUrl()) {
              window.__parkingReserveReadyAt = null;
              return false;
            }
            var now = Date.now();
            if (!window.__parkingReserveReadyAt) window.__parkingReserveReadyAt = now;
            if ((now - window.__parkingReserveReadyAt) < 700) return false;

            if (!click(btn)) return false;
            window.__parkingDidReserve = true;
            return true;
          }

          function clickSaveAndContinue() {
            var now = Date.now();
            if (window.__parkingLastSaveAt && (now - window.__parkingLastSaveAt) < 2500) return false;
            // Prefer vehicle-scoped Save & Continue when the plate form is up.
            var btn = null;
            if (vehiclePlateInput()) {
              btn = findParkMobileVehicleContinueButton();
              var btnKey = btn ? norm((btn.innerText || btn.textContent || '') + ' ' + (btn.getAttribute('aria-label') || '')) : '';
              if (btn && btnKey.indexOf('save') === -1) btn = null;
            }
            if (!btn) {
              btn = findByText(
                'button, a, [role=\"button\"], input[type=\"button\"], input[type=\"submit\"]',
                /saveandcontinue|savecontinue/
              );
            }
            if (!btn || !visible(btn)) return false;
            if (contactJustFilled()) return false;

            var email = firstVisible(emailInputSelector());
            var phone = firstVisible(phoneInputSelector());
            var plate = vehiclePlateInput() || firstVisible('#vrn, input[name=\"vrn\"]');
            var country = firstVisible('select#country, select[name=\"country\"]');
            var state = firstVisible('select#state, select[name=\"state\"]');

            var onContact = !!((email && visible(email)) || (phone && visible(phone)));
            var onVehicle = !!(plate && visible(plate));

            if (onContact) {
              if (cfg.email && email && visible(email) && norm(String(email.value || '')) !== norm(cfg.email)) return false;
              if (email && visible(email) && !String(email.value || '').trim()) return false;
              if (cfg.phone && phone && visible(phone)) {
                var savePhone = String(phone.value || '').replace(/\\D+/g, '');
                var saveWant = String(cfg.phone || '').replace(/\\D+/g, '');
                if (saveWant && savePhone !== saveWant) return false;
              } else if (phone && visible(phone) && !String(phone.value || '').trim()) {
                return false;
              }
            }
            if (onVehicle) {
              if (cfg.licensePlateNumber && !vehiclePlateMatches()) return false;
              if (!String(plate.value || '').trim()) return false;
              if (cfg.country && country && visible(country) && !selectMatchesValue(country, cfg.country)) return false;
              if (cfg.state && state && visible(state) && !selectMatchesValue(state, cfg.state)) return false;
            }
            // Don't click Save on unrelated screens.
            if (!onContact && !onVehicle) return false;
            var ariaDisabled = btn.getAttribute('aria-disabled') === 'true';
            if (btn.disabled || ariaDisabled) {
              if (onVehicle) nudgeVehicleFormValidation(plate);
              if (!forceClickDisabled(btn)) return false;
              bridge({ type: 'log', message: 'Save & Continue forced' });
            } else if (!click(btn, { scroll: false })) {
              return false;
            } else {
              bridge({ type: 'log', message: 'Save & Continue tapped' });
            }
            window.__parkingLastSaveAt = now;
            return true;
          }

          function vehicleSectionNeedsInput() {
            var body = norm(document.body ? document.body.innerText : '');
            if (/novehicleinformationisrequired/.test(body)) return false;
            if (document.querySelector('[data-testid=\"VehicleInfo-button-add-vehicle\"]')) return true;
            if (spotHeroMakeModelInput()) return true;
            var plate = firstVisible('#vrn, input[name=\"vrn\"], [data-testid=\"Vehicle-input-plate\"]');
            return !!plate;
          }

          function contactSectionNeedsInput() {
            if (!contactReadyForPayment()) return true;
            var email = firstVisible(emailInputSelector());
            var phone = firstVisible(phoneInputSelector());
            if (email && cfg.email && norm(String(email.value || '')) !== norm(cfg.email)) return true;
            if (phone && cfg.phone) {
              var curPhone = String(phone.value || '').replace(/\\D+/g, '');
              var wantPhone = String(cfg.phone || '').replace(/\\D+/g, '');
              if (wantPhone && curPhone !== wantPhone) return true;
            }
            return !!(email || phone);
          }

          function wantsApplePay() {
            var m = norm(cfg.paymentMethod || '');
            return !m || m === 'applepay' || m === 'apple';
          }

          function isNativeApplePayBuyButton(el) {
            if (!el) return false;
            try {
              var style = window.getComputedStyle(el);
              var appearance = String(style.webkitAppearance || style.getPropertyValue('-webkit-appearance') || '');
              // Native Apple Pay button is used to complete purchase — never auto-tap.
              return appearance.indexOf('apple-pay-button') !== -1;
            } catch (e) { return false; }
          }

          function findContinueWithApplePayButton() {
            if (!wantsApplePay()) return null;
            // Only Payment Details — never login \"Continue with Apple\" / Sign in with Apple.
            var payCard = document.querySelector(
              '[data-pmtest-id=\"guest-payment-step-card\"], [data-pmtest-id=\"user-payment-step-card\"]'
            );
            if (!payCard || !visible(payCard)) return null;

            var nodes = payCard.querySelectorAll('button, a, [role=\"button\"]');
            for (var i = 0; i < nodes.length; i++) {
              var el = nodes[i];
              if (!visible(el) || el.disabled) continue;
              if (isNativeApplePayBuyButton(el)) continue;
              if (el.getAttribute('data-pmtest-id') === 'complete-purchase-button') continue;
              if (el.getAttribute('data-pmtest-id') === 'apple-login-button') continue;
              var t = textOf(el);
              var html = norm(el.innerHTML || '');
              // Must be Apple *Pay*. \"continuewithapple\" alone is Sign in with Apple.
              if (/signinwithapple/.test(t)) continue;
              if (/continuewithapplepay/.test(t)) return el;
              if (/continuewith/.test(t) && /applepay/.test(html) && !/continuewithapple$/.test(t)) return el;
              // Payment card: \"Continue with\" + Apple Pay glyph (text may be only \"Continue with\").
              if (/^continuewith$/.test(t) && /applepay/.test(html)) return el;
            }
            return null;
          }

          function clickContinueWithApplePay() {
            var now = Date.now();
            if (window.__parkingApplePayAt && (now - window.__parkingApplePayAt) < 2500) return false;
            if (!contactReadyForPayment()) return false;
            var btn = findContinueWithApplePayButton();
            if (!btn) return false;
            if (!click(btn, { scroll: false })) return false;
            window.__parkingApplePayAt = now;
            return true;
          }

          function isCheckedControl(el) {
            if (!el) return false;
            if (el.checked) return true;
            if (el.getAttribute && el.getAttribute('aria-checked') === 'true') return true;
            var input = (el.matches && el.matches('input')) ? el : el.querySelector('input[type=\"checkbox\"]');
            if (input && input.checked) return true;
            return false;
          }

          function acknowledgeTargets() {
            var out = [];
            function add(el) {
              if (!el) return;
              for (var i = 0; i < out.length; i++) if (out[i] === el) return;
              out.push(el);
            }
            var sels = [
              '[data-pmtest-id=\"resale-disclaimer-checkbox\"]',
              '#resale-disclaimer-acknowledgment',
              'input[name=\"resale-disclaimer-acknowledgment\"]',
              '[data-pmtest-id=\"multiple-reservations-acknowledgment-checkbox\"]',
              '#multiple-reservations-acknowledgment',
              'input[name=\"multiple-reservations-acknowledgment\"]'
            ];
            for (var i = 0; i < sels.length; i++) {
              var nodes = document.querySelectorAll(sels[i]);
              for (var j = 0; j < nodes.length; j++) add(nodes[j]);
            }
            // Label / nearby text: \"I acknowledge...\"
            var labels = document.querySelectorAll('label, [role=\"checkbox\"], input[type=\"checkbox\"]');
            for (var k = 0; k < labels.length; k++) {
              var el = labels[k];
              if (!visible(el)) continue;
              var t = textOf(el) + ' ' + labelText(el);
              if (/iacknowledge/.test(t)) add(el);
            }
            return out;
          }

          function acknowledgeNeedsCheck() {
            var targets = acknowledgeTargets();
            for (var i = 0; i < targets.length; i++) {
              var el = targets[i];
              if (!visible(el) && !(el.querySelector && el.querySelector('input'))) continue;
              var clickable = el;
              if (!visible(el) && el.querySelector) {
                var inner = el.querySelector('input[type=\"checkbox\"], [role=\"checkbox\"], button, label');
                if (inner && visible(inner)) clickable = inner;
                else continue;
              }
              if (!isCheckedControl(clickable) && !isCheckedControl(el)) return true;
            }
            return false;
          }

          function checkAcknowledgeBoxes() {
            var now = Date.now();
            if (window.__parkingAckAt && (now - window.__parkingAckAt) < 1500) return false;
            var did = false;
            var targets = acknowledgeTargets();
            for (var i = 0; i < targets.length; i++) {
              var el = targets[i];
              var clickable = el;
              if (!visible(el)) {
                var inner = el.querySelector && el.querySelector('input[type=\"checkbox\"], [role=\"checkbox\"]');
                if (inner && visible(inner)) clickable = inner;
                else continue;
              }
              if (isCheckedControl(clickable) || isCheckedControl(el)) continue;
              var input = (clickable.matches && clickable.matches('input[type=\"checkbox\"]'))
                ? clickable
                : (clickable.querySelector && clickable.querySelector('input[type=\"checkbox\"]'));
              if (input && !input.checked) {
                try {
                  input.click();
                  if (!input.checked) {
                    input.checked = true;
                    input.dispatchEvent(new Event('input', { bubbles: true }));
                    input.dispatchEvent(new Event('change', { bubbles: true }));
                  }
                  did = true;
                  continue;
                } catch (e) {}
              }
              if (click(clickable)) did = true;
            }
            if (did) window.__parkingAckAt = now;
            return did;
          }

          function paymentSectionNeedsAction() {
            // ParkMobile only — SpotHero / ParkChirp payment left alone.
            var onPM = /parkmobile\\.io/i.test(location.hostname || '');
            if (!onPM) return false;
            if (wantsApplePay() && findContinueWithApplePayButton()) return true;
            if (acknowledgeNeedsCheck()) return true;
            return false;
          }

          function isParkChirp() {
            return /parkchirp\\.com/i.test(location.hostname || '');
          }

          function parkChirpIsSignedIn() {
            var t = (document.body && document.body.innerText) || '';
            if (/you are logged in as/i.test(t)) return true;
            if (/log\\s*out\\?/i.test(t)) return true;
            // Logged-in checkout no longer shows the Cognito login form.
            if (!document.querySelector('#aws-cognito-log-in')
                && document.querySelector('#gpi-checkout-submit')) return true;
            return false;
          }

          function parkChirpNeedsSignIn() {
            if (!isParkChirp()) return false;
            if (parkChirpIsSignedIn()) return false;
            var t = (document.body && document.body.innerText) || '';
            if (/you need to log in or create an account/i.test(t)) return true;
            if (document.querySelector('#aws-cognito-log-in #login-password, #aws-cognito-log-in input[type=\"password\"]')) {
              return true;
            }
            // Checkout shell visible but session not confirmed yet.
            if (document.querySelector('#gpi-checkout-submit')) return true;
            return false;
          }

          function parkChirpLoginForm() {
            return document.querySelector('#aws-cognito-log-in')
              || document.querySelector('form[name=\"aws-cognito-log-in\"]');
          }

          function parkChirpFieldLooksAutofilled(el) {
            if (!el) return false;
            if (String(el.value || '').length > 0) return true;
            try {
              if (el.matches && el.matches(':-webkit-autofill')) return true;
            } catch (e) {}
            try {
              // iOS often paints autofill without exposing .value to JS.
              var bg = window.getComputedStyle(el).webkitBackgroundClip || '';
              var color = window.getComputedStyle(el).backgroundColor || '';
              if (/autofill/i.test(el.className || '')) return true;
              if (color && color !== 'rgba(0, 0, 0, 0)' && color !== 'transparent'
                  && /rgb\\(\\s*250\\s*,\\s*255\\s*,\\s*189/i.test(color)) return true;
            } catch (e2) {}
            return false;
          }

          function parkChirpFindLoginFields() {
            var form = parkChirpLoginForm();
            if (!form || !visible(form)) {
              // Form may be in a tab; still prefer Cognito ids over Create Account passwords.
              form = parkChirpLoginForm();
            }
            var email = form
              ? (form.querySelector('#login-email-address, input[name=\"login-email-address\"], input[type=\"email\"]') || null)
              : firstVisible('#login-email-address, input[name=\"login-email-address\"]');
            var pass = form
              ? (form.querySelector('#login-password, input[name=\"login-password\"], input[type=\"password\"]') || null)
              : firstVisible('#login-password, input[name=\"login-password\"]');
            if (!pass || !visible(pass)) return null;
            if (email && !visible(email)) email = null;
            return { email: email, password: pass, form: form || pass.form || null };
          }

          function parkChirpPrepareLoginAutocomplete(fields) {
            if (!fields) return;
            try {
              if (fields.email) {
                fields.email.setAttribute('autocomplete', 'username');
                fields.email.setAttribute('autocapitalize', 'none');
                fields.email.setAttribute('autocorrect', 'off');
                fields.email.setAttribute('spellcheck', 'false');
              }
              if (fields.password) {
                fields.password.setAttribute('autocomplete', 'current-password');
              }
            } catch (e) {}
          }

          /// Only after Keychain had a chance — JS-filling email often suppresses the Passwords bar.
          function fillParkChirpLoginEmail() {
            if (!cfg.email) return false;
            var fields = parkChirpFindLoginFields();
            if (!fields || !fields.email) return false;
            var cur = String(fields.email.value || '').trim();
            if (cur && norm(cur) === norm(cfg.email)) return false;
            if (cur && cur.indexOf('@') !== -1) return false;
            return setNativeValue(fields.email, cfg.email);
          }

          /// Password ready: Keychain autofill (value may be hidden from JS), or typed ≥8 and stable.
          function parkChirpPasswordReady(pass) {
            if (!pass) return false;
            var v = String(pass.value || '');
            try {
              if (pass.matches && pass.matches(':-webkit-autofill')) return true;
            } catch (e) {}
            if (v.length < 8) return false; // Cognito passwords are ≥ 8; also blocks mid-typing Submit
            var now = Date.now();
            var snap = window.__parkingParkChirpPassSnap;
            if (!snap || snap.v !== v) {
              window.__parkingParkChirpPassSnap = { v: v, at: now };
              return false;
            }
            return (now - snap.at) >= 1200;
          }

          /// Prepare Cognito login for Keychain. Do NOT JS-focus or JS-fill email —
          /// programmatic focus dismisses the Passwords bar; only a real tap shows it in WKWebView.
          function hintParkChirpPasswordAutofill() {
            if (!isParkChirp() || parkChirpIsSignedIn()) return false;
            var fields = parkChirpFindLoginFields();
            if (!fields || !fields.password) return false;
            parkChirpPrepareLoginAutocomplete(fields);
            if (window.__parkingParkChirpKeychainPrompted) return false;
            window.__parkingParkChirpKeychainPrompted = true;
            bridge({ type: 'parkChirpKeychain' });
            bridge({
              type: 'log',
              message: 'parkChirp keychain: tap Email Address → Passwords/key (JS cannot fetch Keychain)'
            });
            return true;
          }

          function parkChirpLoginFieldsFilled() {
            var fields = parkChirpFindLoginFields();
            if (!fields || !fields.password) return null;
            var emailOk = fields.email
              && (String(fields.email.value || '').indexOf('@') !== -1 || parkChirpFieldLooksAutofilled(fields.email));
            if (!emailOk) return null;
            if (!parkChirpPasswordReady(fields.password)) return null;
            return fields;
          }

          function findParkChirpLoginSubmit(fields) {
            if (!fields) return null;
            var scope = fields.form || parkChirpLoginForm() || document;
            var buttons = scope.querySelectorAll('button, input[type=\"submit\"]');
            for (var i = 0; i < buttons.length; i++) {
              var b = buttons[i];
              if (!visible(b)) continue;
              var label = norm(b.innerText || b.value || '');
              if (/checkout|apply|create|register|subscribe|apple|sso|forgot/i.test(label)) continue;
              // Cognito login uses a green \"Submit\" button (not \"Login Submit\").
              if (label === 'submit' || label === 'loginsubmit' || label === 'login'
                  || label === 'signin' || label === 'logon') {
                return b;
              }
            }
            var fallback = scope.querySelector('button.button-spinner, button.button-green, button[type=\"submit\"], input[type=\"submit\"]');
            if (fallback && visible(fallback)) {
              var fl = norm(fallback.innerText || fallback.value || '');
              if (!/checkout|apply|create|register|subscribe|apple|sso|forgot/i.test(fl)) return fallback;
            }
            return null;
          }

          function logParkChirpLoginDiagnostics() {
            var now = Date.now();
            if (window.__parkingParkChirpLoginDiagAt && (now - window.__parkingParkChirpLoginDiagAt) < 8000) return;
            window.__parkingParkChirpLoginDiagAt = now;
            var fields = parkChirpFindLoginFields();
            var btn = findParkChirpLoginSubmit(fields);
            bridge({
              type: 'log',
              message: 'parkChirpLoginDiag email=' + (fields && fields.email
                  ? (String(fields.email.value || '').trim() || (parkChirpFieldLooksAutofilled(fields.email) ? 'autofill' : 'empty'))
                  : 'missing')
                + ' pass=' + (fields && fields.password
                  ? ((fields.password.value || '').length ? 'len' + String(fields.password.value).length
                    : (parkChirpFieldLooksAutofilled(fields.password) ? 'autofill' : 'empty'))
                  : 'missing')
                + ' btn=' + (btn ? ((btn.innerText || '').trim().slice(0, 20)) : 'missing')
                + ' signedIn=' + parkChirpIsSignedIn()
            });
          }

          /// After Keychain AutoFill or a finished password (≥8, stable), tap Cognito Submit once.
          function submitParkChirpLoginIfAutofilled() {
            if (!isParkChirp() || parkChirpIsSignedIn()) return false;
            if (window.__parkingParkChirpLoginAt && (Date.now() - window.__parkingParkChirpLoginAt) < 10000) {
              return false;
            }
            var fields = parkChirpLoginFieldsFilled();
            if (!fields) return false;
            // Never Submit while the user still has the password field focused (typing).
            if (document.activeElement === fields.password) return false;
            var btn = findParkChirpLoginSubmit(fields);
            if (!btn) {
              if (fields.form && typeof fields.form.requestSubmit === 'function') {
                try {
                  fields.form.requestSubmit();
                  window.__parkingParkChirpLoginAt = Date.now();
                  bridge({ type: 'log', message: 'parkChirp login requestSubmit' });
                  return true;
                } catch (e) {}
              }
              return false;
            }
            if (click(btn)) {
              window.__parkingParkChirpLoginAt = Date.now();
              bridge({
                type: 'log',
                message: 'parkChirp login Submit tapped passLen='
                  + String(fields.password.value || '').length
              });
              return true;
            }
            return false;
          }

          function parkChirpPad2(n) {
            return (n < 10 ? '0' : '') + n;
          }

          /// Wall-as-UTC unix in the URL → local wall yyyy-MM-dd / HH:mm for ParkChirp selects.
          function parkChirpWallPartsFromUnix(sec) {
            var d = new Date(sec * 1000);
            return {
              date: d.getUTCFullYear() + '-' + parkChirpPad2(d.getUTCMonth() + 1) + '-' + parkChirpPad2(d.getUTCDate()),
              time: parkChirpPad2(d.getUTCHours()) + ':' + parkChirpPad2(d.getUTCMinutes())
            };
          }

          function parkChirpSetSelect(el, val) {
            if (!el || !val) return false;
            var ok = false;
            for (var i = 0; i < el.options.length; i++) {
              if (el.options[i].value === val) { ok = true; break; }
            }
            if (!ok) return false;
            if (el.value === val) return false;
            el.value = val;
            try {
              el.dispatchEvent(new Event('input', { bubbles: true }));
              el.dispatchEvent(new Event('change', { bubbles: true }));
              if (window.jQuery) jQuery(el).trigger('change');
            } catch (e) {}
            return true;
          }

          function parkChirpHasOption(el, val) {
            if (!el || val == null || val === '') return false;
            for (var i = 0; i < el.options.length; i++) {
              if (el.options[i].value === val) return true;
            }
            return false;
          }

          function parkChirpUnixFromWallParts(dateStr, timeStr) {
            var dp = String(dateStr || '').split('-');
            var tp = String(timeStr || '').split(':');
            if (dp.length < 3 || tp.length < 2) return 0;
            var ms = Date.UTC(+dp[0], +dp[1] - 1, +dp[2], +tp[0], +tp[1], 0);
            return Math.floor(ms / 1000);
          }

          function restoreParkChirpUrlTimes(startSec, endSec) {
            try {
              var u = new URL(location.href);
              var curStart = u.searchParams.get('startTime') || '';
              var curEnd = u.searchParams.get('endTime') || '';
              if (curStart === String(startSec) && curEnd === String(endSec)) return false;
              u.searchParams.set('startTime', String(startSec));
              u.searchParams.set('endTime', String(endSec));
              u.searchParams.delete('expectedPrice');
              history.replaceState(history.state, '', u.toString());
              return true;
            } catch (e) { return false; }
          }

          function parkChirpCandidateList() {
            return (cfg.parkChirpCandidates && cfg.parkChirpCandidates.length)
              ? cfg.parkChirpCandidates
              : [];
          }

          function parkChirpPickers() {
            return {
              sd: document.querySelector('select[name=\"start-date\"]'),
              st: document.querySelector('select[name=\"start-time\"]'),
              ed: document.querySelector('select[name=\"end-date\"]'),
              et: document.querySelector('select[name=\"end-time\"]')
            };
          }

          /// True when GUI still shows this candidate (SPA did not rewrite overnight / other day).
          function parkChirpWindowAccepted(startSec, endSec) {
            var start = parkChirpWallPartsFromUnix(startSec);
            var end = parkChirpWallPartsFromUnix(endSec);
            var p = parkChirpPickers();
            if (!p.sd || !p.st || !p.ed || !p.et) return false;
            if (p.sd.value !== start.date || p.st.value !== start.time) return false;
            if (p.ed.value !== end.date || p.et.value !== end.time) return false;
            try {
              var u = new URL(location.href);
              var urlStart = u.searchParams.get('startTime') || '';
              var urlEnd = u.searchParams.get('endTime') || '';
              // URL may lag briefly; selects are authoritative. If URL present and disagrees, reject.
              if (urlStart && urlEnd && (urlStart !== String(startSec) || urlEnd !== String(endSec))) {
                return false;
              }
            } catch (e) {}
            return true;
          }

          function parkChirpApplyCandidate(startSec, endSec) {
            var start = parkChirpWallPartsFromUnix(startSec);
            var end = parkChirpWallPartsFromUnix(endSec);
            var p = parkChirpPickers();
            if (!p.sd || !p.st || !p.ed || !p.et || !p.sd.options.length) return 'wait';
            // Date missing from picker (full / past / sold out) → skip this candidate.
            if (!parkChirpHasOption(p.sd, start.date) || !parkChirpHasOption(p.ed, end.date)) {
              return 'skip';
            }
            parkChirpSetSelect(p.sd, start.date);
            parkChirpSetSelect(p.ed, end.date);
            // Time options may cascade after date — require 5:30–11:00 start and 11:30 end slots.
            if (!parkChirpHasOption(p.st, start.time) || !parkChirpHasOption(p.et, end.time)) {
              return 'skip';
            }
            parkChirpSetSelect(p.st, start.time);
            parkChirpSetSelect(p.et, end.time);
            restoreParkChirpUrlTimes(startSec, endSec);
            return 'applied';
          }

          /// Walk today→current+2 × start 5:30…11:00 → end 11:30 until SPA keeps the window (or cap).
          function applyParkChirpUrlDatesAndTimes() {
            if (!isParkChirp()) return false;
            if (window.__parkingParkChirpTimesDone) return false;
            var candidates = parkChirpCandidateList();
            if (!candidates.length) {
              window.__parkingParkChirpTimesDone = true;
              return false;
            }
            var attempt = window.__parkingParkChirpDateAttempt | 0;
            var settleMs = 2000;

            // After an apply, wait for SPA rewrite, then accept or advance.
            if (window.__parkingParkChirpSettleAt) {
              if ((Date.now() - window.__parkingParkChirpSettleAt) < settleMs) {
                return false;
              }
              var pending = candidates[attempt];
              if (pending && parkChirpWindowAccepted(pending.startSec | 0, pending.endSec | 0)) {
                window.__parkingParkChirpTimesDone = true;
                window.__parkingParkChirpSettleAt = null;
                return false;
              }
              // Force-rewritten (or not sticky) → next future date.
              window.__parkingParkChirpSettleAt = null;
              window.__parkingParkChirpDateAttempt = attempt + 1;
              attempt = window.__parkingParkChirpDateAttempt;
            }

            while (attempt < candidates.length) {
              var c = candidates[attempt];
              var startSec = c.startSec | 0;
              var endSec = c.endSec | 0;
              var result = parkChirpApplyCandidate(startSec, endSec);
              if (result === 'wait') return false;
              if (result === 'skip') {
                attempt += 1;
                window.__parkingParkChirpDateAttempt = attempt;
                continue;
              }
              // applied — wait for SPA settle on next pass.
              window.__parkingParkChirpDateAttempt = attempt;
              window.__parkingParkChirpSettleAt = Date.now();
              window.__parkingParkChirpTimesAt = Date.now();
              return true;
            }

            window.__parkingParkChirpTimesDone = true;
            return false;
          }

          function bridge(msg) {
            try {
              if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.parkingBridge) {
                window.webkit.messageHandlers.parkingBridge.postMessage(msg);
              }
            } catch (e) {}
          }

          function haversineMeters(lat1, lng1, lat2, lng2) {
            var R = 6371000;
            var toRad = Math.PI / 180;
            var dLat = (lat2 - lat1) * toRad;
            var dLng = (lng2 - lng1) * toRad;
            var a = Math.sin(dLat / 2) * Math.sin(dLat / 2)
              + Math.cos(lat1 * toRad) * Math.cos(lat2 * toRad)
              * Math.sin(dLng / 2) * Math.sin(dLng / 2);
            return 2 * R * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
          }

          /// On-street Search Zones only — never /search/transient (offstreet garage location_ids).
          function isOnStreetZonesSearchUrl(url) {
            var u = String(url || '');
            if (!/\\/api\\/zones\\/search/i.test(u)) return false;
            if (/\\/api\\/zones\\/search\\/transient/i.test(u)) return false;
            return true;
          }

          function cacheZonesSearchPayload(data, via) {
            var list = Array.isArray(data) ? data
              : (data && (data.zones || data.results || data.items || data.data)) || [];
            if (!Array.isArray(list) || !list.length) return;
            // Keep OnStreet rows with a real internalZoneCode (e.g. 30447328).
            // Transient/offstreet payloads use location_id and 404 on /zone/start.
            var onStreet = [];
            for (var i = 0; i < list.length; i++) {
              var z = list[i] || {};
              var typ = String(z.type || z.parkingType || z.zoneType || '').toLowerCase();
              if (typ === 'offstreet' || typ === 'off-street' || typ === 'garage') continue;
              if (z.location_id && !z.internalZoneCode && !z.internalCode) continue;
              var internal = String(z.internalZoneCode || z.internalCode || '').trim();
              if (!internal || !/^\\d{5,}$/.test(internal)) continue;
              onStreet.push(z);
            }
            if (!onStreet.length) {
              bridge({ type: 'log', message: 'zones ' + via + ' ignored (no on-street internals) raw=' + list.length });
              return;
            }
            window.__parkingZoneApiResults = onStreet;
            window.__parkingNearestZoneFetchedAt = Date.now();
            bridge({ type: 'log', message: 'zones ' + via + ' cached count=' + onStreet.length });
          }

          /// Cache SPA /api/zones/search — ParkMobile uses XHR; our own fetch often 422s.
          function installZoneFetchHook() {
            if (window.__parkingZoneFetchHooked) return;
            window.__parkingZoneFetchHooked = true;
            window.__parkingZoneApiResults = window.__parkingZoneApiResults || [];
            try {
              var orig = window.fetch;
              if (typeof orig === 'function') {
                window.fetch = function() {
                  var args = arguments;
                  var req = args[0];
                  var url = (typeof req === 'string') ? req : ((req && req.url) || '');
                  return orig.apply(this, args).then(function(res) {
                    try {
                      if (isOnStreetZonesSearchUrl(url) && res && res.ok && res.clone) {
                        res.clone().json().then(function(data) {
                          cacheZonesSearchPayload(data, 'fetch');
                        }).catch(function() {});
                      }
                    } catch (e) {}
                    return res;
                  });
                };
              }
            } catch (e) {}
            try {
              var XO = XMLHttpRequest.prototype.open;
              var XS = XMLHttpRequest.prototype.send;
              XMLHttpRequest.prototype.open = function(method, url) {
                try { this.__parkingZoneUrl = String(url || ''); } catch (e) { this.__parkingZoneUrl = ''; }
                return XO.apply(this, arguments);
              };
              XMLHttpRequest.prototype.send = function() {
                var xhr = this;
                var url = xhr.__parkingZoneUrl || '';
                if (isOnStreetZonesSearchUrl(url)) {
                  xhr.addEventListener('load', function() {
                    try {
                      if (xhr.status < 200 || xhr.status >= 300) return;
                      cacheZonesSearchPayload(JSON.parse(xhr.responseText || 'null'), 'xhr');
                    } catch (e) {}
                  });
                }
                return XS.apply(this, arguments);
              };
            } catch (e) {}
          }

          function isParkMobileZoneFlow() {
            return !!cfg.parkMobileZoneMode && /parkmobile/i.test(location.hostname || '');
          }

          /// Re-apply native lat/lng into navigator.geolocation (WKWebView geo is flaky).
          function ensureNativeGeolocationStub() {
            if (cfg.lat == null || cfg.lng == null) return false;
            if (window.__parkingGeoStubbed
                && window.__parkingNativeGeo
                && window.__parkingNativeGeo.lat === cfg.lat
                && window.__parkingNativeGeo.lng === cfg.lng) {
              return true;
            }
            try {
              var lat = cfg.lat;
              var lng = cfg.lng;
              window.__parkingNativeGeo = { lat: lat, lng: lng, accuracy: 25 };
              function position() {
                return {
                  coords: {
                    latitude: lat, longitude: lng, accuracy: 25,
                    altitude: null, altitudeAccuracy: null, heading: null, speed: null
                  },
                  timestamp: Date.now()
                };
              }
              var geo = navigator.geolocation || {};
              geo.getCurrentPosition = function(success) {
                if (typeof success === 'function') try { success(position()); } catch (e) {}
              };
              geo.watchPosition = function(success) {
                if (typeof success === 'function') try { success(position()); } catch (e) {}
                return 1;
              };
              geo.clearWatch = function() {};
              navigator.geolocation = geo;
              window.__parkingGeoStubbed = true;
              bridge({ type: 'log', message: 'native geolocation stub lat=' + lat + ' lng=' + lng });
              return true;
            } catch (e) { return false; }
          }

          function isZoneSearchPage() {
            return /\\/search/i.test(location.pathname || '');
          }

          function isZoneStartPage() {
            return /\\/zone\\/start/i.test(location.pathname || '')
              || /\\/zone\\/\\d+/i.test(location.pathname || '');
          }

          /// Target after zone Continue loop: /zone/auth?checkoutState=...
          function isZoneAuthCheckoutPage() {
            var path = location.pathname || '';
            var q = location.search || '';
            return /\\/zone\\/auth/i.test(path) && /(?:^|[?&])checkoutState=/i.test(q);
          }

          function isZoneVehiclePage() {
            return /\\/zone\\/vehicle/i.test(location.pathname || '');
          }

          function isZoneContactPage() {
            return /\\/zone\\/contact/i.test(location.pathname || '');
          }

          function zoneEmailStepVisible() {
            return !!firstVisible(emailInputSelector());
          }

          /// Zone entry/duration only — not vehicle/payment/auth (those use guest + fillFields).
          function isZonePreAuthPage() {
            if (isZoneAuthCheckoutPage()) return false;
            var path = location.pathname || '';
            if (/\\/zone\\/(auth|vehicle|payment|contact|confirm|review|summary|receipt)/i.test(path)) {
              return false;
            }
            return /\\/zone(\\/|$)/i.test(path);
          }

          function clickSearchZonesMode() {
            var radios = document.querySelectorAll('[role=\"radio\"], input[type=\"radio\"]');
            for (var i = 0; i < radios.length; i++) {
              var r = radios[i];
              var label = ((r.getAttribute('aria-label') || '') + ' ' + (r.innerText || '') + ' ' + (r.value || '')).toLowerCase();
              if (label.indexOf('search zones') !== -1 || label.indexOf('search zone') !== -1) {
                var selected = r.getAttribute('aria-checked') === 'true' || r.checked;
                if (!selected) {
                  if (click(r)) {
                    window.__parkingDidTapGeo = false;
                    window.__parkingGeoTappedAt = 0;
                    window.__parkingZoneApiResults = [];
                    window.__parkingNearestZoneCandidate = null;
                    window.__parkingZoneActivated = false;
                    return true;
                  }
                }
                return false;
              }
            }
            var buttons = document.querySelectorAll('button, [role=\"button\"], label');
            for (var j = 0; j < buttons.length; j++) {
              var b = buttons[j];
              var t = ((b.getAttribute('aria-label') || '') + ' ' + (b.innerText || '')).toLowerCase();
              if (t.indexOf('search zones') !== -1 && click(b)) return true;
            }
            return false;
          }

          function clickGetUserLocation() {
            if (window.__parkingDidTapGeo) return false;
            var candidates = document.querySelectorAll('button, [role=\"button\"], a');
            for (var i = 0; i < candidates.length; i++) {
              var el = candidates[i];
              var label = ((el.getAttribute('aria-label') || '') + ' ' + (el.title || '') + ' ' + (el.innerText || '')).toLowerCase();
              if (label.indexOf('get user location') !== -1
                  || label.indexOf('current location') !== -1
                  || label.indexOf('my location') !== -1
                  || label === 'locate me') {
                if (!click(el)) return false;
                window.__parkingDidTapGeo = true;
                window.__parkingGeoTappedAt = Date.now();
                // Clear any pre-geo Atlanta/default list so we don't pick a stale zone.
                window.__parkingZoneApiResults = [];
                window.__parkingNearestZoneCandidate = null;
                window.__parkingZoneActivated = false;
                bridge({ type: 'log', message: 'tapped Get user location' });
                return true;
              }
            }
            return false;
          }

          function zoneCandidatesFromDom() {
            var out = [];
            var links = document.querySelectorAll('a[href*=\"internalZoneCode\"], a[href*=\"/zone/\"]');
            for (var i = 0; i < links.length; i++) {
              var a = links[i];
              var href = a.getAttribute('href') || '';
              var aria = a.getAttribute('aria-label') || '';
              var text = (a.innerText || '').trim();
              var isPark = /park here/i.test(aria + ' ' + text) || /internalZoneCode=/i.test(href);
              if (!isPark && !/\\/zone\\/start\\?internalZoneCode=/i.test(href)) continue;
              var im = href.match(/internalZoneCode=(\\d+)/);
              var zm = (aria + ' ' + text).match(/Zone\\s*#\\s*(\\d+)/i);
              if (!zm) {
                var parentText = '';
                try { parentText = (a.parentElement && a.parentElement.parentElement && a.parentElement.parentElement.innerText) || ''; } catch (e) {}
                zm = parentText.match(/Zone\\s*#\\s*(\\d+)/i);
              }
              var zoneNum = zm ? zm[1] : (im ? im[1] : '');
              if (!zoneNum && !im) continue;
              out.push({
                zoneID: zoneNum || (im && im[1]) || '',
                internalZoneCode: im ? im[1] : '',
                label: ('Zone # ' + (zoneNum || '')).trim(),
                href: href,
                el: a,
                distanceMeters: null,
                order: out.length
              });
            }
            return out;
          }

          function zonePointLatLng(z) {
            if (!z) return null;
            if (z.latitude != null && z.longitude != null) return { lat: Number(z.latitude), lng: Number(z.longitude) };
            if (z.lat != null && (z.lng != null || z.lon != null)) return { lat: Number(z.lat), lng: Number(z.lng != null ? z.lng : z.lon) };
            if (z.location && z.location.lat != null) {
              return { lat: Number(z.location.lat), lng: Number(z.location.lng != null ? z.location.lng : z.location.lon) };
            }
            if (z.gpsPoints && z.gpsPoints.length) {
              var g = z.gpsPoints[0];
              if (g && g.latitude != null && g.longitude != null) return { lat: Number(g.latitude), lng: Number(g.longitude) };
            }
            if (z.zoneInfo && z.zoneInfo.latitude != null) {
              return { lat: Number(z.zoneInfo.latitude), lng: Number(z.zoneInfo.longitude) };
            }
            return null;
          }

          function zoneCandidatesFromApi() {
            var list = window.__parkingZoneApiResults || [];
            var out = [];
            // Address slug search (/search/hoboken-nj-usa): prefer API distance to map center.
            // cfg lat/lng is the garage stub and can be tens of km away.
            var addressSearch = /\\/search\\/[^/]+/i.test(location.pathname || '');
            for (var i = 0; i < list.length; i++) {
              var z = list[i] || {};
              // Public Zone # is signageCode (e.g. 47039); internalZoneCode is e.g. 30447039.
              var zoneID = String(z.signageCode || z.zoneCode || z.zoneNumber || z.displayZoneCode
                || z.publicZoneCode || z.zone || '');
              var internal = String(z.internalZoneCode || z.internalCode || '').trim();
              if (!internal || !/^\\d{5,}$/.test(internal)) continue;
              var pt = zonePointLatLng(z);
              var dist = null;
              if (addressSearch && typeof z.distanceMiles === 'number') {
                dist = z.distanceMiles * 1609.34;
              } else if (typeof z.distanceInMeters === 'number') {
                dist = z.distanceInMeters;
              } else if (typeof z.distance === 'number') {
                dist = z.distance;
              } else if (typeof z.distanceMiles === 'number') {
                dist = z.distanceMiles * 1609.34;
              } else if (!addressSearch && cfg.lat != null && cfg.lng != null && pt) {
                dist = haversineMeters(cfg.lat, cfg.lng, pt.lat, pt.lng);
              }
              out.push({
                zoneID: zoneID || internal,
                signageCode: zoneID,
                internalZoneCode: internal,
                label: z.locationName || z.supplierName || z.name
                  ? String(z.locationName || z.supplierName || z.name)
                  : ('Zone # ' + (zoneID || internal)),
                href: '/zone/start?internalZoneCode=' + encodeURIComponent(internal),
                el: null,
                distanceMeters: dist,
                order: i
              });
            }
            return out;
          }

          function findZoneNumberInput() {
            var inputs = document.querySelectorAll(
              'input[type=\"text\"], input[type=\"search\"], input[type=\"tel\"], input[type=\"number\"], input:not([type])'
            );
            for (var i = 0; i < inputs.length; i++) {
              var el = inputs[i];
              if (!visible(el)) continue;
              var label = ((el.getAttribute('aria-label') || '') + ' ' + (el.name || '') + ' ' + (el.id || '')
                + ' ' + (el.placeholder || '') + ' ' + labelText(el)).toLowerCase();
              if (label.indexOf('zone') !== -1) return el;
            }
            // /zone/start: first visible text field is usually Zone #.
            if (isZoneStartPage()) {
              for (var j = 0; j < inputs.length; j++) {
                if (visible(inputs[j]) && !inputs[j].disabled && !inputs[j].readOnly) return inputs[j];
              }
            }
            return null;
          }

          /// Hint iOS numeric keypad on Zone #. Do NOT set pattern=[0-9]* —
          /// that forces the locked number pad with no ABC/globe switch.
          function nudgeZoneIdNumericKeypad(el) {
            el = el || findZoneNumberInput();
            if (!el) return false;
            try {
              var changed = false;
              if (el.getAttribute('inputmode') !== 'numeric') {
                el.setAttribute('inputmode', 'numeric');
                changed = true;
              }
              // Drop any prior lock-to-number-pad pattern (ours or SPA).
              if (el.getAttribute('pattern') === '[0-9]*' || el.getAttribute('pattern') === '\\d*') {
                el.removeAttribute('pattern');
                changed = true;
              }
              if (el.getAttribute('enterkeyhint') !== 'done') {
                el.setAttribute('enterkeyhint', 'done');
                changed = true;
              }
              if (changed && !window.__parkingZoneKeypadNudged) {
                window.__parkingZoneKeypadNudged = true;
                bridge({ type: 'log', message: 'zoneId keypad nudge inputmode=numeric (no pattern lock)' });
              }
              return changed;
            } catch (e) {
              return false;
            }
          }

          /// Prefill returns filled on zone-id and stops; keep attrs alive across React re-renders.
          function ensureZoneIdKeypadWatch() {
            if (window.__parkingZoneKeypadWatch) return;
            window.__parkingZoneKeypadWatch = setInterval(function() {
              try {
                if (!isParkMobileZoneFlow()) return;
                if (!isZoneIdEntryPage()) return;
                nudgeZoneIdNumericKeypad();
              } catch (e) {}
            }, 1200);
          }

          /// Do not call /api/zones/search ourselves — live XHR shows our fetch gets HTTP 400/422.
          /// Rely on SPA Search Zones + Get user location (cached via installZoneFetchHook / DOM).
          function requestNearestZonesFromApi() {
            if ((window.__parkingZoneApiResults || []).length) {
              window.__parkingNearestZoneFetchedAt = Date.now();
              var nearest = pickNearestZoneCandidate();
              // Clear stale Atlanta/default picks when nothing is nearby.
              window.__parkingNearestZoneCandidate = nearest || null;
              return true;
            }
            return false;
          }

          function isAcceptableZoneCandidate(candidate) {
            if (!candidate || !candidate.internalZoneCode) return false;
            if (!/^\\d{5,}$/.test(String(candidate.internalZoneCode))) return false;
            var addressSearch = /\\/search\\/[^/]+/i.test(location.pathname || '');
            var maxM = addressSearch ? ADDRESS_ZONE_MAX_METERS : NEARBY_ZONE_MAX_METERS;
            if (typeof candidate.distanceMeters === 'number' && isFinite(candidate.distanceMeters)) {
              return candidate.distanceMeters <= maxM;
            }
            // Geo mode requires a known nearby distance.
            if (!addressSearch && cfg.lat != null && cfg.lng != null) return false;
            return !!addressSearch;
          }

          /// Prefer arriving via /search Park Here. Bare /zone/start has no working self-search API.
          function fillNearestZoneOnStartPage() {
            if (!isZoneStartPage() && !zoneEntryFormVisible()) return null;
            if (/internalZoneCode=/i.test(location.search || '')) {
              return 'ready';
            }
            var existing = readPrefilledZoneValue();
            if (existing) return 'ready';
            requestNearestZonesFromApi();
            var candidate = pickNearestZoneCandidate();
            window.__parkingNearestZoneCandidate = candidate || null;
            if (isAcceptableZoneCandidate(candidate) && !window.__parkingNearestZoneNavigated) {
              window.__parkingNearestZoneNavigated = true;
              window.__parkingNearestZoneFilled = true;
              try {
                location.href = '/zone/start?internalZoneCode=' + encodeURIComponent(candidate.internalZoneCode);
                bridge({ type: 'log', message: 'navigate nearest internalZoneCode=' + candidate.internalZoneCode });
                return 'navigated';
              } catch (e) {}
            }
            if (isAcceptableZoneCandidate(candidate)) {
              var input = findZoneNumberInput();
              var code = String(candidate.signageCode || candidate.zoneID || '').trim();
              if (input) nudgeZoneIdNumericKeypad(input);
              if (input && code && setNativeValue(input, code)) {
                window.__parkingNearestZoneFilled = true;
                bridge({ type: 'log', message: 'filled Zone # ' + code });
                return 'filled';
              }
            }
            // Send bare start page through the working /search + geo flow once.
            if (!window.__parkingRedirectedToSearch) {
              window.__parkingRedirectedToSearch = true;
              bridge({ type: 'log', message: 'zone/start empty — redirect /search for SPA nearest zone' });
              try { location.href = '/search'; return 'navigated'; } catch (e) {}
            }
            return 'pending';
          }

          /// Reject default-map (Atlanta) / faraway picks when GPS has no local zones.
          var NEARBY_ZONE_MAX_METERS = 2500;
          var ADDRESS_ZONE_MAX_METERS = 8000;

          function pickNearestZoneCandidate() {
            var api = zoneCandidatesFromApi();
            var dom = zoneCandidatesFromDom();
            var addressSearch = /\\/search\\/[^/]+/i.test(location.pathname || '');
            var maxM = addressSearch ? ADDRESS_ZONE_MAX_METERS : NEARBY_ZONE_MAX_METERS;
            // Geo mode: API only (has coords/distance). Never fall back to undated DOM/Atlanta list.
            var merged = api.length ? api : (addressSearch ? dom : []);
            if (!merged.length) return null;
            var withDist = merged.filter(function(z) {
              return typeof z.distanceMeters === 'number' && isFinite(z.distanceMeters)
                && z.distanceMeters >= 0 && z.distanceMeters <= maxM;
            });
            if (withDist.length) {
              withDist.sort(function(a, b) { return a.distanceMeters - b.distanceMeters; });
              return withDist[0];
            }
            // Geo + native fix: no nearby zone — caller pauses for street-address search.
            if (!addressSearch && cfg.lat != null && cfg.lng != null) {
              return null;
            }
            // After user-typed address, SPA list is for that place — first Park Here is OK.
            if (addressSearch) {
              var list = api.length ? api : dom;
              if (!list.length) return null;
              list.sort(function(a, b) { return a.order - b.order; });
              return list[0];
            }
            return null;
          }

          function activateNearestZone(candidate) {
            if (window.__parkingZoneActivated) return false;
            window.__parkingZoneActivated = true;
            if (candidate.el && click(candidate.el)) return true;
            var href = candidate.href || '';
            if (href) {
              try {
                if (href.indexOf('http') === 0) location.href = href;
                else location.href = href.indexOf('/') === 0 ? href : ('/' + href);
                return true;
              } catch (e) {}
            }
            return false;
          }

          function parseDurationMinutesFromOption(text, value) {
            var raw = String(text || '') + ' ' + String(value || '');
            var n = raw.toLowerCase();
            var hm = n.match(/(\\d+)\\s*h(?:ours?)?\\s*(\\d+)\\s*m/);
            if (hm) return parseInt(hm[1], 10) * 60 + parseInt(hm[2], 10);
            var hOnly = n.match(/(\\d+)\\s*h(?:our)?s?\\b/);
            var mOnly = n.match(/(\\d+)\\s*m(?:in(?:ute)?s?)?\\b/);
            if (hOnly && mOnly) return parseInt(hOnly[1], 10) * 60 + parseInt(mOnly[1], 10);
            if (hOnly && !mOnly) return parseInt(hOnly[1], 10) * 60;
            if (mOnly && !hOnly) return parseInt(mOnly[1], 10);
            if (/^\\d+$/.test(String(value || '').trim())) {
              return parseInt(value, 10);
            }
            return null;
          }

          function selectOptionNumbers(sel) {
            var vals = [];
            if (!sel || !sel.options) return vals;
            for (var i = 0; i < sel.options.length; i++) {
              var opt = sel.options[i];
              var n = parseInt(String(opt.value).replace(/[^0-9]/g, ''), 10);
              if (isNaN(n)) n = parseInt(String(opt.text).replace(/[^0-9]/g, ''), 10);
              if (!isNaN(n)) vals.push({ idx: i, n: n, text: String(opt.text || ''), value: String(opt.value || '') });
            }
            return vals;
          }

          /// ParkMobile Hours select: option value is often minutes (\"60\" = 1 Hour), text is \"1 Hour\".
          function parseHourOption(opt) {
            if (!opt) return null;
            var text = String(opt.text || '');
            var value = String(opt.value || '').trim();
            var hText = text.toLowerCase().match(/(\\d+)\\s*h(?:our)?s?\\b/);
            if (hText) return parseInt(hText[1], 10);
            if (/^\\d+$/.test(value)) {
              var n = parseInt(value, 10);
              // Minute-encoded hours: 0, 60, 120… (not a plain 0–12 hour index).
              if (n === 0) return 0;
              if (n >= 60 && n % 60 === 0 && (n / 60) <= 24) return n / 60;
              if (n >= 0 && n <= 12) return n;
            }
            var digits = parseInt(text.replace(/[^0-9]/g, ''), 10);
            return isNaN(digits) ? null : digits;
          }

          function selectHourOptionNumbers(sel) {
            var vals = [];
            if (!sel || !sel.options) return vals;
            for (var i = 0; i < sel.options.length; i++) {
              var hours = parseHourOption(sel.options[i]);
              if (hours == null || hours < 0) continue;
              vals.push({
                idx: i,
                n: hours,
                text: String(sel.options[i].text || ''),
                value: String(sel.options[i].value || '')
              });
            }
            return vals;
          }

          function looksLikeHourSelect(sel) {
            var meta = ((sel.getAttribute('aria-label') || '') + ' ' + (sel.name || '') + ' ' + (sel.id || '')).toLowerCase();
            if (/hour|hr\\b/.test(meta) && !/minute|\\bmin\\b/.test(meta)) return true;
            var vals = selectHourOptionNumbers(sel).map(function(v) { return v.n; });
            if (!vals.length) return false;
            var max = Math.max.apply(null, vals);
            var min = Math.min.apply(null, vals);
            // Hours: 0..12-ish after normalizing minute-encoded values.
            if (max > 12) return false;
            if (min < 0) return false;
            return true;
          }

          function looksLikeMinuteSelect(sel) {
            var meta = ((sel.getAttribute('aria-label') || '') + ' ' + (sel.name || '') + ' ' + (sel.id || '')).toLowerCase();
            if (/minute|\\bmin\\b/.test(meta) && !/hour|hr\\b/.test(meta)) return true;
            var vals = selectOptionNumbers(sel).map(function(v) { return v.n; });
            if (!vals.length) return false;
            var max = Math.max.apply(null, vals);
            if (max > 12 && max <= 59) return true;
            for (var i = 0; i < vals.length; i++) {
              if (vals[i] === 15 || vals[i] === 20 || vals[i] === 30 || vals[i] === 40 || vals[i] === 45) return true;
            }
            return false;
          }

          function setSelectOptionIndex(sel, idx) {
            if (!sel || idx == null || idx < 0 || !sel.options || !sel.options[idx]) return false;
            var opt = sel.options[idx];
            var value = opt.value;
            try {
              for (var oi = 0; oi < sel.options.length; oi++) sel.options[oi].selected = (oi === idx);
            } catch (e0) {}
            try {
              var proto = HTMLSelectElement.prototype;
              var desc = Object.getOwnPropertyDescriptor(proto, 'value');
              if (desc && desc.set) desc.set.call(sel, value);
              else sel.value = value;
            } catch (e) {
              sel.value = value;
            }
            try { sel.selectedIndex = idx; } catch (e2) {}
            try { opt.selected = true; } catch (e3) {}
            try { sel.focus(); } catch (e4) {}
            sel.dispatchEvent(new Event('input', { bubbles: true }));
            sel.dispatchEvent(new Event('change', { bubbles: true }));
            try {
              sel.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertReplacementText' }));
            } catch (e5) {}
            return norm(sel.value) === norm(value) || sel.selectedIndex === idx;
          }

          function setSelectByNumber(sel, wantNumber) {
            if (!sel || wantNumber == null) return false;
            var opts = selectOptionNumbers(sel);
            for (var i = 0; i < opts.length; i++) {
              if (opts[i].n === wantNumber) return setSelectOptionIndex(sel, opts[i].idx);
            }
            return false;
          }

          function setHourSelectByHours(sel, wantHours) {
            if (!sel || wantHours == null) return false;
            var opts = selectHourOptionNumbers(sel);
            for (var i = 0; i < opts.length; i++) {
              if (opts[i].n === wantHours) return setSelectOptionIndex(sel, opts[i].idx);
            }
            // Fallbacks: plain value \"1\" or minute-encoded \"60\".
            if (setSelectByNumber(sel, wantHours)) return true;
            if (wantHours > 0 && setSelectByNumber(sel, wantHours * 60)) return true;
            return false;
          }

          function readSelectedHourNumber(sel) {
            if (!sel || !sel.options || sel.selectedIndex < 0) return null;
            return parseHourOption(sel.options[sel.selectedIndex]);
          }

          function pickDurationCombobox(kindRe, wantNumber) {
            var want = String(wantNumber);
            var combos = document.querySelectorAll('[role=\"combobox\"], button[aria-haspopup=\"listbox\"]');
            var target = null;
            for (var i = 0; i < combos.length; i++) {
              var c = combos[i];
              if (!visible(c)) continue;
              var meta = ((c.getAttribute('aria-label') || '') + ' ' + (c.id || '') + ' ' + (c.innerText || '')).toLowerCase();
              if (kindRe.test(meta)) { target = c; break; }
            }
            if (!target) return false;
            if (!click(target, { scroll: false })) return false;
            var opts = document.querySelectorAll('[role=\"option\"], li[role=\"option\"]');
            for (var j = 0; j < opts.length; j++) {
              var opt = opts[j];
              if (!visible(opt)) continue;
              var key = norm((opt.getAttribute('data-value') || '') + ' ' + (opt.innerText || ''));
              var num = parseInt(String(opt.innerText || '').replace(/[^0-9]/g, ''), 10);
              if (key === norm(want) || num === wantNumber || key.indexOf(norm(want)) !== -1) {
                return click(opt, { scroll: false });
              }
            }
            return false;
          }

          function readSelectedNumber(sel) {
            if (!sel) return null;
            var opts = selectOptionNumbers(sel);
            for (var i = 0; i < opts.length; i++) {
              if (opts[i].idx === sel.selectedIndex) return opts[i].n;
            }
            var n = parseInt(String(sel.value).replace(/[^0-9]/g, ''), 10);
            return isNaN(n) ? null : n;
          }

          function findZoneHourMinuteSelects() {
            var selects = [];
            var all = document.querySelectorAll('select');
            for (var i = 0; i < all.length; i++) if (visible(all[i])) selects.push(all[i]);
            var hourSelect = null;
            var minuteSelect = null;
            var combinedSelect = null;
            for (var si = 0; si < selects.length; si++) {
              var s = selects[si];
              var meta = ((s.getAttribute('aria-label') || '') + ' ' + (s.name || '') + ' ' + (s.id || '')
                + ' ' + ((s.labels && s.labels[0] && s.labels[0].innerText) || '')).toLowerCase();
              if (/duration|time|how long|length/.test(meta) && !/hour|minute|min|hr/.test(meta)) {
                combinedSelect = combinedSelect || s;
              }
              if (/hour|hr\\b/.test(meta)) hourSelect = hourSelect || s;
              if (/minute|\\bmin\\b/.test(meta)) minuteSelect = minuteSelect || s;
            }
            if (!hourSelect || !minuteSelect) {
              for (var ci = 0; ci < selects.length; ci++) {
                var cand = selects[ci];
                if (cand === hourSelect || cand === minuteSelect) continue;
                if (!hourSelect && looksLikeHourSelect(cand) && !looksLikeMinuteSelect(cand)) hourSelect = cand;
                else if (!minuteSelect && looksLikeMinuteSelect(cand)) minuteSelect = cand;
              }
            }
            if ((!hourSelect || !minuteSelect) && selects.length >= 2
                && /duration|hour|minute|how long/i.test(document.body.innerText || '')) {
              if (looksLikeHourSelect(selects[0]) && looksLikeMinuteSelect(selects[1])) {
                hourSelect = hourSelect || selects[0];
                minuteSelect = minuteSelect || selects[1];
              } else if (looksLikeMinuteSelect(selects[0]) && looksLikeHourSelect(selects[1])) {
                minuteSelect = minuteSelect || selects[0];
                hourSelect = hourSelect || selects[1];
              }
            }
            return { hourSelect: hourSelect, minuteSelect: minuteSelect, combinedSelect: combinedSelect, selects: selects };
          }

          /// Greedy hour under cap (don't read minutes yet — list may refresh after hour is set).
          function pickBestHourUnderCap(hourSelect, maxMin) {
            var hourOpts = selectHourOptionNumbers(hourSelect);
            var best = null;
            for (var i = 0; i < hourOpts.length; i++) {
              var h = hourOpts[i].n;
              if (h == null || h < 0 || (h * 60) > maxMin) continue;
              if (!best || h > best.hour) {
                best = { hour: h, hourIdx: hourOpts[i].idx };
              }
            }
            return best;
          }

          /// After hour is fixed: largest live minute with hour×60 + m ≤ maxMin.
          function bestMinuteUnderCap(minuteSelect, hour, maxMin) {
            var remain = maxMin - (hour * 60);
            if (remain < 0) return null;
            var minuteOpts = selectOptionNumbers(minuteSelect);
            var bestM = -1;
            var bestIdx = -1;
            for (var i = 0; i < minuteOpts.length; i++) {
              var m = minuteOpts[i].n;
              if (m == null || m < 0 || m > 59) continue;
              if (m <= remain && m > bestM) {
                bestM = m;
                bestIdx = minuteOpts[i].idx;
              }
            }
            if (bestIdx < 0) return null;
            return { minute: bestM, minuteIdx: bestIdx, total: hour * 60 + bestM };
          }

          function selectGreatestDurationUpToMax() {
            // Retries needed — ParkMobile React resets hour when minutes change (and vice versa).
            var attempts = window.__parkingZoneDurationAttempts || 0;
            if (attempts >= 10) {
              // Keep trying; never false-succeed with minutes-only and Continue at 0h.
              window.__parkingZoneDurationAttempts = 0;
              attempts = 0;
            }
            var maxMin = cfg.maxDurationMinutes || 160;
            var found = findZoneHourMinuteSelects();
            var hourSelect = found.hourSelect;
            var minuteSelect = found.minuteSelect;
            var combinedSelect = found.combinedSelect;

            if (combinedSelect && !hourSelect) {
              var bestIdx = -1;
              var bestMins = -1;
              for (var o = 0; o < combinedSelect.options.length; o++) {
                var opt = combinedSelect.options[o];
                var mins = parseDurationMinutesFromOption(opt.text, opt.value);
                if (mins == null) continue;
                if (/^\\d+$/.test(String(opt.value || '').trim()) && mins <= 3) mins = mins * 60;
                if (mins <= maxMin && mins > bestMins) {
                  bestMins = mins;
                  bestIdx = o;
                }
              }
              if (bestIdx >= 0 && setSelectOptionIndex(combinedSelect, bestIdx)) {
                window.__parkingZoneDurationSet = true;
                bridge({ type: 'log', message: 'setDuration combined=' + bestMins + 'm' });
                return true;
              }
            }

            if (hourSelect && minuteSelect) {
              // Greedy: largest hour ≤ cap, set it, then largest live minute under the cap.
              var bestHour = pickBestHourUnderCap(hourSelect, maxMin);
              if (!bestHour) {
                window.__parkingZoneDurationAttempts = attempts + 1;
                if (!window.__parkingDurationDiagLogged) {
                  window.__parkingDurationDiagLogged = true;
                  bridge({
                    type: 'log',
                    message: 'durationDiag no-hour max=' + maxMin
                      + ' hours=' + selectHourOptionNumbers(hourSelect).map(function(v) { return v.n + '@' + v.value; }).join(',')
                  });
                }
                return false;
              }
              setHourSelectByHours(hourSelect, bestHour.hour) || setSelectOptionIndex(hourSelect, bestHour.hourIdx);
              pickDurationCombobox(/hour|hr/, bestHour.hour);

              var live = bestMinuteUnderCap(minuteSelect, bestHour.hour, maxMin);
              if (!live) {
                // Minute list not ready / empty after hour change — retry next pass.
                window.__parkingZoneDurationAttempts = attempts + 1;
                bridge({
                  type: 'log',
                  message: 'setDuration hour=' + bestHour.hour + ' min=pending max=' + maxMin
                    + ' hourVal=' + (hourSelect.value || '')
                    + ' attempt=' + window.__parkingZoneDurationAttempts
                });
                return false;
              }
              if (live.minuteIdx >= 0) setSelectOptionIndex(minuteSelect, live.minuteIdx);
              else setSelectByNumber(minuteSelect, live.minute);
              pickDurationCombobox(/minute|min/, live.minute);
              // Re-assert hour (React sometimes resets it when minutes change).
              setHourSelectByHours(hourSelect, bestHour.hour) || setSelectOptionIndex(hourSelect, bestHour.hourIdx);
              live = bestMinuteUnderCap(minuteSelect, bestHour.hour, maxMin) || live;
              if (live.minuteIdx >= 0) setSelectOptionIndex(minuteSelect, live.minuteIdx);
              else setSelectByNumber(minuteSelect, live.minute);

              var gotH = readSelectedHourNumber(hourSelect);
              var gotM = readSelectedNumber(minuteSelect);
              var gotTotal = (gotH != null && gotM != null) ? (gotH * 60 + gotM) : -1;
              var target = live.total;
              window.__parkingZoneDurationAttempts = attempts + 1;
              bridge({
                type: 'log',
                message: 'setDuration hour=' + gotH + ' min=' + gotM
                  + ' total=' + gotTotal + 'm target=' + target + 'm max=' + maxMin
                  + ' hourVal=' + (hourSelect.value || '')
                  + ' minOpts=' + selectOptionNumbers(minuteSelect).map(function(v) { return v.n; }).join(',')
                  + ' attempt=' + window.__parkingZoneDurationAttempts
              });
              if (gotH === bestHour.hour && gotM != null && gotTotal <= maxMin) {
                var liveNow = bestMinuteUnderCap(minuteSelect, gotH, maxMin);
                if (liveNow && gotM === liveNow.minute) {
                  window.__parkingZoneDurationSet = true;
                  return true;
                }
              }
              return false;
            }

            // Custom hour/minute comboboxes only.
            var maxH2 = Math.floor(maxMin / 60);
            var wantM = maxMin - maxH2 * 60;
            var minuteSnaps = [40, 30, 20, 45, 15, 50, 10, 0];
            var snapM = 0;
            for (var ms = 0; ms < minuteSnaps.length; ms++) {
              if (minuteSnaps[ms] <= wantM) { snapM = minuteSnaps[ms]; break; }
            }
            var comboChanged = false;
            if (maxH2 > 0) comboChanged = pickDurationCombobox(/hour|hr/, maxH2) || comboChanged;
            comboChanged = pickDurationCombobox(/minute|min/, snapM) || comboChanged;
            if (maxH2 > 0) comboChanged = pickDurationCombobox(/hour|hr/, maxH2) || comboChanged;
            window.__parkingZoneDurationAttempts = attempts + 1;
            if (comboChanged) {
              bridge({ type: 'log', message: 'setDuration combobox hour=' + maxH2 + ' min=' + snapM });
              // Verify via combobox text before committing.
              var hourOk = maxH2 <= 0 || comboboxDisplayMatches(/hour|hr/, String(maxH2));
              var minOk = comboboxDisplayMatches(/minute|min/, String(snapM));
              if (hourOk && minOk) {
                window.__parkingZoneDurationSet = true;
                return true;
              }
            }
            return false;
          }

          function zoneDurationReadyForContinue() {
            if (!hasZoneDurationSelectors()) return true;
            if (window.__parkingZoneDurationSet) return true;
            // Soft accept when UI already shows greedy hour + max live minute under the cap.
            var found = findZoneHourMinuteSelects();
            if (found.hourSelect && found.minuteSelect) {
              var maxMin = cfg.maxDurationMinutes || 160;
              var wantH = pickBestHourUnderCap(found.hourSelect, maxMin);
              var h = readSelectedHourNumber(found.hourSelect);
              var m = readSelectedNumber(found.minuteSelect);
              if (wantH && h === wantH.hour && m != null) {
                var live = bestMinuteUnderCap(found.minuteSelect, h, maxMin);
                if (live && m === live.minute && live.total <= maxMin) return true;
              }
            }
            return false;
          }

          function readPrefilledZoneValue() {
            var el = findZoneNumberInput();
            if (!el) return '';
            return String(el.value || '').trim();
          }

          function zoneEntryFormVisible() {
            return !!findZoneNumberInput();
          }

          function zoneSubmissionErrorVisible() {
            var alerts = document.querySelectorAll('[role=\"alert\"], [class*=\"error\"], [class*=\"Error\"], [data-testid*=\"error\"]');
            for (var i = 0; i < alerts.length; i++) {
              var el = alerts[i];
              if (!visible(el)) continue;
              var t = String(el.innerText || el.textContent || '').replace(/\\s+/g, ' ').trim();
              if (t.length < 3) continue;
              if (/cookie|consent|privacy|necessary/i.test(t)) continue;
              if (/error|sorry|not found|invalid|unable|failed|try again|difficulties|unavailable/i.test(t)) {
                return true;
              }
            }
            var body = String((document.body && document.body.innerText) || '');
            if (/zone not found/i.test(body)) return true;
            if (/sorry,?\\s*we.?re having technical difficulties/i.test(body)) return true;
            if (/please check nearby signage/i.test(body)) return true;
            if (/invalid zone/i.test(body)) return true;
            return false;
          }

          function buttonLabelText(b) {
            return ((b.innerText || '') + ' ' + (b.getAttribute('aria-label') || '') + ' ' + (b.value || ''))
              .toLowerCase().replace(/\\s+/g, ' ').trim();
          }

          function hasConfirmZoneButton() {
            var buttons = document.querySelectorAll('button, [role=\"button\"], input[type=\"submit\"], a');
            for (var i = 0; i < buttons.length; i++) {
              var b = buttons[i];
              if (!visible(b) || b.disabled) continue;
              if (buttonLabelText(b).indexOf('confirm zone') !== -1) return true;
            }
            return false;
          }

          /// Auto Continue only — never returns Confirm Zone (manual pause on zone-id page).
          function findZoneContinueButton() {
            var buttons = document.querySelectorAll('button, [role=\"button\"], input[type=\"submit\"], a');
            var continueBtn = null;
            for (var i = 0; i < buttons.length; i++) {
              var b = buttons[i];
              if (!visible(b) || b.disabled) continue;
              var t = buttonLabelText(b);
              if (!t) continue;
              // Never payment / Apple / purchase CTAs here.
              if (/continue with apple|apple pay|complete purchase|buy with|log in|sign up|sign in/.test(t)) continue;
              if (/save and continue|save & continue/.test(t)) continue;
              // Manual pause: user must tap Confirm Zone.
              if (t.indexOf('confirm zone') !== -1) continue;
              if (t === 'continue' || t === 'confirm' || t === 'next' || t === 'proceed') continueBtn = continueBtn || b;
              else if (/^continue\\b/.test(t) && t.length < 24) continueBtn = continueBtn || b;
            }
            return continueBtn;
          }

          function clickZoneContinueButton() {
            var now = Date.now();
            if (window.__parkingZoneContinueAt && (now - window.__parkingZoneContinueAt) < 2200) return false;
            // Hard stop while Confirm Zone is on screen (map / zone-id selection pause).
            if (hasConfirmZoneButton()) return false;
            var btn = findZoneContinueButton();
            if (!btn) return false;
            var t = buttonLabelText(btn);
            if (t.indexOf('confirm zone') !== -1) return false;
            // No scroll — Continue sits at the bottom; scrolling it into center fights the user every loop.
            if (!click(btn, { scroll: false })) return false;
            window.__parkingZoneContinueAt = now;
            window.__parkingZoneLastSubmitAt = now;
            window.__parkingZoneAwaitErrorCheck = true;
            return true;
          }

          function hasZoneDurationSelectors() {
            var selects = document.querySelectorAll('select');
            var visibleCount = 0;
            for (var i = 0; i < selects.length; i++) {
              if (!visible(selects[i])) continue;
              visibleCount += 1;
              var meta = ((selects[i].getAttribute('aria-label') || '') + ' ' + (selects[i].name || '') + ' ' + (selects[i].id || '')).toLowerCase();
              if (/hour|minute|min|duration|time|length/.test(meta)) return true;
            }
            if (visibleCount >= 2 && /duration|hour|minute|how long/i.test(document.body.innerText || '')) return true;
            return false;
          }

          /// First checkout page that asks for Zone # — prefill only; user submits Confirm Zone.
          function isZoneIdEntryPage() {
            var path = location.pathname || '';
            if (/\\/zone\\/(duration|auth|vehicle|contact|payment|confirm|review|summary)/i.test(path)) {
              return false;
            }
            // Confirm Zone CTA is the map-selection pause — always treat as zone-id entry.
            if (hasConfirmZoneButton()) return true;
            if (hasZoneDurationSelectors()) return false;
            if (zoneCheckoutStepsVisible()) return false;
            if (/\\/zone\\/start/i.test(path)) return true;
            if (zoneEntryFormVisible() && (findZoneNumberInput() || hasConfirmZoneButton())) return true;
            return false;
          }

          function zoneCheckoutStepsVisible() {
            if (firstVisible('#email, input[name=\"email\"], input[type=\"email\"]')) return true;
            if (firstVisible('#phone, input[name=\"phone\"], input[type=\"tel\"]')) return true;
            if (firstVisible('#vrn, input[name=\"vrn\"]')) return true;
            if (findContinueWithApplePayButton()) return true;
            if (findByText('button, a, [role=\"button\"]', /continueasaguest|guestcheckout|continueasguest/)) return true;
            return false;
          }

          function advanceParkMobileZone() {
            if (!isParkMobileZoneFlow() || !cfg.zoneAutomationEnabled) return null;
            installZoneFetchHook();
            ensureNativeGeolocationStub();

            // /search — SPA owns zones/search XHR; auto Park Here nearest, then stop on zone-id page.
            if (isZoneSearchPage()) {
              var searchPath = location.pathname || '';
              if (window.__parkingZoneSearchPath !== searchPath) {
                window.__parkingZoneSearchPath = searchPath;
                window.__parkingZoneApiResults = [];
                window.__parkingNearestZoneCandidate = null;
                window.__parkingZoneActivated = false;
                window.__parkingAwaitZonesLogged = false;
                window.__parkingAwaitAddressLogged = false;
                // Address geocode (/search/hoboken-nj-usa) replaces geo; don't keep Atlanta/stub picks.
                if (/\\/search\\/[^/]+/i.test(searchPath)) {
                  window.__parkingDidTapGeo = true;
                  window.__parkingGeoTappedAt = Date.now();
                  bridge({ type: 'log', message: 'address search path — cleared zone cache' });
                }
              }
              if (dismissCookieBanner()) {
                return { status: 'advanced', filled: 0, action: 'cookie' };
              }
              if (clickSearchZonesMode()) {
                return { status: 'advanced', filled: 0, action: 'searchZonesMode' };
              }
              var addressSearch = /\\/search\\/[^/]+/i.test(searchPath);
              if (!addressSearch && clickGetUserLocation()) {
                return { status: 'advanced', filled: 0, action: 'geo' };
              }
              if (!addressSearch && !window.__parkingDidTapGeo) {
                return { status: 'waiting', filled: 0, action: 'awaitGeoButton' };
              }
              var geoAge = window.__parkingGeoTappedAt ? (Date.now() - window.__parkingGeoTappedAt) : 0;
              var apiCount = (window.__parkingZoneApiResults || []).length;
              var domCount = zoneCandidatesFromDom().length;
              // Wait for SPA recenter + zones/search before picking (avoid stale default list).
              if (geoAge < 2800 && !apiCount) {
                return { status: 'waiting', filled: 0, action: 'awaitZones' };
              }
              requestNearestZonesFromApi();
              var candidate = pickNearestZoneCandidate();
              window.__parkingNearestZoneCandidate = candidate || null;
              if (!isAcceptableZoneCandidate(candidate)) {
                // Geo: give SPA a few seconds, then stop — let user type a street address.
                // Do not keep waiting until a faraway/default (Atlanta) list appears.
                if (!addressSearch) {
                  if (geoAge < 8000) {
                    return { status: 'waiting', filled: 0, action: 'awaitZones' };
                  }
                  if (!window.__parkingAwaitAddressLogged) {
                    window.__parkingAwaitAddressLogged = true;
                    bridge({
                      type: 'log',
                      message: 'awaitAddressSearch — no zone within ' + NEARBY_ZONE_MAX_METERS
                        + 'm of GPS; api=' + apiCount + ' dom=' + domCount
                        + ' (type street address or Park Here manually)'
                    });
                  }
                  return { status: 'filled', filled: 0, action: 'awaitAddressSearch' };
                }
                if (geoAge < 14000) {
                  return { status: 'waiting', filled: 0, action: 'awaitZones' };
                }
                if (!window.__parkingAwaitZonesLogged) {
                  window.__parkingAwaitZonesLogged = true;
                  bridge({ type: 'log', message: 'awaitZones timeout api=' + apiCount + ' dom=' + domCount });
                }
                return { status: 'waiting', filled: 0, action: 'awaitZones' };
              }
              if (activateNearestZone(candidate)) {
                bridge({
                  type: 'log',
                  message: 'pickZone #' + (candidate.signageCode || candidate.zoneID)
                    + ' internal=' + (candidate.internalZoneCode || '')
                    + (candidate.distanceMeters != null ? (' dist=' + Math.round(candidate.distanceMeters) + 'm') : '')
                });
                return { status: 'advanced', filled: 0, action: 'pickZone' };
              }
              return { status: 'waiting', filled: 0, action: 'pickZonePending' };
            }

            // Reached /zone/auth?checkoutState=... — hand off to guest/checkout chain.
            if (isZoneAuthCheckoutPage()) {
              return null;
            }

            // Contact / email step (own page or editable email before payment).
            if (isZoneContactPage() || (zoneEmailStepVisible() && !isZoneVehiclePage() && !isZonePreAuthPage() && !isZoneStartPage())) {
              if (dismissCookieBanner()) {
                return { status: 'advanced', filled: 0, action: 'cookie' };
              }
              logContactDiagnostics();
              var contactFilled = fillContactFields();
              if (contactFilled > 0) {
                return { status: 'waiting', filled: contactFilled, action: 'contactPartial' };
              }
              if (clickParkMobileContactEdit()) {
                return { status: 'advanced', filled: 0, action: 'contactEdit' };
              }
              if (clickParkMobileContactContinue() || clickSaveAndContinue()) {
                return { status: 'advanced', filled: contactFilled, action: 'contactContinue' };
              }
              // Stay on dedicated contact; otherwise fall through so payment/Apple Pay can run.
              if (isZoneContactPage() || contactNeedsEmailFix()) {
                return { status: 'waiting', filled: 0, action: 'awaitContact' };
              }
            }

            // Add Vehicle: fill plate/country/state from config, then Continue.
            if (isZoneVehiclePage()) {
              if (dismissCookieBanner()) {
                return { status: 'advanced', filled: 0, action: 'cookie' };
              }
              // Some zone vehicle screens also ask for email above the plate.
              var contactOnVehicle = fillContactFields();
              if (clickParkMobileAddVehicle()) {
                return { status: 'advanced', filled: contactOnVehicle, action: 'vehicleAdd' };
              }
              // Re-apply fields (React often resets country/state after first paint).
              var forceFill = !window.__parkingZoneVehicleForced
                  || ((window.__parkingZoneVehicleForceAt || 0) + 4000 < Date.now());
              if (forceFill) {
                window.__parkingZoneVehicleForced = true;
                window.__parkingZoneVehicleForceAt = Date.now();
              }
              var vehicleFilled = fillParkMobileVehicleFields({ force: forceFill }) + contactOnVehicle;
              logVehicleFormDiagnostics();
              if (contactOnVehicle > 0 || contactJustFilled()) {
                return { status: 'waiting', filled: vehicleFilled, action: 'contactPartial' };
              }
              if (clickParkMobileVehicleContinue() || clickSaveAndContinue()
                  || clickZoneVehicleContinueAggressive()) {
                return { status: 'advanced', filled: vehicleFilled, action: 'vehicleConfirm' };
              }
              if (vehicleFormReady()) {
                var zoneBtn = findZoneContinueButton();
                if (zoneBtn && forceClickDisabled(zoneBtn)) {
                  window.__parkingLastSaveAt = Date.now();
                  bridge({ type: 'log', message: 'vehicle Continue via zone button fallback' });
                  return { status: 'advanced', filled: vehicleFilled, action: 'vehicleConfirm' };
                }
              }
              if (vehicleFilled > 0) {
                return { status: 'waiting', filled: vehicleFilled, action: 'vehiclePartial' };
              }
              return { status: 'waiting', filled: vehiclePlateMatches() ? 1 : 0, action: 'awaitVehicle' };
            }

            // Loop Continue (and pause on errors) until auth+checkoutState URL.
            if (isZonePreAuthPage() || isZoneStartPage()) {
              if (dismissCookieBanner()) {
                return { status: 'advanced', filled: 0, action: 'cookie' };
              }

              // Zone-id page: prefill / deep-link nearest zone, but never auto-submit Confirm Zone.
              if (isZoneIdEntryPage()) {
                ensureZoneIdKeypadWatch();
                nudgeZoneIdNumericKeypad();
                var nearestStatus = fillNearestZoneOnStartPage();
                if (nearestStatus === 'navigated') {
                  return { status: 'advanced', filled: 0, action: 'pickZone' };
                }
                if (nearestStatus === 'filled') {
                  return { status: 'advanced', filled: 1, action: 'fillZone' };
                }
                if (nearestStatus === 'pending') {
                  return { status: 'waiting', filled: 0, action: 'awaitZonePrefill' };
                }
                nudgeZoneIdNumericKeypad();
                if (!window.__parkingZoneIdManualLogged) {
                  window.__parkingZoneIdManualLogged = true;
                  bridge({
                    type: 'log',
                    message: 'awaitManualZoneIdSubmit — zone ready; not auto-submitting zone-id page'
                  });
                }
                // Stop auto-retry spam; user Confirm Zone / Continue will change URL and restart prefill.
                return {
                  status: 'filled',
                  filled: (readPrefilledZoneValue() || /internalZoneCode=/i.test(location.search || '')) ? 1 : 0,
                  action: 'awaitManualZoneIdSubmit'
                };
              }

              // After an auto-submit, detect errors; if present, wait for manual re-submit.
              if (window.__parkingZoneAwaitErrorCheck) {
                window.__parkingZoneAwaitErrorCheck = false;
                if (zoneSubmissionErrorVisible()) {
                  window.__parkingZoneAwaitManualSubmit = true;
                  bridge({ type: 'log', message: 'zone submit error — waiting for manual re-submit' });
                  return { status: 'waiting', filled: 0, action: 'awaitManualZoneSubmit' };
                }
              }

              if (window.__parkingZoneAwaitManualSubmit) {
                if (zoneSubmissionErrorVisible()) {
                  return { status: 'waiting', filled: 0, action: 'awaitManualZoneSubmit' };
                }
                // Error cleared / user advanced — resume Continue loop.
                window.__parkingZoneAwaitManualSubmit = false;
                window.__parkingZoneEntrySubmitted = true;
                bridge({ type: 'log', message: 'zone manual re-submit detected — resuming toward /zone/auth' });
              }

              if (zoneSubmissionErrorVisible()) {
                window.__parkingZoneAwaitManualSubmit = true;
                return { status: 'waiting', filled: 0, action: 'awaitManualZoneSubmit' };
              }

              // Duration step: set hour+minute up to max before Continue (don't skip with minutes-only).
              if (hasZoneDurationSelectors() && !window.__parkingZoneDurationSet) {
                if (selectGreatestDurationUpToMax()) {
                  return { status: 'advanced', filled: 0, action: 'setDuration' };
                }
                if ((window.__parkingZoneDurationAttempts || 0) < 10) {
                  return { status: 'waiting', filled: 0, action: 'awaitDuration' };
                }
                bridge({ type: 'log', message: 'duration give up after retries — blocking Continue until hour sticks' });
                return { status: 'waiting', filled: 0, action: 'awaitDuration' };
              }

              // Never Continue while hour/minute pickers exist but duration is still wrong (e.g. 0h40m).
              if (hasZoneDurationSelectors() && !zoneDurationReadyForContinue()) {
                window.__parkingZoneDurationSet = false;
                window.__parkingZoneDurationAttempts = Math.min(window.__parkingZoneDurationAttempts || 0, 8);
                selectGreatestDurationUpToMax();
                return { status: 'waiting', filled: 0, action: 'awaitDuration' };
              }

              if (clickZoneContinueButton()) {
                window.__parkingZoneEntrySubmitted = true;
                return { status: 'advanced', filled: 0, action: 'zoneContinue' };
              }

              return { status: 'waiting', filled: 0, action: 'awaitZoneAuth' };
            }

            return null;
          }

          // ParkChirp: wait for account sign-in; never guest, never tap Checkout.
          // Dates/hours are set once at the very end (after sign-in + plate).
          function advanceParkChirp() {
            if (!isParkChirp()) return null;
            if (dismissCookieBanner()) {
              return { status: 'advanced', filled: 0, action: 'cookie' };
            }
            if (submitParkChirpLoginIfAutofilled()) {
              return { status: 'advanced', filled: 0, action: 'loginSubmit' };
            }
            if (parkChirpNeedsSignIn() || !parkChirpIsSignedIn()) {
              var fieldsNow = parkChirpFindLoginFields();
              parkChirpPrepareLoginAutocomplete(fieldsNow);
              logParkChirpLoginDiagnostics();
              if (hintParkChirpPasswordAutofill()) {
                return { status: 'advanced', filled: 0, action: 'autofillHint' };
              }
              return { status: 'waiting', filled: 0, action: 'awaitSignIn' };
            }
            var filled = 0;
            // Prefer configured plate when several radios exist.
            if (cfg.licensePlateNumber) {
              var want = norm(cfg.licensePlateNumber);
              var plates = document.querySelectorAll('input[type=\"radio\"][name=\"license-plates\"]');
              for (var i = 0; i < plates.length; i++) {
                var p = plates[i];
                var label = norm((p.id || '') + ' ' + (p.value || '') + ' ' + ((p.labels && p.labels[0] && p.labels[0].innerText) || ''));
                if (want && label.indexOf(want) !== -1 && !p.checked) {
                  try {
                    p.click();
                    filled += 1;
                  } catch (e) {}
                  break;
                }
              }
            }
            // Very end: force Start/End Date + Time once, then stop.
            if (!window.__parkingParkChirpTimesDone) {
              if (applyParkChirpUrlDatesAndTimes()) {
                return { status: 'advanced', filled: filled, action: 'setTimes' };
              }
              return { status: 'waiting', filled: filled, action: 'parkChirpTimesPending' };
            }
            if (document.querySelector('#gpi-checkout-submit')) {
              return { status: 'filled', filled: filled, action: 'awaitCheckout' };
            }
            return { status: 'waiting', filled: filled, action: 'parkChirpMount' };
          }

          function fillOnce() {
            try {
              if (hasBlockingCaptcha()) return { status: 'captcha', filled: 0, action: 'captcha' };
              var parkChirpStep = advanceParkChirp();
              if (parkChirpStep) return parkChirpStep;
              var zoneStep = advanceParkMobileZone();
              if (zoneStep) return zoneStep;
              var action = null;
              if (dismissCookieBanner()) action = 'cookie';
              if (clickReserveParkHere()) action = action || 'reserve';
              if (!isParkChirp() && preferGuestCheckout()) action = action || 'guest';
              var filled = fillFields();
              filled += fillSpotHeroVehicleModal();
              // SpotHero: open vehicle modal, then confirm after make/model selection.
              if (clickSpotHeroVehicleAdd()) action = action || 'vehicleAdd';
              if (clickParkMobileAddVehicle()) action = action || 'vehicleAdd';
              filled += fillSpotHeroVehicleModal();
              filled += fillContactFields();
              var forceGarageVehicle = isGarageCheckoutVehicleStep() && (
                !window.__parkingGarageVehicleForced
                || ((window.__parkingGarageVehicleForceAt || 0) + 4000 < Date.now())
              );
              if (forceGarageVehicle) {
                window.__parkingGarageVehicleForced = true;
                window.__parkingGarageVehicleForceAt = Date.now();
              }
              filled += fillParkMobileVehicleFields({ force: !!forceGarageVehicle });
              if (isGarageCheckoutVehicleStep() || vehiclePlateInput()) {
                logVehicleFormDiagnostics();
              }
              if (isParkMobileCheckoutFlow()) logContactDiagnostics();
              if (clickSpotHeroVehicleConfirm()) action = action || 'vehicleConfirm';
              // Garage Vehicle Details uses Save & Continue — tap that before bare Continue.
              if (clickSaveAndContinue()
                  || clickParkMobileVehicleContinue()
                  || clickGarageVehicleContinueAggressive()) {
                action = action || 'vehicleConfirm';
              }
              // Collapsed guest Contact with a throwaway email — open Edit before Apple Pay.
              if (clickParkMobileContactEdit()) action = action || 'contactEdit';
              // Don't re-tap Contact Continue once the vehicle form is the active step.
              if (!(isGarageCheckoutVehicleStep() && (vehiclePlateMatches() || vehicleFormReady()))) {
                if (clickSpotHeroContactContinue()) action = action || 'spotHeroContinue';
                if (clickParkMobileContactContinue()) action = action || 'contactContinue';
              }
              // ParkMobile Payment Details → Continue with Apple Pay; Confirm → I acknowledge.
              // Never taps Complete Purchase / Buy with Apple Pay.
              // Hold Apple Pay until BookingConfig email is committed (guest receipts go there).
              if (contactReadyForPayment() && clickContinueWithApplePay()) action = action || 'applePay';
              if (contactReadyForPayment() && checkAcknowledgeBoxes()) action = action || 'acknowledge';
              if (action) {
                return { status: 'advanced', filled: filled, action: action };
              }
              if (!contactReadyForPayment()) {
                return { status: 'waiting', filled: filled, action: 'awaitContact' };
              }
              if (filled > 0) {
                // Keep going if more checkout steps still need input.
                if (contactSectionNeedsInput() || vehicleSectionNeedsInput() || paymentSectionNeedsAction()) {
                  return { status: 'waiting', filled: filled, action: 'partial' };
                }
                return { status: 'filled', filled: filled, action: 'done' };
              }
              if (paymentSectionNeedsAction()) {
                return { status: 'waiting', filled: 0, action: 'paymentPending' };
              }
              // After Apple Pay / acknowledge (no field fills this pass), stop if nothing left.
              if ((window.__parkingApplePayAt || window.__parkingAckAt)
                  && !contactSectionNeedsInput() && !vehicleSectionNeedsInput()) {
                return { status: 'filled', filled: 0, action: 'done' };
              }
              return { status: 'waiting', filled: 0, action: 'idle' };
            } catch (e) {}
            return { status: 'error', filled: 0, action: 'error' };
          }

          function stopRetry(timer) {
            if (timer) clearInterval(timer);
            window.__parkingPrefillBusy = false;
            window.__parkingPrefillKick = null;
          }

          // Re-entry from Swift (or wand): kick another fill without stacking timers.
          if (window.__parkingPrefillKick) {
            var kicked = window.__parkingPrefillKick();
            try { return JSON.stringify(kicked); } catch (e) { return "kicked"; }
          }

          window.__parkingPrefillBusy = true;
          var latest = fillOnce();
          var attempts = 0;
          var maxAttempts = 90; // ~3 minutes at 2s
          var retryTimer = setInterval(function() {
            attempts += 1;
            latest = fillOnce();
            // Only stop when fully done (or exhausted). Keep going through Reserve → guest → Save & Continue → vehicle.
            if (latest.status === 'filled' || attempts >= maxAttempts) {
              stopRetry(retryTimer);
            }
          }, 2000);

          window.__parkingPrefillKick = function() {
            latest = fillOnce();
            if (latest.status === 'filled') stopRetry(retryTimer);
            return latest;
          };

          // Immediate + short delayed passes for SPA form mount.
          setTimeout(function() { latest = fillOnce(); }, 600);
          setTimeout(function() {
            latest = fillOnce();
            if (latest.status === 'filled') stopRetry(retryTimer);
          }, 1600);

          try {
            return JSON.stringify(latest);
          } catch (e) {
            return "started";
          }
        })();
        """
    }

    private static func jsonString(_ value: String) -> String {
        // Bare strings need .fragmentsAllowed. Without it NSJSONSerialization throws
        // an ObjC exception (not a Swift Error), so try? cannot catch it → SIGABRT.
        guard let data = try? JSONSerialization.data(
            withJSONObject: value,
            options: [.fragmentsAllowed]
        ),
        let encoded = String(data: data, encoding: .utf8)
        else {
            return "\"\""
        }
        return encoded
    }
}
