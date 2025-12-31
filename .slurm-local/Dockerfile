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
