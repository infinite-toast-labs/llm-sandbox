#!/usr/bin/env bash
set -euo pipefail

SESSION="pear"
WORKDIR="$HOME/workspaces/tmp"
LOCK_FILE="${XDG_RUNTIME_DIR:-/tmp}/flow2-${SESSION}.lock"
WELCOME_BANNER_FILE="${XDG_RUNTIME_DIR:-/tmp}/flow2-${SESSION}-welcome.txt"

# Keep flow1 behavior by default: auto-start all three CLIs.
# Set FLOW2_AUTOSTART=0 to create layout only.
AUTOSTART="${FLOW2_AUTOSTART:-1}"
# Delay (seconds) between CLI launches to reduce startup CPU spikes.
STARTUP_STAGGER_SECONDS="${FLOW2_STARTUP_STAGGER_SECONDS:-8}"

# Prevent concurrent invocations (e.g., shell startup hooks or accidental double-run).
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "flow2: another invocation is already running; skipping"
    exit 0
fi

# Do not run from inside tmux; this script is intended to be launched from
# a normal shell so attach behavior is explicit and predictable.
if [[ -n "${TMUX:-}" ]]; then
    echo "flow2: refusing to run from inside tmux"
    exit 1
fi

# If session already exists, attach to it
if tmux has-session -t "$SESSION" 2>/dev/null; then
    if [[ -t 1 ]]; then
        tmux attach-session -t "$SESSION"
    else
        echo "flow2: session '$SESSION' already exists (not attaching: no TTY)"
    fi
    exit 0
fi

# --- Window 1: claude ---
tmux new-session -d -s "$SESSION" -n "claude" -c "$WORKDIR"
tmux send-keys -t "$SESSION:claude.0" "cd $WORKDIR" Enter
tmux split-window -d -t "$SESSION:claude" -v -l 25% -c "$WORKDIR"
tmux select-pane -t "$SESSION:claude.0"

# --- Window 2: codex ---
tmux new-window -t "$SESSION" -n "codex" -c "$WORKDIR"
tmux send-keys -t "$SESSION:codex.0" "cd $WORKDIR" Enter
tmux split-window -d -t "$SESSION:codex" -v -l 25% -c "$WORKDIR"
tmux select-pane -t "$SESSION:codex.0"

# --- Window 3: default ---
tmux new-window -t "$SESSION" -n "default" -c "$WORKDIR"

# --- Window 4: gemini ---
tmux new-window -t "$SESSION" -n "gemini" -c "$WORKDIR"
tmux send-keys -t "$SESSION:gemini.0" "cd $WORKDIR" Enter
tmux split-window -d -t "$SESSION:gemini" -v -l 25% -c "$WORKDIR"
tmux select-pane -t "$SESSION:gemini.0"

if [[ "$AUTOSTART" == "1" ]]; then
    # Run in the main panes (.0), staggered to avoid host CPU spikes at launch.
    tmux send-keys -t "$SESSION:claude.0" "cd $WORKDIR && cdsp" Enter
    tmux send-keys -t "$SESSION:codex.0" "cd $WORKDIR && codexdsp" Enter
    tmux send-keys -t "$SESSION:gemini.0" "cd $WORKDIR && gdsp" Enter
else
    tmux send-keys -t "$SESSION:claude.0" "echo 'Autostart disabled. Run: cdsp'" Enter
    tmux send-keys -t "$SESSION:codex.0" "echo 'Autostart disabled. Run: codexdsp'" Enter
    tmux send-keys -t "$SESSION:gemini.0" "echo 'Autostart disabled. Run: gdsp'" Enter
fi

# Print ASCII welcome when creating a new pear session.
cat >"$WELCOME_BANNER_FILE" <<'WELCOME'

    ____  _____   _    ____
   |  _ \| ____| / \  |  _ \
   | |_) |  _|  / _ \ | |_) |
   |  __/| |___/ ___ \|  _ <
   |_|   |_____/_/   \_\_| \_\

   Welcome to the Pear workspace!

WELCOME
tmux send-keys -t "$SESSION:default.0" "cat '$WELCOME_BANNER_FILE'" Enter

# Release the startup lock so future invocations aren't blocked by the tmux
# server inheriting fd 9.
exec 9>&-

# Focus on the default window
tmux select-window -t "$SESSION:default"

# Attach only when we have a terminal
if [[ -t 1 ]]; then
    tmux attach-session -t "$SESSION"
else
    echo "flow2: session '$SESSION' created (not attaching: no TTY)"
fi
