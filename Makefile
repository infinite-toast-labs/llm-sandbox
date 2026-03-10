# LLM Sandbox — Persistent Docker Development Environment

IMAGE_NAME     ?= llm-sandbox
CONTAINER      ?= llm-sandbox
VOLUME         ?= llm-sandbox-home
HOST_PORT      ?= 8080
CONTAINER_PORT := 8080
SHARED_DIR     := $(CURDIR)/sbx-shared
SHELL_USER     := gem
SHELL_HINT     ?= make shell
STREAMLIT_HOST_PORT ?= 8501
DOCKER_BUILD_ARGS ?=
DOCKER_RUN_ARGS ?=
TAILSCALE_HOSTNAME ?= llm-sandbox
TAILSCALE_SCRIPT   := scripts/setup-tailscale.sh
TAILSCALE_SOCKET   := /var/run/tailscale/tailscaled.sock
TAILSCALE_UP_TIMEOUT ?= 20s
SSH_KEY_FILE       ?= $(HOME)/.ssh/id_ed25519.pub
ANDROID_IMAGE_NAME ?= llm-sandbox-android
ANDROID_CONTAINER  ?= llm-sandbox-android
ANDROID_VOLUME     ?= llm-sandbox-android-home
ANDROID_HOST_PORT  ?= 8081
ANDROID_STREAMLIT_HOST_PORT ?= 8502
ANDROID_HOST_CHECK        := scripts/android-host-check.sh
ANDROID_CREATE_AVD        := scripts/android-create-avd.sh
ANDROID_START_EMULATOR    := scripts/android-start-emulator.sh
ANDROID_STOP_EMULATOR     := scripts/android-stop-emulator.sh
ANDROID_CONNECT_CONTAINER := scripts/android-container-connect.sh
ANDROID_AVD_NAME          ?= llm_sandbox_pixel_9_pro_api_36_1
ANDROID_DEVICE_ID         ?= pixel_9_pro
ANDROID_SYSTEM_IMAGE      ?= system-images;android-36.1;google_apis_playstore;arm64-v8a
ANDROID_EMULATOR_PORT     ?= 5560
ANDROID_EMULATOR_TCP_PORT ?= 5561
ANDROID_HOST_ADB_SERVER_PORT ?= 5037

-include .env
export

.PHONY: up start stop destroy clean backup status shell build logs help setup-tailscale tailscale-status \
	android-build android-up android-start android-stop android-clean android-destroy android-backup \
	android-shell android-status android-logs android-prereqs android-avd-create android-emulator-start \
	android-emulator-stop android-connect

help: ## Show available targets
	@grep -h -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-24s\033[0m %s\n", $$1, $$2}'

# -- Build ---------------------------------------------------------------------

build: Dockerfile setup-ai-tools.sh ## Build the Docker image
	docker build $(DOCKER_BUILD_ARGS) -t $(IMAGE_NAME) .

# -- Lifecycle -----------------------------------------------------------------

up: build ## Create/start the container and run first-time setup
	@if docker container inspect $(CONTAINER) >/dev/null 2>&1; then \
		STATE=$$(docker container inspect -f '{{.State.Status}}' $(CONTAINER)); \
		if [ "$$STATE" = "running" ]; then \
			echo "Container '$(CONTAINER)' is already running."; \
		else \
			echo "Container '$(CONTAINER)' is $$STATE. Starting..."; \
			docker start $(CONTAINER); \
		fi; \
	else \
		echo "Creating container '$(CONTAINER)'..."; \
		mkdir -p $(SHARED_DIR); \
		docker volume create $(VOLUME) >/dev/null 2>&1 || true; \
		echo "Attempting to start with /dev/net/tun enabled..."; \
		if docker run -d $(DOCKER_RUN_ARGS) \
			--name $(CONTAINER) \
			--hostname $(CONTAINER) \
			-p $(HOST_PORT):$(CONTAINER_PORT) \
			-p $(STREAMLIT_HOST_PORT):8501 \
			--cap-add NET_ADMIN \
			--security-opt seccomp=unconfined \
			--device /dev/net/tun \
			-v $(VOLUME):/home/gem \
			-v $(SHARED_DIR):/home/gem/shared:ro \
			$(IMAGE_NAME); then \
			echo "/dev/net/tun enabled."; \
		else \
			echo "Warning: could not attach /dev/net/tun; falling back to userspace mode."; \
			docker run -d $(DOCKER_RUN_ARGS) \
				--name $(CONTAINER) \
				--hostname $(CONTAINER) \
				-p $(HOST_PORT):$(CONTAINER_PORT) \
				-p $(STREAMLIT_HOST_PORT):8501 \
				--cap-add NET_ADMIN \
				--security-opt seccomp=unconfined \
				-v $(VOLUME):/home/gem \
				-v $(SHARED_DIR):/home/gem/shared:ro \
				$(IMAGE_NAME); \
		fi; \
		echo "Waiting for container to initialize..."; \
		sleep 5; \
		echo "Running first-time AI tools setup..."; \
		docker exec $(CONTAINER) /opt/setup-ai-tools.sh; \
	fi
	@echo ""
	@echo "Dashboard: http://localhost:$(HOST_PORT)"
	@echo "Shell:     $(SHELL_HINT)"

start: up ## Alias for 'up'

stop: ## Stop the container (data preserved)
	@if docker container inspect $(CONTAINER) >/dev/null 2>&1; then \
		docker stop $(CONTAINER); \
		echo "Container '$(CONTAINER)' stopped."; \
	else \
		echo "Container '$(CONTAINER)' does not exist."; \
	fi

clean: ## Stop and remove the container (volume preserved)
	@echo "This will stop and remove container '$(CONTAINER)'."
	@echo "Volume '$(VOLUME)' and files in /home/$(SHELL_USER) will be preserved."
	@printf "Proceed with clean? [y/N] "; \
	read -r ANSWER; \
	case "$$ANSWER" in y|Y|yes|YES) ;; *) echo "Canceled."; exit 1;; esac
	@$(MAKE) --no-print-directory stop
	@if docker container inspect $(CONTAINER) >/dev/null 2>&1; then \
		docker rm $(CONTAINER); \
		echo "Container '$(CONTAINER)' removed. Volume '$(VOLUME)' preserved."; \
	else \
		echo "Container '$(CONTAINER)' does not exist."; \
	fi

destroy: ## Remove container AND volume (full reset)
	@echo "This will stop and remove container '$(CONTAINER)' and delete volume '$(VOLUME)'."
	@echo "All files stored under /home/$(SHELL_USER) in the sandbox will be permanently deleted."
	@printf "Proceed with destroy (full reset)? [y/N] "; \
	read -r ANSWER; \
	case "$$ANSWER" in y|Y|yes|YES) ;; *) echo "Canceled."; exit 1;; esac
	@$(MAKE) --no-print-directory stop
	@if docker container inspect $(CONTAINER) >/dev/null 2>&1; then \
		docker rm $(CONTAINER); \
		echo "Container '$(CONTAINER)' removed."; \
	else \
		echo "Container '$(CONTAINER)' does not exist."; \
	fi
	@if docker volume inspect $(VOLUME) >/dev/null 2>&1; then \
		docker volume rm $(VOLUME); \
		echo "Volume '$(VOLUME)' removed."; \
	else \
		echo "Volume '$(VOLUME)' does not exist."; \
	fi
	@echo "Full reset complete. Next 'make up' will recreate everything."

backup: ## Backup the home volume to a timestamped archive in repo root
	@set -euo pipefail; \
	if ! docker volume inspect $(VOLUME) >/dev/null 2>&1; then \
		echo "Error: Docker volume '$(VOLUME)' does not exist."; \
		exit 1; \
	fi; \
	if ! docker image inspect $(IMAGE_NAME) >/dev/null 2>&1; then \
		echo "Error: Docker image '$(IMAGE_NAME)' is not available. Run 'make build' first."; \
		exit 1; \
	fi; \
	TIMESTAMP=$$(date +%Y-%m-%d-%H%M%S); \
	OUTPUT="$(CURDIR)/$(VOLUME)-$$TIMESTAMP.tgz"; \
	echo "Creating backup: $$OUTPUT"; \
	docker run --rm \
		--entrypoint bash \
		-u root \
		-e OUTPUT_NAME="$(VOLUME)-$$TIMESTAMP.tgz" \
		-v $(VOLUME):/volume:ro \
		-v $(CURDIR):/backup \
		$(IMAGE_NAME) \
		-lc 'set -euo pipefail; tar -czf "/backup/$$OUTPUT_NAME" -C /volume .'; \
	echo "Backup complete: $$OUTPUT"; \
	ls -lh "$$OUTPUT"

# -- Interaction ---------------------------------------------------------------

setup-tailscale: $(TAILSCALE_SCRIPT) ## Install/configure Tailscale + SSH in container
	@set -euo pipefail; \
	if ! docker container inspect $(CONTAINER) >/dev/null 2>&1; then \
		echo "Container '$(CONTAINER)' does not exist. Run 'make up' first."; \
		exit 1; \
	fi; \
	if ! docker container inspect -f '{{.State.Running}}' $(CONTAINER) | grep -q true; then \
		echo "Container '$(CONTAINER)' is not running. Starting..."; \
		docker start $(CONTAINER) >/dev/null; \
		sleep 3; \
	fi; \
	SSH_KEY_VALUE=""; \
	TS_AUTH_KEY_VALUE="$(TAILSCALE_AUTH_KEY)"; \
	if [ -z "$$TS_AUTH_KEY_VALUE" ]; then \
		echo "Error: TAILSCALE_AUTH_KEY is not set."; \
		echo "Set it in local .env (this repo) or export it in your shell."; \
		echo "Set it explicitly: TAILSCALE_AUTH_KEY=tskey-... make setup-tailscale"; \
		exit 1; \
	fi; \
	if [ -n "$${SSH_PUBLIC_KEY:-}" ]; then \
		SSH_KEY_VALUE="$$SSH_PUBLIC_KEY"; \
	elif [ -f "$(SSH_KEY_FILE)" ]; then \
		SSH_KEY_VALUE="$$(cat "$(SSH_KEY_FILE)")"; \
	elif [ -f "$$HOME/.ssh/id_rsa.pub" ]; then \
		SSH_KEY_VALUE="$$(cat "$$HOME/.ssh/id_rsa.pub")"; \
	fi; \
	docker cp $(TAILSCALE_SCRIPT) $(CONTAINER):/tmp/setup-tailscale.sh; \
	SETUP_RC=0; \
	docker exec -u root \
		-e SHELL_USER="$(SHELL_USER)" \
		-e TAILSCALE_HOSTNAME="$(TAILSCALE_HOSTNAME)" \
		-e TAILSCALE_AUTH_KEY="$$TS_AUTH_KEY_VALUE" \
		-e TAILSCALE_EXTRA_ARGS="$(TAILSCALE_EXTRA_ARGS)" \
		-e TAILSCALE_SOCKET="$(TAILSCALE_SOCKET)" \
		-e TAILSCALE_UP_TIMEOUT="$(TAILSCALE_UP_TIMEOUT)" \
		-e SSH_PUBLIC_KEY="$$SSH_KEY_VALUE" \
		$(CONTAINER) bash /tmp/setup-tailscale.sh || SETUP_RC=$$?; \
	docker exec -u root $(CONTAINER) rm -f /tmp/setup-tailscale.sh >/dev/null 2>&1 || true; \
	TS_IP="$$(docker exec $(CONTAINER) sh -lc 'tailscale ip -4 2>/dev/null | head -1' || true)"; \
	HAS_TUN="$$(docker exec $(CONTAINER) sh -lc 'if [ -e /dev/net/tun ]; then echo 1; else echo 0; fi' 2>/dev/null || echo 0)"; \
	echo ""; \
	if [ -n "$$TS_IP" ]; then \
		echo "Tailscale IP: $$TS_IP"; \
		echo "Tailscale SSH: tailscale ssh $(SHELL_USER)@$(TAILSCALE_HOSTNAME)"; \
		if [ "$$HAS_TUN" = "1" ]; then \
			echo "OpenSSH:       ssh $(SHELL_USER)@$$TS_IP"; \
		else \
			echo "Note: userspace mode active; use tailscale ssh command above."; \
		fi; \
	else \
		echo "Tailscale installed but not connected yet."; \
		echo "If login URL was printed above, complete it then run 'make setup-tailscale' again."; \
	fi; \
	if [ "$$SETUP_RC" -ne 0 ]; then \
		exit "$$SETUP_RC"; \
	fi

tailscale-status: ## Show Tailscale + SSH status inside the container
	@if docker container inspect -f '{{.State.Running}}' $(CONTAINER) 2>/dev/null | grep -q true; then \
		docker exec -u root $(CONTAINER) bash -lc '\
			echo "=== Tailscale ==="; \
			tailscale status 2>/dev/null || echo "tailscale not connected"; \
			echo ""; \
			TS_IP=$$(tailscale ip -4 2>/dev/null | head -1 || true); \
			echo "Tailscale IPv4: $${TS_IP:-unavailable}"; \
			echo ""; \
			echo "=== SSHD ==="; \
			ps -eo pid,comm,args | awk '\''$$2 == "sshd" {print; found=1} END {if (!found) print "sshd not running"}'\'''; \
	else \
		echo "Container '$(CONTAINER)' is not running. Run 'make up' first."; \
		exit 1; \
	fi

shell: ## Open a shell in the running container
	@if docker container inspect -f '{{.State.Running}}' $(CONTAINER) 2>/dev/null | grep -q true; then \
		docker exec -it -u $(SHELL_USER) -w /home/$(SHELL_USER) $(CONTAINER) bash -l; \
	else \
		echo "Container '$(CONTAINER)' is not running. Run 'make up' first."; \
		exit 1; \
	fi

status: ## Show container and volume status
	@echo "=== Container ==="
	@if docker container inspect $(CONTAINER) >/dev/null 2>&1; then \
		docker container inspect -f \
			'Name:    {{.Name}}\nState:   {{.State.Status}}\nStarted: {{.State.StartedAt}}\nImage:   {{.Config.Image}}' \
			$(CONTAINER); \
		echo "Ports:   $(HOST_PORT)->$(CONTAINER_PORT), $(STREAMLIT_HOST_PORT)->8501"; \
	else \
		echo "Container '$(CONTAINER)' does not exist."; \
	fi
	@echo ""
	@echo "=== Volume ==="
	@if docker volume inspect $(VOLUME) >/dev/null 2>&1; then \
		docker volume inspect -f \
			'Name:       {{.Name}}\nDriver:     {{.Driver}}\nMountpoint: {{.Mountpoint}}\nCreated:    {{.CreatedAt}}' \
			$(VOLUME); \
	else \
		echo "Volume '$(VOLUME)' does not exist."; \
	fi

logs: ## Tail container logs
	@docker logs -f $(CONTAINER) 2>/dev/null || echo "Container '$(CONTAINER)' not found."

# -- Optional Android Sandbox --------------------------------------------------

android-build: ## Build the optional Android-enabled sandbox image
	@$(MAKE) --no-print-directory build \
		IMAGE_NAME=$(ANDROID_IMAGE_NAME) \
		DOCKER_BUILD_ARGS='--platform=linux/amd64 --build-arg ENABLE_ANDROID=1'

android-prereqs: $(ANDROID_HOST_CHECK) ## Check optional host prerequisites for Android support
	@ANDROID_AVD_NAME='$(ANDROID_AVD_NAME)' \
	ANDROID_DEVICE_ID='$(ANDROID_DEVICE_ID)' \
	ANDROID_SYSTEM_IMAGE='$(ANDROID_SYSTEM_IMAGE)' \
	ANDROID_EMULATOR_PORT='$(ANDROID_EMULATOR_PORT)' \
	ANDROID_EMULATOR_TCP_PORT='$(ANDROID_EMULATOR_TCP_PORT)' \
	ANDROID_HOST_ADB_SERVER_PORT='$(ANDROID_HOST_ADB_SERVER_PORT)' \
	'./$(ANDROID_HOST_CHECK)'

android-avd-create: android-prereqs $(ANDROID_CREATE_AVD) ## Create the deterministic optional host Pixel 9 Pro AVD
	@ANDROID_AVD_NAME='$(ANDROID_AVD_NAME)' \
	ANDROID_DEVICE_ID='$(ANDROID_DEVICE_ID)' \
	ANDROID_SYSTEM_IMAGE='$(ANDROID_SYSTEM_IMAGE)' \
	ANDROID_EMULATOR_PORT='$(ANDROID_EMULATOR_PORT)' \
	ANDROID_EMULATOR_TCP_PORT='$(ANDROID_EMULATOR_TCP_PORT)' \
	ANDROID_HOST_ADB_SERVER_PORT='$(ANDROID_HOST_ADB_SERVER_PORT)' \
	'./$(ANDROID_CREATE_AVD)'

android-emulator-start: android-avd-create $(ANDROID_START_EMULATOR) ## Start the optional host Android emulator and expose ADB/TCP
	@ANDROID_AVD_NAME='$(ANDROID_AVD_NAME)' \
	ANDROID_DEVICE_ID='$(ANDROID_DEVICE_ID)' \
	ANDROID_SYSTEM_IMAGE='$(ANDROID_SYSTEM_IMAGE)' \
	ANDROID_EMULATOR_PORT='$(ANDROID_EMULATOR_PORT)' \
	ANDROID_EMULATOR_TCP_PORT='$(ANDROID_EMULATOR_TCP_PORT)' \
	ANDROID_HOST_ADB_SERVER_PORT='$(ANDROID_HOST_ADB_SERVER_PORT)' \
	'./$(ANDROID_START_EMULATOR)'

android-emulator-stop: $(ANDROID_STOP_EMULATOR) ## Stop the optional host Android emulator managed by this sandbox
	@ANDROID_AVD_NAME='$(ANDROID_AVD_NAME)' \
	ANDROID_EMULATOR_PORT='$(ANDROID_EMULATOR_PORT)' \
	ANDROID_EMULATOR_TCP_PORT='$(ANDROID_EMULATOR_TCP_PORT)' \
	ANDROID_HOST_ADB_SERVER_PORT='$(ANDROID_HOST_ADB_SERVER_PORT)' \
	'./$(ANDROID_STOP_EMULATOR)'

android-connect: android-emulator-start $(ANDROID_CONNECT_CONTAINER) ## Connect the optional Android sandbox container to the host emulator
	@$(MAKE) --no-print-directory up \
		IMAGE_NAME=$(ANDROID_IMAGE_NAME) \
		CONTAINER=$(ANDROID_CONTAINER) \
		VOLUME=$(ANDROID_VOLUME) \
		HOST_PORT=$(ANDROID_HOST_PORT) \
		STREAMLIT_HOST_PORT=$(ANDROID_STREAMLIT_HOST_PORT) \
		SHELL_HINT='make android-shell' \
		DOCKER_BUILD_ARGS='--platform=linux/amd64 --build-arg ENABLE_ANDROID=1' \
		DOCKER_RUN_ARGS='--platform=linux/amd64'
	@ANDROID_EMULATOR_PORT='$(ANDROID_EMULATOR_PORT)' \
	ANDROID_EMULATOR_TCP_PORT='$(ANDROID_EMULATOR_TCP_PORT)' \
	ANDROID_HOST_ADB_SERVER_PORT='$(ANDROID_HOST_ADB_SERVER_PORT)' \
	'./$(ANDROID_CONNECT_CONTAINER)' '$(ANDROID_CONTAINER)'

android-up: android-connect ## Build and start the optional Android-enabled sandbox, host AVD, and ADB bridge

android-start: android-up ## Alias for 'android-up'

android-stop: ## Stop the optional Android-enabled sandbox container
	@$(MAKE) --no-print-directory stop CONTAINER=$(ANDROID_CONTAINER)

android-clean: ## Stop and remove the optional Android-enabled container (volume preserved)
	@$(MAKE) --no-print-directory clean CONTAINER=$(ANDROID_CONTAINER) VOLUME=$(ANDROID_VOLUME)

android-destroy: ## Remove the optional Android-enabled container and volume (full reset)
	@$(MAKE) --no-print-directory destroy CONTAINER=$(ANDROID_CONTAINER) VOLUME=$(ANDROID_VOLUME)

android-backup: ## Backup the optional Android-enabled home volume to a timestamped archive
	@$(MAKE) --no-print-directory backup IMAGE_NAME=$(ANDROID_IMAGE_NAME) VOLUME=$(ANDROID_VOLUME)

android-shell: ## Open a shell in the optional Android-enabled container
	@$(MAKE) --no-print-directory shell CONTAINER=$(ANDROID_CONTAINER)

android-status: ## Show optional Android sandbox status and current ADB connectivity
	@$(MAKE) --no-print-directory status \
		CONTAINER=$(ANDROID_CONTAINER) \
		VOLUME=$(ANDROID_VOLUME) \
		HOST_PORT=$(ANDROID_HOST_PORT) \
		STREAMLIT_HOST_PORT=$(ANDROID_STREAMLIT_HOST_PORT)
	@echo ""
	@echo "=== Host Android ==="
	@ANDROID_AVD_NAME='$(ANDROID_AVD_NAME)' \
	ANDROID_DEVICE_ID='$(ANDROID_DEVICE_ID)' \
	ANDROID_SYSTEM_IMAGE='$(ANDROID_SYSTEM_IMAGE)' \
	ANDROID_EMULATOR_PORT='$(ANDROID_EMULATOR_PORT)' \
	ANDROID_EMULATOR_TCP_PORT='$(ANDROID_EMULATOR_TCP_PORT)' \
	ANDROID_HOST_ADB_SERVER_PORT='$(ANDROID_HOST_ADB_SERVER_PORT)' \
	'./$(ANDROID_HOST_CHECK)' --quiet || true
	@ADB_BIN="$$(ANDROID_AVD_NAME='$(ANDROID_AVD_NAME)' ./$(ANDROID_HOST_CHECK) --print-adb 2>/dev/null || true)"; \
	if [ -n "$$ADB_BIN" ]; then \
		"$$ADB_BIN" devices; \
	else \
		echo "Host Android tools not fully available."; \
	fi
	@echo ""
	@echo "=== Container ADB ==="
	@if docker container inspect -f '{{.State.Running}}' $(ANDROID_CONTAINER) 2>/dev/null | grep -q true; then \
		docker exec -u gem $(ANDROID_CONTAINER) bash -lc 'if command -v android-adb >/dev/null 2>&1; then android-adb devices -l; else adb -H host.docker.internal -P $(ANDROID_HOST_ADB_SERVER_PORT) devices -l; fi'; \
	else \
		echo "Container '$(ANDROID_CONTAINER)' is not running. Run 'make android-up' first."; \
	fi

android-logs: ## Tail logs for the optional Android-enabled container
	@$(MAKE) --no-print-directory logs CONTAINER=$(ANDROID_CONTAINER)
