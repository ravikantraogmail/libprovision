"""
Management server — runs permanently on the vast.ai instance (port 8001).
Started by provisioning_script.sh on boot. Never restarted between phases.

Endpoints (all called by manage_gpu.py on the laptop via SSH tunnel):
  GET  /health              — is management server alive?
  POST /push-code           — upload tarball, extract to /workspace/autostorygen
  POST /restart?phase=N     — kill old inference server, install phase deps, start new
  POST /install-deps?phase=N— install phase pip packages only (no restart)
  GET  /logs?lines=60       — tail of /tmp/gpu_server.log
  GET  /status              — GPU memory + running processes
"""

import io
import os
import subprocess
import tarfile
import time
from pathlib import Path

import requests as _requests
from fastapi import FastAPI, File, HTTPException, Query, UploadFile

app = FastAPI()

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
WORKSPACE   = "/workspace/autostorygen"
GPU_LOG     = "/tmp/gpu_server.log"
GPU_PID     = "/tmp/gpu_server.pid"
SERVER_PORT = 8000
HF_HOME     = os.getenv("HF_HOME", "/workspace/.hf_home")
HF_TOKEN    = os.getenv("HF_TOKEN", "")

PHASE_PIP: dict[int, list[str]] = {
    6:  ["diffusers>=0.32.0", "transformers>=4.45.0", "accelerate>=1.0.0",
         "sentencepiece>=0.2.0", "protobuf>=4.0.0", "Pillow>=10.0.0"],
    7:  ["diffusers>=0.32.0", "transformers>=4.45.0", "accelerate>=1.0.0",
         "sentencepiece>=0.2.0", "imageio>=2.34.0", "imageio-ffmpeg>=0.5.0",
         "opencv-python-headless>=4.9.0", "Pillow>=10.0.0"],
    8:  ["kokoro>=0.9.2", "soundfile>=0.12.1", "numpy"],
    9:  ["kokoro>=0.9.2", "soundfile>=0.12.1", "numpy"],
    89: ["kokoro>=0.9.2", "soundfile>=0.12.1", "numpy"],
    10: ["audiocraft", "soundfile>=0.12.1"],
    11: ["audiocraft", "soundfile>=0.12.1"],
}


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def _kill_inference_server() -> None:
    """Kill all python3/uvicorn processes and wait for GPU VRAM to free."""
    subprocess.run(["pkill", "-9", "-f", "python3"], capture_output=True)
    time.sleep(5)


def _pip_install(packages: list[str]) -> str:
    """Install pip packages, return combined stdout+stderr."""
    if not packages:
        return ""
    result = subprocess.run(
        ["pip", "install", "--quiet", "--timeout", "120"] + packages,
        capture_output=True, text=True
    )
    return result.stdout + result.stderr


def _wait_healthy(timeout: int = 120) -> bool:
    """Poll inference server /health until OK or timeout."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            r = _requests.get(f"http://127.0.0.1:{SERVER_PORT}/health", timeout=2)
            if r.ok:
                return True
        except Exception:
            pass
        time.sleep(3)
    return False


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------
@app.get("/health")
def health():
    return {"status": "ok", "service": "management", "port": 8001}


@app.post("/push-code")
async def push_code(file: UploadFile = File(...)):
    """
    Accept a .tar.gz of the project and extract it to /workspace.
    The tarball root must be 'autostorygen/' so it lands at
    /workspace/autostorygen.
    """
    content = await file.read()
    try:
        with tarfile.open(fileobj=io.BytesIO(content), mode="r:gz") as tar:
            tar.extractall("/workspace")
        return {"status": "ok", "extracted_to": WORKSPACE}
    except Exception as exc:
        raise HTTPException(500, f"Tarball extraction failed: {exc}")


@app.post("/install-deps")
def install_deps(phase: int = Query(...)):
    """Install pip packages for a given phase without restarting the server."""
    pkgs = PHASE_PIP.get(phase, [])
    if not pkgs:
        return {"status": "ok", "phase": phase, "installed": []}
    out = _pip_install(pkgs)
    return {"status": "ok", "phase": phase, "installed": pkgs, "output": out[-500:]}


@app.post("/restart")
def restart_server(phase: int = Query(...)):
    """
    Kill inference server → install phase deps → start new server → wait healthy.
    HF_TOKEN and HF_HOME are injected from management server's environment.
    """
    _kill_inference_server()

    # Install phase-specific packages
    pkgs = PHASE_PIP.get(phase, [])
    pip_out = _pip_install(pkgs)

    # Build env for child process
    env = os.environ.copy()
    env["PHASE"]              = str(phase)
    env["HF_HOME"]            = HF_HOME
    env["PYTORCH_ALLOC_CONF"] = "expandable_segments:True"
    if HF_TOKEN:
        env["HF_TOKEN"] = HF_TOKEN

    # Start inference server
    Path(GPU_LOG).write_text("")  # clear old log
    with open(GPU_LOG, "w") as log_f:
        proc = subprocess.Popen(
            ["python3", "-u", "-m", "uvicorn", "scripts.gpu_server:app",
             "--host", "0.0.0.0", "--port", str(SERVER_PORT), "--workers", "1"],
            cwd=WORKSPACE, env=env,
            stdout=log_f, stderr=log_f,
        )

    Path(GPU_PID).write_text(str(proc.pid))

    healthy = _wait_healthy(timeout=120)
    return {
        "status":  "ok" if healthy else "timeout",
        "phase":   phase,
        "pid":     proc.pid,
        "healthy": healthy,
        "pip_out": pip_out[-300:] if pip_out else "",
    }


@app.get("/logs")
def get_logs(lines: int = Query(default=60, ge=1, le=500)):
    """Return the last N lines of the inference server log."""
    try:
        all_lines = Path(GPU_LOG).read_text(errors="replace").splitlines()
        return {"lines": all_lines[-lines:], "total": len(all_lines)}
    except FileNotFoundError:
        return {"lines": [], "total": 0}


@app.get("/status")
def status():
    """GPU memory usage + running inference server process info."""
    nvidia = subprocess.run(
        ["nvidia-smi",
         "--query-gpu=memory.used,memory.total,utilization.gpu",
         "--format=csv,noheader,nounits"],
        capture_output=True, text=True
    )
    ps = subprocess.run(
        ["pgrep", "-af", "uvicorn"],
        capture_output=True, text=True
    )
    inference_healthy = False
    try:
        r = _requests.get(f"http://127.0.0.1:{SERVER_PORT}/health", timeout=2)
        inference_healthy = r.ok
    except Exception:
        pass

    return {
        "gpu":              nvidia.stdout.strip(),
        "inference_server": ps.stdout.strip(),
        "inference_healthy": inference_healthy,
    }
