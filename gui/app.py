#!/usr/bin/env python3
"""ModelArray GUI — Flask/Waitress web interface."""

import json
import os
import signal
import subprocess
import sys
import threading
import time
import webbrowser
from datetime import datetime
from pathlib import Path

# ── Venv self-activation ───────────────────────────────────────────────────────
# If invoked with the wrong Python (e.g. `python app.py` outside the venv),
# re-exec transparently with the venv interpreter so imports always work.
_VENV_PYTHON = Path(__file__).resolve().parent / ".venv" / "bin" / "python"
if _VENV_PYTHON.exists() and Path(sys.executable).resolve() != _VENV_PYTHON.resolve():
    os.execv(str(_VENV_PYTHON), [str(_VENV_PYTHON)] + sys.argv)

try:
    from flask import Flask, Response, jsonify, render_template, request, stream_with_context
    from waitress import serve
except ImportError as e:
    print(f"\n[ERROR] Missing dependency: {e.name}")
    print("Install with:  pip install flask waitress")
    raise

# ── Paths ──────────────────────────────────────────────────────────────────────
BASE_DIR = Path(__file__).resolve().parent.parent   # .../ModelArray/
SCRIPTS_DIR = BASE_DIR
CONFIGS_DIR = BASE_DIR / "configs"
PROJECTS_DIR = Path(__file__).resolve().parent / "projects"
PROJECTS_DIR.mkdir(parents=True, exist_ok=True)
LOGS_DIR = Path(__file__).resolve().parent / "logs"
LOGS_DIR.mkdir(parents=True, exist_ok=True)

app = Flask(__name__)
app.config["TEMPLATES_AUTO_RELOAD"] = True

# ── Global job state ───────────────────────────────────────────────────────────
_job_lock = threading.Lock()
_job: dict = {
    "process": None,
    "step": None,
    "log_file": None,
    "started_at": None,
    "returncode": None,
    "cmd": None,
}


# ── Internal helpers ───────────────────────────────────────────────────────────
def _job_running() -> bool:
    with _job_lock:
        p = _job["process"]
        return p is not None and p.poll() is None


def _kill_job() -> bool:
    with _job_lock:
        p = _job["process"]
        if p is None:
            return False
        try:
            os.killpg(os.getpgid(p.pid), signal.SIGTERM)
        except OSError:
            try:
                p.terminate()
            except OSError:
                pass
        return True


# ── Routes: filesystem browser ────────────────────────────────────────────────
@app.route("/browse", methods=["POST"])
def browse():
    """Return directory listing for the file picker."""
    data = request.get_json(silent=True) or {}
    path = (data.get("path") or "/").strip()
    mode = data.get("mode", "dir")          # "dir" or "file"
    exts = data.get("extensions") or []     # e.g. [".json", ".tsv", ".csv"]

    try:
        p = Path(path)
        if not p.exists() or not p.is_dir():
            p = p.parent if p.parent.exists() else Path("/")

        items = []
        if p.parent != p:
            items.append({"name": "..", "path": str(p.parent), "is_dir": True})

        for child in sorted(p.iterdir(), key=lambda x: (not x.is_dir(), x.name.lower())):
            if child.name.startswith("."):
                continue
            is_dir = child.is_dir()
            if not is_dir and mode == "dir":
                continue
            if not is_dir and exts and not any(child.name.endswith(e) for e in exts):
                continue
            items.append({"name": child.name, "path": str(child), "is_dir": is_dir})

        return jsonify({"current": str(p), "items": items})
    except Exception as exc:
        return jsonify({"error": str(exc)}), 500


@app.route("/mkdir", methods=["POST"])
def mkdir():
    """Create a new directory and return it as the new current path."""
    data = request.get_json(silent=True) or {}
    parent = (data.get("parent") or "").strip()
    name   = (data.get("name")   or "").strip()
    if not parent or not name:
        return jsonify({"error": "parent and name are required"}), 400
    # Safety: no path traversal tricks
    if "/" in name or name in (".", ".."):
        return jsonify({"error": "Invalid folder name"}), 400
    try:
        new_dir = Path(parent) / name
        new_dir.mkdir(parents=False, exist_ok=False)
        return jsonify({"path": str(new_dir)})
    except FileExistsError:
        return jsonify({"error": f"'{name}' already exists"}), 409
    except Exception as exc:
        return jsonify({"error": str(exc)}), 500


# ── Routes: config management ──────────────────────────────────────────────────
@app.route("/")
def index():
    return render_template("index.html")


@app.route("/list_configs")
def list_configs():
    configs = sorted(p.name for p in CONFIGS_DIR.glob("*.json")) if CONFIGS_DIR.exists() else []
    return jsonify({"configs": configs})


# ── Routes: project state ──────────────────────────────────────────────────────
@app.route("/list_projects")
def list_projects():
    projects = sorted(p.stem for p in PROJECTS_DIR.glob("*.json"))
    return jsonify({"projects": projects})


@app.route("/save_project", methods=["POST"])
def save_project():
    data = request.get_json(silent=True) or {}
    name = data.get("name", "").strip()
    state = data.get("state")
    if not name or ".." in name or "/" in name:
        return jsonify({"error": "Invalid project name"}), 400
    if state is None:
        return jsonify({"error": "No state provided"}), 400
    try:
        path = PROJECTS_DIR / (name + ".json")
        path.write_text(json.dumps(state, indent=2))
        return jsonify({"message": f"Project '{name}' saved", "name": name})
    except Exception as exc:
        return jsonify({"error": str(exc)}), 500


@app.route("/load_project")
def load_project():
    name = request.args.get("name", "").strip()
    if not name or ".." in name or "/" in name:
        return jsonify({"error": "Invalid project name"}), 400
    path = PROJECTS_DIR / (name + ".json")
    if not path.exists():
        return jsonify({"error": f"Project '{name}' not found"}), 404
    try:
        state = json.loads(path.read_text())
        return jsonify({"state": state, "name": name})
    except Exception as exc:
        return jsonify({"error": str(exc)}), 500



@app.route("/get_config")
def get_config():
    name = request.args.get("name", "").strip()
    if not name or ".." in name:
        return jsonify({"error": "Invalid filename"}), 400
    path = CONFIGS_DIR / name
    if not path.exists():
        return jsonify({"error": f"Not found: {name}"}), 404
    try:
        content = json.loads(path.read_text())
        return jsonify({"content": content, "name": name})
    except Exception as exc:
        return jsonify({"error": str(exc)}), 500


@app.route("/parse_tsv", methods=["POST"])
def parse_tsv():
    """Return column names from a TSV (or CSV) file."""
    data = request.get_json(silent=True) or {}
    path = (data.get("path") or "").strip()
    if not path or ".." in path:
        return jsonify({"error": "Invalid path"}), 400
    try:
        p = Path(path)
        if not p.exists() or not p.is_file():
            return jsonify({"error": f"File not found: {path}"}), 404
        with open(p, "r", encoding="utf-8", errors="replace") as f:
            header = f.readline().strip()
        sep = "\t" if "\t" in header else ","
        columns = [c.strip().strip('"').strip("'") for c in header.split(sep)]
        columns = [c for c in columns if c]
        return jsonify({"columns": columns})
    except Exception as exc:
        return jsonify({"error": str(exc)}), 500


@app.route("/save_config", methods=["POST"])
def save_config():
    data = request.get_json(silent=True) or {}
    name = data.get("name", "").strip()
    content = data.get("content")
    if not name or ".." in name:
        return jsonify({"error": "Invalid filename"}), 400
    if not name.endswith(".json"):
        name += ".json"
    if content is None:
        return jsonify({"error": "No content provided"}), 400
    try:
        CONFIGS_DIR.mkdir(parents=True, exist_ok=True)
        path = CONFIGS_DIR / name
        path.write_text(json.dumps(content, indent=2))
        return jsonify({"message": f"Saved to configs/{name}", "name": name})
    except Exception as exc:
        return jsonify({"error": str(exc)}), 500


# ── Routes: log management ─────────────────────────────────────────────────────
@app.route("/list_logs")
def list_logs():
    logs = sorted((p.name for p in LOGS_DIR.glob("*.log")), reverse=True)[:30]
    return jsonify({"logs": logs})


@app.route("/log_chunk")
def log_chunk():
    """Return log file content starting at `pos` bytes.  Used for terminal polling."""
    pos = int(request.args.get("pos", 0))
    name = request.args.get("name", "").strip()

    with _job_lock:
        log_file = _job["log_file"]

    if name:
        # Named log (history view)
        log_path = LOGS_DIR / name
    elif log_file:
        log_path = Path(log_file)
    else:
        return jsonify({"chunk": "", "pos": 0, "done": True})

    if not log_path.exists():
        return jsonify({"chunk": "", "pos": 0, "done": True})

    try:
        with open(log_path, "rb") as f:
            f.seek(pos)
            data = f.read(65536)  # up to 64 KB per poll
        chunk = data.decode("utf-8", errors="replace")
        new_pos = pos + len(data)
        file_size = log_path.stat().st_size
        done = not _job_running() and new_pos >= file_size
        return jsonify({"chunk": chunk, "pos": new_pos, "done": done})
    except Exception as exc:
        return jsonify({"error": str(exc)}), 500


# ── Routes: pipeline control ───────────────────────────────────────────────────
@app.route("/run", methods=["POST"])
def run_step():
    if _job_running():
        return jsonify({"error": "A job is already running — stop it first."}), 409

    data = request.get_json(silent=True) or {}
    step = str(data.get("step", "")).strip()
    args = data.get("args", {})

    # Build shell command for each step
    if step == "0":
        cmd = ["bash", str(SCRIPTS_DIR / "0_register_acpc_to_mni.sh")]
        if args.get("input_dir"):
            cmd += ["-i", args["input_dir"]]
        elif not args.get("link_source_dir"):
            return jsonify({"error": "Input directory (-i) or Link-only source (-L) is required for Step 0"}), 400
        if args.get("qsiprep_dir") and args.get("input_dir"):
            cmd += ["-q", args["qsiprep_dir"]]
        if args.get("output_dir"):
            cmd += ["-o", args["output_dir"]]
        if args.get("modelarray_dir"):
            cmd += ["-m", args["modelarray_dir"]]
        if args.get("mask_dir"):
            cmd += ["-b", args["mask_dir"]]
        if args.get("link_source_dir"):
            cmd += ["-L", args["link_source_dir"]]
        if args.get("resolution"):
            cmd += ["-s", args["resolution"]]
        if args.get("jobs"):
            cmd += ["-j", str(args["jobs"])]
        if args.get("interpolation"):
            cmd += ["-n", args["interpolation"]]
        if args.get("force"):
            cmd += ["-f"]

    elif step == "1":
        script = (
            "1_generate_cohort_longitudinal.sh"
            if args.get("longitudinal")
            else "1_generate_cohort.sh"
        )
        cmd = ["bash", str(SCRIPTS_DIR / script)]
        missing = []
        for flag, key in [("-p", "participants"), ("-d", "nii_folder"),
                          ("-m", "mask_folder"), ("-o", "output_folder")]:
            val = args.get(key, "").strip()
            if not val:
                missing.append(key)
            else:
                cmd += [flag, val]
        if missing:
            return jsonify({"error": f"Required for Step 1: {', '.join(missing)}"}), 400
        if args.get("subgroup"):
            cmd += ["-s", args["subgroup"]]

    elif step == "2":
        cmd = ["bash", str(SCRIPTS_DIR / "2_run_convoxel.sh")]
        cohort = args.get("cohort_file", "").strip()
        if not cohort:
            return jsonify({"error": "Cohort CSV (-c) is required for Step 2"}), 400
        cmd += ["-c", cohort]
        group_mask = args.get("group_mask", "").strip()
        if group_mask:
            cmd += ["-g", group_mask]
        if args.get("debug"):
            cmd += ["-d"]

    elif step == "3":
        cmd = ["bash", str(SCRIPTS_DIR / "3_run_model.sh")]
        cfg = args.get("config", "").strip()
        if not cfg:
            return jsonify({"error": "A config file is required for Step 3"}), 400
        cmd.append(str(CONFIGS_DIR / cfg))
        if args.get("test"):
            cmd += ["--test"]

    else:
        return jsonify({"error": f"Unknown step: {step!r}"}), 400

    # Launch
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    log_path = LOGS_DIR / f"step{step}_{timestamp}.log"
    try:
        with open(log_path, "w") as lf:
            lf.write(f"Command: {' '.join(cmd)}\n")
            lf.write(f"Started: {datetime.now().isoformat()}\n")
            lf.write("=" * 60 + "\n\n")
            lf.flush()
            process = subprocess.Popen(
                cmd,
                stdout=lf,
                stderr=subprocess.STDOUT,
                cwd=str(BASE_DIR),
                start_new_session=True,   # detach from our process group
            )

        with _job_lock:
            _job["process"] = process
            _job["step"] = step
            _job["log_file"] = str(log_path)
            _job["started_at"] = time.time()
            _job["returncode"] = None
            _job["cmd"] = cmd

        # Background monitor — records exit code and closes job
        def _monitor():
            rc = process.wait()
            with _job_lock:
                _job["returncode"] = rc
                _job["process"] = None
            with open(log_path, "a") as lf:
                lf.write(f"\n[Finished {datetime.now().isoformat()}  exit={rc}]\n")

        threading.Thread(target=_monitor, daemon=True).start()

        return jsonify({"message": f"Step {step} started", "log_file": str(log_path)})

    except Exception as exc:
        return jsonify({"error": str(exc)}), 500


@app.route("/stop", methods=["POST"])
def stop_job():
    killed = _kill_job()
    return jsonify({"message": "Stop signal sent" if killed else "No active job to stop"})


@app.route("/job_status")
def job_status():
    with _job_lock:
        running = _job["process"] is not None and _job["process"].poll() is None
        return jsonify(
            {
                "running": running,
                "step": _job["step"],
                "log_file": _job["log_file"],
                "started_at": _job["started_at"],
                "returncode": _job["returncode"],
            }
        )


# ── Shutdown ───────────────────────────────────────────────────────────────────
@app.route("/shutdown", methods=["POST"])
def shutdown():
    def _exit():
        time.sleep(0.5)
        os._exit(0)
    threading.Thread(target=_exit, daemon=True).start()
    return jsonify({"message": "Shutting down"})


# ── Entry point ────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    import socket

    port = 8080
    for _ in range(20):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            if s.connect_ex(("127.0.0.1", port)) != 0:
                break
            port += 1

    url = f"http://localhost:{port}"
    print(f"  ModelArray GUI  —  {url}")
    print(f"  Scripts dir:  {BASE_DIR}")
    print(f"  Logs dir:     {LOGS_DIR}")
    print("  Press Ctrl+C to quit\n")

    # Open the browser automatically once the server is ready.
    def _open_browser():
        time.sleep(1.2)
        webbrowser.open_new_tab(url)

    threading.Thread(target=_open_browser, daemon=True).start()

    serve(app, host="0.0.0.0", port=port, threads=4)
