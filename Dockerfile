FROM --platform=linux/amd64 nvidia/cuda:11.8.0-cudnn8-runtime-ubuntu22.04

# Environment variables for better performance and behavior
ENV DEBIAN_FRONTEND=noninteractive \
    PIP_PREFER_BINARY=1 \
    PYTHONUNBUFFERED=1 \
    CMAKE_BUILD_PARALLEL_LEVEL=8

# Install Python and dependencies in a single layer
RUN apt-get update && apt-get install -y \
    python3.10 \
    python3-pip \
    git \
    wget \
    libgl1 \
    && ln -sf /usr/bin/python3.10 /usr/bin/python \
    && ln -sf /usr/bin/pip3 /usr/bin/pip \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* \
    && pip install --no-cache-dir comfy-cli runpod requests

# Install ComfyUI
WORKDIR /comfyui
RUN /usr/bin/yes | comfy --workspace /comfyui install --cuda-version 11.8 --nvidia --version 0.2.7

# Add configuration files
COPY src/extra_model_paths.yaml ./
COPY src/start.sh src/restore_snapshot.sh src/rp_handler.py test_input.json /
COPY *snapshot*.json /
RUN chmod +x /start.sh /restore_snapshot.sh

# Install custom nodes from snapshot
RUN /restore_snapshot.sh

# Create model directories (they'll be mounted from network storage)
RUN mkdir -p \
    models/checkpoints \
    models/vae \
    models/unet \
    models/clip \
    models/upscale_models \
    models/loras

WORKDIR /

CMD ["/start.sh"]