#!/usr/bin/env bash
# install.sh — Install the clipboard bridge into a running llm-sandbox container.
#
# Usage (from repo root):
#   ./clipboard-bridge/install.sh [CONTAINER_NAME]
#
# Default container name: llm-sandbox
#
# This script:
#   1. Copies clipboard_server.py and clip to /home/gem/
#   2. Installs tmux.conf to /home/gem/.tmux.conf
#   3. Installs nginx config to /opt/gem/nginx/clipboard.conf
#   4. Installs supervisord config to /opt/gem/supervisord/clipboard_server.conf
#   5. Patches code_server.conf with sub_filter to inject the clipboard poller
#      into code-server's HTML (for direct /code-server/ access)
#   6. Patches /opt/aio/index.html to add the iframe clipboard permission
#      and the browser-side clipboard poller script
#   7. Reloads nginx and starts the clipboard server via supervisord

set -euo pipefail

CONTAINER="${1:-llm-sandbox}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Installing clipboard bridge into container: ${CONTAINER}"

# 1. Copy clipboard server, clip script, and poller JS
docker cp "${SCRIPT_DIR}/clipboard_server.py"      "${CONTAINER}:/home/gem/clipboard_server.py"
docker cp "${SCRIPT_DIR}/clip"                      "${CONTAINER}:/home/gem/clip"
docker cp "${SCRIPT_DIR}/aio-clipboard-poller.js"   "${CONTAINER}:/home/gem/clipboard-poller.js"
docker exec -u root "${CONTAINER}" chown gem:gem /home/gem/clipboard_server.py /home/gem/clip /home/gem/clipboard-poller.js
docker exec -u root "${CONTAINER}" chmod +x /home/gem/clip

# 2. Install tmux.conf
docker cp "${SCRIPT_DIR}/tmux.conf" "${CONTAINER}:/home/gem/.tmux.conf"
docker exec -u root "${CONTAINER}" chown gem:gem /home/gem/.tmux.conf

# 3. Install nginx config
docker cp "${SCRIPT_DIR}/nginx-clipboard.conf" "${CONTAINER}:/opt/gem/nginx/clipboard.conf"

# 4. Install supervisord config
docker cp "${SCRIPT_DIR}/supervisord-clipboard.conf" "${CONTAINER}:/opt/gem/supervisord/clipboard_server.conf"

# 5. Patch code_server.conf — inject clipboard poller via sub_filter
#    Uses an external script (not inline) to comply with code-server's CSP.
#    The JS file is served by nginx at /clipboard-poller.js (see nginx-clipboard.conf).
if ! docker exec "${CONTAINER}" grep -q 'sub_filter.*clipboard' /opt/gem/nginx/code_server.conf 2>/dev/null; then
    docker exec -u root "${CONTAINER}" sed -i '/location \/code-server\// {
        n
        a\
\    # Clipboard bridge: inject poller into code-server HTML\
\    sub_filter </body> '"'"'<script src="/clipboard-poller.js"></script></body>'"'"';\
\    sub_filter_once on;\
\    proxy_set_header Accept-Encoding "";
    }' /opt/gem/nginx/code_server.conf
    echo "  Patched code_server.conf with clipboard sub_filter"
else
    echo "  code_server.conf clipboard sub_filter already patched"
fi

# 6a. Patch AIO index.html — add iframe clipboard permission
if ! docker exec "${CONTAINER}" grep -q 'clipboard-write' /opt/aio/index.html 2>/dev/null; then
    docker exec -u root "${CONTAINER}" sed -i \
        "s|iframe.className = 'panel-iframe';|iframe.className = 'panel-iframe';\n                iframe.allow = 'clipboard-write; clipboard-read';|" \
        /opt/aio/index.html
    echo "  Patched iframe allow attribute"
else
    echo "  iframe allow attribute already patched"
fi

# 6b. Patch AIO index.html — add clipboard poller script
if ! docker exec "${CONTAINER}" grep -q 'Clipboard bridge' /opt/aio/index.html 2>/dev/null; then
    docker exec -u root "${CONTAINER}" sed -i '/<\/body>/i\
\    <!-- Clipboard bridge: polls HTTP endpoint for tmux clipboard data -->\
\    <script>\
\    (function(){\
\      setInterval(async()=>{\
\        try{\
\          const r=await fetch("/clipboard/");\
\          const t=await r.text();\
\          if(t) await navigator.clipboard.writeText(t);\
\        }catch(e){}\
\      },300);\
\    })();\
\    </script>' /opt/aio/index.html
    echo "  Patched clipboard poller script"
else
    echo "  Clipboard poller script already patched"
fi

# 7. Reload services
docker exec -u root "${CONTAINER}" nginx -s reload 2>/dev/null || true
docker exec -u root "${CONTAINER}" supervisorctl reread  2>/dev/null || true
docker exec -u root "${CONTAINER}" supervisorctl update  2>/dev/null || true

# Verify
sleep 1
STATUS=$(docker exec -u root "${CONTAINER}" supervisorctl status clipboard-server 2>/dev/null | awk '{print $2}')
if [ "$STATUS" = "RUNNING" ]; then
    echo ""
    echo "Clipboard bridge installed and running."
    echo "  - Reload localhost:8080 in your browser"
    echo "  - In tmux, copy text with y or Enter in copy mode"
    echo "  - Text will appear in your system clipboard"
else
    echo ""
    echo "WARNING: clipboard-server status: ${STATUS}"
    echo "Check: docker exec -u root ${CONTAINER} supervisorctl status clipboard-server"
fi
