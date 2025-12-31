# Local Slurm cluster in Docker
A small, reproducible Slurm cluster for **local development and testing**, running entirely in Docker.

This repository gives you:
- A 3-node Slurm topology: **controller** + **2 compute nodes** (plus a MariaDB service for accounting).
- A committed `.slurm-local/` folder containing the compose stack, image definition, and Slurm config template.
- A host-side `./slurm` wrapper so you can run `sinfo`, `srun`, `sbatch`, `sacct`, etc. without manually `docker exec`-ing.
- Optional **GPU GRES modeling** (including “fake GPU” device files) so scheduling with `--gres=gpu:X` can be tested even without real GPUs, this needs to set `SLURM_GPU_COUNT=X` at first.

Primary use cases:
- Validate `sbatch` / `srun` scripts locally.
- Test multi-node / multi-rank launches (e.g. `torch.distributed`) without a real cluster.
- Use `sacct` locally via `slurmdbd` + MariaDB.

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

Tip: running `./slurm` with **no args** opens an interactive shell in the controller container.

## Important concept: what gets mounted at `/work`
All Slurm containers bind-mount a host directory to `/work`.

- Host path comes from `SLURM_WORKDIR` (written into `.slurm-local/.env`).
- Inside containers, that host path is always available at `/work`.

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

## Repository layout
- `README.md`: this documentation
- `setup_slurm_local.sh`: manage the local cluster (`up`, `down`, `logs`)
- `slurm`: host wrapper that runs Slurm commands inside the controller container
- `job.sh`: example multi-node batch job (Torch distributed env wiring)
- `.slurm-local/`:
  - `.env`: generated compose environment (paths, container names, DB creds, GPU count)
  - `docker-compose.yml`: services + volumes
  - `Dockerfile`: Slurm image definition
  - `entrypoint.sh`: container init (munge, config rendering, daemons, accounting bootstrap)
  - `slurm.conf.template`: Slurm config template

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
- `.slurm-local/.env` is **always rewritten** on `up` so the bind-mount points at your current directory (unless you override via env vars).
- Other files in `.slurm-local/` are only created if missing, unless `--force` is provided.

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

GPU modeling:
- `SLURM_GPU_COUNT`: integer. Total GPUs to model across the **gpu** partition.
  - Split across compute nodes at startup:
    - node1 gets `ceil(total/2)`
    - node2 gets `floor(total/2)`
  - If `/dev/nvidia*` exists, `gres.conf` uses real device paths.
  - Otherwise placeholder files `/dev/fakegpuN` are created and used by `gres.conf`.

Accounting (for `sacct`):
- `SLURM_DB_HOST`, `SLURM_DB_PORT`
- `SLURM_DB_NAME`, `SLURM_DB_USER`
- `SLURM_DB_PASS`, `SLURM_DB_ROOT_PASS`
- `SLURM_DB_CONTAINER_NAME`
- `SLURM_DBD_PORT` (default: 6819)

Security note: defaults are for **local dev only**.

## `./slurm` wrapper
The `slurm` script is a host-side helper that:
- Checks Docker is available and the controller container is running.
- Runs your command inside the controller container using `docker exec -it ...`.
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

Design note: this config is intentionally minimal and optimized for “does it schedule/run?” rather than perfect resource isolation.

## Example batch job (`job.sh`)
`job.sh` demonstrates a multi-node `srun` launch using **MPI (mpi4py)** via Slurm **PMI2**.

### SBATCH directives
- `--partition=gpu`
- `--nodes=2`
- `--ntasks=10`
- `--cpus-per-task=1`
- `--mem=1G`
- `--time=00:05:00`
- Logs:
  - `--output=slurm-%j.out`
  - `--error=slurm-%j.err`

### Distributed mode (MPI)
The script sets:
- `NEWS_AGENT_DISTRIBUTED_MODE=shard`
- `NEWS_AGENT_DISTRIBUTED_BACKEND=mpi`
- `NEWS_AGENT_MPI_CHECK=1` (optional sanity check)

It launches the workload with:
- `srun --mpi=pmi2 ...`

Notes:
- Slurm places ranks across nodes (because `--nodes=2` and `--ntasks=10`).
- PMI2 is what wires up the MPI runtime (env + PMI server) so ranks can communicate.
- The script intentionally does **not** set torchrun-style `RANK/WORLD_SIZE/LOCAL_RANK`, so the code can auto-detect MPI launches if you use backend=auto.
- The LangChain script is executed only on rank 0.

### Requesting GPUs
`job.sh` selects the `gpu` partition but does not include `#SBATCH --gres=gpu:...`.

To enforce GPU allocation:
```bash
./slurm sbatch --gres=gpu:1 job.sh
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

MPI smoke test (PMI2 across 2 nodes):
```bash
./slurm srun -p gpu --mpi=pmi2 -N2 -n4 -l python3 -c 'from mpi4py import MPI; import socket; comm=MPI.COMM_WORLD; print("rank", comm.Get_rank(), "host", socket.gethostname()); comm.Barrier()'
```

Inspect rendered config:
```bash
./slurm bash -lc 'cat /etc/slurm/slurm.conf'
./slurm bash -lc 'cat /etc/slurm/gres.conf'
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

### `srun: ... Aborted` / step cancelled
This usually means one rank crashed and `--kill-on-bad-exit=1` terminated the step.
- Check `slurm-<jobid>.out` and `slurm-<jobid>.err`.
- Reduce to `--nodes=1 --ntasks=1` to surface a clean traceback.

### Resetting the environment
`bash setup_slurm_local.sh down` stops containers but keeps the Docker volumes (including the accounting DB).

To wipe persisted state, you can remove the volumes from `.slurm-local/`:
```bash
# destructive: removes slurm-shared and mariadb-data
cd .slurm-local && docker compose down -v
```

## `.gitignore`
This repo currently tracks `.slurm-local/` (so it acts as the canonical template).

At minimum, it’s useful to ignore Slurm job logs:
```gitignore
slurm-*.out
slurm-*.err
```
