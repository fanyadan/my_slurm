# my_slurm: local Slurm cluster (Docker)
This repo provides a reproducible **local Slurm dev environment** (3 nodes: **1 controller + 2 compute nodes**) using Docker.

Prereqs:
- Docker
- Docker Compose (`docker compose` plugin or `docker-compose`)

This setup runs Slurm daemons inside Linux containers, which makes it practical on machines that don’t run Slurm natively.

It’s intended for:
- Validating `sbatch`/`srun` scripts locally.
- Testing multi-node / multi-rank launches (e.g., `torch.distributed`) without a real cluster.
- Getting `sacct` working locally via `slurmdbd` + MariaDB.

## Quick start
1) Start the local cluster:
```bash
bash setup_slurm_local.sh up
```

2) Verify Slurm sees the nodes/partitions:
```bash
./slurm sinfo
./slurm srun -N3 -n3 hostname
```

3) Submit the example job:
```bash
./slurm sbatch job.sh
```

4) Follow container logs:
```bash
bash setup_slurm_local.sh logs
```

5) Stop the cluster:
```bash
bash setup_slurm_local.sh down
```

Tip: `./slurm` with **no args** opens an interactive shell inside the controller container.

## High-level architecture
The Docker Compose stack in `.slurm-local/docker-compose.yml` runs:
- **`mariadb`**: accounting database (used by `slurmdbd`).
- **`slurmctld`** (container name defaults to `slurm-local`): runs `munged`, `slurmdbd`, `slurmctld`, and also a `slurmd` (because `SLURM_ROLE=all`).
- **`slurm1`** (`slurm-local-1`): compute node running `munged` + `slurmd`.
- **`slurm2`** (`slurm-local-2`): compute node running `munged` + `slurmd`.

All Slurm containers bind-mount the host **work directory** at:
- Host: `${SLURM_WORKDIR}`
- Container: `/work`

This is how your job scripts and code are visible inside the cluster.

## Repository layout
- `setup_slurm_local.sh`: generates/updates `.slurm-local/` and manages `docker compose up/down/logs`.
- `slurm`: host-side helper wrapper that runs Slurm commands inside the controller container.
- `.slurm-local/`: compose + Dockerfile + entrypoint + Slurm config template.
- `job.sh`: example Slurm batch script that launches a distributed workload.

## `setup_slurm_local.sh`
### Commands
```bash
bash setup_slurm_local.sh up
bash setup_slurm_local.sh down
bash setup_slurm_local.sh logs

# regenerate template files (Dockerfile, compose, entrypoint, slurm.conf template, wrapper)
bash setup_slurm_local.sh --force up
```

### Compose selection
The script prefers `docker compose` (Compose plugin). If that’s unavailable, it falls back to `docker-compose`.

### What it writes
- Always (re)writes: `.slurm-local/.env`
  - This is refreshed every `up` so the bind-mount points at the directory you ran the script from (unless you override with env vars).
- Writes only if missing (or if `--force`):
  - `.slurm-local/docker-compose.yml`
  - `.slurm-local/Dockerfile`
  - `.slurm-local/entrypoint.sh`
  - `.slurm-local/slurm.conf.template`
  - `./slurm` wrapper

### Configuration (environment variables)
You can override most behavior by exporting env vars when running `setup_slurm_local.sh`.

Core paths/names:
- `SLURM_WORKDIR`: host directory to mount at `/work` in containers. Default: current directory when you run the script.
- `SLURM_LOCAL_DIR`: where generated compose/config files live. Default: `./.slurm-local`.
- `SLURM_WRAPPER_PATH`: path to the generated wrapper. Default: `./slurm`.
- `SLURM_CONTAINER_NAME`: controller container name (also the default `SlurmctldHost`). Default: `slurm-local`.
- `SLURM_NODE1_NAME`, `SLURM_NODE2_NAME`: compute container names/hostnames. Defaults: `${SLURM_CONTAINER_NAME}-1` and `-2`.
- `SLURM_CTLD_HOST`: Slurm controller hostname used in config. Default: `${SLURM_CONTAINER_NAME}`.
- `SLURM_IMAGE_NAME`: image tag to build/run. Default: `slurm-local:dev`.

GPU modeling:
- `SLURM_GPU_COUNT`: optional integer. Total GPUs to *model* across the **gpu partition**.
  - At container start, GPUs are split across node1/node2.
  - If `/dev/nvidia*` exists in the container, `gres.conf` is built from real devices.
  - Otherwise placeholder files `/dev/fakegpuN` are created so Slurm can still schedule against `gpu:X`.

Accounting (for `sacct`):
- `SLURM_DB_HOST`, `SLURM_DB_PORT`
- `SLURM_DB_NAME`, `SLURM_DB_USER`
- `SLURM_DB_PASS`, `SLURM_DB_ROOT_PASS`
- `SLURM_DB_CONTAINER_NAME`
- `SLURM_DBD_PORT` (defaults to 6819)

Security note: these defaults are meant for **local dev only**.

### Common “workdir” gotcha
The example `job.sh` runs:
- `python3 /work/my_agent/news_agent_hf_toolcall.py`
- `python3 /work/my_agent/news_agent_langchain.py`

That means **`/work` must contain a `my_agent/` directory**.

If your directory structure is:
```
<parent>/
  my_slurm/
  my_agent/
```
then run setup from `<parent>` (or set `SLURM_WORKDIR=<parent>`) so both projects appear under `/work`.

Example:
```bash
SLURM_WORKDIR="$(pwd -P)/.." bash setup_slurm_local.sh up
```

## `./slurm` wrapper
`slurm` is a convenience script that:
- Verifies Docker is available and the controller container is running.
- `docker exec`s into the controller container and runs the Slurm command you pass.
- Maps your **current host directory** into the correct `/work/...` path inside the container so relative paths like `job.sh` work even from subdirectories.

It also supports:
- `SLURM_CONTAINER_NAME`: select which controller container to exec into.
- `SLURM_ENV_FILE`: override where the wrapper loads the generated env file from (default: `./.slurm-local/.env`).

Examples:
```bash
./slurm sinfo
./slurm squeue
./slurm srun -n1 hostname
./slurm sbatch job.sh
```

### Passing secrets/tokens safely
The wrapper forwards selected environment variables into the container **only if they are set on the host**:
- `HF_TOKEN`
- `HUGGINGFACEHUB_API_TOKEN`
- `HF_API_KEY`
- `NEWS_API_KEY`

This keeps secrets out of repo files.

## `.slurm-local/` internals
### Docker image (`.slurm-local/Dockerfile`)
Builds an Ubuntu-based Slurm image that includes:
- Slurm daemons: `slurmctld`, `slurmd`, `slurmdbd`, plus `slurm-client`
- Munge for authentication
- `python3` + `pip`
- Preinstalled Python deps used by typical jobs (`requests`, `huggingface_hub`, `numpy`, `torch`, `pydantic`, `langchain`, `langgraph`, etc.)

### Entrypoint (`.slurm-local/entrypoint.sh`)
At container start it:
- Creates `munge` + `slurm` users.
- Shares a single Munge key across all nodes via the named volume mounted at `/shared`.
- Renders `/etc/slurm/slurm.conf` from `slurm.conf.template` by substituting:
  - controller host, node names
  - detected CPU count (`nproc`) and RAM (`/proc/meminfo`)
  - optional GPU `Gres=gpu:X` per compute node
- Writes `/etc/slurm/gres.conf` per node.
- Creates `/etc/slurm/slurmdbd.conf` on the controller and starts:
  - `munged`
  - `slurmdbd`
  - `slurmctld`
  - `slurmd`
- Bootstraps accounting with `sacctmgr` (adds cluster/account/root user).
- Tails Slurm logs to container stdout.

### Slurm config (`.slurm-local/slurm.conf.template`)
Notable settings:
- Ports:
  - `SlurmctldPort=6817`
  - `SlurmdPort=6818`
  - `AccountingStoragePort=6819` (slurmdbd)
- `SelectType=select/cons_tres` with `SelectTypeParameters=CR_Core`
- `GresTypes=gpu`
- Accounting via `slurmdbd` (`AccountingStorageType=accounting_storage/slurmdbd`)
- Partitions:
  - `debug` (default): controller + both compute nodes
  - `gpu`: **compute nodes only** (controller excluded)

## Example batch job (`job.sh`)
This repo includes `job.sh` as an example multi-node launch.

### SBATCH directives
- `--partition=gpu`
- `--nodes=2`
- `--ntasks=10` with `--cpus-per-task=1`
- `--mem=1G`
- `--time=00:05:00`
- stdout/stderr: `slurm-%j.out` and `slurm-%j.err`

### Distributed env
The script sets:
- `NEWS_AGENT_DISTRIBUTED_MODE=shard`
- `NEWS_AGENT_TORCH_BACKEND=gloo`

And computes:
- `MASTER_ADDR`: first hostname in `$SLURM_JOB_NODELIST`
- `MASTER_PORT`: derived from job id (`20000 + (SLURM_JOB_ID % 40000)`)

Then runs:
```bash
srun -l --kill-on-bad-exit=1 bash -lc '...
  export RANK="$SLURM_PROCID"
  export WORLD_SIZE="$SLURM_NTASKS"
  export LOCAL_RANK="$SLURM_LOCALID"
  python3 /work/my_agent/news_agent_hf_toolcall.py
  python3 /work/my_agent/news_agent_langchain.py
'
```

Notes:
- `--kill-on-bad-exit=1` means if *any rank* fails, Slurm terminates the whole step.
- You are running **two scripts back-to-back in the same rank**. If both use `torch.distributed`, ensure they don’t conflict (e.g., they both try to init the same process group).

### Requesting GPUs
`job.sh` currently selects the `gpu` partition but does **not** include `#SBATCH --gres=gpu:...`.

If you want Slurm to enforce GPU allocation, request it explicitly:
```bash
./slurm sbatch --gres=gpu:1 job.sh
```
(Works only if GPUs are configured via `SLURM_GPU_COUNT` and `gres.conf`.)

## Troubleshooting
### `Container 'slurm-local' is not running`
Start the stack:
```bash
bash setup_slurm_local.sh up
```

### `sbatch: error: Requested node configuration is not available`
Usually means one of:
- You requested more nodes than exist in a partition (the `gpu` partition has only the 2 compute nodes).
- You requested `--gres=gpu:X` but GPUs weren’t configured (`SLURM_GPU_COUNT` unset/0 or gres misconfigured).

Debug checklist:
```bash
./slurm sinfo
./slurm sinfo -o "%P %D %t %N"
./slurm scontrol show node slurm-local-1
./slurm scontrol show node slurm-local-2

# dry-run scheduling without running the job
./slurm sbatch --test-only --gres=gpu:1 job.sh
```

### `srun: ... Aborted` / step cancelled
This is commonly caused by one task exiting/crashing, then `--kill-on-bad-exit=1` kills the whole step.
- Inspect the per-job logs: `slurm-<jobid>.out` and `slurm-<jobid>.err`.
- Consider running smaller first: `--nodes=1 --ntasks=1` to get a clean traceback.

## Recommended `.gitignore`
Slurm creates per-job logs.
Typical ignores:
```gitignore
slurm-*.out
slurm-*.err
.slurm-local/
```

(Adjust based on whether you want to commit the generated `.slurm-local/` templates or treat them as build artifacts.)
