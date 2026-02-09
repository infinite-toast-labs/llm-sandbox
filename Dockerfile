FROM ghcr.io/agent-infra/sandbox:latest

COPY setup-ai-tools.sh /opt/setup-ai-tools.sh
RUN chmod +x /opt/setup-ai-tools.sh

RUN echo 'alias cdsp="claude --dangerously-skip-permissions"' >> /etc/profile && \
    echo 'alias cdsp="claude --dangerously-skip-permissions"' >> /etc/bash.bashrc && \
    echo 'alias gdsp="gemini --yolo"' >> /etc/profile && \
    echo 'alias gdsp="gemini --yolo"' >> /etc/bash.bashrc && \
    echo 'alias f1="rn_script_flow2.sh"' >> /etc/bash.bashrc && \
    echo 'alias codexdsp="codex --dangerously-bypass-approvals-and-sandbox"' >> /etc/profile && \
    echo 'alias codexdsp="codex --dangerously-bypass-approvals-and-sandbox"' >> /etc/bash.bashrc

COPY entrypoint-wrapper.sh /opt/entrypoint-wrapper.sh
RUN chmod +x /opt/entrypoint-wrapper.sh
ENTRYPOINT ["/opt/entrypoint-wrapper.sh"]
