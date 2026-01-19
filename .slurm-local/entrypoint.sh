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
# Use cgroup v2 when available (Docker Desktop uses cgroup v2).
CgroupPlugin=autodetect

# This dev image doesn't run systemd; avoid D-Bus/systemd scope management.
IgnoreSystemd=yes

# Help in container environments where controllers may not be enabled by default.
EnableControllers=yes

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
