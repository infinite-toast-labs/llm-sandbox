# Clipboard Bridge: tmux → System Clipboard

## The Problem

When you run tmux inside the Docker container's code-server (VS Code in a
browser at `localhost:8080`), tmux's built-in copy commands only write to
tmux's internal paste buffer. The copied text never reaches your Mac/host
system clipboard — so you can't Cmd+V it into other apps.

### Why It Doesn't "Just Work"

There are **three independent problems** that all conspire to break the
clipboard chain:

#### 1. OSC 52 — The Standard Solution That Doesn't Work Here

OSC 52 is a terminal escape sequence (`ESC]52;c;<base64>BEL`) that tells a
terminal emulator to write text to the system clipboard. It's the standard
way tmux communicates clipboard data to the outer terminal. In a normal
setup (e.g., iTerm2 + tmux over SSH), this works great.

**Why it fails in our stack:**

The code-server terminal uses xterm.js, which _does_ support OSC 52 via the
`@xterm/addon-clipboard` addon. However, VS Code wraps the addon's clipboard
provider with its own internal clipboard service. In the code-server (web)
context, this service silently fails to call `navigator.clipboard.writeText()`.
We confirmed this by:

- Intercepting `navigator.clipboard.writeText()` — it was never called
- Verifying that calling `navigator.clipboard.writeText()` directly from
  JavaScript in the same page works perfectly
- Confirming clipboard-write permission is "granted" and the page is a
  secure context (localhost)

The OSC 52 bytes reach xterm.js, are consumed by the parser (not displayed
as text), but the final clipboard write never happens.

#### 2. Missing terminfo `Ms` Capability

Even if OSC 52 _did_ work in code-server, tmux checks the outer terminal's
terminfo for the `Ms` capability before sending OSC 52 sequences. The
`xterm-256color` terminfo in the container doesn't include `Ms`, so tmux
silently skips sending OSC 52 even with `set-clipboard on`.

**Fix (in `.tmux.conf`):**
```
set -as terminal-overrides ",xterm*:Ms=\E]52;%p1%s;%p2%s\007"
```

This tells tmux to add the `Ms` capability for terminals matching `xterm*`.

#### 3. iframe Clipboard Permission

The AIO Sandbox dashboard (`localhost:8080`) embeds code-server in an
`<iframe>`. By default, iframes do NOT inherit the parent page's clipboard
permissions. Without `allow="clipboard-write"` on the iframe element, any
`navigator.clipboard.writeText()` call inside the iframe silently fails.

**Fix (in `/opt/aio/index.html`):**
```javascript
iframe.allow = 'clipboard-write; clipboard-read';
```

---

## The Solution: HTTP Clipboard Bridge

Since the native OSC 52 pipeline through code-server's xterm.js is broken,
we bypass it entirely with a lightweight HTTP-based clipboard relay.

### Architecture

```
┌──────────────────────────────────────────────────────┐
│  Docker Container (llm-sandbox)                      │
│                                                      │
│  ┌──────────┐   stdin    ┌──────────┐   HTTP POST    │
│  │  tmux    │──────────▶│  ~/clip  │──────────────▶ │
│  │ (copy y) │  (pipe)    │ (bash)   │  curl :9123    │
│  └──────────┘            └──────────┘                │
│                                          │           │
│                                          ▼           │
│                                ┌──────────────────┐  │
│                                │ clipboard_server  │  │
│                                │ (Python :9123)    │  │
│                                │ stores text       │  │
│                                └──────────────────┘  │
│                                          │           │
│                   nginx proxy            │           │
│                   /clipboard/ ──────────▶│           │
│                                                      │
└──────────────────────────────────────────────────────┘
                               │
                     HTTP GET /clipboard/
                               │
                               ▼
┌──────────────────────────────────────────────────────┐
│  Browser (localhost:8080)                             │
│                                                      │
│  ┌──────────────────────────────────────────┐        │
│  │  AIO index.html                          │        │
│  │                                          │        │
│  │  setInterval(async () => {               │        │
│  │    const r = await fetch("/clipboard/"); │        │
│  │    const t = await r.text();             │        │
│  │    if (t) navigator.clipboard.writeText  │        │
│  │  }, 300);                                │        │
│  └──────────────────────────────────────────┘        │
│                    │                                  │
│                    ▼                                  │
│           System Clipboard                            │
│           (Cmd+V works!)                              │
└──────────────────────────────────────────────────────┘
```

### Data Flow (Step by Step)

1. **User copies in tmux** — Enters copy mode (`Ctrl+B [`), selects text
   with vi keys, presses `y` or `Enter`.

2. **tmux pipes to `~/clip`** — The `.tmux.conf` binding
   `copy-pipe-and-cancel "~/clip"` pipes the selected text to the `~/clip`
   script's stdin AND stores it in the tmux paste buffer.

3. **`~/clip` POSTs to clipboard server** — The script reads stdin and
   uses `curl` to POST the text to `http://127.0.0.1:9123/`. The curl
   runs in the background (`&`) so tmux doesn't block.

4. **Clipboard server stores the text** — The Python HTTP server on port
   9123 stores the text in memory (thread-safe, single global variable).

5. **nginx proxies `/clipboard/`** — The browser can reach the clipboard
   server via `http://localhost:8080/clipboard/` because nginx proxies
   this path to `127.0.0.1:9123`.

6. **Browser JS polls and writes** — A `setInterval` in the AIO dashboard
   page fetches `/clipboard/` every 300ms. If the response is non-empty,
   it calls `navigator.clipboard.writeText(text)`.

7. **GET clears the stored text** — The clipboard server clears its stored
   text after a GET to avoid writing the same text repeatedly.

8. **System clipboard updated** — The browser's Clipboard API writes to
   the system clipboard. You can now `Cmd+V` anywhere.

**Latency:** ~300ms worst case (the poll interval).

---

## Components

### `clipboard_server.py`
**Location in container:** `/home/gem/clipboard_server.py`
**Managed by:** supervisord (auto-start, auto-restart)

A minimal Python HTTP server (stdlib only, no dependencies). Two endpoints:
- `POST /` — Store clipboard text
- `GET /` — Retrieve and clear clipboard text

Listens on `127.0.0.1:9123` (container-internal only).

### `clip`
**Location in container:** `/home/gem/clip`
**Called by:** tmux `copy-pipe-and-cancel`

A 4-line bash script that reads stdin and POSTs it to the clipboard server.
Backgrounded curl so tmux doesn't block.

### `tmux.conf`
**Location in container:** `/home/gem/.tmux.conf`

Configures:
- vi copy-mode keys
- Mouse support
- OSC 52 terminal overrides (belt-and-suspenders)
- `y` and `Enter` bindings to `copy-pipe-and-cancel "~/clip"`

### `nginx-clipboard.conf`
**Location in container:** `/opt/gem/nginx/clipboard.conf`

Proxies `/clipboard/` → `127.0.0.1:9123`.

### `supervisord-clipboard.conf`
**Location in container:** `/opt/gem/supervisord/clipboard_server.conf`

Auto-starts `clipboard_server.py` as the `gem` user, restarts on crash.

### `aio-clipboard-poller.js`
**Injected into:** `/opt/aio/index.html` (before `</body>`)

The browser-side polling loop. Also requires the iframe `allow` attribute
patch so the clipboard API works from within the code-server iframe.

### `install.sh`
One-shot script that installs all components into a running container.

---

## Installation

### Quick Install (running container)

From the repo root:
```bash
./clipboard-bridge/install.sh
```

Then reload `localhost:8080` in your browser.

### Verify It Works

```bash
# From the host — pipe text through the clip script
docker exec -u gem llm-sandbox bash -lc 'echo "hello clipboard" | ~/clip'

# Wait a second, then check
sleep 1
pbpaste
# Should output: hello clipboard
```

Or in tmux: enter copy mode (`Ctrl+B [`), select text, press `y`, then
`Cmd+V` in any app.

---

## Troubleshooting

### Clipboard server not running

```bash
docker exec -u root llm-sandbox supervisorctl status clipboard-server
# Should show: RUNNING

# If not:
docker exec -u root llm-sandbox supervisorctl start clipboard-server
```

### Test the HTTP chain manually

```bash
# POST some text
docker exec -u gem llm-sandbox curl -s -X POST -d "test" http://127.0.0.1:9123/

# GET it back (should return "test")
docker exec -u gem llm-sandbox curl -s http://127.0.0.1:9123/

# GET again (should be empty — cleared after first read)
docker exec -u gem llm-sandbox curl -s http://127.0.0.1:9123/
```

### Browser not picking up clipboard

- Make sure you're on the AIO dashboard page (`localhost:8080`), not
  directly on `localhost:8080/code-server/`
- Check browser console for errors: `fetch("/clipboard/")` should return 200
- Ensure the page has clipboard permission (Chrome shows a clipboard icon
  in the address bar if permission is blocked)
- Try hard-refreshing the page (`Cmd+Shift+R`)

### tmux copy not triggering

- Verify `.tmux.conf` is loaded: `tmux show-options -g | grep clip`
- If you changed `.tmux.conf` after starting tmux, reload it:
  `tmux source-file ~/.tmux.conf`
- Test the clip script directly: `echo "test" | ~/clip`

### Works from terminal but not from tmux copy mode

- Check that `~/clip` exists and is executable: `ls -la ~/clip`
- Test manually: `echo "manual test" | ~/clip`
- If tmux was started before `.tmux.conf` was updated, reload:
  `Ctrl+B :source-file ~/.tmux.conf`
