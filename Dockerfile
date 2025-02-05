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

# Start container
CMD ["/start.sh"]

# Stage 2: Download models
FROM base as downloader

# Define ARG and ENV with a default empty value
ARG HUGGINGFACE_ACCESS_TOKEN
ENV HUGGINGFACE_TOKEN=$HUGGINGFACE_ACCESS_TOKEN

# Add more verbose token checking
RUN echo "Checking Hugging Face token..." && \
    if [ -z "$HUGGINGFACE_TOKEN" ]; then \
        echo "Error: HUGGINGFACE_ACCESS_TOKEN is not set"; \
        echo "Please set HUGGINGFACE_ACCESS_TOKEN in DockerHub build settings"; \
        exit 1; \
    else \
        echo "Token is present (length: ${#HUGGINGFACE_TOKEN})"; \
    fi
    
# Change working directory to ComfyUI
WORKDIR /comfyui

# Create all necessary directories
RUN mkdir -p models/checkpoints \
    models/vae \
    models/unet \
    models/clip \
    models/upscale_models \
    models/loras

# Download models with single-line progress bars
RUN set -e && \
    echo "Starting model downloads..." && \
    for URL in \
        "https://huggingface.co/black-forest-labs/FLUX.1-dev/resolve/main/flux1-dev.safetensors models/unet/flux1-dev.safetensors auth" \
        "https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/clip_l.safetensors models/clip/clip_l.safetensors noauth" \
        "https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/t5xxl_fp8_e4m3fn.safetensors models/clip/t5xxl_fp8_e4m3fn.safetensors noauth" \
        "https://huggingface.co/black-forest-labs/FLUX.1-dev/resolve/main/ae.safetensors models/vae/ae.safetensors auth" \
        "https://huggingface.co/BeichenZhang/LongCLIP-L/resolve/main/longclip-L.pt models/clip/longclip-L.pt noauth" \
        "https://huggingface.co/ai-forever/Real-ESRGAN/resolve/main/RealESRGAN_x2.pth models/upscale_models/RealESRGAN_x2.pth noauth" \
        "https://huggingface.co/nerijs/dark-fantasy-illustration-flux/resolve/main/darkfantasy_illustration_v2.safetensors models/loras/darkfantasy_illustration_v2.safetensors noauth" \
        "https://huggingface.co/XLabs-AI/flux-RealismLora/resolve/main/lora.safetensors models/loras/flux-RealismLora.safetensors noauth" \
        "https://huggingface.co/k0n8/IshmaelV3/resolve/main/1shm43l_v3.safetensors models/loras/1shm43l_v3.safetensors noauth"; \
    do \
        SRC=$(echo $URL | cut -d' ' -f1); \
        DEST=$(echo $URL | cut -d' ' -f2); \
        AUTH=$(echo $URL | cut -d' ' -f3); \
        echo "Starting download of $(basename $DEST)..."; \
        if [ "$AUTH" = "auth" ]; then \
            wget --progress=bar:force:noscroll --header="Authorization: Bearer ${HUGGINGFACE_TOKEN}" -O "$DEST" "$SRC" || exit 1; \
        else \
            wget --progress=bar:force:noscroll -O "$DEST" "$SRC" || exit 1; \
        fi; \
        echo "Completed download of $(basename $DEST)"; \
    done

# Stage 3: Final image
FROM base as final

# Copy models from stage 2 to the final image
COPY --from=downloader /comfyui/models /comfyui/models

# Start container
CMD ["/start.sh"]