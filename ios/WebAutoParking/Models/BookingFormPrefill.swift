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
        guard isParkingHost else { return false }

        let path = url.path.lowercased()
        let query = (url.query ?? "").lowercased()
        let haystack = path + "?" + query

        return haystack.contains("reservation")
            || haystack.contains("purchase")
            || haystack.contains("checkout")
            || haystack.contains("payment")
            || haystack.contains("/book")
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
            paymentMethod: \(payment)
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

          function clickReserveParkHere() {
            if (window.__parkingDidReserve) return false;
            var btn = findByText(
              'button, a, [role=\"button\"], input[type=\"button\"], input[type=\"submit\"]',
              /reserve.*parkhere|parkhere|reserveyourspot|reservethisspot/
            );
            if (!btn) return false;
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
            var scopes = [];
            var payCard = document.querySelector(
              '[data-pmtest-id=\"guest-payment-step-card\"], [data-pmtest-id=\"user-payment-step-card\"]'
            );
            if (payCard) scopes.push(payCard);
            scopes.push(document);
            for (var s = 0; s < scopes.length; s++) {
              var root = scopes[s];
              var nodes = root.querySelectorAll('button, a, [role=\"button\"]');
              for (var i = 0; i < nodes.length; i++) {
                var el = nodes[i];
                if (!visible(el) || el.disabled) continue;
                if (isNativeApplePayBuyButton(el)) continue;
                // Never tap final purchase.
                if (el.getAttribute('data-pmtest-id') === 'complete-purchase-button') continue;
                var t = textOf(el);
                var html = norm(el.innerHTML || '');
                // ParkMobile: outline button \"Continue with\" + Apple Pay mark.
                if (/continuewithapplepay/.test(t)) return el;
                if (/continuewith/.test(t) && (/applepay/.test(t) || /applepay/.test(html))) return el;
                if (root !== document && /^continuewith$/.test(t)) return el;
              }
            }
            // Global fallback (still skip buy / complete).
            var global = findByText(
              'button, a, [role=\"button\"]',
              /continuewithapplepay|continuewithapple/
            );
            if (global && !isNativeApplePayBuyButton(global)
                && global.getAttribute('data-pmtest-id') !== 'complete-purchase-button') {
              return global;
            }
            // \"Continue with\" alone only inside payment step card.
            if (payCard) {
              var only = Array.prototype.find.call(
                payCard.querySelectorAll('button, a, [role=\"button\"]'),
                function(el) {
                  return visible(el) && !el.disabled && /continuewith/.test(textOf(el))
                    && !isNativeApplePayBuyButton(el);
                }
              );
              if (only) return only;
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
            // ParkMobile only — SpotHero payment left alone.
            var onPM = /parkmobile\\.io/i.test(location.hostname || '');
            if (!onPM) return false;
            if (wantsApplePay() && findContinueWithApplePayButton()) return true;
            if (acknowledgeNeedsCheck()) return true;
            return false;
          }

          function fillOnce() {
            try {
              if (hasBlockingCaptcha()) return { status: 'captcha', filled: 0, action: 'captcha' };
              var action = null;
              if (dismissCookieBanner()) action = 'cookie';
              if (clickReserveParkHere()) action = action || 'reserve';
              if (preferGuestCheckout()) action = action || 'guest';
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
