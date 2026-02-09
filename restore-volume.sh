#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./restore-volume.sh <backup-file.tgz> [--yes]

Environment overrides:
  VOLUME_NAME     Docker volume to restore into (default: llm-sandbox-home)
  CONTAINER_NAME  Container to stop/start around restore (default: llm-sandbox)
  IMAGE_NAME      Image used for restore helper container (default: llm-sandbox)

Examples:
  ./restore-volume.sh llm-sandbox-home-2026-02-06-193409.tgz
  ./restore-volume.sh /path/to/backup.tgz --yes
EOF
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage
  exit 1
fi

BACKUP_FILE="$1"
AUTO_YES="${2:-}"
VOLUME_NAME="${VOLUME_NAME:-llm-sandbox-home}"
CONTAINER_NAME="${CONTAINER_NAME:-llm-sandbox}"
IMAGE_NAME="${IMAGE_NAME:-llm-sandbox}"

if [[ ! -f "${BACKUP_FILE}" ]]; then
  echo "Error: backup file not found: ${BACKUP_FILE}" >&2
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "Error: docker is required but not installed." >&2
  exit 1
fi

if ! docker image inspect "${IMAGE_NAME}" >/dev/null 2>&1; then
  echo "Error: Docker image '${IMAGE_NAME}' is not available. Build it first (e.g. 'make build')." >&2
  exit 1
fi

if ! docker volume inspect "${VOLUME_NAME}" >/dev/null 2>&1; then
  echo "Volume '${VOLUME_NAME}' does not exist. Creating it..."
  docker volume create "${VOLUME_NAME}" >/dev/null
fi

BACKUP_DIR="$(cd "$(dirname "${BACKUP_FILE}")" && pwd)"
BACKUP_BASENAME="$(basename "${BACKUP_FILE}")"

echo "Restore plan:"
echo "  Backup file: ${BACKUP_DIR}/${BACKUP_BASENAME}"
echo "  Volume:      ${VOLUME_NAME}"
echo "  Container:   ${CONTAINER_NAME}"
echo ""
echo "This will DELETE current contents of volume '${VOLUME_NAME}' and replace them with the backup."

if [[ "${AUTO_YES}" != "--yes" ]]; then
  printf "Proceed with restore? [y/N] "
  read -r ANSWER
  case "${ANSWER}" in
    y|Y|yes|YES) ;;
    *)
      echo "Canceled."
      exit 1
      ;;
  esac
fi

if docker container inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
  if [[ "$(docker container inspect -f '{{.State.Running}}' "${CONTAINER_NAME}")" == "true" ]]; then
    echo "Stopping running container '${CONTAINER_NAME}'..."
    docker stop "${CONTAINER_NAME}" >/dev/null
  fi
fi

echo "Restoring volume '${VOLUME_NAME}' from '${BACKUP_BASENAME}'..."
docker run --rm \
  --entrypoint bash \
  -u root \
  -e BACKUP_BASENAME="${BACKUP_BASENAME}" \
  -v "${VOLUME_NAME}:/restore" \
  -v "${BACKUP_DIR}:/backup:ro" \
  "${IMAGE_NAME}" \
  -lc 'set -euo pipefail; shopt -s dotglob nullglob; rm -rf /restore/*; tar -xzf "/backup/${BACKUP_BASENAME}" -C /restore'

if docker container inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
  echo "Starting container '${CONTAINER_NAME}'..."
  docker start "${CONTAINER_NAME}" >/dev/null
  echo "Restore complete. Container '${CONTAINER_NAME}' is running."
else
  echo "Restore complete. Container '${CONTAINER_NAME}' does not exist yet."
  echo "Create/start it with: make up"
fi
