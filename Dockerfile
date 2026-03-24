FROM ghcr.io/agent-infra/sandbox:latest

ARG ENABLE_ANDROID=0
ARG ANDROID_CMDLINE_TOOLS_VERSION=14742923
ARG ANDROID_SDK_ROOT=/opt/android-sdk
ARG ANDROID_PLATFORM=android-36
ARG ANDROID_BUILD_TOOLS=34.0.0

ENV ANDROID_HOME=${ANDROID_SDK_ROOT}
ENV ANDROID_SDK_ROOT=${ANDROID_SDK_ROOT}
ENV PATH=${ANDROID_SDK_ROOT}/cmdline-tools/latest/bin:${ANDROID_SDK_ROOT}/platform-tools:${PATH}

COPY setup-ai-tools.sh /opt/setup-ai-tools.sh
RUN chmod +x /opt/setup-ai-tools.sh

RUN if [ "$ENABLE_ANDROID" = "1" ]; then \
      export DEBIAN_FRONTEND=noninteractive; \
      apt-get update; \
      apt-get install -y --no-install-recommends \
        curl \
        gradle \
        openjdk-17-jdk-headless \
        python3-pip \
        unzip; \
      rm -rf /var/lib/apt/lists/*; \
      mkdir -p "${ANDROID_SDK_ROOT}/cmdline-tools"; \
      curl -fsSL \
        "https://dl.google.com/android/repository/commandlinetools-linux-${ANDROID_CMDLINE_TOOLS_VERSION}_latest.zip" \
        -o /tmp/android-cmdline-tools.zip; \
      rm -rf /tmp/android-sdk-tools; \
      unzip -q /tmp/android-cmdline-tools.zip -d /tmp/android-sdk-tools; \
      mkdir -p "${ANDROID_SDK_ROOT}/cmdline-tools/latest"; \
      mv /tmp/android-sdk-tools/cmdline-tools/* "${ANDROID_SDK_ROOT}/cmdline-tools/latest/"; \
      yes | sdkmanager --sdk_root="${ANDROID_SDK_ROOT}" --licenses >/dev/null; \
      yes | sdkmanager --sdk_root="${ANDROID_SDK_ROOT}" "platform-tools"; \
      yes | sdkmanager --sdk_root="${ANDROID_SDK_ROOT}" "build-tools;${ANDROID_BUILD_TOOLS}"; \
      yes | sdkmanager --sdk_root="${ANDROID_SDK_ROOT}" "platforms;${ANDROID_PLATFORM}"; \
      test -x "${ANDROID_SDK_ROOT}/platform-tools/adb"; \
      test -d "${ANDROID_SDK_ROOT}/build-tools/${ANDROID_BUILD_TOOLS}"; \
      ln -sf "${ANDROID_SDK_ROOT}/platform-tools/adb" /usr/local/bin/adb; \
      ln -sf "${ANDROID_SDK_ROOT}/cmdline-tools/latest/bin/sdkmanager" /usr/local/bin/sdkmanager; \
      ln -sf "${ANDROID_SDK_ROOT}/cmdline-tools/latest/bin/avdmanager" /usr/local/bin/avdmanager; \
      rm -rf /tmp/android-cmdline-tools.zip /tmp/android-sdk-tools; \
    fi

RUN echo 'alias cdsp="claude --dangerously-skip-permissions"' >> /etc/profile && \
    echo 'alias cdsp="claude --dangerously-skip-permissions"' >> /etc/bash.bashrc && \
    echo 'alias gdsp="gemini --yolo"' >> /etc/profile && \
    echo 'alias gdsp="gemini --yolo"' >> /etc/bash.bashrc && \
    echo 'alias f1="rn_script_flow2.sh"' >> /etc/bash.bashrc && \
    echo 'alias codexdsp="codex --dangerously-bypass-approvals-and-sandbox"' >> /etc/profile && \
    echo 'alias codexdsp="codex --dangerously-bypass-approvals-and-sandbox"' >> /etc/bash.bashrc && \
    if [ -f /opt/gem/bashrc ] && ! grep -q "llm-sandbox tool env" /opt/gem/bashrc; then \
      printf '%s\n' \
        '' \
        '# >>> llm-sandbox tool env >>>' \
        'export NPM_CONFIG_PREFIX="$HOME/.npm-global"' \
        'mkdir -p "$NPM_CONFIG_PREFIX/bin" "$NPM_CONFIG_PREFIX/lib" >/dev/null 2>&1 || true' \
        'case ":$PATH:" in' \
        '  *":$NPM_CONFIG_PREFIX/bin:"*) ;;' \
        '  *) export PATH="$NPM_CONFIG_PREFIX/bin:$PATH" ;;' \
        'esac' \
        'case ":$PATH:" in' \
        '  *":$HOME/.local/bin:"*) ;;' \
        '  *) export PATH="$HOME/.local/bin:$PATH" ;;' \
        'esac' \
        '# <<< llm-sandbox tool env <<<' \
        >> /opt/gem/bashrc; \
    fi

COPY entrypoint-wrapper.sh /opt/entrypoint-wrapper.sh
RUN chmod +x /opt/entrypoint-wrapper.sh
ENTRYPOINT ["/opt/entrypoint-wrapper.sh"]
