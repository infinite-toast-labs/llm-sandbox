#!/usr/bin/env bash
set -euo pipefail

SESSION="agent-teams"
WORKDIR="/home/gem/workspaces/agent-teams"
LOCK_FILE="${XDG_RUNTIME_DIR:-/tmp}/flow2-${SESSION}.lock"
WELCOME_BANNER_FILE="${XDG_RUNTIME_DIR:-/tmp}/flow2-${SESSION}-welcome.txt"

# Keep flow1 behavior by default-teams: auto-start all three CLIs.
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

# --- Window 1: codex-agent ---
tmux new-session -d -s "$SESSION" -n "codex-agent" -c "$WORKDIR"
tmux send-keys -t "$SESSION:codex-agent.0" "cd $WORKDIR" Enter
tmux split-window -d -t "$SESSION:codex-agent" -v -l 25% -c "$WORKDIR"
tmux select-pane -t "$SESSION:codex-agent.0"

# --- Window 2: gemini-agent ---
tmux new-window -t "$SESSION" -n "gemini-agent" -c "$WORKDIR"
tmux send-keys -t "$SESSION:gemini-agent.0" "cd $WORKDIR" Enter
tmux split-window -d -t "$SESSION:gemini-agent" -v -l 25% -c "$WORKDIR"
tmux select-pane -t "$SESSION:gemini-agent.0"

# --- Window 3: claude-agent ---
tmux new-window -t "$SESSION" -n "claude-agent" -c "$WORKDIR"
tmux send-keys -t "$SESSION:claude-agent.0" "cd $WORKDIR" Enter
tmux split-window -d -t "$SESSION:claude-agent" -v -l 25% -c "$WORKDIR"
tmux select-pane -t "$SESSION:claude-agent.0"

# --- Window 4: default-teams ---
tmux new-window -t "$SESSION" -n "default-teams" -c "$WORKDIR"

if [[ "$AUTOSTART" == "1" ]]; then
    # Run in the main panes (.0), staggered to avoid host CPU spikes at launch.
    tmux send-keys -t "$SESSION:codex-agent.0" "cd $WORKDIR && codexdsp" Enter
    tmux send-keys -t "$SESSION:gemini-agent.0" "cd $WORKDIR && gdsp" Enter
    tmux send-keys -t "$SESSION:claude-agent.0" "cd $WORKDIR && cdsp" Enter
else
    tmux send-keys -t "$SESSION:codex-agent.0" "echo 'Autostart disabled. Run: codexdsp'" Enter
    tmux send-keys -t "$SESSION:gemini-agent.0" "echo 'Autostart disabled. Run: gdsp'" Enter
    tmux send-keys -t "$SESSION:claude-agent.0" "echo 'Autostart disabled. Run: cdsp'" Enter
fi

# Print ASCII welcome when creating a new agent-teams session.
cat >"$WELCOME_BANNER_FILE" <<'WELCOME'

   =========================================
              AGENT-TEAMS SESSION
   =========================================
   windows:
   - codex-agent
   - gemini-agent
   - claude-agent
   - default-teams

WELCOME
tmux send-keys -t "$SESSION:default-teams.0" "cat '$WELCOME_BANNER_FILE'" Enter

# Release the startup lock so future invocations aren't blocked by the tmux
# server inheriting fd 9.
exec 9>&-

# Focus on the default-teams window
tmux select-window -t "$SESSION:default-teams"

# Attach only when we have a terminal
if [[ -t 1 ]]; then
    tmux attach-session -t "$SESSION"
else
    echo "flow2: session '$SESSION' created (not attaching: no TTY)"
fi
