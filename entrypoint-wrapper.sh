#!/usr/bin/env bash
# Fix ownership of /home/gem when mounted as a Docker volume (created root-owned)
chown "$USER_UID:$USER_GID" /home/gem
exec /opt/gem/run.sh "$@"
