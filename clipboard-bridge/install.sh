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
#   5. Patches /opt/aio/index.html to add the iframe clipboard permission
#      and the browser-side clipboard poller script
#   6. Reloads nginx and starts the clipboard server via supervisord

set -euo pipefail

CONTAINER="${1:-llm-sandbox}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Installing clipboard bridge into container: ${CONTAINER}"

# 1. Copy clipboard server and clip script
docker cp "${SCRIPT_DIR}/clipboard_server.py" "${CONTAINER}:/home/gem/clipboard_server.py"
docker cp "${SCRIPT_DIR}/clip"                "${CONTAINER}:/home/gem/clip"
docker exec -u root "${CONTAINER}" chown gem:gem /home/gem/clipboard_server.py /home/gem/clip
docker exec -u root "${CONTAINER}" chmod +x /home/gem/clip

# 2. Install tmux.conf
docker cp "${SCRIPT_DIR}/tmux.conf" "${CONTAINER}:/home/gem/.tmux.conf"
docker exec -u root "${CONTAINER}" chown gem:gem /home/gem/.tmux.conf

# 3. Install nginx config
docker cp "${SCRIPT_DIR}/nginx-clipboard.conf" "${CONTAINER}:/opt/gem/nginx/clipboard.conf"

# 4. Install supervisord config
docker cp "${SCRIPT_DIR}/supervisord-clipboard.conf" "${CONTAINER}:/opt/gem/supervisord/clipboard_server.conf"

# 5. Patch AIO index.html — add iframe clipboard permission
if ! docker exec "${CONTAINER}" grep -q 'clipboard-write' /opt/aio/index.html 2>/dev/null; then
    docker exec -u root "${CONTAINER}" sed -i \
        "s|iframe.className = 'panel-iframe';|iframe.className = 'panel-iframe';\n                iframe.allow = 'clipboard-write; clipboard-read';|" \
        /opt/aio/index.html
    echo "  Patched iframe allow attribute"
else
    echo "  iframe allow attribute already patched"
fi

# 5b. Patch AIO index.html — add clipboard poller script
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

# 6. Reload services
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
