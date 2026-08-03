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
              var setter = Object.getOwnPropertyDescriptor(proto, 'value');
              if (setter && setter.set) setter.set.call(el, value);
              else el.value = value;
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
            return filled;
          }

          function clickParkMobileContactContinue() {
            var now = Date.now();
            if (window.__parkingLastSaveAt && (now - window.__parkingLastSaveAt) < 2500) return false;
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

          /// Force plate + country + state from BookingConfig (overwrite wrong defaults like AL / partial plate).
          function fillParkMobileVehicleFields() {
            var filled = 0;
            if (cfg.licensePlateNumber) {
              var plateEl = firstVisible(
                '#vrn, input[name=\"vrn\"], #licensePlate, #license-plate, #plate, input[name*=\"plate\" i], input[id*=\"plate\" i], input[name*=\"license\" i], input[name*=\"lpn\" i], [data-testid=\"Vehicle-input-plate\"], [data-pmtest-id*=\"vehicle\"][data-pmtest-id*=\"plate\"], [data-pmtest-id*=\"license\"]'
              );
              if (plateEl) {
                var curPlate = String(plateEl.value || '').trim();
                if (norm(curPlate) !== norm(cfg.licensePlateNumber)
                    && setNativeValue(plateEl, cfg.licensePlateNumber)) {
                  filled += 1;
                }
              }
            }
            if (cfg.country) {
              var countryEl = firstVisible(
                'select#country, select[name=\"country\"], select[name*=\"country\" i], select[id*=\"country\" i], [data-testid=\"Vehicle-input-country\"]'
              );
              if (countryEl && !selectMatchesValue(countryEl, cfg.country)
                  && setNativeValue(countryEl, cfg.country)) {
                filled += 1;
              } else if (!countryEl) {
                filled += pickComboboxOption(/country|nation/i, cfg.country) ? 1 : 0;
              }
            }
            if (cfg.state) {
              var stateEl = firstVisible(
                'select#state, select[name=\"state\"], select[name*=\"state\" i], select[id*=\"state\" i], select[name*=\"province\" i], [data-testid=\"Vehicle-input-state\"]'
              );
              if (stateEl && !selectMatchesValue(stateEl, cfg.state)
                  && setNativeValue(stateEl, cfg.state)) {
                filled += 1;
              } else if (!stateEl) {
                filled += pickComboboxOption(/state|province/i, cfg.state) ? 1 : 0;
              }
            }
            return filled;
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
            var seen = [];
            var fallback = null;
            for (var s = 0; s < selectors.length; s++) {
              var nodes = [];
              try { nodes = document.querySelectorAll(selectors[s]); } catch (e) { continue; }
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
                if (/payment/.test(tid) && tid.indexOf('vehicle') === -1) continue;
                if (tid.indexOf('continue') !== -1 || tid.indexOf('vehiclesubmit') !== -1
                    || (tid.indexOf('vehicle') !== -1 && tid.indexOf('confirm') !== -1)) {
                  return b;
                }
                if (key === 'saveandcontinue' || key === 'savecontinue' || key === 'continue'
                    || key === 'next' || key === 'save' || key === 'addvehicle' || key === 'confirm') {
                  return b;
                }
                // \"Continue\" with trailing icon/accessibility junk still starts with continue.
                if (key.indexOf('continue') === 0 && key.length < 32) return b;
                if ((b.type || '').toLowerCase() === 'submit') {
                  fallback = fallback || b;
                }
              }
            }
            return fallback;
          }

          function vehicleFormReady() {
            var plate = firstVisible(
              '#vrn, input[name=\"vrn\"], #licensePlate, input[name*=\"plate\" i], input[id*=\"plate\" i]'
            );
            if (!plate || !visible(plate) || !String(plate.value || '').trim()) return null;
            if (cfg.licensePlateNumber && norm(String(plate.value || '')) !== norm(cfg.licensePlateNumber)) return null;
            var country = firstVisible('select#country, select[name=\"country\"], select[name*=\"country\" i]');
            var state = firstVisible('select#state, select[name=\"state\"], select[name*=\"state\" i], select[name*=\"province\" i]');
            if (cfg.country && country && visible(country) && !selectMatchesValue(country, cfg.country)) return null;
            if (cfg.state && state && visible(state) && !selectMatchesValue(state, cfg.state)) return null;
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
            var ariaDisabled = btn.getAttribute('aria-disabled') === 'true';
            if (btn.disabled || ariaDisabled) {
              // React often keeps Continue disabled until a real input cycle; nudge then force.
              nudgeVehicleFormValidation(form.plate);
              if (!forceClickDisabled(btn)) return false;
            } else if (!click(btn, { scroll: false })) {
              return false;
            }
            window.__parkingLastSaveAt = now;
            bridge({ type: 'log', message: 'vehicle Continue tapped' });
            return true;
          }

          function preferGuestCheckout() {
            if (!cfg.preferGuestCheckout) return false;
            var guestBtn = findByText(
              'button, a, [role=\"button\"], input[type=\"button\"], input[type=\"submit\"]',
              /continueasa?guest|continueasguest|checkoutasguest|guestcheckout|without(an)?account|payasguest|bookasguest/
            );
            if (guestBtn) return click(guestBtn);
            return false;
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
            var btn = findByText(
              'button, a, [role=\"button\"], input[type=\"button\"], input[type=\"submit\"]',
              /saveandcontinue|savecontinue/
            );
            if (!btn || btn.disabled) return false;

            var email = firstVisible(emailInputSelector());
            var phone = firstVisible(phoneInputSelector());
            var plate = firstVisible('#vrn, input[name=\"vrn\"]');
            var country = firstVisible('select#country, select[name=\"country\"]');
            var state = firstVisible('select#state, select[name=\"state\"]');

            var onContact = !!((email && visible(email)) || (phone && visible(phone)));
            var onVehicle = !!(plate && visible(plate));

            if (onContact) {
              if (cfg.email && email && visible(email) && norm(String(email.value || '')) !== norm(cfg.email)) return false;
              if (email && visible(email) && !String(email.value || '').trim()) return false;
              if (phone && visible(phone) && !String(phone.value || '').trim()) return false;
            }
            if (onVehicle) {
              if (!String(plate.value || '').trim()) return false;
              if (country && visible(country) && (!String(country.value || '').trim() || country.selectedIndex <= 0)) return false;
              if (state && visible(state) && (!String(state.value || '').trim() || state.selectedIndex <= 0)) return false;
            }
            // Don't click Save on unrelated screens.
            if (!onContact && !onVehicle) return false;
            if (!click(btn, { scroll: false })) return false;
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
            return false;
          }

          function parkChirpNeedsSignIn() {
            if (!isParkChirp()) return false;
            if (parkChirpIsSignedIn()) return false;
            var t = (document.body && document.body.innerText) || '';
            if (/you need to log in or create an account/i.test(t)) return true;
            if (document.querySelector('input[type=\"password\"]')) return true;
            // Checkout shell visible but session not confirmed yet.
            if (document.querySelector('#gpi-checkout-submit')) return true;
            return false;
          }

          function parkChirpFindLoginFields() {
            var pass = null;
            var passes = document.querySelectorAll('input[type=\"password\"]');
            for (var i = 0; i < passes.length; i++) {
              if (visible(passes[i])) { pass = passes[i]; break; }
            }
            if (!pass) return null;
            var email = null;
            var root = pass.form || pass.closest('form') || pass.parentElement || document;
            var inputs = root.querySelectorAll('input[type=\"email\"], input[type=\"text\"], input:not([type])');
            for (var j = 0; j < inputs.length; j++) {
              var el = inputs[j];
              if (!visible(el)) continue;
              var key = classify(el);
              var looksEmail = key === 'email' || /email/i.test(el.name || '') || /email/i.test(el.id || '')
                || /email/i.test(el.placeholder || '') || /username/i.test(el.autocomplete || '');
              if (looksEmail) { email = el; break; }
            }
            return { email: email, password: pass, form: pass.form || null };
          }

          /// Hint iOS Password AutoFill toward saved parkchirp.com credentials (QuickType / key icon).
          /// Fields already use autocomplete=username/current-password; focus surfaces the suggestions.
          function hintParkChirpPasswordAutofill() {
            if (!isParkChirp() || parkChirpIsSignedIn()) return false;
            if (window.__parkingParkChirpAutofillHint) return false;
            var fields = parkChirpFindLoginFields();
            if (!fields || !fields.password) return false;
            try {
              if (fields.email) {
                fields.email.setAttribute('autocomplete', 'username');
                fields.email.setAttribute('autocapitalize', 'none');
                fields.email.setAttribute('autocorrect', 'off');
                fields.email.setAttribute('spellcheck', 'false');
              }
              fields.password.setAttribute('autocomplete', 'current-password');
              var target = fields.email || fields.password;
              ensureInView(target);
              try { target.focus(); } catch (e) {}
              try { target.click(); } catch (e) {}
              window.__parkingParkChirpAutofillHint = true;
              return true;
            } catch (e) {
              return false;
            }
          }

          function parkChirpLoginFieldsFilled() {
            var fields = parkChirpFindLoginFields();
            if (!fields || !fields.password || !(fields.password.value || '').length) return null;
            if (!fields.email || (fields.email.value || '').indexOf('@') === -1) return null;
            return fields;
          }

          function findParkChirpLoginSubmit(fields) {
            if (!fields) return null;
            var scope = fields.form || (fields.password && fields.password.closest('form')) || document;
            var buttons = scope.querySelectorAll('button, input[type=\"submit\"]');
            for (var i = 0; i < buttons.length; i++) {
              var b = buttons[i];
              if (!visible(b)) continue;
              var label = norm(b.innerText || b.value || '');
              // Login Submit — skip Create Account / Checkout / Apply.
              if (label === 'submit' || label === 'loginsubmit' || label === 'login' || label === 'signin') {
                if (/checkout|apply|create|register|subscribe/i.test(label)) continue;
                return b;
              }
            }
            // Fallback: submit nearest password field's form.
            if (fields.form) {
              var fallback = fields.form.querySelector('button[type=\"submit\"], input[type=\"submit\"], button');
              if (fallback && visible(fallback)) {
                var fl = norm(fallback.innerText || fallback.value || '');
                if (!/checkout|apply|create|register|subscribe/i.test(fl)) return fallback;
              }
            }
            return null;
          }

          /// After iOS/Apple Password AutoFill fills email+password, tap Login Submit once.
          function submitParkChirpLoginIfAutofilled() {
            if (!isParkChirp() || parkChirpIsSignedIn()) return false;
            if (window.__parkingParkChirpLoginAt && (Date.now() - window.__parkingParkChirpLoginAt) < 8000) {
              return false;
            }
            var fields = parkChirpLoginFieldsFilled();
            if (!fields) return false;
            var btn = findParkChirpLoginSubmit(fields);
            if (!btn) return false;
            if (click(btn)) {
              window.__parkingParkChirpLoginAt = Date.now();
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

          function cacheZonesSearchPayload(data, via) {
            var list = Array.isArray(data) ? data
              : (data && (data.zones || data.results || data.items || data.data)) || [];
            if (!Array.isArray(list) || !list.length) return;
            window.__parkingZoneApiResults = list;
            window.__parkingNearestZoneFetchedAt = Date.now();
            bridge({ type: 'log', message: 'zones ' + via + ' cached count=' + list.length });
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
                      if (/\\/api\\/zones\\/search/i.test(url) && res && res.ok && res.clone) {
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
                if (/\\/api\\/zones\\/search/i.test(url)) {
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
            for (var i = 0; i < list.length; i++) {
              var z = list[i] || {};
              // Public Zone # is signageCode (e.g. 47039); internalZoneCode is e.g. 30447039.
              var zoneID = String(z.signageCode || z.zoneCode || z.zoneNumber || z.displayZoneCode
                || z.publicZoneCode || z.zone || z.code || '');
              var internal = String(z.internalZoneCode || z.internalCode || '');
              var pt = zonePointLatLng(z);
              var dist = null;
              if (cfg.lat != null && cfg.lng != null && pt) {
                dist = haversineMeters(cfg.lat, cfg.lng, pt.lat, pt.lng);
              } else if (typeof z.distance === 'number') {
                dist = z.distance;
              } else if (typeof z.distanceInMeters === 'number') {
                dist = z.distanceInMeters;
              } else if (typeof z.distanceMiles === 'number') {
                dist = z.distanceMiles * 1609.34;
              }
              if (!zoneID && !internal) continue;
              out.push({
                zoneID: zoneID || internal,
                signageCode: zoneID,
                internalZoneCode: internal,
                label: z.locationName || z.supplierName || z.name
                  ? String(z.locationName || z.supplierName || z.name)
                  : ('Zone # ' + (zoneID || internal)),
                href: internal ? ('/zone/start?internalZoneCode=' + encodeURIComponent(internal)) : '',
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

          /// Do not call /api/zones/search ourselves — live XHR shows our fetch gets HTTP 400/422.
          /// Rely on SPA Search Zones + Get user location (cached via installZoneFetchHook / DOM).
          function requestNearestZonesFromApi() {
            if ((window.__parkingZoneApiResults || []).length) {
              window.__parkingNearestZoneFetchedAt = Date.now();
              var nearest = pickNearestZoneCandidate();
              if (nearest) window.__parkingNearestZoneCandidate = nearest;
              return true;
            }
            return false;
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
            var candidate = window.__parkingNearestZoneCandidate || pickNearestZoneCandidate();
            if (candidate && candidate.internalZoneCode && !window.__parkingNearestZoneNavigated) {
              window.__parkingNearestZoneNavigated = true;
              window.__parkingNearestZoneFilled = true;
              try {
                location.href = '/zone/start?internalZoneCode=' + encodeURIComponent(candidate.internalZoneCode);
                bridge({ type: 'log', message: 'navigate nearest internalZoneCode=' + candidate.internalZoneCode });
                return 'navigated';
              } catch (e) {}
            }
            if (candidate) {
              var input = findZoneNumberInput();
              var code = String(candidate.signageCode || candidate.zoneID || '').trim();
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

          function pickNearestZoneCandidate() {
            var api = zoneCandidatesFromApi();
            var dom = zoneCandidatesFromDom();
            var merged = api.length ? api : dom;
            if (!merged.length) return null;
            var withDist = merged.filter(function(z) { return typeof z.distanceMeters === 'number'; });
            if (withDist.length) {
              withDist.sort(function(a, b) { return a.distanceMeters - b.distanceMeters; });
              return withDist[0];
            }
            // After geo recenter, ParkMobile lists zones nearest-first.
            merged.sort(function(a, b) { return a.order - b.order; });
            return merged[0];
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

          function looksLikeHourSelect(sel) {
            var vals = selectOptionNumbers(sel).map(function(v) { return v.n; });
            if (!vals.length) return false;
            var max = Math.max.apply(null, vals);
            var min = Math.min.apply(null, vals);
            // Hours: 0..12-ish. Minutes usually include 15/20/30/40/45 or go above 12.
            if (max > 12) return false;
            if (min < 0) return false;
            return true;
          }

          function looksLikeMinuteSelect(sel) {
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
              var proto = HTMLSelectElement.prototype;
              var desc = Object.getOwnPropertyDescriptor(proto, 'value');
              if (desc && desc.set) desc.set.call(sel, value);
              else sel.value = value;
            } catch (e) {
              sel.value = value;
            }
            try { sel.selectedIndex = idx; } catch (e2) {}
            try { opt.selected = true; } catch (e3) {}
            sel.dispatchEvent(new Event('input', { bubbles: true }));
            sel.dispatchEvent(new Event('change', { bubbles: true }));
            return norm(sel.value) === norm(value) || sel.selectedIndex === idx;
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

          function selectGreatestDurationUpToMax() {
            // Allow a few retries — minute change often resets hour in React state.
            var attempts = window.__parkingZoneDurationAttempts || 0;
            if (attempts >= 4) return false;
            var maxMin = cfg.maxDurationMinutes || 100;
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

            // Classify unlabeled selects by option shape (hours 0-12 vs minutes 0/20/40…).
            if (!hourSelect || !minuteSelect) {
              for (var ci = 0; ci < selects.length; ci++) {
                var cand = selects[ci];
                if (!hourSelect && looksLikeHourSelect(cand) && !looksLikeMinuteSelect(cand)) hourSelect = cand;
                else if (!minuteSelect && looksLikeMinuteSelect(cand)) minuteSelect = cand;
              }
            }
            // Last resort DOM order only if still missing and shapes agree.
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
              if (bestIdx >= 0) {
                var combinedChanged = setSelectOptionIndex(combinedSelect, bestIdx);
                if (combinedChanged) {
                  window.__parkingZoneDurationSet = true;
                  bridge({ type: 'log', message: 'setDuration combined=' + bestMins + 'm' });
                  return true;
                }
              }
            }

            if (hourSelect && minuteSelect) {
              var maxH = Math.floor(maxMin / 60);
              var hourOpts = selectOptionNumbers(hourSelect).filter(function(v) { return v.n <= maxH; });
              hourOpts.sort(function(a, b) { return b.n - a.n; });
              var bestHIdx = -1;
              var bestMIdx = -1;
              var bestHVal = -1;
              var bestMVal = -1;
              for (var k = 0; k < hourOpts.length; k++) {
                var candH = hourOpts[k];
                var remain = maxMin - candH.n * 60;
                var localBestM = -1;
                var localBestIdx = -1;
                var minuteOpts = selectOptionNumbers(minuteSelect);
                for (var mi = 0; mi < minuteOpts.length; mi++) {
                  var mVal = minuteOpts[mi].n;
                  if (mVal <= remain && mVal > localBestM) {
                    localBestM = mVal;
                    localBestIdx = minuteOpts[mi].idx;
                  }
                }
                if (localBestIdx >= 0) {
                  bestHIdx = candH.idx;
                  bestHVal = candH.n;
                  bestMIdx = localBestIdx;
                  bestMVal = localBestM;
                  break;
                }
              }
              if (bestHIdx >= 0 && bestMIdx >= 0) {
                // Set minutes first, then hours — and re-apply hours (React often resets hour on minute change).
                setSelectOptionIndex(minuteSelect, bestMIdx);
                setSelectOptionIndex(hourSelect, bestHIdx);
                setSelectOptionIndex(hourSelect, bestHIdx);
                var gotH = readSelectedNumber(hourSelect);
                var gotM = readSelectedNumber(minuteSelect);
                window.__parkingZoneDurationAttempts = attempts + 1;
                var total = (gotH != null ? gotH : 0) * 60 + (gotM != null ? gotM : 0);
                var target = bestHVal * 60 + bestMVal;
                bridge({
                  type: 'log',
                  message: 'setDuration hour=' + gotH + ' min=' + gotM + ' target=' + target + 'm'
                });
                if (gotH === bestHVal && gotM === bestMVal) {
                  window.__parkingZoneDurationSet = true;
                  return true;
                }
                // Also try combobox UI if native select did not stick.
                if (gotH !== bestHVal) pickDurationCombobox(/hour|hr/, bestHVal);
                if (gotM !== bestMVal) pickDurationCombobox(/minute|min/, bestMVal);
                gotH = readSelectedNumber(hourSelect);
                gotM = readSelectedNumber(minuteSelect);
                if (gotH === bestHVal && gotM === bestMVal) {
                  window.__parkingZoneDurationSet = true;
                  return true;
                }
                // Partial progress (e.g. minutes only) — keep retrying next tick.
                return gotM === bestMVal || gotH === bestHVal || total >= Math.min(maxMin, 40);
              }
            }

            // Custom hour/minute comboboxes only.
            var maxH2 = Math.floor(maxMin / 60);
            var wantM = maxMin - maxH2 * 60;
            // Snap minutes to common 20-min blocks used by ParkMobile zones.
            var minuteSnaps = [0, 20, 40, 15, 30, 45, 10, 50];
            var snapM = 0;
            for (var ms = 0; ms < minuteSnaps.length; ms++) {
              if (minuteSnaps[ms] <= wantM && minuteSnaps[ms] >= snapM) snapM = minuteSnaps[ms];
            }
            var comboChanged = false;
            if (maxH2 > 0) comboChanged = pickDurationCombobox(/hour|hr/, maxH2) || comboChanged;
            comboChanged = pickDurationCombobox(/minute|min/, snapM) || comboChanged;
            if (comboChanged) {
              window.__parkingZoneDurationAttempts = attempts + 1;
              bridge({ type: 'log', message: 'setDuration combobox hour=' + maxH2 + ' min=' + snapM });
              return true;
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

          function findZoneContinueButton() {
            var buttons = document.querySelectorAll('button, [role=\"button\"], input[type=\"submit\"], a');
            var confirmBtn = null;
            var continueBtn = null;
            for (var i = 0; i < buttons.length; i++) {
              var b = buttons[i];
              if (!visible(b) || b.disabled) continue;
              var t = ((b.innerText || '') + ' ' + (b.getAttribute('aria-label') || '') + ' ' + (b.value || '')).toLowerCase().replace(/\\s+/g, ' ').trim();
              if (!t) continue;
              // Never payment / Apple / purchase CTAs here.
              if (/continue with apple|apple pay|complete purchase|buy with|log in|sign up|sign in/.test(t)) continue;
              if (/save and continue|save & continue/.test(t)) continue;
              if (t.indexOf('confirm zone') !== -1) confirmBtn = confirmBtn || b;
              else if (t === 'continue' || t === 'confirm' || t === 'next' || t === 'proceed') continueBtn = continueBtn || b;
              else if (/^continue\\b/.test(t) && t.length < 24) continueBtn = continueBtn || b;
            }
            return confirmBtn || continueBtn;
          }

          function clickZoneContinueButton() {
            var now = Date.now();
            if (window.__parkingZoneContinueAt && (now - window.__parkingZoneContinueAt) < 2200) return false;
            var btn = findZoneContinueButton();
            if (!btn) return false;
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

          /// First checkout page that asks for Zone # — prefill only; user submits Confirm Zone / Continue.
          function isZoneIdEntryPage() {
            var path = location.pathname || '';
            if (/\\/zone\\/(duration|auth|vehicle|contact|payment|confirm|review|summary)/i.test(path)) {
              return false;
            }
            if (hasZoneDurationSelectors()) return false;
            if (zoneCheckoutStepsVisible()) return false;
            if (/\\/zone\\/start/i.test(path)) return true;
            if (zoneEntryFormVisible() && findZoneContinueButton()) return true;
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
              if (dismissCookieBanner()) {
                return { status: 'advanced', filled: 0, action: 'cookie' };
              }
              if (clickSearchZonesMode()) {
                return { status: 'advanced', filled: 0, action: 'searchZonesMode' };
              }
              if (clickGetUserLocation()) {
                return { status: 'advanced', filled: 0, action: 'geo' };
              }
              if (!window.__parkingDidTapGeo) {
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
              var candidate = window.__parkingNearestZoneCandidate || pickNearestZoneCandidate();
              if (!candidate) {
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
              var contactFilled = fillContactFields();
              if (clickParkMobileContactContinue() || clickSaveAndContinue()) {
                return { status: 'advanced', filled: contactFilled, action: 'contactContinue' };
              }
              if (contactFilled > 0) {
                return { status: 'waiting', filled: contactFilled, action: 'contactPartial' };
              }
              // Stay on dedicated contact; otherwise fall through so payment/Apple Pay can run.
              if (isZoneContactPage()) {
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
              var vehicleFilled = fillParkMobileVehicleFields() + contactOnVehicle;
              if (clickParkMobileVehicleContinue() || clickSaveAndContinue()) {
                return { status: 'advanced', filled: vehicleFilled, action: 'vehicleConfirm' };
              }
              // Last resort: any Continue-like control on the vehicle page once fields look ready.
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
              return { status: 'waiting', filled: 0, action: 'awaitVehicle' };
            }

            // Loop Continue (and pause on errors) until auth+checkoutState URL.
            if (isZonePreAuthPage() || isZoneStartPage()) {
              if (dismissCookieBanner()) {
                return { status: 'advanced', filled: 0, action: 'cookie' };
              }

              // Zone-id page: prefill / deep-link nearest zone, but never auto-submit Confirm Zone.
              if (isZoneIdEntryPage()) {
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
                if ((window.__parkingZoneDurationAttempts || 0) < 4) {
                  return { status: 'waiting', filled: 0, action: 'awaitDuration' };
                }
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
              filled += fillParkMobileVehicleFields();
              if (clickSpotHeroVehicleConfirm()) action = action || 'vehicleConfirm';
              if (clickParkMobileVehicleContinue()) action = action || 'vehicleConfirm';
              // SpotHero contact Continue + ParkMobile Save & Continue.
              if (clickSpotHeroContactContinue()) action = action || 'spotHeroContinue';
              if (clickParkMobileContactContinue()) action = action || 'contactContinue';
              if (clickSaveAndContinue()) action = action || 'saveContinue';
              // ParkMobile Payment Details → Continue with Apple Pay; Confirm → I acknowledge.
              // Never taps Complete Purchase / Buy with Apple Pay.
              if (clickContinueWithApplePay()) action = action || 'applePay';
              if (checkAcknowledgeBoxes()) action = action || 'acknowledge';
              if (action) {
                return { status: 'advanced', filled: filled, action: action };
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
