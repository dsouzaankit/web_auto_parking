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
            var options = el.options || [];
            var match = null;
            for (var i = 0; i < options.length; i++) {
              var opt = options[i];
              var key = norm((opt.value || '') + ' ' + (opt.text || '') + ' ' + (opt.label || ''));
              if (!key) continue;
              if (key === want || key.indexOf(want) !== -1 || want.indexOf(key) !== -1) {
                match = opt;
                if (key === want || norm(opt.value) === want || norm(opt.text) === want) break;
              }
            }
            if (!match) return false;
            el.value = match.value;
            el.dispatchEvent(new Event('input', { bubbles: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
            return true;
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
            var key = labelText(el);
            if (!key) return null;
            if (/(email|e-mail|mailaddress)/.test(key)) return 'email';
            if (/(phone|mobile|tel|cellphone)/.test(key)) return 'phone';
            // ParkMobile uses #vrn / name=vrn for license plate.
            if (/(^vrn$|licenseplate|licenceplate|platenumber|platereg|vehicleplate|^plate$|lpnumber)/.test(key)) return 'plate';
            if (/(makeandmodel|vehiclemake|carmake|vehiclemodel|carmodel|make|model|vehiclename|vehicledescription)/.test(key)
                && !/(payment|card)/.test(key)) return 'makeModel';
            if (/(vehiclecountry|platercountry|registrationcountry|countryregion|^country$)/.test(key)
                && !/(phonecountry)/.test(key)) return 'country';
            if (/(vehiclestate|platestate|registrationstate|stateprovince|province|^state$)/.test(key)
                && !/(unitedstates|statement)/.test(key)) return 'state';
            if (/(address1|addressline1|streetaddress|street|mailingaddress|billingaddress|homeaddress|^address$|residential)/.test(key)
                && !/(email|phone|ip)/.test(key)) return 'address';
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
              var emailEl = document.querySelector('#email, input[name=\"email\"], input[type=\"email\"]');
              if (emailEl && visible(emailEl) && !emailEl.value && setNativeValue(emailEl, cfg.email)) filled += 1;
            }
            if (cfg.phone) {
              var phoneEl = document.querySelector('#phone, input[name=\"phone\"], input[type=\"tel\"]');
              if (phoneEl && visible(phoneEl) && !phoneEl.value && setNativeValue(phoneEl, cfg.phone)) filled += 1;
            }
            if (cfg.licensePlateNumber) {
              // ParkMobile vehicle plate field is #vrn (Vehicle Registration Number).
              var plateEl = document.querySelector(
                '#vrn, input[name=\"vrn\"], #licensePlate, #license-plate, #plate, input[name*=\"plate\" i], input[id*=\"plate\" i], input[name*=\"license\" i]'
              );
              if (plateEl && visible(plateEl) && !plateEl.value && setNativeValue(plateEl, cfg.licensePlateNumber)) filled += 1;
            }
            if (cfg.makeAndModel) {
              var makeEl = document.querySelector(
                'input[name*=\"make\" i], input[id*=\"make\" i], input[name*=\"model\" i], input[id*=\"vehicle\" i], textarea[name*=\"vehicle\" i]'
              );
              if (makeEl && visible(makeEl) && !makeEl.value && setNativeValue(makeEl, cfg.makeAndModel)) filled += 1;
            }
            if (cfg.country) {
              var countryEl = document.querySelector(
                'select#country, select[name=\"country\"], select[name*=\"country\" i], select[id*=\"country\" i], input[name*=\"country\" i], input[id*=\"country\" i]'
              );
              if (countryEl && visible(countryEl) && setNativeValue(countryEl, cfg.country)) filled += 1;
            }
            if (cfg.state) {
              var stateEl = document.querySelector(
                'select#state, select[name=\"state\"], select[name*=\"state\" i], select[id*=\"state\" i], select[name*=\"province\" i], input[name*=\"state\" i], input[id*=\"state\" i]'
              );
              if (stateEl && visible(stateEl) && setNativeValue(stateEl, cfg.state)) filled += 1;
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

          function spotHeroMakeModelInput() {
            var root = document.querySelector(
              '[data-testid=\"AddVehicle-autosuggest-vehicle\"], [data-testid=\"Vehicle-autosuggest-vehicle\"]'
            );
            if (root) {
              var input = root.querySelector('input');
              if (input && visible(input)) return input;
            }
            // Label-based fallback for Make and Model.
            var labeled = Array.prototype.find.call(
              document.querySelectorAll('input'),
              function(el) {
                if (!visible(el)) return false;
                return /makeandmodel|makemodel/.test(labelText(el));
              }
            );
            return labeled || null;
          }

          function selectSpotHeroMakeModelOption(want) {
            var wantKey = norm(want);
            var options = document.querySelectorAll(
              '[role=\"option\"], [class*=\"option\" i], [class*=\"menu\" i] [id*=\"option\"], li, div[class*=\"suggest\" i]'
            );
            var best = null;
            for (var i = 0; i < Math.min(options.length, 80); i++) {
              var el = options[i];
              if (!visible(el)) continue;
              var t = norm(el.innerText || el.textContent || '');
              if (!t || t.length > 80) continue;
              if (t === wantKey || t.indexOf(wantKey) !== -1 || wantKey.indexOf(t) !== -1) {
                best = el;
                break;
              }
              // Prefer exact-ish brand+model matches over \"Vehicle Not Listed\".
              if (!best && /chevrolet|impala|honda|toyota|ford|bmw/.test(t) && wantKey && t.indexOf(wantKey.slice(0, 4)) !== -1) {
                best = el;
              }
            }
            if (!best) {
              // Last resort: first visible autosuggest option that isn't a prompt.
              for (var j = 0; j < Math.min(options.length, 40); j++) {
                var opt = options[j];
                if (!visible(opt)) continue;
                var ot = norm(opt.innerText || opt.textContent || '');
                if (!ot || /typenosearch|noselection|select/.test(ot)) continue;
                if (/vehiclenotlisted/.test(ot) && wantKey) continue;
                best = opt;
                break;
              }
            }
            if (!best) return false;
            return click(best);
          }

          function fillSpotHeroVehicleModal() {
            if (!cfg.makeAndModel && !cfg.licensePlateNumber && !cfg.state) return 0;
            var filled = 0;
            var makeInput = spotHeroMakeModelInput();
            if (makeInput && cfg.makeAndModel) {
              var current = String(makeInput.value || '').trim();
              var selectedShown = document.querySelector(
                '[data-testid=\"AddVehicle-autosuggest-vehicle\"] [class*=\"single-value\" i], [data-testid=\"Vehicle-autosuggest-vehicle\"] [class*=\"single-value\" i]'
              );
              var already = selectedShown && norm(selectedShown.textContent).indexOf(norm(cfg.makeAndModel)) !== -1;
              if (!already) {
                try { makeInput.focus(); } catch (e) {}
                if (setNativeValue(makeInput, cfg.makeAndModel)) filled += 1;
                try {
                  makeInput.dispatchEvent(new KeyboardEvent('keydown', { bubbles: true, key: 'ArrowDown' }));
                } catch (e) {}
                if (selectSpotHeroMakeModelOption(cfg.makeAndModel)) filled += 1;
              }
            }

            var plate = document.querySelector(
              '[data-testid=\"Vehicle-input-plate\"], input[name*=\"plate\" i], input[id*=\"plate\" i]'
            );
            if (plate && visible(plate) && cfg.licensePlateNumber && !String(plate.value || '').trim()) {
              if (setNativeValue(plate, cfg.licensePlateNumber)) filled += 1;
            }

            var state = document.querySelector(
              '[data-testid=\"Vehicle-input-state\"], select[name*=\"state\" i], select[id*=\"state\" i]'
            );
            if (state && visible(state) && cfg.state) {
              if (setNativeValue(state, cfg.state)) filled += 1;
            }
            return filled;
          }

          function clickSpotHeroVehicleConfirm() {
            var now = Date.now();
            if (window.__parkingSpotHeroConfirmAt && (now - window.__parkingSpotHeroConfirmAt) < 2500) return false;
            var btn = document.querySelector('[data-testid=\"VehicleInfo-modal-button-confirm\"]');
            if (!btn || !visible(btn)) {
              // Only accept a Confirm that sits in a vehicle modal (has make/model or plate fields).
              var dialogs = document.querySelectorAll('[role=\"dialog\"], .chakra-modal__content');
              btn = null;
              for (var i = 0; i < dialogs.length; i++) {
                var dlg = dialogs[i];
                if (!visible(dlg)) continue;
                if (/payment/i.test(dlg.innerText || '')) continue;
                if (!/(makeandmodel|licenseplate|vehiclenotlisted)/.test(norm(dlg.innerText || ''))) continue;
                var cand = Array.prototype.find.call(dlg.querySelectorAll('button,[role=\"button\"]'), function(el) {
                  return visible(el) && /^confirm$/i.test((el.innerText || '').trim());
                });
                if (cand) { btn = cand; break; }
              }
            }
            if (!btn || !visible(btn) || btn.disabled) return false;

            // Only confirm if make/model looks selected or plate filled.
            var makeInput = spotHeroMakeModelInput();
            var selectedShown = document.querySelector(
              '[data-testid=\"AddVehicle-autosuggest-vehicle\"] [class*=\"single-value\" i], [data-testid=\"Vehicle-autosuggest-vehicle\"] [class*=\"single-value\" i]'
            );
            var plate = document.querySelector('[data-testid=\"Vehicle-input-plate\"]');
            var hasMake = !!(selectedShown && String(selectedShown.textContent || '').trim())
              || !!(makeInput && String(makeInput.value || '').trim());
            var hasPlate = !!(plate && visible(plate) && String(plate.value || '').trim());
            if (!hasMake && !hasPlate) return false;

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

            var email = document.querySelector('#email, input[name=\"email\"], input[type=\"email\"]');
            var phone = document.querySelector('#phone, input[name=\"phone\"], input[type=\"tel\"]');
            var plate = document.querySelector('#vrn, input[name=\"vrn\"]');
            var country = document.querySelector('select#country, select[name=\"country\"]');
            var state = document.querySelector('select#state, select[name=\"state\"]');

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
            var plate = document.querySelector('#vrn, input[name=\"vrn\"], [data-testid=\"Vehicle-input-plate\"]');
            return !!(plate && visible(plate));
          }

          function contactSectionNeedsInput() {
            var email = document.querySelector('#email, input[name=\"email\"], input[type=\"email\"], [data-testid=\"email-input\"]');
            var phone = document.querySelector('#phone, input[name=\"phone\"], input[type=\"tel\"], [data-testid=\"phone-input\"]');
            return !!((email && visible(email)) || (phone && visible(phone)));
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
              if (action) {
                return { status: 'advanced', filled: filled, action: action };
              }
              if (filled > 0) {
                // Keep going if more checkout steps still need input.
                if (contactSectionNeedsInput() || vehicleSectionNeedsInput()) {
                  return { status: 'waiting', filled: filled, action: 'partial' };
                }
                return { status: 'filled', filled: filled, action: 'done' };
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
