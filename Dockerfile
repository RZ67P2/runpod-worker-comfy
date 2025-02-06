# Stage 1: Base image with common dependencies
FROM nvidia/cuda:11.8.0-cudnn8-runtime-ubuntu22.04 as base

# Prevents prompts from packages asking for user input during installation
ENV DEBIAN_FRONTEND=noninteractive
# Prefer binary wheels over source distributions for faster pip installations
ENV PIP_PREFER_BINARY=1
# Ensures output from python is printed immediately to the terminal without buffering
ENV PYTHONUNBUFFERED=1 
# Speed up some cmake builds
ENV CMAKE_BUILD_PARALLEL_LEVEL=8

# Install Python, git and other necessary tools
RUN apt-get update && apt-get install -y \
    python3.10 \
    python3-pip \
    git \
    wget \
    pv \
    libgl1 \
    && ln -sf /usr/bin/python3.10 /usr/bin/python \
    && ln -sf /usr/bin/pip3 /usr/bin/pip

# Clean up to reduce image size
RUN apt-get autoremove -y && apt-get clean -y && rm -rf /var/lib/apt/lists/*

# Install comfy-cli
RUN pip install comfy-cli

# Install ComfyUI
RUN /usr/bin/yes | comfy --workspace /comfyui install --cuda-version 11.8 --nvidia --version 0.2.7

# Change working directory to ComfyUI
WORKDIR /comfyui

# Install runpod
RUN pip install runpod requests

# Support for the network volume
ADD src/extra_model_paths.yaml ./

# Go back to the root
WORKDIR /

# Add scripts
ADD src/start.sh src/restore_snapshot.sh src/rp_handler.py test_input.json ./
RUN chmod +x /start.sh /restore_snapshot.sh

# Optionally copy the snapshot file
ADD *snapshot*.json /

# Restore the snapshot to install custom nodes
RUN /restore_snapshot.sh

# Stage 2a: First batch of models (largest files first)
FROM base as downloader1
ARG HUGGINGFACE_ACCESS_TOKEN
ENV HUGGINGFACE_TOKEN=$HUGGINGFACE_ACCESS_TOKEN

WORKDIR /comfyui
RUN mkdir -p models/unet models/clip models/vae

RUN set -e && \
    echo "Starting first batch downloads..." && \
    for URL in \
        "https://huggingface.co/black-forest-labs/FLUX.1-dev/resolve/main/flux1-dev.safetensors models/unet/flux1-dev.safetensors auth" \
        "https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/clip_l.safetensors models/clip/clip_l.safetensors noauth" \
        "https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/t5xxl_fp16.safetensors models/clip/t5xxl_fp16.safetensors noauth"; \
    do \
        SRC=$(echo $URL | cut -d' ' -f1); \
        DEST=$(echo $URL | cut -d' ' -f2); \
        AUTH=$(echo $URL | cut -d' ' -f3); \
        echo "Starting download of $(basename $DEST)"; \
        if [ "$AUTH" = "auth" ]; then \
            wget --no-verbose --show-progress --progress=dot:giga --header="Authorization: Bearer ${HUGGINGFACE_TOKEN}" -O "$DEST" "$SRC"; \
        else \
            wget --no-verbose --show-progress --progress=dot:giga -O "$DEST" "$SRC"; \
        fi && \
        echo "Completed download of $(basename $DEST)"; \
    done

# Stage 2b: Second batch of models
FROM base as downloader2
ARG HUGGINGFACE_ACCESS_TOKEN
ENV HUGGINGFACE_TOKEN=$HUGGINGFACE_ACCESS_TOKEN

WORKDIR /comfyui
RUN mkdir -p models/vae models/clip models/upscale_models

RUN set -e && \
    echo "Starting second batch downloads..." && \
    for URL in \
        "https://huggingface.co/black-forest-labs/FLUX.1-dev/resolve/main/ae.safetensors models/vae/ae.safetensors auth" \
        "https://huggingface.co/BeichenZhang/LongCLIP-L/resolve/main/longclip-L.pt models/clip/longclip-L.pt noauth" \
        "https://huggingface.co/ai-forever/Real-ESRGAN/resolve/main/RealESRGAN_x2.pth models/upscale_models/RealESRGAN_x2.pth noauth"; \
    do \
        SRC=$(echo $URL | cut -d' ' -f1); \
        DEST=$(echo $URL | cut -d' ' -f2); \
        AUTH=$(echo $URL | cut -d' ' -f3); \
        echo "Starting download of $(basename $DEST)"; \
        if [ "$AUTH" = "auth" ]; then \
            wget --no-verbose --show-progress --progress=dot:giga --header="Authorization: Bearer ${HUGGINGFACE_TOKEN}" -O "$DEST" "$SRC"; \
        else \
            wget --no-verbose --show-progress --progress=dot:giga -O "$DEST" "$SRC"; \
        fi && \
        echo "Completed download of $(basename $DEST)"; \
    done

# Stage 2c: Third batch of models (LoRAs)
FROM base as downloader3
ARG HUGGINGFACE_ACCESS_TOKEN
ENV HUGGINGFACE_TOKEN=$HUGGINGFACE_ACCESS_TOKEN

WORKDIR /comfyui
RUN mkdir -p models/loras

RUN set -e && \
    echo "Starting third batch downloads..." && \
    for URL in \
        "https://huggingface.co/nerijs/dark-fantasy-illustration-flux/resolve/main/darkfantasy_illustration_v2.safetensors models/loras/darkfantasy_illustration_v2.safetensors noauth" \
        "https://huggingface.co/XLabs-AI/flux-RealismLora/resolve/main/lora.safetensors models/loras/flux-RealismLora.safetensors noauth" \
        "https://huggingface.co/k0n8/IshmaelV3/resolve/main/1shm43l_v3.safetensors models/loras/1shm43l_v3.safetensors noauth"; \
    do \
        SRC=$(echo $URL | cut -d' ' -f1); \
        DEST=$(echo $URL | cut -d' ' -f2); \
        AUTH=$(echo $URL | cut -d' ' -f3); \
        echo "Starting download of $(basename $DEST)"; \
        if [ "$AUTH" = "auth" ]; then \
            wget --no-verbose --progress=dot:giga --header="Authorization: Bearer ${HUGGINGFACE_TOKEN}" -O "$DEST" "$SRC"; \
        else \
            wget --no-verbose --progress=dot:giga -O "$DEST" "$SRC"; \
        fi && \
        echo "Completed download of $(basename $DEST)"; \
    done

# Stage 3: Final image
FROM base as final

# Copy models from all stages to the final image
COPY --from=downloader1 /comfyui/models /comfyui/models/
COPY --from=downloader2 /comfyui/models /comfyui/models/
COPY --from=downloader3 /comfyui/models /comfyui/models/

# Start container
CMD ["/start.sh"]