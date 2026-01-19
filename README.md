# Local Slurm cluster in Docker
A small, reproducible Slurm cluster for **local development and testing**, running entirely in Docker.

This repository is intentionally opinionated: it optimizes for “easy to boot, easy to inspect, easy to throw away”, not for production-grade isolation.

## What you get (key features)
- **3-node Slurm topology** in Docker: **1 controller** + **2 compute nodes** (plus a MariaDB service for accounting).
- **Self-contained** `.slurm-local/` folder (Compose stack, image definition, Slurm config template).
- A host-side `./slurm` wrapper so you can run `sinfo`, `srun`, `sbatch`, `sacct`, … without manually `docker exec`-ing.
- **Multi-node MPI support** using **MPICH + mpi4py**, launched via Slurm **PMI2** (`srun --mpi=pmi2`).
- Optional **GPU GRES modeling** so scheduling with `--gres=gpu:X` can be tested even without real GPUs.
- Slurm accounting enabled (`slurmdbd` + MariaDB) so `sacct` works locally.

Primary use cases:
- Validate `sbatch` / `srun` scripts locally.
- Test multi-node / multi-rank launches (MPI, or any other launcher supported by Slurm).
- Reproduce scheduler/resource-request issues without a real cluster.

What this is *not*:
- A **secure** multi-tenant cluster.
  - This repo can simulate multi-tenant *policies* (users/accounts/partitions), but it’s not a hardened production environment.
- A real GPU-enabled Slurm deployment (the “fake GPU” mode is scheduling-only).

## Requirements
- Docker
- Docker Compose (either `docker compose` or `docker-compose`)

Quick checks:
```bash
docker version

docker compose version || docker-compose --version
```

## Quick start
### 1) Bring up the local cluster
From this repo root:
```bash
bash setup_slurm_local.sh up
```

Verify:
```bash
./slurm sinfo
./slurm srun -N3 -n3 hostname
```

Tip: running `./slurm` with **no args** opens an interactive shell in the controller container.

### 2) Submit the example job
```bash
./slurm sbatch job.sh
```

### 3) Follow logs
```bash
bash setup_slurm_local.sh logs
```

### 4) Stop the cluster
```bash
bash setup_slurm_local.sh down
```

## Important concept: what gets mounted at `/work`
All Slurm containers bind-mount a host directory to `/work`.

- Host path comes from `SLURM_WORKDIR` (written into `.slurm-local/.env`).
- Inside containers, that host path is always available at `/work`.

By default, `setup_slurm_local.sh up` sets `SLURM_WORKDIR` to your current `$PWD` **at the moment you run the script**.

This matters because `job.sh` executes:
- `python3 /work/my_agent/news_agent_hf_toolcall.py`
- `python3 /work/my_agent/news_agent_langchain.py`

So `/work` must contain a `my_agent/` directory.

Recommended layout:
```
<workdir>/
  my_slurm/
  my_agent/
```

If you keep `my_agent/` as a sibling repo, start Slurm with a parent mount:
```bash
# from the my_slurm repo root
SLURM_WORKDIR="$(pwd -P)/.." bash setup_slurm_local.sh up
```

## Repository layout
- `README.md`: this documentation
- `setup_slurm_local.sh`: manage the local cluster (`up`, `down`, `logs`)
- `slurm`: host wrapper that runs Slurm commands inside the controller container
- `job.sh`: example multi-node batch job (MPI via PMI2)
- `.slurm-local/`:
  - `.env`: generated compose environment (paths, container names, DB creds, GPU count)
  - `docker-compose.yml`: services + volumes
  - `Dockerfile`: Slurm image definition
  - `entrypoint.sh`: container init (munge, config rendering, daemons, accounting bootstrap)
  - `slurm.conf.template`: Slurm config template

## High-level architecture
The Docker Compose stack in `.slurm-local/docker-compose.yml` runs:
- `mariadb`: accounting DB
- `slurmctld` (container name defaults to `slurm-local`):
  - `munged`
  - `slurmdbd`
  - `slurmctld`
  - `slurmd` (because `SLURM_ROLE=all`)
- `slurm1` (`slurm-local-1`): compute node (`munged` + `slurmd`)
- `slurm2` (`slurm-local-2`): compute node (`munged` + `slurmd`)

Compose volumes:
- `slurm-shared`: shared munge key (`/shared/munge.key`) so Slurm auth works across nodes
- `mariadb-data`: persists the accounting DB across restarts

## Partitions and scheduling model
This setup defines:
- `debug` (default): controller + both compute nodes (restricted via `AllowGroups`/`AllowAccounts`; defaults to `admin,teama`)
- `gpu`: compute nodes only (restricted via `AllowGroups`/`AllowAccounts`; defaults to `admin,teama`)
- **Tenant partitions** (generated at container start from `SLURM_TENANTS`): one partition per tenant, compute nodes only

CPU + memory are rendered at container start by reading `nproc` and `/proc/meminfo` inside the container.

Design note: the config is intentionally minimal and optimized for “does it schedule/run?” rather than strict resource isolation.

### Multi-tenant mode (partition-per-tenant)
This repo supports a basic “multi-tenant” model for local testing:
- Each tenant is represented as:
  - a Unix login user inside the containers
  - a Slurm account (same name)
  - a Slurm partition (same name), restricted via `AllowGroups=<tenant>`
    - (The admin group is also allowed so operators can debug all tenants.)

Enable it by setting `SLURM_TENANTS` when bringing the cluster up:
```bash
# Two example tenants with explicit UID/GID
SLURM_TENANTS='teama:10001:10001,teamb:10002:10002' \
  bash setup_slurm_local.sh up
```

Then submit/run as a tenant by overriding which user `./slurm` execs as:
```bash
# Run a command as teamA (inside the controller container)
SLURM_EXEC_USER=teama ./slurm srun -p teama -n1 hostname

# This should fail (teama cannot use teamb partition)
SLURM_EXEC_USER=teama ./slurm srun -p teamb -n1 hostname
```

Per-tenant work dirs:
- The entrypoint creates per-tenant directories under `SLURM_TENANTS_DIR` (default: `/work/tenants`).
- Example: `/work/tenants/teama`, `/work/tenants/teamb`.

### Limitations / design choices (important)
- This is not a hardened security boundary. Treat it as a *policy simulation* for Slurm.
- No cgroups isolation by default (see `SLURM_ENABLE_CGROUP` below).
- The controller also runs `slurmd` (because `SLURM_ROLE=all`), and the `debug` partition includes it.
- All nodes share the same host bind mount at `/work` (good for local dev; not representative of a real shared filesystem setup).

## `setup_slurm_local.sh`
### Commands
```bash
bash setup_slurm_local.sh up
bash setup_slurm_local.sh down
bash setup_slurm_local.sh logs

# overwrite generated templates (compose, Dockerfile, entrypoint, slurm.conf template, wrapper)
bash setup_slurm_local.sh --force up
```

### Compose selection
The script prefers `docker compose` (Compose plugin). If that’s unavailable, it falls back to `docker-compose`.

### File generation behavior
- `.slurm-local/.env` is **always rewritten** on `up`.
  - This is what makes `SLURM_WORKDIR` default to “where you ran the script from”.
  - If you want a stable mount, set `SLURM_WORKDIR=...` explicitly when running `up`.
  - Any values you rely on (for example `SLURM_GPU_COUNT`) should be passed/exported when you run `up`, otherwise they may be reset.
  - `.slurm-local/.env` is generated and host-specific; it is not meant to be committed.
    - See `.slurm-local/.env.example` for a safe, committed reference.
- Other files in `.slurm-local/` are only created if missing, unless `--force` is provided.
  - If you manually edited `.slurm-local/Dockerfile`, `.slurm-local/entrypoint.sh`, etc., **avoid** `--force`.

### Configuration (environment variables)
You can override most behavior by exporting env vars when running `setup_slurm_local.sh`.

Core paths/names:
- `SLURM_WORKDIR`: host directory to mount at `/work` in containers. Default: `$PWD` when you run the script.
- `SLURM_LOCAL_DIR`: where the compose stack lives. Default: `./.slurm-local`.
- `SLURM_WRAPPER_PATH`: where to write the host wrapper. Default: `./slurm`.
- `SLURM_CONTAINER_NAME`: controller container name. Default: `slurm-local`.
- `SLURM_NODE1_NAME`, `SLURM_NODE2_NAME`: compute container names/hostnames. Defaults: `${SLURM_CONTAINER_NAME}-1` and `-2`.
- `SLURM_CTLD_HOST`: controller hostname used in config. Default: `${SLURM_CONTAINER_NAME}`.
- `SLURM_IMAGE_NAME`: image tag. Default: `slurm-local:dev`.

Multi-tenant:
- `SLURM_ADMIN_ACCOUNT`: admin Slurm account name. Default: `admin`.
- `SLURM_TENANTS`: comma-separated tenant specs. Each tenant becomes a user+account+partition.
  - Format: `name[:uid[:gid]]`
  - Example: `teama:10001:10001,teamb:10002:10002`
- `SLURM_TENANTS_DIR`: where to create per-tenant dirs inside containers. Default: `/work/tenants`.
- `SLURM_TENANT_UID_BASE`, `SLURM_TENANT_GID_BASE`: base IDs used when uid/gid aren’t specified in `SLURM_TENANTS`. Defaults: `10000`.

Optional isolation:
- `SLURM_ENABLE_CGROUP`: set to `1` to enable `task/cgroup` + `proctrack/cgroup` and write `cgroup.conf`.
- `SLURM_PRIVILEGED`: set to `true` to run Slurm containers privileged (sometimes required for cgroups to work).

Accounting (for `sacct`):
- `SLURM_DB_HOST`, `SLURM_DB_PORT`
- `SLURM_DB_NAME`, `SLURM_DB_USER`
- `SLURM_DB_PASS`, `SLURM_DB_ROOT_PASS`
- `SLURM_DB_CONTAINER_NAME`
- `SLURM_DBD_PORT` (default: 6819)

Accounting behavior:
- The controller starts `slurmdbd` and bootstraps a minimal accounting setup (admin + tenants) on startup.
- MariaDB state is persisted in the `mariadb-data` Docker volume. `down` keeps it; `down -v` wipes it.
- If you **upgrade Slurm** (especially across major versions), `slurmdbd` may refuse to start due to an old schema.
  - Fix (dev-only): wipe the MariaDB volume and restart:
    - `bash setup_slurm_local.sh down` then `docker volume rm slurm-local_mariadb-data`

Security note: defaults are for **local dev only**.

## GPU GRES modeling (scheduling-only)
If you want to test `--gres=gpu:X` scheduling logic locally, set `SLURM_GPU_COUNT` when bringing the cluster up:
```bash
SLURM_GPU_COUNT=10 bash setup_slurm_local.sh up
```

How it works:
- `SLURM_GPU_COUNT` is the **total** number of GPUs to model across the **gpu** partition.
- At container start, GPUs are split across compute nodes:
  - node1 gets `ceil(total/2)`
  - node2 gets `floor(total/2)`
- `entrypoint.sh` renders both:
  - `slurm.conf` with `NodeName=... Gres=gpu:X`
  - node-local `/etc/slurm/gres.conf` with either:
    - real `/dev/nvidia*` device paths (if present), or
    - placeholder files `/dev/fakegpuN`

Important:
- The “fake GPU” mode enables **scheduling tests only**. It does not magically provide CUDA inside the container.
- If you submit with `--gres=gpu:1` but `SLURM_GPU_COUNT` is empty/0, Slurm may say:
  - `Requested node configuration is not available`

## MPI support (MPICH + mpi4py + Slurm PMI2)
The Slurm image includes:
- MPICH runtime + headers (`mpich`, `libmpich-dev`)
- `mpi4py` built from source against MPICH (`MPICC=mpicc ... --no-binary=mpi4py`)

Slurm’s MPI “wireup” is done via PMI2. Useful commands:
```bash
./slurm srun --mpi=list

# simple 2-node MPI sanity check
./slurm srun -p gpu --mpi=pmi2 -N2 -n4 -l python3 -c 'from mpi4py import MPI; import socket; comm=MPI.COMM_WORLD; print("rank", comm.Get_rank(), "host", socket.gethostname()); comm.Barrier()'
```

Important:
- If you need to run two separate MPI programs, run them as **two separate `srun --mpi=pmi2` steps**.
  - Starting a second MPI program inside the same `srun` step can fail with PMI errors (e.g. `Broken pipe`).

## `./slurm` wrapper
The `slurm` script is a host-side helper that:
- Checks Docker is available and the controller container is running.
- Runs your command inside the controller container using `docker exec -it ...`.
- Defaults to running as the **host uid:gid** inside the container (so Slurm sees non-root users).
- Sets `-w` so relative paths (like `job.sh`) work from subdirectories.

Examples:
```bash
./slurm sinfo
./slurm squeue
./slurm srun -n1 hostname
./slurm sbatch job.sh
```

### Workdir mapping details
The wrapper figures out the in-container working directory by:
- Reading `SLURM_WORKDIR` from your environment, or from `./.slurm-local/.env`.
- Comparing it to your current `pwd -P`.
- Converting your host path into `/work/<relative-subdir>`.

Override knobs:
- `SLURM_CONTAINER_NAME`: controller container name to exec into
- `SLURM_ENV_FILE`: alternate env file path (default: `./.slurm-local/.env`)
- `SLURM_EXEC_USER`: exec as a specific container user (e.g. `teama`, or `root`)
- `SLURM_EXEC_UID` / `SLURM_EXEC_GID`: exec as a specific uid/gid

### Passing secrets/tokens safely
The wrapper passes selected env vars through to the container **by name** (no values are written to disk):
- `HF_TOKEN`
- `HUGGINGFACEHUB_API_TOKEN`
- `HF_API_KEY`
- `NEWS_API_KEY`

If you need additional pass-through variables, add them to `slurm` (look for `EXTRA_ENV_ARGS`).

## `.slurm-local/` internals
### Docker image (`.slurm-local/Dockerfile`)
The Slurm image is Ubuntu-based and installs:
- Slurm: `slurm-client`, `slurmctld`, `slurmd`, `slurmdbd`
- Munge: for auth (`AuthType=auth/munge`)
- Utilities used by the entrypoint (`tini`, `gosu`, `netcat-openbsd`, etc.)
- Python 3 + pip
- MPICH + mpi4py (see the MPI section)

It also pre-installs Python packages commonly used by the example workload:
- `requests`, `huggingface_hub`, `numpy`, `torch`, `pydantic`, `langchain`, `langchain-core`, `langgraph`

### Entrypoint (`.slurm-local/entrypoint.sh`)
At container start it:
- Creates users (`munge`, `slurm`).
- Creates and shares a single munge key via `/shared/munge.key`.
- Renders `slurm.conf` from `slurm.conf.template` using:
  - controller/node names
  - `nproc` and `/proc/meminfo` for CPU/RAM
  - optional per-node GPU `Gres=gpu:X`
- Writes config into both `/etc/slurm` and `/etc/slurm-llnl`.
- Writes `gres.conf` per node.
- On the controller:
  - waits for MariaDB
  - starts `slurmdbd`, bootstraps accounting (`sacctmgr`), starts `slurmctld`
- On compute nodes:
  - starts `slurmd`
- Calls `scontrol update NodeName=... State=RESUME` to bring nodes up.
- Tails Slurm logs to container stdout.

### Slurm config (`.slurm-local/slurm.conf.template`)
Notable settings:
- Ports:
  - `SlurmctldPort=6817`
  - `SlurmdPort=6818`
  - `AccountingStoragePort=6819` (slurmdbd)
- Scheduler/resources:
  - `SelectType=select/cons_tres` + `SelectTypeParameters=CR_Core`
  - `GresTypes=gpu`
- Accounting:
  - `AccountingStorageType=accounting_storage/slurmdbd`
- Partitions:
  - `debug` (default): controller + both compute nodes
  - `gpu`: compute nodes only

## Example batch job (`job.sh`)
`job.sh` demonstrates a multi-node `srun` launch using **MPI (mpi4py)** via Slurm **PMI2**.

### SBATCH directives
- `--partition=gpu`
  - By default, `gpu` is restricted via `AllowGroups`/`AllowAccounts` (defaults to `admin,teama`); submit with `-p <tenant>` if needed (command-line options override SBATCH directives).
- `--nodes=2`
- `--ntasks=10`
- `--cpus-per-task=1`
- `--mem=1G`
- `--time=00:05:00` (increase this if your workload is slow or calls external APIs)
- Logs:
  - `--output=slurm-%j.out`
  - `--error=slurm-%j.err`

### Distributed mode (MPI)
The script sets:
- `NEWS_AGENT_DISTRIBUTED_MODE=shard`
- `NEWS_AGENT_DISTRIBUTED_BACKEND=mpi`
- `NEWS_AGENT_MPI_CHECK=1` (optional sanity check)

It then runs **two separate MPI steps**:
- `srun --mpi=pmi2 ... python3 /work/my_agent/news_agent_hf_toolcall.py`
- `srun --mpi=pmi2 ... python3 /work/my_agent/news_agent_langchain.py`

Notes:
- Slurm places ranks across nodes (because `--nodes=2` and `--ntasks=10`).
- PMI2 is what wires up the MPI runtime (env + PMI server) so ranks can communicate.
- The script intentionally does **not** set torchrun-style `RANK/WORLD_SIZE/LOCAL_RANK`.

### Requesting GPUs
`job.sh` selects the `gpu` partition but does not include `#SBATCH --gres=gpu:...`.

To enforce GPU allocation:
```bash
# admin partition
./slurm sbatch --gres=gpu:1 job.sh

# tenant partition
SLURM_EXEC_USER=teama ./slurm sbatch -p teama --gres=gpu:1 job.sh
```

## Useful commands
Cluster status:
```bash
./slurm sinfo
./slurm squeue
./slurm scontrol show partition debug
./slurm scontrol show partition gpu
./slurm scontrol show node slurm-local-1
./slurm scontrol show node slurm-local-2
```

Dry-run scheduling (no execution):
```bash
./slurm sbatch --test-only --gres=gpu:1 job.sh
```

Accounting:
```bash
./slurm sacct -j <jobid> -o JobID,JobName%20,Partition%10,State,ExitCode,Elapsed,AllocTRES%60
```

Inspect rendered config:
```bash
./slurm bash -lc 'cat /etc/slurm/slurm.conf'
./slurm bash -lc 'cat /etc/slurm/gres.conf'
```

Logs:
- Follow container logs (includes Slurm daemon logs streamed by the entrypoint):
```bash
bash setup_slurm_local.sh logs
```
- Or inspect log files inside the controller:
```bash
./slurm bash -lc 'ls -l /var/log/slurm && tail -n 200 /var/log/slurm/slurmctld.log'
```

## Troubleshooting
### `Container 'slurm-local' is not running`
```bash
bash setup_slurm_local.sh up
```

### `Requested node configuration is not available`
Common causes:
- Asking for too many nodes for a partition.
- Requesting GPUs (`--gres=gpu:X`) when GPUs weren’t configured (`SLURM_GPU_COUNT` is empty/0) or GRES is mismatched.

Debug:
```bash
./slurm sinfo
./slurm sinfo -o "%P %D %t %N"
./slurm scontrol show partition gpu
./slurm scontrol show node slurm-local-1
./slurm scontrol show node slurm-local-2
./slurm sbatch --test-only --gres=gpu:1 job.sh
```

### PMI / MPI errors (e.g. `Broken pipe`)
If you see PMI errors like `Broken pipe` / `PMI_Get_appnum returned -1`, make sure you are not launching multiple MPI programs inside the same `srun --mpi=pmi2` step.

Preferred pattern:
- multiple programs => multiple `srun --mpi=pmi2 ...` steps

### `srun: ... Aborted` / step cancelled
This usually means one rank crashed and `--kill-on-bad-exit=1` terminated the step.
- Check `slurm-<jobid>.out` and `slurm-<jobid>.err`.
- Reduce to `--nodes=1 --ntasks=1` to surface a clean traceback.

### Job cancelled due to time limit
If you see:
- `*** JOB <id> ... CANCELLED ... DUE TO TIME LIMIT ***`

Increase `#SBATCH --time=...` in your job script.

### Resetting the environment
`bash setup_slurm_local.sh down` stops containers but keeps the Docker volumes (including the accounting DB).

To wipe persisted state, remove volumes from `.slurm-local/`:
```bash
# destructive: removes slurm-shared and mariadb-data
cd .slurm-local && (docker compose down -v || docker-compose down -v)
```

## `.gitignore`
This repo currently tracks `.slurm-local/` (so it acts as the canonical template).

At minimum, it’s useful to ignore Slurm job logs:
```gitignore
slurm-*.out
slurm-*.err
```
