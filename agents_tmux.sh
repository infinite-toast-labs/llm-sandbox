#!/usr/bin/env bash
set -euo pipefail

SESSION="agent-teams"
WORKDIR="/home/gem/workspaces/agent-teams"
LOCK_FILE="${XDG_RUNTIME_DIR:-/tmp}/flow2-${SESSION}.lock"
WELCOME_BANNER_FILE="${XDG_RUNTIME_DIR:-/tmp}/flow2-${SESSION}-welcome.txt"

AUTOSTART="${FLOW2_AUTOSTART:-1}"
STARTUP_STAGGER_SECONDS="${FLOW2_STARTUP_STAGGER_SECONDS:-8}"

if [[ -n "${TMUX:-}" ]]; then
    echo "flow2: refusing to run from inside tmux"
    exit 1
fi

if tmux has-session -t "$SESSION" 2>/dev/null; then
    if [[ -t 1 ]]; then
        tmux attach-session -t "$SESSION"
    else
        echo "flow2: session '$SESSION' already exists (not attaching: no TTY)"
    fi
    exit 0
fi

# PID-based lock: only block if another process is actually running
if [[ -f "$LOCK_FILE" ]]; then
    LOCK_PID=$(cat "$LOCK_FILE" 2>/dev/null)
    if [[ -n "$LOCK_PID" ]] && kill -0 "$LOCK_PID" 2>/dev/null; then
        echo "flow2: another invocation (PID $LOCK_PID) is already running; skipping"
        exit 0
    fi
    rm -f "$LOCK_FILE"
fi
echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

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

# Focus on the default-teams window
tmux select-window -t "$SESSION:default-teams"

# Attach only when we have a terminal
if [[ -t 1 ]]; then
    tmux attach-session -t "$SESSION"
else
    echo "flow2: session '$SESSION' created (not attaching: no TTY)"
fi
