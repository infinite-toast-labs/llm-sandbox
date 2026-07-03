#!/usr/bin/env bash
set -euo pipefail

SENTINEL="/home/gem/.ai-tools-installed"

ensure_user_bins() {
    su - gem -c 'mkdir -p "$HOME/.npm-global/bin" "$HOME/.npm-global/lib" "$HOME/.local/bin" && npm config set prefix "$HOME/.npm-global"' || {
        echo "[setup-ai-tools] WARNING: npm prefix setup failed"
    }
}

ensure_opencode_path() {
    local config_file

    for config_file in /opt/gem/bashrc /home/gem/.bashrc; do
        if [ -f "$config_file" ] && ! grep -Fq '$HOME/.opencode/bin' "$config_file"; then
            printf '%s\n' \
                '' \
                '# opencode' \
                'case ":$PATH:" in' \
                '  *":$HOME/.opencode/bin:"*) ;;' \
                '  *) export PATH="$HOME/.opencode/bin:$PATH" ;;' \
                'esac' \
                >> "$config_file"
        fi
    done
}

install_opencode() {
    echo "[setup-ai-tools] Installing opencode..."
    su - gem -c 'curl -fsSL https://opencode.ai/install | bash -s -- --no-modify-path && ln -sf "$HOME/.opencode/bin/opencode" "$HOME/.local/bin/opencode"' || {
        echo "[setup-ai-tools] WARNING: opencode installation failed"
    }
}

ensure_opencode_path

if [ -f "$SENTINEL" ]; then
    echo "[setup-ai-tools] AI tools already installed, checking opencode."
    ensure_user_bins
    if su - gem -c 'test -x "$HOME/.opencode/bin/opencode"'; then
        su - gem -c 'ln -sf "$HOME/.opencode/bin/opencode" "$HOME/.local/bin/opencode"' || true
        echo "[setup-ai-tools] opencode already installed."
    else
        install_opencode
    fi
    exit 0
fi

echo "[setup-ai-tools] Installing AI CLI tools (first-run setup)..."

# Ensure npm globals for gem live under home (shared between code-server + SSH sessions).
ensure_user_bins

# Install Claude Code
echo "[setup-ai-tools] Installing Claude Code..."
su - gem -c 'curl -fsSL https://claude.ai/install.sh | bash' || {
    echo "[setup-ai-tools] WARNING: Claude Code installation failed"
}

# Keep opencode PATH management in the image/template because the sandbox
# regenerates ~/.bashrc on container start.
install_opencode

# Install OpenAI Codex
echo "[setup-ai-tools] Installing OpenAI Codex..."
su - gem -c 'export NPM_CONFIG_PREFIX="$HOME/.npm-global"; export PATH="$NPM_CONFIG_PREFIX/bin:$HOME/.local/bin:$PATH"; npm i -g @openai/codex' || {
    echo "[setup-ai-tools] WARNING: OpenAI Codex installation failed"
}

# Install Google Gemini CLI
echo "[setup-ai-tools] Installing Google Gemini CLI..."
su - gem -c 'export NPM_CONFIG_PREFIX="$HOME/.npm-global"; export PATH="$NPM_CONFIG_PREFIX/bin:$HOME/.local/bin:$PATH"; npm install -g @google/gemini-cli' || {
    echo "[setup-ai-tools] WARNING: Google Gemini CLI installation failed"
}

# Mark installation complete
su - gem -c "touch $SENTINEL"
echo "[setup-ai-tools] AI tools installation complete."
