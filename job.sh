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

# Distributed mode for /work/my_agent/news_agent_hf_toolcall.py
# - Uses mpi4py collectives
# - Launched by Slurm with PMI2 support (srun --mpi=pmi2)
export NEWS_AGENT_DISTRIBUTED_MODE=shard
export NEWS_AGENT_DISTRIBUTED_BACKEND=mpi

# Optional: enable MPI startup validation (prints a host distribution summary from rank 0)
export NEWS_AGENT_MPI_CHECK=1

# Launch one process per task across nodes, with PMI2 environment for MPI.
# NOTE: We intentionally do NOT export torchrun-style RANK/WORLD_SIZE/LOCAL_RANK here
# so the code can auto-detect MPI launches if desired.
#
# IMPORTANT: Do not run two separate MPI programs back-to-back inside the same srun step,
# because the second MPI_Init can fail with PMI "Broken pipe". Instead, run them as
# separate srun steps.

# Step 1: MPI-sharded HF tool-call agent
srun --mpi=pmi2 -l --kill-on-bad-exit=1 python3 /work/my_agent/news_agent_hf_toolcall.py

# Step 2: MPI-sharded LangChain agent
srun --mpi=pmi2 -l --kill-on-bad-exit=1 python3 /work/my_agent/news_agent_langchain.py
