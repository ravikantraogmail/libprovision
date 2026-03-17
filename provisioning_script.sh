#!/bin/bash
# =============================================================================
# Vast.ai Provisioning Script — Tales from Willowwood Forest (autostorygen)
# =============================================================================
# This script runs automatically when a new vast.ai instance starts.
# It installs all dependencies for Phases 6-9 (FLUX, LTX-Video, Kokoro TTS).
# Phases 10-11 (AudioCraft) are installed separately to avoid pydantic conflict.
# =============================================================================

LOG_FILE="/workspace/provisioning_log.txt"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

fail() {
    log "ERROR: $1"
    exit 1
}

# -----------------------------------------------------------------------------
# 1. Init
# -----------------------------------------------------------------------------
echo "" > "$LOG_FILE"
log "=== Provisioning started ==="

# -----------------------------------------------------------------------------
# 2. Activate virtual environment
# -----------------------------------------------------------------------------
log "Activating virtual environment..."
source /venv/main/bin/activate || fail "Could not activate /venv/main"
log "Python: $(python3 --version)"
log "pip:    $(pip --version)"

# -----------------------------------------------------------------------------
# 3. Ensure 'python' resolves to python3 (vast.ai only has python3 by default)
# -----------------------------------------------------------------------------
if ! command -v python &>/dev/null; then
    log "python not found — creating symlink python -> python3"
    ln -sf "$(which python3)" /usr/local/bin/python \
        && log "Symlink created: python -> $(which python3)" \
        || log "WARNING: Could not create python symlink (non-fatal)"
else
    log "python already available: $(python --version)"
fi

# -----------------------------------------------------------------------------
# 4. Change to workspace
# -----------------------------------------------------------------------------
cd /workspace || fail "Could not cd to /workspace"
log "Working directory: $(pwd)"

# -----------------------------------------------------------------------------
# 4. System packages (ffmpeg + libav for audiocraft/imageio)
# -----------------------------------------------------------------------------
log "Installing system packages..."
apt-get update -qq && apt-get install -y -qq \
    ffmpeg \
    pkg-config \
    libavformat-dev \
    libavcodec-dev \
    libavdevice-dev \
    libavutil-dev \
    libavfilter-dev \
    libswscale-dev \
    libswresample-dev \
    git \
    && log "System packages installed OK" \
    || fail "System package installation failed"

# -----------------------------------------------------------------------------
# 5. FastAPI server dependencies (always needed)
# -----------------------------------------------------------------------------
log "Installing FastAPI + uvicorn..."
pip install --quiet --timeout 120 \
    fastapi \
    "uvicorn[standard]" \
    requests \
    && log "FastAPI installed OK" \
    || fail "FastAPI installation failed"

# -----------------------------------------------------------------------------
# 6. Phase 6 + 7 — FLUX portraits & LTX-Video clips
#    (diffusers requires pydantic v2)
# -----------------------------------------------------------------------------
log "Installing diffusers stack (phases 6+7)..."
pip install --quiet --timeout 120 \
    "diffusers>=0.32.0" \
    "transformers>=4.45.0" \
    "accelerate>=1.0.0" \
    "sentencepiece>=0.2.0" \
    "protobuf>=4.0.0" \
    "Pillow>=10.0.0" \
    "imageio>=2.34.0" \
    "imageio-ffmpeg>=0.5.0" \
    "opencv-python-headless>=4.9.0" \
    && log "Diffusers stack installed OK" \
    || fail "Diffusers stack installation failed"

# -----------------------------------------------------------------------------
# 7. Phase 8+9 — Kokoro TTS
# -----------------------------------------------------------------------------
log "Installing Kokoro TTS (phases 8+9)..."
pip install --quiet --timeout 120 \
    "kokoro>=0.9.2" \
    "soundfile>=0.12.1" \
    numpy \
    && log "Kokoro TTS installed OK" \
    || fail "Kokoro TTS installation failed"

# NOTE: Phase 10+11 (AudioCraft/MusicGen) uses pydantic v1 which conflicts
# with diffusers. Install separately when switching to phase 10:
#   pip install audiocraft soundfile
# This will downgrade pydantic — only run AFTER all diffusers phases are done.

# -----------------------------------------------------------------------------
# 8. HuggingFace cache on /workspace (NOT /root/.cache — root disk is only 70GB)
# -----------------------------------------------------------------------------
log "Setting up HuggingFace cache on /workspace..."
mkdir -p /workspace/.hf_home

# Persist HF_HOME + PYTORCH settings so every new shell/server picks them up
cat >> /etc/environment <<'EOF'
HF_HOME=/workspace/.hf_home
PYTORCH_ALLOC_CONF=expandable_segments:True
EOF

# Also add to venv activate so they apply when venv is sourced
cat >> /venv/main/bin/activate <<'EOF'
export HF_HOME=/workspace/.hf_home
export PYTORCH_ALLOC_CONF=expandable_segments:True
EOF

log "HF_HOME and PYTORCH_ALLOC_CONF set permanently"

# Login to HuggingFace (required for gated models like FLUX.1-schnell)
if [ -n "$HF_TOKEN" ]; then
    log "Logging in to HuggingFace (HF_TOKEN is set)..."
    python3 -c "from huggingface_hub import login; login('$HF_TOKEN')" \
        && log "HuggingFace login OK" \
        || log "WARNING: HuggingFace login failed — gated models (FLUX) may not download"
else
    log "WARNING: HF_TOKEN not set — FLUX.1-schnell will fail (gated model)"
    log "  Set HF_TOKEN in template env vars or export HF_TOKEN=hf_... before running"
fi

# -----------------------------------------------------------------------------
# 9. Clone project code (if REPO_URL env var is set)
# -----------------------------------------------------------------------------
if [ -n "$REPO_URL" ]; then
    log "Cloning repo: $REPO_URL ..."
    git clone "$REPO_URL" /workspace/autostorygen \
        && log "Repo cloned OK" \
        || fail "Repo clone failed"
else
    log "REPO_URL not set — skipping code clone (push via manage_gpu.py)"
fi

# -----------------------------------------------------------------------------
# 10. Download mgmt_server.py from libprovision repo and start it
# -----------------------------------------------------------------------------
log "Downloading mgmt_server.py from libprovision repo..."

LIBPROVISION_RAW="https://raw.githubusercontent.com/ravikantraogmail/libprovision/main"
MGMT_DIR="/workspace/autostorygen/scripts"
MGMT_SCRIPT="$MGMT_DIR/mgmt_server.py"

mkdir -p "$MGMT_DIR"
curl -fsSL "$LIBPROVISION_RAW/mgmt_server.py" -o "$MGMT_SCRIPT" \
    && log "mgmt_server.py downloaded OK" \
    || { log "WARNING: Failed to download mgmt_server.py — check repo URL"; }

log "Starting management server on port 8001..."
if [ -f "$MGMT_SCRIPT" ]; then
    HF_HOME=/workspace/.hf_home HF_TOKEN="$HF_TOKEN" \
        nohup python3 -u -m uvicorn scripts.mgmt_server:app \
        --host 0.0.0.0 --port 8001 --workers 1 \
        > /tmp/mgmt_server.log 2>&1 &
    echo $! > /tmp/mgmt_server.pid
    sleep 5
    if curl -sf http://127.0.0.1:8001/health > /dev/null; then
        log "Management server is UP on port 8001"
    else
        log "WARNING: Management server did not respond — check /tmp/mgmt_server.log"
    fi
else
    log "ERROR: mgmt_server.py not found at $MGMT_SCRIPT"
    log "  Bootstrap manually: python scripts/manage_gpu.py --ssh '...' bootstrap"
fi

# -----------------------------------------------------------------------------
# 11. Done
# -----------------------------------------------------------------------------
log "=== Provisioning complete ==="
log "Installed packages summary:"
pip show diffusers transformers accelerate kokoro fastapi uvicorn 2>/dev/null \
    | grep -E "^Name|^Version" | tee -a "$LOG_FILE"
log ""
log "Next steps:"
log "  1. Run SSH tunnel on laptop: ssh -L 8000:localhost:8000 -N ..."
log "  2. Push code:   python scripts/manage_gpu.py --ssh '...' push-code"
log "  3. Start server: python scripts/manage_gpu.py --ssh '...' start-server --phase 6"
