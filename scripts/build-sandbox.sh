#!/bin/sh
# Builds the Docker image that mac-exec runs sandbox commands in. Run it once after cloning,
# and again after sandbox/Dockerfile changes. Docker Desktop must be running.
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
image="${MAC_EXEC_IMAGE:-mac-exec-sandbox:latest}"

if ! command -v docker >/dev/null 2>&1; then
  echo "docker was not found. Install Docker Desktop and start it first." >&2
  exit 1
fi
if ! docker info >/dev/null 2>&1; then
  echo "Docker is not running. Start Docker Desktop, wait until it is ready, then run this again." >&2
  exit 1
fi

docker build --pull -t "$image" "$project_dir/sandbox"
echo "Built $image."
