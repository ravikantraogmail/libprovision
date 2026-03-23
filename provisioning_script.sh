#!/bin/bash
# =============================================================================
# Vast.ai Provisioning Script — Tales from the Indian Jungle (autostorygen)
# =============================================================================
# Runs automatically when a new vast.ai instance starts (injected as the
# onstart command by scripts/vast_provisioner.py).
#
# What this script does:
#   1. Installs system packages (ffmpeg, libav)
#   2. Installs FastAPI + uvicorn (management server)
#   3. Installs diffusers stack (Phases 6+7 — FLUX portraits + LTX-Video)
#   4. Installs Kokoro TTS (Phases 8+9)
#   5. Sets up HuggingFace cache on /workspace (not root disk)
#   6. Logs in to HuggingFace (for gated FLUX model)
#   7. Starts the management server on port 8001 (if code is present)
#
# NOTE: Phases 10+11 (AudioCraft/MusicGen) use pydantic v1 which conflicts
# with diffusers. They are installed on-demand when the phase switches.
#
# After this script finishes:
#   python scripts/vast_provisioner.py status    # wait for "running"
#   python scripts/vast_provisioner.py tunnel    # open SSH tunnel
#   python scripts/manage_gpu.py bootstrap --ssh "..."  # push code + start mgmt server
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
# 3. Ensure 'python' resolves to python3
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
# 5. System packages (ffmpeg + libav for audiocraft/imageio)
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
# 6. FastAPI + uvicorn (management server — always needed)
# -----------------------------------------------------------------------------
log "Installing FastAPI + uvicorn..."
pip install --quiet --timeout 120 \
    fastapi \
    "uvicorn[standard]" \
    python-multipart \
    && log "FastAPI installed OK" \
    || fail "FastAPI installation failed"

# -----------------------------------------------------------------------------
# 7. Phases 6+7 — diffusers stack (FLUX portraits + LTX-Video clips)
#    torch, numpy, Pillow, huggingface-hub already in vastai/pytorch base image
# -----------------------------------------------------------------------------
log "Installing diffusers stack (phases 6+7)..."
pip install --quiet --timeout 120 \
    "diffusers>=0.32.0" \
    "transformers>=4.45.0" \
    "accelerate>=1.0.0" \
    "sentencepiece>=0.2.0" \
    "protobuf>=4.0.0" \
    "imageio>=2.34.0" \
    "imageio-ffmpeg>=0.5.0" \
    "opencv-python-headless>=4.9.0" \
    && log "Diffusers stack installed OK" \
    || fail "Diffusers stack installation failed"

# -----------------------------------------------------------------------------
# 8. Phases 8+9 — Kokoro TTS
# -----------------------------------------------------------------------------
log "Installing Kokoro TTS (phases 8+9)..."
pip install --quiet --timeout 120 \
    "kokoro>=0.9.2" \
    "soundfile>=0.12.1" \
    && log "Kokoro TTS installed OK" \
    || fail "Kokoro TTS installation failed"

# NOTE: Phases 10+11 (AudioCraft/MusicGen) require pydantic v1 which conflicts
# with diffusers. They are installed on-demand when the mgmt server restarts
# for phase 10 — do NOT install here.

# -----------------------------------------------------------------------------
# 9. HuggingFace cache on /workspace (NOT /root/.cache — root disk ~70GB only)
# -----------------------------------------------------------------------------
log "Setting up HuggingFace cache on /workspace..."
mkdir -p /workspace/.hf_home

# Persist env vars so every new shell and server process picks them up
cat >> /etc/environment <<'EOF'
HF_HOME=/workspace/.hf_home
PYTORCH_ALLOC_CONF=expandable_segments:True
EOF

cat >> /venv/main/bin/activate <<'EOF'
export HF_HOME=/workspace/.hf_home
export PYTORCH_ALLOC_CONF=expandable_segments:True
EOF

log "HF_HOME and PYTORCH_ALLOC_CONF set permanently"

# Log in to HuggingFace (required for gated FLUX.1-schnell model)
if [ -n "$HF_TOKEN" ]; then
    log "Logging in to HuggingFace (HF_TOKEN is set)..."
    python3 -c "from huggingface_hub import login; login('$HF_TOKEN')" \
        && log "HuggingFace login OK" \
        || log "WARNING: HuggingFace login failed — gated models (FLUX) may not download"
else
    log "WARNING: HF_TOKEN not set — FLUX.1-schnell will fail (gated model)"
    log "  Set HF_TOKEN in .env before running vast_provisioner.py provision"
fi

# -----------------------------------------------------------------------------
# 10. Start management server on port 8001 (if code already present)
#
# Code is pushed AFTER provisioning via:
#   python scripts/manage_gpu.py --ssh "..." bootstrap
# So this block only starts the server when code was pre-loaded (e.g. re-use
# of an existing instance or SKIP_CLONE workflow). On a fresh instance the
# mgmt_server.py file won't exist yet — that's expected and non-fatal.
# -----------------------------------------------------------------------------
MGMT_SCRIPT="/workspace/autostorygen/scripts/mgmt_server.py"

log "Checking for management server..."
if [ -f "$MGMT_SCRIPT" ]; then
    log "Starting management server on port 8001..."
    cd /workspace/autostorygen || fail "Could not cd to /workspace/autostorygen"
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
    log "Code not present yet — management server will be started after code push."
    log "  Next step on your laptop:"
    log "    python scripts/vast_provisioner.py tunnel    # open SSH tunnel"
    log "    python scripts/manage_gpu.py --ssh '...' bootstrap  # push code + start mgmt"
fi

# -----------------------------------------------------------------------------
# 11. Done
# -----------------------------------------------------------------------------
log "=== Provisioning complete ==="
log ""
log "Installed packages:"
pip show diffusers transformers accelerate kokoro fastapi uvicorn 2>/dev/null \
    | grep -E "^Name|^Version" | tee -a "$LOG_FILE"
log ""
log "Next steps on your laptop:"
log "  python scripts/vast_provisioner.py status          # confirm instance is running"
log "  python scripts/vast_provisioner.py tunnel          # print + run SSH tunnel command"
log "  python scripts/manage_gpu.py --ssh '...' bootstrap # push code + start mgmt server"
log "  python scripts/manage_gpu.py start-server --phase 6"
