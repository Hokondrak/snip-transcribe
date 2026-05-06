"""
SnipTranscribe — Worker Script
Polls clipboard for a screenshot image, sends it to a local Ollama vision model,
and writes the transcribed text back to the clipboard.

Launched by sniptranscribe.ahk via pythonw.exe (no console window).
"""

import base64
import io
import json
import os
import sys
import tempfile
import time
import tomllib
import atexit
from pathlib import Path

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
APPDATA_DIR = Path(os.environ.get("APPDATA", "")) / "sniptranscribe"
CONFIG_FILENAME = "config.toml"
LOCK_FILENAME = "sniptranscribe.lock"
MAX_IMAGE_EDGE = 1024
POLL_INTERVAL_S = 0.2
POLL_TIMEOUT_S = 30.0
REQUEST_TIMEOUT_S = 120
DEFAULT_NUM_CTX = 16384

# ---------------------------------------------------------------------------
# Defaults (used when config keys are missing)
# ---------------------------------------------------------------------------
DEFAULT_CONFIG = {
    "hotkey": {"binding": "Ctrl+Shift+T"},
    "model": {
        "name": "glm-ocr",
        "keep_alive": "15m",
        "endpoint": "http://localhost:11434",
    },
    "prompt": {
        "template": (
            "Transcribe the text content of this image. Preserve structure using "
            "Markdown: headings, bullets, numbered lists, code blocks for code or "
            "monospace text, and tables where applicable. Do not add commentary, "
            "explanations, or surrounding text — output only the transcription. "
            "If the image contains a diagram or chart with no readable text, "
            "output a single line: [diagram: <one-line description>]."
        )
    },
    "output": {"format": "markdown", "strip_trailing_whitespace": True},
    "notifications": {"on_start": False, "on_success": True, "on_error": True},
}


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
def load_config() -> dict:
    """Load config.toml from %APPDATA%/sniptranscribe, falling back to script dir."""
    paths = [
        APPDATA_DIR / CONFIG_FILENAME,
        Path(__file__).parent / CONFIG_FILENAME,
    ]
    for p in paths:
        if p.is_file():
            with open(p, "rb") as f:
                user_cfg = tomllib.load(f)
            # Merge with defaults (shallow per-section)
            merged = {}
            for section, defaults in DEFAULT_CONFIG.items():
                merged[section] = {**defaults, **user_cfg.get(section, {})}
            return merged
    return dict(DEFAULT_CONFIG)


# ---------------------------------------------------------------------------
# File lock (concurrency guard)
# ---------------------------------------------------------------------------
_lock_handle = None


def acquire_lock() -> bool:
    """Try to acquire a file lock. Returns True on success, False if already held."""
    global _lock_handle
    lock_path = Path(tempfile.gettempdir()) / LOCK_FILENAME
    try:
        # On Windows, opening with exclusive access acts as a lock
        _lock_handle = open(lock_path, "x")
        atexit.register(release_lock)
        return True
    except FileExistsError:
        # Check if the lock file is stale (older than 5 minutes)
        try:
            age = time.time() - lock_path.stat().st_mtime
            if age > 300:
                lock_path.unlink(missing_ok=True)
                _lock_handle = open(lock_path, "x")
                atexit.register(release_lock)
                return True
        except OSError:
            pass
        return False


def release_lock():
    """Release the file lock."""
    global _lock_handle
    if _lock_handle:
        try:
            _lock_handle.close()
        except OSError:
            pass
        try:
            Path(tempfile.gettempdir(), LOCK_FILENAME).unlink(missing_ok=True)
        except OSError:
            pass
        _lock_handle = None


# ---------------------------------------------------------------------------
# Notifications
# ---------------------------------------------------------------------------
def notify(title: str, body: str, cfg: dict, *, is_error: bool = False, is_success: bool = False):
    """Show a Windows toast notification based on config preferences."""
    notif_cfg = cfg.get("notifications", {})

    if is_error and not notif_cfg.get("on_error", True):
        return
    if is_success and not notif_cfg.get("on_success", True):
        return
    if not is_error and not is_success and not notif_cfg.get("on_start", False):
        return

    try:
        from win11toast import toast

        kwargs = {"app_id": "SnipTranscribe"}

        # Play a chime on success
        if is_success:
            kwargs["audio"] = "ms-winsoundevent:Notification.Default"

        # Non-blocking: use scenario='reminder' would block; we just fire-and-forget
        toast(title, body, **kwargs)
    except Exception:
        pass  # Notifications are best-effort; never crash over them


# ---------------------------------------------------------------------------
# Clipboard: read image
# ---------------------------------------------------------------------------
def poll_clipboard_for_image(timeout_s: float = POLL_TIMEOUT_S) -> "Image.Image | None":
    """Poll the clipboard for an image, up to timeout_s seconds."""
    from PIL import Image, ImageGrab

    deadline = time.time() + timeout_s
    while time.time() < deadline:
        try:
            img = ImageGrab.grabclipboard()
            if isinstance(img, Image.Image):
                return img
        except Exception:
            pass
        time.sleep(POLL_INTERVAL_S)
    return None


# ---------------------------------------------------------------------------
# Image preprocessing
# ---------------------------------------------------------------------------
def preprocess_image(img: "Image.Image") -> str:
    """Trim whitespace, resize if needed, convert to PNG, return raw base64 string."""
    from PIL import Image, ImageOps

    # Convert to RGB first (needed for all subsequent operations)
    if img.mode not in ("RGB", "L"):
        img = img.convert("RGB")

    # Trim whitespace borders — reduces image tokens sent to the model
    # getbbox() on an inverted image finds the bounding box of non-white content
    try:
        gray = img.convert("L")
        # Invert so white→black, then find bbox of non-black (i.e. non-white original)
        inverted = ImageOps.invert(gray)
        bbox = inverted.getbbox()
        if bbox:
            # Add a small padding (8px) so text isn't right at the edge
            pad = 8
            left = max(0, bbox[0] - pad)
            upper = max(0, bbox[1] - pad)
            right = min(img.width, bbox[2] + pad)
            lower = min(img.height, bbox[3] + pad)
            cropped = img.crop((left, upper, right, lower))
            # Only use the crop if it actually removed meaningful whitespace (>10%)
            if cropped.width * cropped.height < img.width * img.height * 0.9:
                img = cropped
    except Exception:
        pass  # If trimming fails for any reason, proceed with the original image

    # Resize so longest edge ≤ MAX_IMAGE_EDGE
    w, h = img.size
    if max(w, h) > MAX_IMAGE_EDGE:
        img.thumbnail((MAX_IMAGE_EDGE, MAX_IMAGE_EDGE), Image.LANCZOS)

    # Encode as PNG → base64
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    return base64.b64encode(buf.getvalue()).decode("ascii")


# ---------------------------------------------------------------------------
# Ollama API call
# ---------------------------------------------------------------------------
def call_ollama(base64_image: str, cfg: dict) -> str:
    """Send image to Ollama /api/generate and return the response text."""
    import requests

    model_cfg = cfg.get("model", {})
    prompt_cfg = cfg.get("prompt", {})

    endpoint = model_cfg.get("endpoint", "http://localhost:11434")
    url = f"{endpoint}/api/generate"

    payload = {
        "model": model_cfg.get("name", "glm-ocr"),
        "prompt": prompt_cfg.get("template", DEFAULT_CONFIG["prompt"]["template"]).strip(),
        "images": [base64_image],
        "stream": False,
        "options": {"num_ctx": DEFAULT_NUM_CTX},
        "keep_alive": model_cfg.get("keep_alive", "15m"),
    }

    response = requests.post(url, json=payload, timeout=REQUEST_TIMEOUT_S)
    response.raise_for_status()

    data = response.json()
    return data.get("response", "").strip()


# ---------------------------------------------------------------------------
# Clipboard: write text
# ---------------------------------------------------------------------------
def write_to_clipboard(text: str, cfg: dict):
    """Write transcribed text to clipboard."""
    import pyperclip

    output_cfg = cfg.get("output", {})
    if output_cfg.get("strip_trailing_whitespace", True):
        lines = text.split("\n")
        text = "\n".join(line.rstrip() for line in lines)

    pyperclip.copy(text)


# ---------------------------------------------------------------------------
# Ollama auto-start
# ---------------------------------------------------------------------------
def _try_start_ollama(cfg: dict) -> bool:
    """Attempt to start Ollama serve in the background. Returns True if it comes online."""
    import subprocess
    import requests

    model_cfg = cfg.get("model", {})
    endpoint = model_cfg.get("endpoint", "http://localhost:11434")

    try:
        # Launch ollama serve as a detached background process
        subprocess.Popen(
            ["ollama", "serve"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            creationflags=subprocess.DETACHED_PROCESS | subprocess.CREATE_NO_WINDOW,
        )
    except FileNotFoundError:
        return False  # ollama not in PATH
    except Exception:
        return False

    # Poll until Ollama responds (up to 15 seconds)
    deadline = time.time() + 15
    while time.time() < deadline:
        try:
            r = requests.get(f"{endpoint}/", timeout=2)
            if r.status_code == 200:
                return True
        except Exception:
            pass
        time.sleep(1)
    return False


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    cfg = load_config()

    # ── Concurrency guard ──────────────────────────────────────────────
    if not acquire_lock():
        notify("SnipTranscribe", "Already transcribing.", cfg, is_error=True)
        sys.exit(0)

    try:
        # ── Start notification ─────────────────────────────────────────
        notify("SnipTranscribe", "Transcribing…", cfg)

        # ── Poll clipboard for image ──────────────────────────────────
        img = poll_clipboard_for_image()
        if img is None:
            notify("SnipTranscribe", "No image captured.", cfg, is_error=True)
            sys.exit(0)

        # ── Preprocess ────────────────────────────────────────────────
        base64_image = preprocess_image(img)

        # ── Call Ollama ───────────────────────────────────────────────
        try:
            text = call_ollama(base64_image, cfg)
        except Exception as e:
            error_str = str(e)
            is_conn_error = "ConnectionError" in type(e).__name__ or "Connection refused" in error_str

            # Connection refused → try to auto-start Ollama, then retry
            if is_conn_error:
                if _try_start_ollama(cfg):
                    # Ollama started — retry the call
                    try:
                        text = call_ollama(base64_image, cfg)
                    except Exception as e2:
                        notify(
                            "SnipTranscribe",
                            "Ollama started but transcription failed. Is the model pulled?",
                            cfg,
                            is_error=True,
                        )
                        sys.exit(1)
                else:
                    notify(
                        "SnipTranscribe",
                        "Ollama not running and could not be started automatically.",
                        cfg,
                        is_error=True,
                    )
                    sys.exit(1)
            # 404 → Model not pulled
            elif "404" in error_str or "not found" in error_str.lower():
                model_name = cfg.get("model", {}).get("name", "glm-ocr")
                notify(
                    "SnipTranscribe",
                    f"Model not found. Run: ollama pull {model_name}",
                    cfg,
                    is_error=True,
                )
                sys.exit(1)
            else:
                # Truncate long error messages
                short_err = error_str[:120] if len(error_str) > 120 else error_str
                notify(
                    "SnipTranscribe",
                    f"Transcription failed: {short_err}",
                    cfg,
                    is_error=True,
                )
                sys.exit(1)

        # ── Validate response ─────────────────────────────────────────
        if not text:
            notify("SnipTranscribe", "No text extracted.", cfg, is_error=True)
            sys.exit(0)

        # ── Write to clipboard ────────────────────────────────────────
        write_to_clipboard(text, cfg)

        # ── Success ───────────────────────────────────────────────────
        # Brief summary: first 60 chars of transcribed text
        preview = text[:60].replace("\n", " ")
        if len(text) > 60:
            preview += "…"
        notify("SnipTranscribe ✓", preview, cfg, is_success=True)

    finally:
        release_lock()


if __name__ == "__main__":
    main()
