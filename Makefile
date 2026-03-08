# LLM Sandbox — Persistent Docker Development Environment

IMAGE_NAME     := llm-sandbox
CONTAINER      := llm-sandbox
VOLUME         := llm-sandbox-home
HOST_PORT      := 8080
CONTAINER_PORT := 8080
SHARED_DIR     := $(CURDIR)/sbx-shared
SHELL_USER     := gem
TAILSCALE_HOSTNAME ?= llm-sandbox
TAILSCALE_SCRIPT   := scripts/setup-tailscale.sh
TAILSCALE_SOCKET   := /var/run/tailscale/tailscaled.sock
TAILSCALE_UP_TIMEOUT ?= 20s
SSH_KEY_FILE       ?= $(HOME)/.ssh/id_ed25519.pub

-include .env
export

.PHONY: up start stop destroy clean backup status shell build logs help setup-tailscale tailscale-status

help: ## Show available targets
	@grep -h -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

# -- Build ---------------------------------------------------------------------

build: Dockerfile setup-ai-tools.sh ## Build the Docker image
	docker build -t $(IMAGE_NAME) .

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
		if docker run -d \
			--name $(CONTAINER) \
			--hostname $(CONTAINER) \
			-p $(HOST_PORT):$(CONTAINER_PORT) \
			-p 8501:8501 \
			--cap-add NET_ADMIN \
			--security-opt seccomp=unconfined \
			--device /dev/net/tun \
			-v $(VOLUME):/home/gem \
			-v $(SHARED_DIR):/home/gem/shared:ro \
			$(IMAGE_NAME); then \
			echo "/dev/net/tun enabled."; \
		else \
			echo "Warning: could not attach /dev/net/tun; falling back to userspace mode."; \
			docker run -d \
				--name $(CONTAINER) \
				--hostname $(CONTAINER) \
				-p $(HOST_PORT):$(CONTAINER_PORT) \
				-p 8501:8501 \
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
	@echo "Shell:     make shell"

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
		echo "Ports:   $(HOST_PORT)->$(CONTAINER_PORT)"; \
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
