// Authorization codes go only to the authenticated Drive gateway. No Google
// credentials, access tokens or refresh tokens are persisted in the browser.
(() => {
  let loading;
  let pending = false;
  window.familyDocumentsDrive = Object.freeze({
    prepare() {
      if (window.google?.accounts?.oauth2) return Promise.resolve();
      if (loading) return loading;
      loading = new Promise((resolve, reject) => {
        const script = document.createElement('script');
        const timer = setTimeout(() => reject(new Error('Google unavailable')), 15000);
        script.src = 'https://accounts.google.com/gsi/client';
        script.async = true;
        script.onload = () => { clearTimeout(timer); resolve(); };
        script.onerror = () => { clearTimeout(timer); reject(new Error('Google unavailable')); };
        document.head.appendChild(script);
      }).catch(error => { loading = undefined; throw error; });
      return loading;
    },
    authorize(clientId) {
      return new Promise((resolve, reject) => {
        if (pending || !window.google?.accounts?.oauth2 || !clientId) {
          reject(new Error('Authorization unavailable')); return;
        }
        pending = true;
        let settled = false;
        const finish = (error, code) => {
          if (settled) return;
          settled = true;
          pending = false; clearTimeout(timer);
          if (error) reject(new Error('Authorization not completed')); else resolve(code);
        };
        const timer = setTimeout(() => finish(true), 120000);
        const client = google.accounts.oauth2.initCodeClient({
          client_id: clientId,
          scope: 'https://www.googleapis.com/auth/drive.file',
          ux_mode: 'popup',
          callback: response => finish(Boolean(response.error || !response.code), response.code),
          error_callback: () => finish(true),
        });
        // Called synchronously from the click handler, preserving popup permission.
        client.requestCode();
      });
    },
  });
})();
