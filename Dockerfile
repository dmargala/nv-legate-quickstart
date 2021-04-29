# Copyright 2021 NVIDIA Corporation
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

# Parent image
ARG CUDA_VER
ARG LINUX_VER
ARG PYTHON_VER
FROM rapidsai/rapidsai-core-dev:0.19-cuda${CUDA_VER}-devel-${LINUX_VER}-py${PYTHON_VER}

# Build arguments
ARG CUDA_VER
ENV CUDA_VER=${CUDA_VER}
ARG DEBUG
ENV DEBUG=${DEBUG}
ARG LINUX_VER
ENV LINUX_VER=${LINUX_VER}
ARG PLATFORM
ENV PLATFORM=${PLATFORM}
ARG PYTHON_VER
ENV PYTHON_VER=${PYTHON_VER}
ARG GPU_ARCH
ENV GPU_ARCH=${GPU_ARCH}

# Set compile-time & runtime paths
# The order of directories is important: legate > conda > MOFED > distro
# `source activate` will append conda dirs to PATH automaticaly
ENV CPATH="/opt/conda/envs/rapids/include:${CPATH}"
ENV LIBRARY_PATH="/opt/conda/envs/rapids/lib:${LIBRARY_PATH}"
ENV LD_LIBRARY_PATH="/opt/conda/envs/rapids/lib:${LD_LIBRARY_PATH}"
ENV LEGATE_DIR=/opt/legate/install
ENV CUDA_HOME=/usr/local/cuda

# Execute RUN commands in strict mode
SHELL [ "/bin/bash", "-eo", "pipefail", "-c" ]

# Create an alias for the stub libcuda, required when static-linking with UCX libraries
RUN cd ${CUDA_HOME}/lib64/stubs \
 && ln -s libcuda.so libcuda.so.1

# Add third-party apt repos
RUN export LINUX_VER_URL="$(echo "$LINUX_VER" | tr '.' '')" \
 && curl -fsSL https://developer.download.nvidia.com/devtools/repos/${LINUX_VER_URL}/amd64/nvidia.pub | apt-key add - \
 && echo "deb https://developer.download.nvidia.com/devtools/repos/${LINUX_VER_URL}/amd64/ /" >> /etc/apt/sources.list.d/nsys.list

# Install apt packages
RUN apt-get update \
 && if [[ "$PLATFORM" != generic ]]; then \
    apt-get install -y --no-install-recommends \
    `# requirements for MOFED packages` \
    libnl-3-200 libnl-route-3-200 libnl-3-dev libnl-route-3-dev \
    `# requirements for UCX build` \
    libtool libnuma-dev \
  ; fi \
 && apt-get install -y --no-install-recommends \
    `# useful utilities` \
    nsight-systems-cli numactl gdb \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

# Copy quickstart to image
COPY quickstart /opt/legate/quickstart

# Install Verbs & RDMA-CM from MOFED
RUN if [[ "$PLATFORM" != generic ]]; then \
    source /opt/legate/quickstart/common.sh \
 && set_mofed_vars \
 && export MOFED_ID=MLNX_OFED_LINUX-${MOFED_VER_LONG}-${LINUX_VER}-x86_64 \
 && cd /tmp \
 && curl -fSsL http://content.mellanox.com/ofed/MLNX_OFED-${MOFED_VER_LONG}/${MOFED_ID}.tgz | tar -xz \
 && cd ${MOFED_ID} \
 && dpkg -i $(echo $(find . -false \
    -or -name ibverbs-providers_${MOFED_DEB_VER}'*.deb' \
    -or -name libibverbs-dev_${MOFED_DEB_VER}'*.deb' \
    -or -name libibverbs1_${MOFED_DEB_VER}'*.deb' \
    -or -name libibverbs1-dbg_${MOFED_DEB_VER}'*.deb' \
    -or -name libmlx5-1_${MOFED_DEB_VER}'*.deb' \
    -or -name libmlx5-1-dbg_${MOFED_DEB_VER}'*.deb' \
    -or -name libmlx5-dev_${MOFED_DEB_VER}'*.deb' \
    -or -name librdmacm-dev_${MOFED_DEB_VER}'*.deb' \
    -or -name librdmacm1_${MOFED_DEB_VER}'*.deb' \
    -or -name librdmacm1-dbg_${MOFED_DEB_VER}'*.deb')) \
 && cd /tmp \
 && rm -rf ${MOFED_ID} \
 && echo ${MOFED_VER} > /opt/mofed-ver \
 && cp /opt/legate/quickstart/ibdev2netdev /usr/bin \
  ; fi

# Build UCX with Verbs support
RUN if [[ "$PLATFORM" != generic ]]; then \
    source activate rapids \
 && export LD_LIBRARY_PATH=${LD_LIBRARY_PATH}:${CUDA_HOME}/lib64/stubs \
 && /opt/legate/quickstart/install_ib_ucx.sh \
  ; fi

# Build OpenMPI from source, to make sure it matches our version of UCX.
RUN if [[ "$PLATFORM" != generic ]]; then
    source activate rapids \
 && export LD_LIBRARY_PATH=${LD_LIBRARY_PATH}:${CUDA_HOME}/lib64/stubs \
 && cd /tmp \
 && curl -fSsL https://download.open-mpi.org/release/open-mpi/v4.1/openmpi-4.1.1.tar.gz | tar -xz \
 && cd openmpi-* \
 && mkdir build \
 && cd build \
 && ../configure \
    --with-verbs \
    --with-cuda=${CUDA_HOME} \
    --with-ucx=${CONDA_PREFIX} \
    --enable-mca-no-build=btl-uct \
    --with-hwloc=internal \
    --with-libevent=internal \
 && make -j install \
 && cd /tmp \
 && rm -rf openmpi-* \
 && ldconfig \
  ; fi

# Build GASNet, Legion and legate.core
COPY legate.core /opt/legate/legate.core
RUN source activate rapids \
 && cd /opt/legate/legate.core \
 && export LD_LIBRARY_PATH=${LD_LIBRARY_PATH}:${CUDA_HOME}/lib64/stubs \
 && bash -x /opt/legate/quickstart/build.sh

# Build legate.hello
COPY legate.hello /opt/legate/legate.hello
RUN source activate rapids \
 && cd /opt/legate/legate.hello \
 && bash -x /opt/legate/quickstart/build.sh

# Build legate.pandas
COPY legate.pandas /opt/legate/legate.pandas
RUN source activate rapids \
 && cd /opt/legate/legate.pandas \
 && bash -x /opt/legate/quickstart/build.sh

# Needed for Pandas IO tests
RUN chmod og+w /opt/legate/legate.pandas/tests/io

# Build legate.numpy
COPY legate.numpy /opt/legate/legate.numpy
RUN source activate rapids \
 && cd /opt/legate/legate.numpy \
 && bash -x /opt/legate/quickstart/build.sh

# Create a new user
RUN useradd -rm -d /home/legate-user -s /bin/bash -g root -G sudo -u 1001 legate-user
USER legate-user
WORKDIR /home/legate-user
ENV PATH=${PATH}:/opt/legate/install/bin

# Custom entrypoint script
ENTRYPOINT [ "/opt/legate/quickstart/entrypoint.sh" ]
CMD [ "/bin/bash" ]
