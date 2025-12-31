#!/usr/bin/env bash
set -euo pipefail

CONTAINER_NAME="${SLURM_CONTAINER_NAME:-slurm-local}"

in_container() {
  [[ -f "/.dockerenv" ]] && return 0
  [[ -r "/proc/1/cgroup" ]] && grep -qE '(docker|containerd|kubepods|podman)' /proc/1/cgroup && return 0
  return 1
}

if ! command -v docker >/dev/null 2>&1; then
  if in_container; then
    cat >&2 <<EOF
ERROR: 'docker' is not available in this environment.

This ./slurm script is a host-side wrapper that uses Docker to exec into the '$CONTAINER_NAME' container.
If you're already inside the container (or inside an srun step), run Slurm commands directly, e.g.:
  sinfo
  srun -n1 hostname

If you meant to target a specific node, use:
  srun -w <node> -n1 hostname
(See: sinfo)
EOF
  else
    echo "ERROR: 'docker' command not found. Install Docker Desktop (macOS) or add docker to PATH." >&2
  fi
  exit 127
fi

ps_names=""
if ! ps_names="$(docker ps --format '{{.Names}}')"; then
  echo "ERROR: Failed to run 'docker ps'. Is Docker running?" >&2
  exit 1
fi

if ! grep -qx "$CONTAINER_NAME" <<<"$ps_names"; then
  echo "Container '$CONTAINER_NAME' is not running." >&2
  echo "Start it with: bash setup_slurm_local.sh up" >&2
  exit 1
fi

# Map the host's current working directory into the container.
# Docker Compose bind-mounts $SLURM_WORKDIR -> /work, but the wrapper used to always
# exec with -w /work. If you run ./slurm from a subdirectory, Slurm would fail to
# find relative paths like job.sh.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ENV_FILE="${SLURM_ENV_FILE:-$SCRIPT_DIR/.slurm-local/.env}"

# Prefer an explicit env var; fall back to the generated compose .env file.
if [[ -z "${SLURM_WORKDIR:-}" && -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  set -a
  source "$ENV_FILE"
  set +a
fi

WORKDIR_IN_CONTAINER="/work"
if [[ -n "${SLURM_WORKDIR:-}" ]]; then
  HOST_PWD="$(pwd -P)"
  MOUNT_ROOT="${SLURM_WORKDIR%/}"

  # Normalize symlinks so /Users/... (logical) matches /Volumes/... (physical).
  if MOUNT_ROOT_P="$(cd "$MOUNT_ROOT" 2>/dev/null && pwd -P)"; then
    MOUNT_ROOT="$MOUNT_ROOT_P"
  fi

  if [[ "$HOST_PWD" == "$MOUNT_ROOT" ]]; then
    WORKDIR_IN_CONTAINER="/work"
  elif [[ "$HOST_PWD" == "$MOUNT_ROOT/"* ]]; then
    REL="${HOST_PWD#"$MOUNT_ROOT/"}"
    WORKDIR_IN_CONTAINER="/work/$REL"
  fi
fi

# Choose which user to exec as inside the controller container.
# - Default: run as the *host* uid:gid (so Slurm sees non-root users and can enforce multi-tenant policies).
# - Override:
#   - SLURM_EXEC_USER=<name|uid[:gid]>
#   - SLURM_EXEC_UID=<uid> and/or SLURM_EXEC_GID=<gid>
EXEC_USER_ARGS=()
if [[ -n "${SLURM_EXEC_USER:-}" ]]; then
  EXEC_USER_ARGS+=( -u "${SLURM_EXEC_USER}" )
elif [[ -n "${SLURM_EXEC_UID:-}" || -n "${SLURM_EXEC_GID:-}" ]]; then
  uid="${SLURM_EXEC_UID:-$(id -u)}"
  gid="${SLURM_EXEC_GID:-$(id -g)}"
  EXEC_USER_ARGS+=( -u "${uid}:${gid}" )
else
  EXEC_USER_ARGS+=( -u "$(id -u):$(id -g)" )
fi

# Pass selected host env vars through to the exec'd command inside the container.
# This keeps secrets out of repo files while still making them available to sbatch/srun.
EXTRA_ENV_ARGS=()
[[ -n "${HF_TOKEN:-}" ]] && EXTRA_ENV_ARGS+=( -e HF_TOKEN )
[[ -n "${HUGGINGFACEHUB_API_TOKEN:-}" ]] && EXTRA_ENV_ARGS+=( -e HUGGINGFACEHUB_API_TOKEN )
[[ -n "${HF_API_KEY:-}" ]] && EXTRA_ENV_ARGS+=( -e HF_API_KEY )
[[ -n "${NEWS_API_KEY:-}" ]] && EXTRA_ENV_ARGS+=( -e NEWS_API_KEY )

if [[ $# -eq 0 ]]; then
  exec docker exec -it "${EXEC_USER_ARGS[@]}" "${EXTRA_ENV_ARGS[@]}" -w "$WORKDIR_IN_CONTAINER" "$CONTAINER_NAME" bash
fi

exec docker exec -it "${EXEC_USER_ARGS[@]}" "${EXTRA_ENV_ARGS[@]}" -w "$WORKDIR_IN_CONTAINER" "$CONTAINER_NAME" "$@"
