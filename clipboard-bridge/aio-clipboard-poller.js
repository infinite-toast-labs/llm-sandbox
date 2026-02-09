// aio-clipboard-poller.js — Browser-side clipboard bridge poller.
//
// This script runs in the AIO Sandbox dashboard page (index.html).
// It polls the /clipboard/ HTTP endpoint every 300ms. When the endpoint
// returns non-empty text, it writes that text to the system clipboard
// using the browser's Clipboard API (navigator.clipboard.writeText).
//
// Injected as a <script> block before </body> in /opt/aio/index.html.

(function () {
  setInterval(async () => {
    try {
      const r = await fetch("/clipboard/");
      const t = await r.text();
      if (t) await navigator.clipboard.writeText(t);
    } catch (e) {}
  }, 300);
})();
