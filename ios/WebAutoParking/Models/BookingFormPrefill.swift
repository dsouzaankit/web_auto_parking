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
        completion: ((Outcome) -> Void)? = nil
    ) {
        guard shouldInject(for: webView.url, trigger: trigger) else {
            AppLog.log("Prefill skipped (\(trigger.rawValue)) for \(webView.url?.absoluteString ?? "(nil)")")
            completion?(.skipped)
            return
        }
        AppLog.log("Prefill inject (\(trigger.rawValue)) \(webView.url?.absoluteString ?? "(nil)")")
        webView.evaluateJavaScript(script(config: config)) { result, error in
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

    private static func script(config: BookingConfig) -> String {
        let email = jsonString(config.normalizedEmail)
        let phone = jsonString(config.normalizedPhone)
        let address = jsonString(config.normalizedAddress)
        let makeModel = jsonString(config.vehicle.normalizedMakeAndModel)
        let plate = jsonString(config.vehicle.normalizedLicensePlate)
        let country = jsonString(config.vehicle.normalizedCountry)
        let state = jsonString(config.vehicle.normalizedState)
        let preferGuest = config.preferGuestCheckout ? "true" : "false"
        let payment = jsonString(config.prefersApplePay ? "applePay" : config.paymentMethod)
        // Today+3 days × 5:30…11:00 → 11:30 — prefill walks until SPA accepts as-is.
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
            parkChirpCandidates: \(parkChirpCandidatesJSON)
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
          function click(el) {
            if (!el || !visible(el)) return false;
            try { el.scrollIntoView({ block: 'center', inline: 'nearest' }); } catch (e) {}
            try { el.click(); } catch (e) {}
            return true;
          }
          function setNativeValue(el, value) {
            if (!el || value == null || value === '') return false;
            if (el.disabled || el.readOnly) return false;
            try { el.scrollIntoView({ block: 'center', inline: 'nearest' }); } catch (e) {}
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
            if (cfg.email) {
              var emailEl = firstVisible('#email, input[name=\"email\"], input[type=\"email\"], [data-testid=\"email-input\"]');
              if (emailEl && !String(emailEl.value || '').trim() && setNativeValue(emailEl, cfg.email)) filled += 1;
            }
            if (cfg.phone) {
              var phoneEl = firstVisible('#phone, input[name=\"phone\"], input[type=\"tel\"], [data-testid=\"phone-input\"]');
              if (phoneEl && !String(phoneEl.value || '').trim() && setNativeValue(phoneEl, cfg.phone)) filled += 1;
            }
            // ParkMobile vehicle block: always target *visible* #vrn/#country/#state
            // (page mounts hidden duplicates that break querySelector).
            if (cfg.licensePlateNumber) {
              var plateEl = firstVisible(
                '#vrn, input[name=\"vrn\"], #licensePlate, #license-plate, #plate, input[name*=\"plate\" i], input[id*=\"plate\" i], input[name*=\"license\" i], [data-testid=\"Vehicle-input-plate\"]'
              );
              if (plateEl && !String(plateEl.value || '').trim() && setNativeValue(plateEl, cfg.licensePlateNumber)) filled += 1;
            }
            if (cfg.makeAndModel) {
              var makeEl = firstVisible(
                'input[name*=\"make\" i], input[id*=\"make\" i], input[name*=\"model\" i], input[id*=\"vehicle\" i], textarea[name*=\"vehicle\" i]'
              );
              if (makeEl && !String(makeEl.value || '').trim() && setNativeValue(makeEl, cfg.makeAndModel)) filled += 1;
            }
            if (cfg.country) {
              var countryEl = firstVisible(
                'select#country, select[name=\"country\"], select[name*=\"country\" i], select[id*=\"country\" i]'
              );
              if (countryEl) {
                var needsCountry = !String(countryEl.value || '').trim() || countryEl.selectedIndex <= 0
                  || norm(countryEl.value) !== norm(cfg.country);
                if (needsCountry && setNativeValue(countryEl, cfg.country)) filled += 1;
              }
            }
            if (cfg.state) {
              var stateEl = firstVisible(
                'select#state, select[name=\"state\"], select[name*=\"state\" i], select[id*=\"state\" i], select[name*=\"province\" i], [data-testid=\"Vehicle-input-state\"]'
              );
              if (stateEl) {
                var needsState = !String(stateEl.value || '').trim() || stateEl.selectedIndex <= 0
                  || norm(stateEl.value) !== norm(cfg.state);
                if (needsState && setNativeValue(stateEl, cfg.state)) filled += 1;
              }
            }
            return filled;
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
            return click(btn);
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

            var email = firstVisible('#email, input[name=\"email\"], input[type=\"email\"]');
            var phone = firstVisible('#phone, input[name=\"phone\"], input[type=\"tel\"]');
            var plate = firstVisible('#vrn, input[name=\"vrn\"]');
            var country = firstVisible('select#country, select[name=\"country\"]');
            var state = firstVisible('select#state, select[name=\"state\"]');

            var onContact = !!((email && visible(email)) || (phone && visible(phone)));
            var onVehicle = !!(plate && visible(plate));

            if (onContact) {
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
            if (!click(btn)) return false;
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
            var email = firstVisible('#email, input[name=\"email\"], input[type=\"email\"], [data-testid=\"email-input\"]');
            var phone = firstVisible('#phone, input[name=\"phone\"], input[type=\"tel\"], [data-testid=\"phone-input\"]');
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
            if (!click(btn)) return false;
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
              try { target.scrollIntoView({ block: 'center', inline: 'nearest' }); } catch (e) {}
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

          /// Walk today→+3 days × start 5:30…11:00 → end 11:30 until SPA keeps the window as-is.
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
              var action = null;
              if (dismissCookieBanner()) action = 'cookie';
              if (clickReserveParkHere()) action = action || 'reserve';
              if (!isParkChirp() && preferGuestCheckout()) action = action || 'guest';
              var filled = fillFields();
              filled += fillSpotHeroVehicleModal();
              // SpotHero: open vehicle modal, then confirm after make/model selection.
              if (clickSpotHeroVehicleAdd()) action = action || 'vehicleAdd';
              filled += fillSpotHeroVehicleModal();
              if (clickSpotHeroVehicleConfirm()) action = action || 'vehicleConfirm';
              // SpotHero contact Continue + ParkMobile Save & Continue.
              if (clickSpotHeroContactContinue()) action = action || 'spotHeroContinue';
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
