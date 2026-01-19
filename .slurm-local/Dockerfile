FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# Build a newer Slurm than Ubuntu 22.04 provides so cgroup v2 works on modern Docker engines.
# Override as needed:
#   docker build --build-arg SLURM_VERSION=25.11.2 ...
ARG SLURM_VERSION=25.11.2

# Docker Desktop on Apple Silicon builds arm64 by default (ports.ubuntu.com).
# Use a mirror to avoid intermittent 5xx from the default ports mirror.
ARG UBUNTU_PORTS_MIRROR=http://mirrors.aliyun.com/ubuntu-ports/
RUN sed -i "s|http://ports.ubuntu.com/ubuntu-ports/|${UBUNTU_PORTS_MIRROR}|g" /etc/apt/sources.list

RUN apt-get -o Acquire::Retries=5 update \
 && apt-get -o Acquire::Retries=5 install -y --no-install-recommends --fix-missing \
    ca-certificates \
    bash \
    procps \
    iproute2 \
    tini \
    gosu \
    netcat-openbsd \
    curl \
    bzip2 \
    munge \
    libmunge-dev \
    mariadb-client \
    default-libmysqlclient-dev \
    python3 \
    python3-pip \
    python3-venv \
    python3-dev \
    python-is-python3 \
    build-essential \
    pkg-config \
    flex \
    bison \
    libssl-dev \
    libpam0g-dev \
    libreadline-dev \
    libhwloc-dev \
    libdbus-1-dev \
    linux-libc-dev \
    libbpf-dev \
    mpich \
    libmpich-dev \
 && rm -rf /var/lib/apt/lists/*

# Build Slurm from source (SchedMD) so we get cgroup v2 support.
RUN set -eux; \
  tmp="$(mktemp -d)"; \
  cd "$tmp"; \
  curl -fsSL "https://download.schedmd.com/slurm/slurm-${SLURM_VERSION}.tar.bz2" -o slurm.tar.bz2; \
  tar -xjf slurm.tar.bz2; \
  cd "slurm-${SLURM_VERSION}"; \
  ./configure \
    --prefix=/usr \
    --sysconfdir=/etc/slurm \
    --with-munge; \
  make -j"$(nproc)"; \
  make install; \
  ldconfig; \
  cd /; \
  rm -rf "$tmp"

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
