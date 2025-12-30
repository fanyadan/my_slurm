#!/usr/bin/env bash
#SBATCH --job-name=news_fetch
#SBATCH --output=slurm-%j.out
#SBATCH --error=slurm-%j.err
#SBATCH --time=00:05:00
#SBATCH --cpus-per-task=1
#SBATCH --mem=1G
#SBATCH --partition=gpu
#SBATCH --nodes=2
#SBATCH --ntasks=10
#SBATCH --export=ALL

# Real distributed mode for /work/my_agent/news_agent_hf_toolcall.py
# - Uses torch.distributed with init_method=env://
# - Requires MASTER_ADDR/MASTER_PORT + per-rank RANK/WORLD_SIZE
export NEWS_AGENT_DISTRIBUTED_MODE=shard
export NEWS_AGENT_TORCH_BACKEND=gloo

MASTER_ADDR="$(scontrol show hostnames "$SLURM_JOB_NODELIST" | head -n 1)"
MASTER_PORT="$((20000 + (SLURM_JOB_ID % 40000)))"
export MASTER_ADDR MASTER_PORT

# Launch one process per task. Each task maps Slurm env -> torch env.
srun -l --kill-on-bad-exit=1 bash -lc '
  export RANK="$SLURM_PROCID"
  export WORLD_SIZE="$SLURM_NTASKS"
  export LOCAL_RANK="$SLURM_LOCALID"
  python3 /work/my_agent/news_agent_hf_toolcall.py
  python3 /work/my_agent/news_agent_langchain.py
'
