import Foundation
import WebKit

enum BookingFormPrefill {
    /// Applies `BookingConfig.json`: contact, vehicle, guest checkout, Apple Pay.
    static func inject(into webView: WKWebView, config: BookingConfig = .load()) {
        webView.evaluateJavaScript(script(config: config), completionHandler: nil)
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

        return """
        (function() {
          if (window.__parkingPrefillInstalled) {
            window.__parkingPrefillRun && window.__parkingPrefillRun();
            return;
          }
          window.__parkingPrefillInstalled = true;

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
            var style = window.getComputedStyle(el);
            if (style.display === 'none' || style.visibility === 'hidden' || style.opacity === '0') return false;
            var r = el.getBoundingClientRect();
            return r.width > 0 && r.height > 0;
          }
          function click(el) {
            if (!el || !visible(el)) return false;
            try { el.scrollIntoView({ block: 'center', inline: 'nearest' }); } catch (e) {}
            el.click();
            return true;
          }
          function setNativeValue(el, value) {
            if (!el || value == null || value === '') return false;
            if (el.disabled || el.readOnly) return false;
            var tag = (el.tagName || '').toUpperCase();
            if (tag === 'SELECT') {
              return setSelectValue(el, value);
            }
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
            var aria = el.getAttribute('aria-label') || '';
            var ph = el.placeholder || '';
            var name = el.name || '';
            var id = el.id || '';
            var ac = el.autocomplete || '';
            var alt = el.getAttribute('alt') || '';
            return norm(t + ' ' + aria + ' ' + ph + ' ' + name + ' ' + id + ' ' + ac + ' ' + alt);
          }
          function classify(el) {
            var key = labelText(el);
            if (!key) return null;
            if (/(email|e-mail|mailaddress)/.test(key)) return 'email';
            if (/(phone|mobile|tel|cellphone)/.test(key)) return 'phone';
            if (/(licenseplate|licenceplate|platenumber|platereg|vehicleplate|^plate$|lpnumber)/.test(key)) return 'plate';
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
            return norm((el.innerText || el.textContent || '') + ' ' + (el.getAttribute('aria-label') || '') + ' ' + (el.value || '') + ' ' + (el.getAttribute('alt') || ''));
          }
          function findByText(selectors, re) {
            var nodes = document.querySelectorAll(selectors);
            for (var i = 0; i < nodes.length; i++) {
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

          function preferGuestCheckout() {
            if (!cfg.preferGuestCheckout) return;
            var guestBtn = findByText(
              'button, a, [role=\"button\"], input[type=\"button\"], input[type=\"submit\"]',
              /^(continueasguest|checkoutasguest|guestcheckout|continuewithout(an)?account|payasguest|bookasguest)$|continueasguest|checkoutasguest|guestcheckout|without(an)?account|payasguest/
            );
            if (guestBtn) click(guestBtn);
          }

          function selectApplePay() {
            if (norm(cfg.paymentMethod) !== 'applepay') return;

            var appleBtn = document.querySelector(
              'apple-pay-button, button.apple-pay-button, .apple-pay-button, [aria-label*=\"Apple Pay\" i], [aria-label*=\"ApplePay\" i]'
            );
            if (appleBtn && visible(appleBtn)) {
              click(appleBtn);
              return;
            }

            var radios = document.querySelectorAll('input[type=\"radio\"]');
            for (var i = 0; i < radios.length; i++) {
              var r = radios[i];
              var key = norm((r.value || '') + ' ' + labelText(r) + ' ' + (r.id || '') + ' ' + (r.name || ''));
              if (/applepay|apple_pay/.test(key)) {
                if (!r.checked) {
                  r.checked = true;
                  r.dispatchEvent(new Event('input', { bubbles: true }));
                  r.dispatchEvent(new Event('change', { bubbles: true }));
                  click(r);
                  if (r.labels && r.labels[0]) click(r.labels[0]);
                }
                return;
              }
            }

            var payLabel = findByText('label, button, a, [role=\"button\"], [role=\"radio\"], div, span', /^applepay$|applepay/);
            if (payLabel) {
              var target = payLabel.closest('label, button, [role=\"button\"], [role=\"radio\"]') || payLabel;
              click(target);
              return;
            }

            var icons = document.querySelectorAll('img[alt*=\"Apple Pay\" i], img[src*=\"apple-pay\" i], img[src*=\"apple_pay\" i]');
            for (var j = 0; j < icons.length; j++) {
              var icon = icons[j];
              var clickable = icon.closest('button, a, label, [role=\"button\"], [role=\"radio\"]');
              if (clickable && visible(clickable)) {
                click(clickable);
                return;
              }
            }
          }

          function fillFields() {
            var nodes = document.querySelectorAll('input, textarea, select');
            for (var i = 0; i < nodes.length; i++) {
              var el = nodes[i];
              var type = (el.type || '').toLowerCase();
              if (type === 'hidden' || type === 'password' || type === 'checkbox' || type === 'radio'
                  || type === 'submit' || type === 'button' || type === 'file') continue;
              if (el.tagName !== 'SELECT' && el.value && String(el.value).trim() !== '') continue;
              if (el.tagName === 'SELECT' && el.value && String(el.value).trim() !== '' && el.selectedIndex > 0) continue;
              var kind = classify(el);
              if (!kind) continue;
              applyKind(el, kind);
            }
            if (cfg.email) {
              var emailEl = document.querySelector('#email, input[name=\"email\"], input[type=\"email\"]');
              if (emailEl && !emailEl.value) setNativeValue(emailEl, cfg.email);
            }
            if (cfg.phone) {
              var phoneEl = document.querySelector('#phone, input[name=\"phone\"], input[type=\"tel\"]');
              if (phoneEl && !phoneEl.value) setNativeValue(phoneEl, cfg.phone);
            }
            if (cfg.licensePlateNumber) {
              var plateEl = document.querySelector(
                '#licensePlate, #license-plate, #plate, input[name*=\"plate\" i], input[id*=\"plate\" i], input[name*=\"license\" i]'
              );
              if (plateEl && !plateEl.value) setNativeValue(plateEl, cfg.licensePlateNumber);
            }
            if (cfg.makeAndModel) {
              var makeEl = document.querySelector(
                'input[name*=\"make\" i], input[id*=\"make\" i], input[name*=\"model\" i], input[id*=\"vehicle\" i], textarea[name*=\"vehicle\" i]'
              );
              if (makeEl && !makeEl.value) setNativeValue(makeEl, cfg.makeAndModel);
            }
            if (cfg.country) {
              var countryEl = document.querySelector(
                'select[name*=\"country\" i], select[id*=\"country\" i], input[name*=\"country\" i], input[id*=\"country\" i]'
              );
              if (countryEl) setNativeValue(countryEl, cfg.country);
            }
            if (cfg.state) {
              var stateEl = document.querySelector(
                'select[name*=\"state\" i], select[id*=\"state\" i], select[name*=\"province\" i], input[name*=\"state\" i], input[id*=\"state\" i]'
              );
              if (stateEl) setNativeValue(stateEl, cfg.state);
            }
          }

          function fillOnce() {
            preferGuestCheckout();
            fillFields();
            selectApplePay();
          }

          window.__parkingPrefillRun = fillOnce;
          fillOnce();
          var obs = new MutationObserver(function() { fillOnce(); });
          if (document.documentElement) {
            obs.observe(document.documentElement, { childList: true, subtree: true });
          }
          setTimeout(fillOnce, 400);
          setTimeout(fillOnce, 1200);
          setTimeout(fillOnce, 2500);
        })();
        """
    }

    private static func jsonString(_ value: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: value, options: [])
        return String(data: data ?? Data("\"\"".utf8), encoding: .utf8) ?? "\"\""
    }
}
