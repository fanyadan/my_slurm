#!/usr/bin/env bash
set -euo pipefail

# Local Slurm dev environment (3 nodes: 1 controller + 2 compute) via Docker.
# - Works well on macOS because Slurm daemons run inside Linux containers.
# - Creates files under .slurm-local/ and a small ./slurm wrapper (execs into the controller).
#
# Usage:
#   bash setup_slurm_local.sh up
#   ./slurm sinfo
#   ./slurm srun -N3 -n3 hostname
#   bash setup_slurm_local.sh down

ACTION="${1:-up}"
FORCE=0
if [[ "$ACTION" == "--force" ]]; then
  FORCE=1
  ACTION="${2:-up}"
fi

PROJECT_DIR="${SLURM_WORKDIR:-$PWD}"
ROOT_DIR="${SLURM_LOCAL_DIR:-$PWD/.slurm-local}"
WRAPPER_PATH="${SLURM_WRAPPER_PATH:-$PWD/slurm}"

# Controller container name (also used by the host-side ./slurm wrapper).
CONTAINER_NAME="${SLURM_CONTAINER_NAME:-slurm-local}"

# Additional compute nodes (container_name == hostname == NodeName).
NODE1_NAME="${SLURM_NODE1_NAME:-${CONTAINER_NAME}-1}"
NODE2_NAME="${SLURM_NODE2_NAME:-${CONTAINER_NAME}-2}"

# Slurm controller hostname (must be resolvable from other containers).
CTLD_HOST="${SLURM_CTLD_HOST:-${CONTAINER_NAME}}"

# Image tag for all services (built from $ROOT_DIR/Dockerfile).
IMAGE_NAME="${SLURM_IMAGE_NAME:-slurm-local:dev}"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

compose_cmd() {
  # Prefer 'docker compose' (plugin). Fall back to 'docker-compose'.
  if docker compose version >/dev/null 2>&1; then
    echo "docker compose"
    return
  fi
  if command -v docker-compose >/dev/null 2>&1; then
    echo "docker-compose"
    return
  fi
  fail "Docker Compose not found. Install Docker Desktop (macOS) or docker+compose (Linux)."
}

write_file() {
  local path="$1"
  local mode="$2"

  if [[ -e "$path" && "$FORCE" -ne 1 ]]; then
    return
  fi
  umask 022
  cat >"$path"
  chmod "$mode" "$path"
}

ensure_files() {
  mkdir -p "$ROOT_DIR" || fail "Could not create $ROOT_DIR"

  # Always refresh .env so the bind-mount points at the directory you run this from.
  # Also write defaults for Slurm accounting (slurmdbd + MariaDB) so `sacct` works.
  local db_host db_port db_name db_user db_pass db_root_pass db_container_name dbd_port
  db_host="${SLURM_DB_HOST:-mariadb}"
  db_port="${SLURM_DB_PORT:-3306}"
  db_name="${SLURM_DB_NAME:-slurm_acct_db}"
  db_user="${SLURM_DB_USER:-slurm}"
  db_pass="${SLURM_DB_PASS:-slurm}"
  db_root_pass="${SLURM_DB_ROOT_PASS:-slurmroot}"
  db_container_name="${SLURM_DB_CONTAINER_NAME:-${CONTAINER_NAME}-db}"
  dbd_port="${SLURM_DBD_PORT:-6819}"

  # Capture the host user identity so jobs can be submitted as a non-root user inside containers.
  # Users/UIDs are created by entrypoint.sh at container start.
  local host_user_name host_uid host_gid
  host_user_name="${SLURM_HOST_USER_NAME:-$(id -un)}"
  host_uid="${SLURM_HOST_UID:-$(id -u)}"
  host_gid="${SLURM_HOST_GID:-$(id -g)}"

  # Multi-tenant knobs
  local admin_account tenants tenants_dir enable_cgroup privileged tenant_uid_base tenant_gid_base
  admin_account="${SLURM_ADMIN_ACCOUNT:-admin}"
  tenants="${SLURM_TENANTS:-}"
  tenants_dir="${SLURM_TENANTS_DIR:-/work/tenants}"
  tenant_uid_base="${SLURM_TENANT_UID_BASE:-10000}"
  tenant_gid_base="${SLURM_TENANT_GID_BASE:-10000}"
  enable_cgroup="${SLURM_ENABLE_CGROUP:-0}"
  privileged="${SLURM_PRIVILEGED:-false}"

  cat >"$ROOT_DIR/.env" <<EOF
SLURM_WORKDIR=$PROJECT_DIR
SLURM_IMAGE_NAME=$IMAGE_NAME
SLURM_CONTAINER_NAME=$CONTAINER_NAME
SLURM_NODE1_NAME=$NODE1_NAME
SLURM_NODE2_NAME=$NODE2_NAME
SLURM_CTLD_HOST=$CTLD_HOST
SLURM_GPU_COUNT=${SLURM_GPU_COUNT:-}

# Host identity (used to create a matching user inside containers)
SLURM_HOST_USER_NAME=$host_user_name
SLURM_HOST_UID=$host_uid
SLURM_HOST_GID=$host_gid

# Multi-tenant
SLURM_ADMIN_ACCOUNT=$admin_account
SLURM_TENANTS=$tenants
SLURM_TENANTS_DIR=$tenants_dir
SLURM_TENANT_UID_BASE=$tenant_uid_base
SLURM_TENANT_GID_BASE=$tenant_gid_base
SLURM_ENABLE_CGROUP=$enable_cgroup
SLURM_PRIVILEGED=$privileged

SLURM_DB_HOST=$db_host
SLURM_DB_PORT=$db_port
SLURM_DB_NAME=$db_name
SLURM_DB_USER=$db_user
SLURM_DB_PASS=$db_pass
SLURM_DB_ROOT_PASS=$db_root_pass
SLURM_DB_CONTAINER_NAME=$db_container_name
SLURM_DBD_PORT=$dbd_port
EOF

  write_file "$ROOT_DIR/docker-compose.yml" 0644 <<'YAML'
services:
  mariadb:
    image: mariadb:10.11
    container_name: ${SLURM_DB_CONTAINER_NAME}
    hostname: mariadb
    environment:
      - MARIADB_DATABASE=${SLURM_DB_NAME}
      - MARIADB_USER=${SLURM_DB_USER}
      - MARIADB_PASSWORD=${SLURM_DB_PASS}
      - MARIADB_ROOT_PASSWORD=${SLURM_DB_ROOT_PASS}
    volumes:
      - mariadb-data:/var/lib/mysql

  slurmctld:
    build:
      context: .
    image: ${SLURM_IMAGE_NAME}
    container_name: ${SLURM_CONTAINER_NAME}
    hostname: ${SLURM_CONTAINER_NAME}
    privileged: ${SLURM_PRIVILEGED:-false}
    environment:
      - SLURM_ROLE=all
      - SLURM_NODE_NAME=${SLURM_CONTAINER_NAME}
      - SLURM_CTLD_HOST=${SLURM_CTLD_HOST}
      - SLURM_NODE1_NAME=${SLURM_NODE1_NAME}
      - SLURM_NODE2_NAME=${SLURM_NODE2_NAME}
      - SLURM_GPU_COUNT=${SLURM_GPU_COUNT:-}
      - SLURM_DB_HOST=${SLURM_DB_HOST}
      - SLURM_DB_PORT=${SLURM_DB_PORT}
      - SLURM_DB_NAME=${SLURM_DB_NAME}
      - SLURM_DB_USER=${SLURM_DB_USER}
      - SLURM_DB_PASS=${SLURM_DB_PASS}
      - SLURM_DBD_PORT=${SLURM_DBD_PORT}
      - SLURM_HOST_USER_NAME=${SLURM_HOST_USER_NAME:-}
      - SLURM_HOST_UID=${SLURM_HOST_UID:-}
      - SLURM_HOST_GID=${SLURM_HOST_GID:-}
      - SLURM_ADMIN_ACCOUNT=${SLURM_ADMIN_ACCOUNT:-admin}
      - SLURM_TENANTS=${SLURM_TENANTS:-}
      - SLURM_TENANTS_DIR=${SLURM_TENANTS_DIR:-/work/tenants}
      - SLURM_TENANT_UID_BASE=${SLURM_TENANT_UID_BASE:-10000}
      - SLURM_TENANT_GID_BASE=${SLURM_TENANT_GID_BASE:-10000}
      - SLURM_ENABLE_CGROUP=${SLURM_ENABLE_CGROUP:-0}
    volumes:
      - "${SLURM_WORKDIR}:/work"
      - slurm-shared:/shared
    depends_on:
      - mariadb

  slurm1:
    image: ${SLURM_IMAGE_NAME}
    container_name: ${SLURM_NODE1_NAME}
    hostname: ${SLURM_NODE1_NAME}
    privileged: ${SLURM_PRIVILEGED:-false}
    environment:
      - SLURM_ROLE=slurmd
      - SLURM_NODE_NAME=${SLURM_NODE1_NAME}
      - SLURM_CTLD_HOST=${SLURM_CTLD_HOST}
      - SLURM_NODE1_NAME=${SLURM_NODE1_NAME}
      - SLURM_NODE2_NAME=${SLURM_NODE2_NAME}
      - SLURM_GPU_COUNT=${SLURM_GPU_COUNT:-}
      - SLURM_HOST_USER_NAME=${SLURM_HOST_USER_NAME:-}
      - SLURM_HOST_UID=${SLURM_HOST_UID:-}
      - SLURM_HOST_GID=${SLURM_HOST_GID:-}
      - SLURM_ADMIN_ACCOUNT=${SLURM_ADMIN_ACCOUNT:-admin}
      - SLURM_TENANTS=${SLURM_TENANTS:-}
      - SLURM_TENANTS_DIR=${SLURM_TENANTS_DIR:-/work/tenants}
      - SLURM_TENANT_UID_BASE=${SLURM_TENANT_UID_BASE:-10000}
      - SLURM_TENANT_GID_BASE=${SLURM_TENANT_GID_BASE:-10000}
      - SLURM_ENABLE_CGROUP=${SLURM_ENABLE_CGROUP:-0}
    volumes:
      - "${SLURM_WORKDIR}:/work"
      - slurm-shared:/shared
    depends_on:
      - slurmctld

  slurm2:
    image: ${SLURM_IMAGE_NAME}
    container_name: ${SLURM_NODE2_NAME}
    hostname: ${SLURM_NODE2_NAME}
    privileged: ${SLURM_PRIVILEGED:-false}
    environment:
      - SLURM_ROLE=slurmd
      - SLURM_NODE_NAME=${SLURM_NODE2_NAME}
      - SLURM_CTLD_HOST=${SLURM_CTLD_HOST}
      - SLURM_NODE1_NAME=${SLURM_NODE1_NAME}
      - SLURM_NODE2_NAME=${SLURM_NODE2_NAME}
      - SLURM_GPU_COUNT=${SLURM_GPU_COUNT:-}
      - SLURM_HOST_USER_NAME=${SLURM_HOST_USER_NAME:-}
      - SLURM_HOST_UID=${SLURM_HOST_UID:-}
      - SLURM_HOST_GID=${SLURM_HOST_GID:-}
      - SLURM_ADMIN_ACCOUNT=${SLURM_ADMIN_ACCOUNT:-admin}
      - SLURM_TENANTS=${SLURM_TENANTS:-}
      - SLURM_TENANTS_DIR=${SLURM_TENANTS_DIR:-/work/tenants}
      - SLURM_TENANT_UID_BASE=${SLURM_TENANT_UID_BASE:-10000}
      - SLURM_TENANT_GID_BASE=${SLURM_TENANT_GID_BASE:-10000}
      - SLURM_ENABLE_CGROUP=${SLURM_ENABLE_CGROUP:-0}
    volumes:
      - "${SLURM_WORKDIR}:/work"
      - slurm-shared:/shared
    depends_on:
      - slurmctld

volumes:
  slurm-shared:
  mariadb-data:
YAML

  write_file "$ROOT_DIR/Dockerfile" 0644 <<'DOCKER'
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get -o Acquire::Retries=5 update \
 && apt-get -o Acquire::Retries=5 install -y --no-install-recommends --fix-missing \
    ca-certificates \
    bash \
    procps \
    iproute2 \
    tini \
    gosu \
    netcat-openbsd \
    munge \
    python3 \
    python3-pip \
    python3-venv \
    python3-dev \
    python-is-python3 \
    build-essential \
    pkg-config \
    mpich \
    libmpich-dev \
    slurm-client \
    slurmctld \
    slurmd \
    slurmdbd \
    mariadb-client \
 && rm -rf /var/lib/apt/lists/*

# Python deps for common job scripts (keeps Slurm image self-contained)
RUN MPICC=mpicc python3 -m pip install --no-cache-dir --no-binary=mpi4py \
    requests \
    huggingface_hub \
    numpy \
    torch \
    pydantic \
    langchain \
    langchain-core \
    langgraph \
    mpi4py

COPY entrypoint.sh /entrypoint.sh
COPY slurm.conf.template /slurm.conf.template

RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/usr/bin/tini", "--", "/entrypoint.sh"]
DOCKER

  write_file "$ROOT_DIR/slurm.conf.template" 0644 <<'CONF'
# Minimal 3-node Slurm config (controller + 2 nodes).
# This is rendered at container start by replacing @CTLD@, @NODE1@, @NODE2@, @CPUS@, @MEM_MB@.

ClusterName=local

SlurmctldHost=@CTLD@
SlurmctldPort=6817
SlurmdPort=6818

AuthType=auth/munge
CryptoType=crypto/munge

SlurmUser=slurm
SlurmdUser=root

StateSaveLocation=/var/spool/slurmctld
SlurmdSpoolDir=/var/spool/slurmd
SlurmctldPidFile=/run/slurmctld.pid
SlurmdPidFile=/run/slurmd.pid

SwitchType=switch/none
MpiDefault=none
ProctrackType=@PROCTRACK_TYPE@
TaskPlugin=@TASK_PLUGIN@

ReturnToService=2
SlurmctldTimeout=300
SlurmdTimeout=300
InactiveLimit=0
KillWait=30
MinJobAge=300

SchedulerType=sched/backfill
SelectType=select/cons_tres
SelectTypeParameters=CR_Core

# Generic resources (GRES)
# NOTE: In this local Docker setup we can optionally expose host GPUs to a single node
# (the controller/compute node) and then group it in a "gpu" partition.
GresTypes=gpu

SlurmctldLogFile=/var/log/slurm/slurmctld.log
SlurmdLogFile=/var/log/slurm/slurmd.log
SlurmctldDebug=info
SlurmdDebug=info

# Accounting (required for sacct)
JobAcctGatherType=jobacct_gather/linux
JobAcctGatherFrequency=30

AccountingStorageType=accounting_storage/slurmdbd
AccountingStorageHost=@CTLD@
AccountingStoragePort=6819
AccountingStorageEnforce=limits,qos,associations

# Nodes / partitions
# - @NODE1_GRES@ / @NODE2_GRES@ are rendered by entrypoint.sh (empty if no GPUs are configured).
NodeName=@CTLD@  NodeAddr=@CTLD@  CPUs=@CPUS@ RealMemory=@MEM_MB@ State=UNKNOWN
NodeName=@NODE1@ NodeAddr=@NODE1@ CPUs=@CPUS@ RealMemory=@MEM_MB@ @NODE1_GRES@ State=UNKNOWN
NodeName=@NODE2@ NodeAddr=@NODE2@ CPUs=@CPUS@ RealMemory=@MEM_MB@ @NODE2_GRES@ State=UNKNOWN

# Admin/debug partition (default)
PartitionName=debug Nodes=@CTLD@,@NODE1@,@NODE2@ Default=YES MaxTime=INFINITE State=UP @DEBUG_PARTITION_ACCESS@

# Admin GPU partition (compute nodes only; controller excluded)
PartitionName=gpu Nodes=@NODE1@,@NODE2@ Default=NO MaxTime=INFINITE State=UP @GPU_PARTITION_ACCESS@

# Tenant partitions (generated by entrypoint.sh from SLURM_TENANTS)
@TENANT_PARTITIONS@
CONF

  write_file "$ROOT_DIR/entrypoint.sh" 0755 <<'ENTRY'
#!/usr/bin/env bash
set -euo pipefail

ROLE="${SLURM_ROLE:-all}"

NODE_NAME="${SLURM_NODE_NAME:-$(hostname)}"
CTLD_HOST="${SLURM_CTLD_HOST:-slurm-local}"
NODE1_NAME="${SLURM_NODE1_NAME:-${CTLD_HOST}-1}"
NODE2_NAME="${SLURM_NODE2_NAME:-${CTLD_HOST}-2}"

DB_HOST="${SLURM_DB_HOST:-mariadb}"
DB_PORT="${SLURM_DB_PORT:-3306}"
DB_NAME="${SLURM_DB_NAME:-slurm_acct_db}"
DB_USER="${SLURM_DB_USER:-slurm}"
DB_PASS="${SLURM_DB_PASS:-slurm}"
DBD_PORT="${SLURM_DBD_PORT:-6819}"

# Multi-tenant config
ADMIN_ACCOUNT="${SLURM_ADMIN_ACCOUNT:-admin}"
TENANTS_RAW="${SLURM_TENANTS:-}"
TENANTS_DIR="${SLURM_TENANTS_DIR:-/work/tenants}"
TENANT_UID_BASE="${SLURM_TENANT_UID_BASE:-10000}"
TENANT_GID_BASE="${SLURM_TENANT_GID_BASE:-10000}"

# Host identity (optional): create a matching login user inside containers.
HOST_USER_NAME="${SLURM_HOST_USER_NAME:-}"
HOST_UID_RAW="${SLURM_HOST_UID:-}"
HOST_GID_RAW="${SLURM_HOST_GID:-}"

# Optional: enable Slurm cgroups (requires sufficient container permissions; see README)
ENABLE_CGROUP_RAW="${SLURM_ENABLE_CGROUP:-0}"
ENABLE_CGROUP=0
if [[ "${ENABLE_CGROUP_RAW,,}" =~ ^(1|true|yes)$ ]]; then
  ENABLE_CGROUP=1
fi

declare -a TENANT_NAMES=()
declare -a TENANT_UIDS=()
declare -a TENANT_GIDS=()

# GPU config (optional)
# SLURM_GPU_COUNT is the total number of GPUs to model across the GPU partition.
# We split them across NODE1 and NODE2 so the controller node stays out of GPU scheduling.
GPU_COUNT_RAW="${SLURM_GPU_COUNT:-}"
GPU_COUNT=0
if [[ "${GPU_COUNT_RAW}" =~ ^[0-9]+$ ]]; then
  GPU_COUNT="${GPU_COUNT_RAW}"
fi

GPU_COUNT_NODE1=$(( (GPU_COUNT + 1) / 2 ))
GPU_COUNT_NODE2=$(( GPU_COUNT / 2 ))

NODE1_GRES=""
NODE2_GRES=""
if [[ "${GPU_COUNT_NODE1}" -gt 0 ]]; then
  NODE1_GRES="Gres=gpu:${GPU_COUNT_NODE1}"
fi
if [[ "${GPU_COUNT_NODE2}" -gt 0 ]]; then
  NODE2_GRES="Gres=gpu:${GPU_COUNT_NODE2}"
fi

SHARED_DIR="/shared"
MUNGE_SHARED_KEY="${SHARED_DIR}/munge.key"

ensure_user() {
  local user="$1"
  local home="$2"
  if id -u "$user" >/dev/null 2>&1; then
    return
  fi
  useradd --system --create-home --home-dir "$home" --shell /usr/sbin/nologin "$user"
}

ensure_login_user_with_ids() {
  local user="$1"
  local uid="$2"
  local gid="$3"

  if id -u "$user" >/dev/null 2>&1; then
    return
  fi

  if getent passwd "$uid" >/dev/null 2>&1; then
    echo "ERROR: UID $uid already exists in container; cannot create user '$user'" >&2
    exit 1
  fi

  # If the GID already exists, reuse that group; otherwise create a dedicated group.
  if ! getent group "$gid" >/dev/null 2>&1; then
    if ! getent group "$user" >/dev/null 2>&1; then
      groupadd -g "$gid" "$user"
    fi
  fi

  useradd --uid "$uid" --gid "$gid" --create-home --home-dir "/home/$user" --shell /bin/bash "$user"
}

trim_ws() {
  local s="$1"
  # trim leading
  s="${s#"${s%%[![:space:]]*}"}"
  # trim trailing
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

parse_tenants() {
  local raw="$1"
  local idx=0

  if [[ -z "$raw" ]]; then
    return
  fi

  local item name uid gid
  IFS=',' read -r -a items <<<"$raw"
  for item in "${items[@]}"; do
    item="$(trim_ws "$item")"
    [[ -z "$item" ]] && continue

    name=""
    uid=""
    gid=""

    IFS=':' read -r name uid gid <<<"$item"
    name="$(trim_ws "$name")"
    name="${name,,}"

    if [[ -z "$name" || ! "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
      echo "WARN: skipping invalid tenant spec: '$item'" >&2
      continue
    fi

    if [[ -z "${uid:-}" ]]; then
      uid=$((TENANT_UID_BASE + idx))
    fi
    if [[ -z "${gid:-}" ]]; then
      gid=$((TENANT_GID_BASE + idx))
    fi

    if [[ ! "$uid" =~ ^[0-9]+$ || ! "$gid" =~ ^[0-9]+$ ]]; then
      echo "WARN: skipping tenant with non-numeric uid/gid: '$item'" >&2
      continue
    fi

    TENANT_NAMES+=("$name")
    TENANT_UIDS+=("$uid")
    TENANT_GIDS+=("$gid")
    idx=$((idx + 1))
  done
}

parse_tenants "$TENANTS_RAW"

wait_for_tcp() {
  local host="$1"
  local port="$2"
  local retries="${3:-60}"

  for _ in $(seq 1 "$retries"); do
    if nc -z "$host" "$port" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

bootstrap_accounting() {
  local cluster
  cluster="$(awk -F= '/^ClusterName=/{print $2; exit}' /etc/slurm/slurm.conf 2>/dev/null || true)"
  cluster="${cluster:-local}"

  for _ in $(seq 1 60); do
    if sacctmgr -n list cluster >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done

  sacctmgr -i add cluster "$cluster" >/dev/null 2>&1 || true

  # Admin account (cluster operators)
  sacctmgr -i add account "$ADMIN_ACCOUNT" Description="Admin account" >/dev/null 2>&1 || true
  sacctmgr -i add user root Account="$ADMIN_ACCOUNT" DefaultAccount="$ADMIN_ACCOUNT" >/dev/null 2>&1 || true

  if [[ -n "${HOST_USER_NAME}" ]]; then
    sacctmgr -i add user "$HOST_USER_NAME" Account="$ADMIN_ACCOUNT" DefaultAccount="$ADMIN_ACCOUNT" >/dev/null 2>&1 || true
  fi

  # Tenants: 1 tenant == 1 Slurm account + 1 Unix user (same name)
  local i t
  for i in "${!TENANT_NAMES[@]}"; do
    t="${TENANT_NAMES[$i]}"
    sacctmgr -i add account "$t" Description="Tenant account: $t" >/dev/null 2>&1 || true
    sacctmgr -i add user "$t" Account="$t" DefaultAccount="$t" >/dev/null 2>&1 || true
  done
}

ensure_user munge /nonexistent
ensure_user slurm /var/lib/slurm

# Create a host-matching login user (so sbatch/srun can run as non-root by default).
HOST_UID=""
HOST_GID=""
if [[ "${HOST_UID_RAW}" =~ ^[0-9]+$ ]]; then
  HOST_UID="${HOST_UID_RAW}"
fi
if [[ "${HOST_GID_RAW}" =~ ^[0-9]+$ ]]; then
  HOST_GID="${HOST_GID_RAW}"
fi

if [[ -n "${HOST_USER_NAME}" && -n "${HOST_UID}" && -n "${HOST_GID}" ]]; then
  ensure_login_user_with_ids "$HOST_USER_NAME" "$HOST_UID" "$HOST_GID"
fi

# Ensure admin Unix group exists and include the host user.
# We use AllowGroups in partitions for access control (more reliable than AllowAccounts in this dev setup).
if [[ -n "${ADMIN_ACCOUNT}" ]]; then
  if ! getent group "$ADMIN_ACCOUNT" >/dev/null 2>&1; then
    groupadd "$ADMIN_ACCOUNT" >/dev/null 2>&1 || true
  fi
  if [[ -n "${HOST_USER_NAME}" ]] && id -u "$HOST_USER_NAME" >/dev/null 2>&1; then
    usermod -aG "$ADMIN_ACCOUNT" "$HOST_USER_NAME" >/dev/null 2>&1 || true
  fi
fi

# Create tenant users and their home directories.
for i in "${!TENANT_NAMES[@]}"; do
  ensure_login_user_with_ids "${TENANT_NAMES[$i]}" "${TENANT_UIDS[$i]}" "${TENANT_GIDS[$i]}"
done

# Create per-tenant work directories under the shared /work mount.
if [[ "${#TENANT_NAMES[@]}" -gt 0 ]]; then
  mkdir -p "$TENANTS_DIR" || true
  chmod 0755 "$TENANTS_DIR" || true

  for i in "${!TENANT_NAMES[@]}"; do
    d="$TENANTS_DIR/${TENANT_NAMES[$i]}"
    mkdir -p "$d" || true
    chown "${TENANT_UIDS[$i]}:${TENANT_GIDS[$i]}" "$d" || true
    chmod 0750 "$d" || true
  done
fi

# Shared munge key so auth works across containers.
install -d -m 0755 "$SHARED_DIR"
if [[ "$ROLE" == "all" || "$ROLE" == "ctld" ]]; then
  if [[ ! -f "$MUNGE_SHARED_KEY" ]]; then
    dd if=/dev/urandom of="$MUNGE_SHARED_KEY" bs=1 count=1024 status=none
    chmod 0400 "$MUNGE_SHARED_KEY"
  fi
fi

# Wait for munge key to exist (compute nodes depend on it).
for _ in $(seq 1 60); do
  if [[ -f "$MUNGE_SHARED_KEY" ]]; then
    break
  fi
  sleep 0.5
done
if [[ ! -f "$MUNGE_SHARED_KEY" ]]; then
  echo "ERROR: munge key not found at $MUNGE_SHARED_KEY" >&2
  exit 1
fi

# Munge runtime dirs + key
install -d -m 0700 -o munge -g munge /etc/munge
cp "$MUNGE_SHARED_KEY" /etc/munge/munge.key
chown munge:munge /etc/munge/munge.key
chmod 0400 /etc/munge/munge.key
install -d -m 0755 -o munge -g munge /run/munge /var/log/munge

# Slurm dirs
install -d -m 0755 -o slurm -g slurm /var/spool/slurmctld /var/log/slurm
install -d -m 0755 /var/spool/slurmd

# Render slurm.conf (support both /etc/slurm and /etc/slurm-llnl, since distros vary)
CPUS="$(nproc)"
MEM_MB="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)"

install -d -m 0755 /etc/slurm /etc/slurm-llnl

PROCTRACK_TYPE="proctrack/linuxproc"
TASK_PLUGIN="task/none"
if [[ "$ENABLE_CGROUP" -eq 1 ]]; then
  PROCTRACK_TYPE="proctrack/cgroup"
  TASK_PLUGIN="task/cgroup"
fi

DEBUG_PARTITION_ACCESS=""
GPU_PARTITION_ACCESS=""
if [[ -n "$ADMIN_ACCOUNT" ]]; then
  # Allow teama to use the admin partitions (debug/gpu) alongside the admin account.
  admin_part_allow_groups="${ADMIN_ACCOUNT},teama"
  admin_part_allow_accounts="${ADMIN_ACCOUNT},teama"
  DEBUG_PARTITION_ACCESS="AllowGroups=${admin_part_allow_groups} AllowAccounts=${admin_part_allow_accounts}"
  GPU_PARTITION_ACCESS="AllowGroups=${admin_part_allow_groups} AllowAccounts=${admin_part_allow_accounts}"
fi

TENANT_PARTITIONS=""
for i in "${!TENANT_NAMES[@]}"; do
  t="${TENANT_NAMES[$i]}"

  tenant_allow_groups="$t"
  tenant_allow_accounts="$t"
  if [[ -n "$ADMIN_ACCOUNT" ]]; then
    tenant_allow_groups="$t,$ADMIN_ACCOUNT"
    tenant_allow_accounts="$t,$ADMIN_ACCOUNT"
  fi

  TENANT_PARTITIONS+="PartitionName=${t} Nodes=${NODE1_NAME},${NODE2_NAME} Default=NO MaxTime=INFINITE State=UP AllowGroups=${tenant_allow_groups} AllowAccounts=${tenant_allow_accounts}"$'\n'
done
TENANT_PARTITIONS="${TENANT_PARTITIONS%$'\n'}"

TMP_CONF="$(mktemp)"
sed -e "s|@CTLD@|${CTLD_HOST}|g" \
    -e "s|@NODE1@|${NODE1_NAME}|g" \
    -e "s|@NODE2@|${NODE2_NAME}|g" \
    -e "s|@NODE1_GRES@|${NODE1_GRES}|g" \
    -e "s|@NODE2_GRES@|${NODE2_GRES}|g" \
    -e "s|@PROCTRACK_TYPE@|${PROCTRACK_TYPE}|g" \
    -e "s|@TASK_PLUGIN@|${TASK_PLUGIN}|g" \
    -e "s|@DEBUG_PARTITION_ACCESS@|${DEBUG_PARTITION_ACCESS}|g" \
    -e "s|@GPU_PARTITION_ACCESS@|${GPU_PARTITION_ACCESS}|g" \
    -e "s|@CPUS@|${CPUS}|g" \
    -e "s|@MEM_MB@|${MEM_MB}|g" \
    /slurm.conf.template > "$TMP_CONF"

awk -v tp="$TENANT_PARTITIONS" '{ if ($0 == "@TENANT_PARTITIONS@") { if (tp != "") print tp; next } print }' "$TMP_CONF" > /etc/slurm/slurm.conf
rm -f "$TMP_CONF"

cp /etc/slurm/slurm.conf /etc/slurm-llnl/slurm.conf

# Optional: Slurm cgroup plugin configuration
if [[ "$ENABLE_CGROUP" -eq 1 ]]; then
  cat >/etc/slurm/cgroup.conf <<'EOF'
CgroupAutomount=yes
ConstrainCores=yes
ConstrainRAMSpace=yes
EOF
  cp /etc/slurm/cgroup.conf /etc/slurm-llnl/cgroup.conf
fi

# Render gres.conf for the local node (slurmd reads this) so GRES matches slurm.conf.
: > /etc/slurm/gres.conf

LOCAL_GPU_COUNT=0
if [[ "${NODE_NAME}" == "${NODE1_NAME}" ]]; then
  LOCAL_GPU_COUNT="${GPU_COUNT_NODE1}"
elif [[ "${NODE_NAME}" == "${NODE2_NAME}" ]]; then
  LOCAL_GPU_COUNT="${GPU_COUNT_NODE2}"
fi

if [[ "${LOCAL_GPU_COUNT}" -gt 0 ]]; then
  if ls /dev/nvidia[0-9]* >/dev/null 2>&1; then
    # Real NVIDIA devices present
    i=0
    for f in /dev/nvidia[0-9]*; do
      echo "NodeName=${NODE_NAME} Name=gpu File=${f}" >> /etc/slurm/gres.conf
      i=$((i + 1))
      [[ $i -ge $LOCAL_GPU_COUNT ]] && break
    done
  else
    # No real GPUs: create placeholder files so Slurm can still schedule against gpu:X
    for i in $(seq 0 $((LOCAL_GPU_COUNT - 1))); do
      f="/dev/fakegpu${i}"
      touch "${f}"
      echo "NodeName=${NODE_NAME} Name=gpu File=${f}" >> /etc/slurm/gres.conf
    done
  fi
fi

cp /etc/slurm/gres.conf /etc/slurm-llnl/gres.conf

export SLURM_CONF=/etc/slurm/slurm.conf

touch /var/log/slurm/slurmctld.log /var/log/slurm/slurmd.log /var/log/slurm/slurmdbd.log
chown slurm:slurm /var/log/slurm/slurmctld.log /var/log/slurm/slurmdbd.log || true

# slurmdbd.conf (controller only)
if [[ "$ROLE" == "all" || "$ROLE" == "ctld" ]]; then
  cat >/etc/slurm/slurmdbd.conf <<EOF
AuthType=auth/munge
DbdHost=${CTLD_HOST}
DbdPort=${DBD_PORT}
SlurmUser=slurm
LogFile=/var/log/slurm/slurmdbd.log
PidFile=/run/slurmdbd.pid
StorageType=accounting_storage/mysql
StorageHost=${DB_HOST}
StoragePort=${DB_PORT}
StorageUser=${DB_USER}
StoragePass=${DB_PASS}
StorageLoc=${DB_NAME}
EOF
  chmod 0600 /etc/slurm/slurmdbd.conf
  chown slurm:slurm /etc/slurm/slurmdbd.conf
  cp /etc/slurm/slurmdbd.conf /etc/slurm-llnl/slurmdbd.conf
fi

pids=()

# NOTE: Slurm uses Munge for auth; Slurmctld runs as 'slurm'; Slurmd runs as root.
gosu munge munged --foreground &
pids+=("$!")

if [[ "$ROLE" == "all" || "$ROLE" == "ctld" ]]; then
  if ! wait_for_tcp "$DB_HOST" "$DB_PORT" 90; then
    echo "ERROR: accounting DB not reachable at ${DB_HOST}:${DB_PORT}" >&2
    exit 1
  fi

  gosu slurm slurmdbd -D &
  pids+=("$!")

  bootstrap_accounting

  gosu slurm slurmctld -D &
  pids+=("$!")
fi

if [[ "$ROLE" == "all" || "$ROLE" == "slurmd" ]]; then
  slurmd -D &
  pids+=("$!")
fi

# Bring nodes up if they start in a drained state (only from controller).
if [[ "$ROLE" == "all" || "$ROLE" == "ctld" ]]; then
  for _ in $(seq 1 60); do
    if sinfo >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done
  for n in "$CTLD_HOST" "$NODE1_NAME" "$NODE2_NAME"; do
    scontrol update NodeName="$n" State=RESUME >/dev/null 2>&1 || true
  done
fi

# Stream logs to container stdout for easy debugging
TAIL_PID=""
if command -v tail >/dev/null 2>&1; then
  tail -n+1 -F /var/log/slurm/slurmdbd.log /var/log/slurm/slurmctld.log /var/log/slurm/slurmd.log &
  TAIL_PID=$!
fi

# Exit if any daemon exits
wait -n "${pids[@]}"
code=$?

kill "$TAIL_PID" "${pids[@]}" >/dev/null 2>&1 || true
exit "$code"
ENTRY

  # Host-side wrapper
  if [[ -e "$WRAPPER_PATH" && "$FORCE" -ne 1 ]]; then
    return
  fi

  cat >"$WRAPPER_PATH" <<'WRAP'
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
WRAP
  chmod 0755 "$WRAPPER_PATH"
}

cmd_up() {
  need_cmd docker
  local compose
  compose="$(compose_cmd)"

  ensure_files

  (
    cd "$ROOT_DIR"
    # shellcheck disable=SC2086
    $compose up -d --build
  )

  echo "Slurm is up. Try: $WRAPPER_PATH sinfo"
  echo "Nodes: $CONTAINER_NAME, $NODE1_NAME, $NODE2_NAME"
}

cmd_down() {
  local compose
  compose="$(compose_cmd)"

  if [[ ! -d "$ROOT_DIR" ]]; then
    echo "Nothing to do (missing $ROOT_DIR)."
    return
  fi

  (
    cd "$ROOT_DIR"
    # shellcheck disable=SC2086
    $compose down
  )
}

cmd_logs() {
  need_cmd docker
  local compose
  compose="$(compose_cmd)"

  (
    cd "$ROOT_DIR"
    # shellcheck disable=SC2086
    $compose logs -f --tail=200
  )
}

usage() {
  cat <<EOF
Usage:
  bash setup_slurm_local.sh [--force] up      # build + start local Slurm in Docker
  bash setup_slurm_local.sh down             # stop
  bash setup_slurm_local.sh logs             # follow container logs

Files:
  $ROOT_DIR/   (compose + Dockerfile + config)
  $WRAPPER_PATH (host-side helper to run sinfo/srun/sbatch inside the controller container)

Notes:
  - This is a local dev setup (3 nodes: controller + 2 compute, partition 'debug').
  - If you meant "set up Slurm on real Linux nodes" (controller/compute), tell me your distro + topology.
EOF
}

case "$ACTION" in
  up) cmd_up ;;
  down) cmd_down ;;
  logs) cmd_logs ;;
  -h|--help|help) usage ;;
  *)
    usage
    fail "Unknown action: $ACTION"
    ;;
esac
