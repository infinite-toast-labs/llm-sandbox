#!/usr/bin/env bash
set -euo pipefail

SENTINEL="/home/gem/.ai-tools-installed"

if [ -f "$SENTINEL" ]; then
    echo "[setup-ai-tools] AI tools already installed, skipping."
    exit 0
fi

echo "[setup-ai-tools] Installing AI CLI tools (first-run setup)..."

# Install Claude Code
echo "[setup-ai-tools] Installing Claude Code..."
su - gem -c 'curl -fsSL https://claude.ai/install.sh | bash' || {
    echo "[setup-ai-tools] WARNING: Claude Code installation failed"
}

# Install OpenAI Codex
echo "[setup-ai-tools] Installing OpenAI Codex..."
su - gem -c 'npm i -g @openai/codex' || {
    echo "[setup-ai-tools] WARNING: OpenAI Codex installation failed"
}

# Install Google Gemini CLI
echo "[setup-ai-tools] Installing Google Gemini CLI..."
su - gem -c 'npm install -g @google/gemini-cli' || {
    echo "[setup-ai-tools] WARNING: Google Gemini CLI installation failed"
}

# Mark installation complete
su - gem -c "touch $SENTINEL"
echo "[setup-ai-tools] AI tools installation complete."
