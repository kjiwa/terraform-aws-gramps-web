// Shell configuration for the status page. The page shares an origin with the
// Gramps Web SPA, so the tokens and theme settings the SPA keeps in
// localStorage are readable here.
(function () {
  function read(key, fallback) {
    try {
      return JSON.parse(localStorage.getItem(key) || fallback);
    } catch (e) {
      return JSON.parse(fallback);
    }
  }

  function treeIdFromToken() {
    try {
      var token = localStorage.getItem('access_token');
      if (!token) return null;
      var segment = token.split('.')[1];
      if (!segment) return null;
      var payload = JSON.parse(atob(segment.replace(/-/g, '+').replace(/_/g, '/')));
      return payload.tree || null;
    } catch (e) {
      return null;
    }
  }

  // Gramps Web's getSettings(): tree-independent settings overlaid with the
  // current tree's.
  function mergedSettings() {
    try {
      var perTree = read('grampsjs_settings_tree', '{}');
      var treeId = treeIdFromToken();
      return Object.assign({}, read('grampsjs_settings', '{}'), (treeId && perTree[treeId]) || {});
    } catch (e) {
      return {};
    }
  }

  function treeConfig() {
    try {
      return read('grampsjs_tree_config', '{}')[treeIdFromToken() || 'unknown'] || {};
    } catch (e) {
      return {};
    }
  }

  // The token endpoint is rate limited to one request per second, so
  // concurrent callers share one in-flight refresh.
  var refreshInFlight = null;

  function refreshToken() {
    if (refreshInFlight) return refreshInFlight;
    refreshInFlight = (async function () {
      var rt = localStorage.getItem('refresh_token');
      if (!rt) return null;
      var r = await fetch('/api/token/refresh/', {
        method: 'POST',
        headers: { Authorization: 'Bearer ' + rt, Accept: 'application/json' },
      });
      if (!r.ok) return null;
      var d = await r.json();
      if (!d.access_token) return null;
      localStorage.setItem('access_token', d.access_token);
      return d.access_token;
    })();
    refreshInFlight
      .finally(function () {
        refreshInFlight = null;
      })
      .catch(function () {});
    return refreshInFlight;
  }

  window.STATUS_CONFIG = {
    pathPrefix: '/_status',
    authHeader: 'X-Gramps-Token',
    getToken: function () {
      return localStorage.getItem('access_token');
    },
    refreshToken: refreshToken,
    signInUrl: '/',
    disabledPanels: ${jsonencode(disabled)},
    theme: function () {
      var mode = mergedSettings().theme;
      return {
        scheme: mode === 'light' || mode === 'dark' ? mode : null,
        primary: treeConfig()['frontend.primaryColor'] || null,
      };
    },
  };
})();
