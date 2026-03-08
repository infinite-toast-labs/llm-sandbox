FROM ghcr.io/agent-infra/sandbox:latest

COPY setup-ai-tools.sh /opt/setup-ai-tools.sh
RUN chmod +x /opt/setup-ai-tools.sh

RUN echo 'alias cdsp="claude --dangerously-skip-permissions"' >> /etc/profile && \
    echo 'alias cdsp="claude --dangerously-skip-permissions"' >> /etc/bash.bashrc && \
    echo 'alias gdsp="gemini --yolo"' >> /etc/profile && \
    echo 'alias gdsp="gemini --yolo"' >> /etc/bash.bashrc && \
    echo 'alias f1="rn_script_flow2.sh"' >> /etc/bash.bashrc && \
    echo 'alias codexdsp="codex --dangerously-bypass-approvals-and-sandbox"' >> /etc/profile && \
    echo 'alias codexdsp="codex --dangerously-bypass-approvals-and-sandbox"' >> /etc/bash.bashrc && \
    if [ -f /opt/gem/bashrc ] && ! grep -q "llm-sandbox tool env" /opt/gem/bashrc; then \
      cat >> /opt/gem/bashrc <<'EOF'; \

# >>> llm-sandbox tool env >>>
export NPM_CONFIG_PREFIX="$HOME/.npm-global"
mkdir -p "$NPM_CONFIG_PREFIX/bin" "$NPM_CONFIG_PREFIX/lib" >/dev/null 2>&1 || true
case ":$PATH:" in
  *":$NPM_CONFIG_PREFIX/bin:"*) ;;
  *) export PATH="$NPM_CONFIG_PREFIX/bin:$PATH" ;;
esac
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) export PATH="$HOME/.local/bin:$PATH" ;;
esac
# <<< llm-sandbox tool env <<<
EOF \
      ; \
    fi

COPY entrypoint-wrapper.sh /opt/entrypoint-wrapper.sh
RUN chmod +x /opt/entrypoint-wrapper.sh
ENTRYPOINT ["/opt/entrypoint-wrapper.sh"]
