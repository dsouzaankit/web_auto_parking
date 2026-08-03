import Foundation
import WebKit

/// WKWebView `navigator.geolocation` is unreliable even after permission grant.
/// Stub it with the app's Core Location fix so ParkMobile can prefill the nearest zone.
enum GeolocationBridge {
    static func userScript(latitude: Double?, longitude: Double?) -> WKUserScript {
        WKUserScript(
            source: installJS(latitude: latitude, longitude: longitude),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
    }

    static func installJS(latitude: Double?, longitude: Double?) -> String {
        let latJS = latitude.map { String($0) } ?? "null"
        let lngJS = longitude.map { String($0) } ?? "null"
        return """
        (function() {
          var lat = \(latJS);
          var lng = \(lngJS);
          if (lat == null || lng == null || !isFinite(lat) || !isFinite(lng)) return;
          if (window.__parkingNativeGeo
              && window.__parkingNativeGeo.lat === lat
              && window.__parkingNativeGeo.lng === lng
              && window.__parkingGeoStubbed) {
            return;
          }
          window.__parkingNativeGeo = { lat: lat, lng: lng, accuracy: 25 };
          function position() {
            return {
              coords: {
                latitude: lat,
                longitude: lng,
                accuracy: 25,
                altitude: null,
                altitudeAccuracy: null,
                heading: null,
                speed: null
              },
              timestamp: Date.now()
            };
          }
          function successSoon(success) {
            if (typeof success !== 'function') return;
            try { success(position()); } catch (e) {}
          }
          try {
            var geo = navigator.geolocation || {};
            geo.getCurrentPosition = function(success, error, options) {
              successSoon(success);
            };
            geo.watchPosition = function(success, error, options) {
              successSoon(success);
              return 1;
            };
            geo.clearWatch = function() {};
            navigator.geolocation = geo;
            window.__parkingGeoStubbed = true;
          } catch (e) {}
          try {
            if (navigator.permissions && navigator.permissions.query) {
              var origQuery = navigator.permissions.query.bind(navigator.permissions);
              navigator.permissions.query = function(desc) {
                try {
                  if (desc && String(desc.name || '').toLowerCase() === 'geolocation') {
                    return Promise.resolve({ state: 'granted', onchange: null });
                  }
                } catch (e) {}
                return origQuery(desc);
              };
            }
          } catch (e) {}
        })();
        """
    }
}
