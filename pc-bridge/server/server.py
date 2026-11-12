# PC Bridge - MCP server. Started by setup.ps1 (START.bat), settings come from ..\config.json.
# Serves MCP (streamable HTTP) on 127.0.0.1:<port>/<secret>/mcp; ngrok exposes it to the agent.
# Every tool call is written to logs\tools.log.

import base64
import ctypes
import fnmatch
import functools
import getpass
import hmac
import inspect
import json
import locale
import os
import platform
import re
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
import urllib.parse
import xml.etree.ElementTree as ET
from datetime import datetime
from html.parser import HTMLParser
from io import BytesIO
from pathlib import Path

import anyio.to_thread
import httpx
import uvicorn
from mcp.server.fastmcp import FastMCP, Image
from mcp.server.fastmcp.exceptions import ToolError

try:
    from mcp.types import ToolAnnotations
except ImportError:  # older mcp
    ToolAnnotations = None
try:
    from mcp.server.transport_security import TransportSecuritySettings
except ImportError:  # older mcp
    TransportSecuritySettings = None

# ---------------------------------------------------------------- config ----

ROOT = Path(__file__).resolve().parent.parent
LOGS_DIR = ROOT / "logs"
JOBS_DIR = LOGS_DIR / "jobs"
IS_WIN = os.name == "nt"
CREATE_NO_WINDOW = 0x08000000
CREATE_NEW_PROCESS_GROUP = 0x00000200
DETACHED_PROCESS = 0x00000008
MAX_TEXT = 60_000


def _fatal(message):
    print(f"PC Bridge: {message}", file=sys.stderr, flush=True)
    sys.exit(1)


def _load_config():
    path = ROOT / "config.json"
    try:
        with open(path, encoding="utf-8-sig") as f:  # PowerShell 5 writes UTF-8 with BOM
            cfg = json.load(f)
    except FileNotFoundError:
        _fatal(f"{path} not found. Start the bridge with START.bat.")
    except ValueError as e:
        _fatal(f"config.json is damaged ({e}). Run SETTINGS.bat.")
    if not isinstance(cfg, dict):
        _fatal("config.json is damaged. Run SETTINGS.bat.")
    return cfg


def _read_version():
    try:
        return (ROOT / "VERSION.txt").read_text(encoding="utf-8-sig").strip() or "1.2"
    except OSError:
        return "1.2"


CFG = _load_config()
SECRET = str(CFG.get("secret") or "")
if not re.fullmatch(r"[A-Za-z0-9_-]{16,}", SECRET):
    _fatal("config.json has no valid secret key. Run SETTINGS.bat.")
VERSION = _read_version()
PORT = int(CFG.get("port") or 8765)
WORKSPACE = Path(os.path.realpath(CFG.get("workspace") or ROOT / "workspace"))
FULL_DISK = bool(CFG.get("full_disk"))
MAX_DOWNLOAD_MB = int(CFG.get("max_download_mb") or 4096)
MODULES = {
    "internet": bool(CFG.get("enable_internet")),
    "shell": bool(CFG.get("enable_shell")),
    "blender": bool(CFG.get("enable_blender")),
    "roblox": bool(CFG.get("enable_roblox")),
    "screen": bool(CFG.get("enable_screen")),
}
for _d in (WORKSPACE, LOGS_DIR, JOBS_DIR):
    _d.mkdir(parents=True, exist_ok=True)
RUN_STAMP = datetime.now().strftime("%Y%m%d-%H%M%S")

# --------------------------------------------------------------- logging ----

_log_lock = threading.Lock()
_QUIET_ARGS = {"content", "code", "data_base64", "text"}  # log only their length


def log(line):
    stamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    with _log_lock:
        try:
            with open(LOGS_DIR / "tools.log", "a", encoding="utf-8") as f:
                f.write(f"{stamp}  {line}\n")
        except OSError:
            pass


def _short_args(kwargs):
    parts = []
    for key, value in kwargs.items():
        if key in _QUIET_ARGS and isinstance(value, str):
            parts.append(f"{key}=<{len(value)} chars>")
        else:
            text = repr(value)
            parts.append(f"{key}={text if len(text) <= 300 else text[:300] + '...'}")
    return ", ".join(parts)


# ----------------------------------------------------------- MCP server ----

INSTRUCTIONS = f"""PC Bridge runs on the user's own computer ({platform.system()}). Its tools act on that computer.
- Relative paths are inside the workspace folder ({WORKSPACE}). {"Absolute paths anywhere on the disk are allowed." if FULL_DISK else "Paths outside the workspace are blocked."}
- Long work (commands, renders, downloads, builds) waits up to `timeout` seconds and then keeps running as a background job:
  check it with job_status(job_id) and cancel it with job_stop(job_id). background=true returns immediately.
- view_image shows an image file; read_file_base64 / write_file_base64 move files in chunks.
- Every action is logged on the PC (logs/tools.log). Ask the user before deleting things or doing anything risky."""


def _fastmcp_kwargs():
    params = inspect.signature(FastMCP.__init__).parameters
    kwargs = {"name": "PC Bridge", "instructions": INSTRUCTIONS, "stateless_http": True, "json_response": True}
    if "log_level" in params:
        kwargs["log_level"] = "WARNING"  # INFO logs every request into server.err.log
    if "transport_security" in params and TransportSecuritySettings is not None:
        # Requests arrive through ngrok; the secret path (SecretPathGate) is the access check.
        kwargs["transport_security"] = TransportSecuritySettings(enable_dns_rebinding_protection=False)
    if "max_request_body_size" in params:
        kwargs["max_request_body_size"] = 32 * 1024 * 1024
    return kwargs


mcp = FastMCP(**_fastmcp_kwargs())
mcp._mcp_server.version = VERSION  # otherwise serverInfo reports the mcp library version
_TOOL_PARAMS = inspect.signature(mcp.tool).parameters
REGISTERED = []


def bridge_tool(module=None, read_only=False, destructive=False, open_world=False):
    """Register a blocking function as an MCP tool if its module is enabled.

    FastMCP calls sync tools on the event loop, so the work is moved to a thread
    to keep the server responsive (job_status must answer while a render runs)."""

    def decorate(fn):
        if module and not MODULES.get(module):
            return fn

        @functools.wraps(fn)
        async def wrapper(**kwargs):
            log(f"CALL {fn.__name__}({_short_args(kwargs)})")
            started = time.monotonic()
            try:
                result = await anyio.to_thread.run_sync(functools.partial(fn, **kwargs))
            except ToolError as e:
                log(f"FAIL {fn.__name__}: {str(e)[:500]}")
                raise
            except (Exception, SystemExit) as e:  # SystemExit from a library must not stop the bridge
                log(f"FAIL {fn.__name__}: {type(e).__name__}: {str(e)[:500]}")
                raise ToolError(f"{type(e).__name__}: {e}") from e
            log(f"DONE {fn.__name__} ({time.monotonic() - started:.1f}s)")
            return result

        options = {}
        if "structured_output" in _TOOL_PARAMS:
            options["structured_output"] = False
        if "annotations" in _TOOL_PARAMS and ToolAnnotations is not None:
            options["annotations"] = ToolAnnotations(
                readOnlyHint=read_only, destructiveHint=destructive, openWorldHint=open_world
            )
        mcp.tool(**options)(wrapper)
        REGISTERED.append(fn.__name__)
        return fn

    return decorate


# --------------------------------------------------------------- helpers ----


def clip(text, limit=MAX_TEXT):
    if len(text) <= limit:
        return text
    return text[:limit] + f"\n...[cut: {len(text) - limit} more characters]"


def human_size(n):
    n = float(n)
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1024 or unit == "GB":
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1024


def _norm(path):
    return os.path.normcase(os.path.normpath(str(path)))


def is_inside(path, root):
    try:
        return os.path.commonpath([_norm(path), _norm(root)]) == _norm(root)
    except ValueError:  # different drives
        return False


def resolve(p, must_exist=False):
    """Turn a user path into an absolute path, enforcing the workspace limit."""
    raw = str(p if p is not None else "").strip().strip('"').strip() or "."
    if FULL_DISK:
        raw = os.path.expandvars(os.path.expanduser(raw))
    path = Path(raw)
    if not path.is_absolute():
        path = WORKSPACE / path
    path = Path(os.path.realpath(path))  # also resolves symlinks that point outside
    if not FULL_DISK and not is_inside(path, WORKSPACE):
        raise ToolError(
            f"'{p}' is outside the workspace folder ({WORKSPACE}). Full-disk access is off: "
            "use paths inside the workspace, or turn on full-disk access with SETTINGS.bat."
        )
    if must_exist and not path.exists():
        raise ToolError(f"Not found: {show(path)}")
    return path


def show(path):
    """Path as the agent should pass it back: relative inside the workspace, absolute outside."""
    path = Path(path)
    if is_inside(path, WORKSPACE):
        return os.path.relpath(path, WORKSPACE)
    return str(path)


def decode_text(data):
    if data.startswith((b"\xff\xfe", b"\xfe\xff")):
        return data.decode("utf-16", errors="replace")
    try:
        return data.decode("utf-8-sig")
    except UnicodeDecodeError:
        pass
    encoding = locale.getpreferredencoding(False) or "latin-1"
    if encoding.lower().replace("-", "") == "utf8":
        encoding = "latin-1"
    return data.decode(encoding, errors="replace")


def decode_output(data):
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        pass
    if IS_WIN:  # console programs that ignore UTF-8 write in the OEM code page (cp866 on Russian Windows)
        try:
            return data.decode(f"cp{ctypes.windll.kernel32.GetOEMCP()}", errors="replace")
        except Exception:
            pass
    return data.decode("utf-8", errors="replace")


def read_tail(path, max_chars):
    try:
        size = path.stat().st_size
        with open(path, "rb") as f:
            if size > max_chars * 4:
                f.seek(size - max_chars * 4)
            data = f.read()
    except OSError:
        return ""
    if len(data) < size:
        data = data.lstrip(bytes(range(0x80, 0xC0)))  # don't start mid UTF-8 character
    text = decode_output(data).replace("\r\n", "\n")
    if len(text) > max_chars or len(data) < size:
        text = "...(earlier output cut)...\n" + text[-max_chars:]
    return text


def image_content(img, max_size=1280, fmt="jpeg"):
    from PIL import Image as PILImage

    if max(img.size) > max_size:
        img = img.copy()
        img.thumbnail((max_size, max_size), PILImage.LANCZOS)
    if fmt == "jpeg" and img.mode != "RGB":
        rgba = img.convert("RGBA")
        background = PILImage.new("RGB", rgba.size, (255, 255, 255))
        background.paste(rgba, mask=rgba.split()[3])
        img = background
    buf = BytesIO()
    if fmt == "jpeg":
        img.save(buf, "JPEG", quality=85)
    else:
        img.save(buf, "PNG", optimize=True)
    return img.size, Image(data=buf.getvalue(), format=fmt)


def load_image_preview(path, max_size=1280):
    from PIL import Image as PILImage
    from PIL import ImageOps

    with PILImage.open(path) as img:
        original = img.size
        img = ImageOps.exif_transpose(img)
        img.load()
    shown, content = image_content(img, max_size)
    return original, shown, content


def open_gui(argv):
    """Start a desktop program that should stay open after the bridge stops."""
    kwargs = {"cwd": str(WORKSPACE), "stdin": subprocess.DEVNULL, "stdout": subprocess.DEVNULL,
              "stderr": subprocess.DEVNULL, "close_fds": True}
    if IS_WIN:
        kwargs["creationflags"] = DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP
    else:
        kwargs["start_new_session"] = True
    subprocess.Popen([str(a) for a in argv], **kwargs)


# ------------------------------------------------------------------ jobs ----
# Every external program runs as a job: output goes to logs\jobs\*.log, the tool waits up to
# `timeout` seconds and otherwise leaves it running so the agent can poll job_status.

JOBS = {}
_jobs_lock = threading.Lock()
_job_counter = 0


def _kill_on_close_job():
    """Windows job object that kills our child processes when the bridge stops (Q, STOP.bat)."""
    if not IS_WIN:
        return None
    try:
        from ctypes import wintypes

        k32 = ctypes.WinDLL("kernel32", use_last_error=True)

        class IO_COUNTERS(ctypes.Structure):
            _fields_ = [(n, ctypes.c_ulonglong) for n in (
                "ReadOperationCount", "WriteOperationCount", "OtherOperationCount",
                "ReadTransferCount", "WriteTransferCount", "OtherTransferCount")]

        class BASIC_LIMITS(ctypes.Structure):
            _fields_ = [("PerProcessUserTimeLimit", ctypes.c_int64), ("PerJobUserTimeLimit", ctypes.c_int64),
                        ("LimitFlags", wintypes.DWORD), ("MinimumWorkingSetSize", ctypes.c_size_t),
                        ("MaximumWorkingSetSize", ctypes.c_size_t), ("ActiveProcessLimit", wintypes.DWORD),
                        ("Affinity", ctypes.c_size_t), ("PriorityClass", wintypes.DWORD),
                        ("SchedulingClass", wintypes.DWORD)]

        class EXTENDED_LIMITS(ctypes.Structure):
            _fields_ = [("BasicLimitInformation", BASIC_LIMITS), ("IoInfo", IO_COUNTERS),
                        ("ProcessMemoryLimit", ctypes.c_size_t), ("JobMemoryLimit", ctypes.c_size_t),
                        ("PeakProcessMemoryUsed", ctypes.c_size_t), ("PeakJobMemoryUsed", ctypes.c_size_t)]

        k32.CreateJobObjectW.restype = wintypes.HANDLE
        k32.CreateJobObjectW.argtypes = [ctypes.c_void_p, wintypes.LPCWSTR]
        k32.SetInformationJobObject.argtypes = [wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p, wintypes.DWORD]
        k32.AssignProcessToJobObject.argtypes = [wintypes.HANDLE, wintypes.HANDLE]
        handle = k32.CreateJobObjectW(None, None)
        if not handle:
            return None
        info = EXTENDED_LIMITS()
        info.BasicLimitInformation.LimitFlags = 0x2000  # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        if not k32.SetInformationJobObject(handle, 9, ctypes.byref(info), ctypes.sizeof(info)):
            return None
        return k32, handle
    except Exception:
        return None


_WIN_JOB = _kill_on_close_job()


class Job:
    def __init__(self, kind, title):
        global _job_counter
        with _jobs_lock:
            _job_counter += 1
            self.id = f"{kind}-{_job_counter}"
        self.kind = kind
        self.title = title
        self.stem = JOBS_DIR / f"{RUN_STAMP}_{self.id}"
        self.log_path = Path(f"{self.stem}.log")
        self.started = time.time()
        self.finished = None
        self.status = "running"
        self.exit_code = None
        self.proc = None
        self.progress = ""
        self.result = ""
        self.project = None
        self.on_finish = None
        self.done = threading.Event()
        self.stop_requested = threading.Event()
        with _jobs_lock:
            JOBS[self.id] = self
            finished = [j for j in JOBS.values() if j.done.is_set()]
            for old in finished[: max(0, len(JOBS) - 200)]:
                JOBS.pop(old.id, None)


def _finish(job, status, code=None):
    job.exit_code = code
    job.finished = time.time()
    if job.status == "running":
        job.status = status
    if job.on_finish:
        try:
            job.on_finish(job)
        except Exception as e:
            job.result += f"\n(post-processing failed: {e})"
    job.done.set()


def launch(job, argv, cwd=None):
    argv = [str(a) for a in argv]
    log_file = open(job.log_path, "wb")
    kwargs = {"cwd": str(cwd or WORKSPACE), "stdin": subprocess.DEVNULL, "stdout": log_file,
              "stderr": subprocess.STDOUT}
    if IS_WIN:
        kwargs["creationflags"] = CREATE_NO_WINDOW | CREATE_NEW_PROCESS_GROUP
    else:
        kwargs["start_new_session"] = True
    try:
        job.proc = subprocess.Popen(argv, **kwargs)
    except OSError as e:
        log_file.close()
        job.result = f"Could not start {argv[0]}: {e}"
        _finish(job, "failed")
        raise ToolError(job.result) from e
    if _WIN_JOB:
        try:
            _WIN_JOB[0].AssignProcessToJobObject(_WIN_JOB[1], int(job.proc._handle))
        except Exception:
            pass

    def watch():
        code = job.proc.wait()
        log_file.close()
        _finish(job, "finished" if code == 0 else "failed", code)

    threading.Thread(target=watch, daemon=True, name=f"watch-{job.id}").start()
    return job


def run_in_thread(job, target):
    def body():
        try:
            job.result = target(job) or ""
            _finish(job, "finished", 0)
        except Exception as e:
            job.result = str(e) if isinstance(e, ToolError) else f"{type(e).__name__}: {e}"
            _finish(job, "stopped" if job.stop_requested.is_set() else "failed", 1)

    threading.Thread(target=body, daemon=True, name=f"job-{job.id}").start()
    return job


def kill_tree(proc):
    if IS_WIN:
        subprocess.run(["taskkill", "/PID", str(proc.pid), "/T", "/F"], stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, creationflags=CREATE_NO_WINDOW)
        return
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(proc.pid, sig)
        except (ProcessLookupError, PermissionError):
            return
        try:
            proc.wait(timeout=3)
            return
        except subprocess.TimeoutExpired:
            continue


def stop_job(job):
    if job.done.is_set():
        return False
    job.stop_requested.set()
    job.status = "stopped"
    if job.proc is not None and job.proc.poll() is None:
        kill_tree(job.proc)
    return True


def job_report(job, tail=6000):
    elapsed = (job.finished or time.time()) - job.started
    head = f"Job {job.id} [{job.status}"
    if job.proc is not None and job.exit_code is not None:
        head += f", exit code {job.exit_code}"
    lines = [f"{head}] {elapsed:.1f}s - {job.title}"]
    if job.progress:
        lines.append(f"Progress: {job.progress}")
    if job.result:
        lines.append(job.result.strip())
    if job.proc is not None:
        output = read_tail(job.log_path, tail)
        if output.strip():
            lines.append("--- output ---\n" + output.rstrip())
        else:
            lines.append("(no output yet)" if job.status == "running" else "(no output)")
    return "\n".join(lines)


def wait_report(job, timeout, background, tail=6000):
    if background:
        return (f"Started background job {job.id} ({job.title}).\n"
                f'Check it with job_status(job_id="{job.id}"), cancel it with job_stop.')
    timeout = max(1, min(int(timeout), 3600))
    if job.done.wait(timeout):
        return job_report(job, tail)
    return (job_report(job, tail) + f"\n\nStill running after {timeout}s, so it continues in the background "
            f'as job {job.id}. Check it later with job_status(job_id="{job.id}") or cancel it with job_stop.')


def get_job(job_id):
    job = JOBS.get((job_id or "").strip())
    if not job:
        known = ", ".join(list(JOBS)[-15:]) or "none"
        raise ToolError(f"No job '{job_id}'. Known jobs: {known}")
    return job


# ---------------------------------------------------------- always tools ----


@bridge_tool(read_only=True)
def server_info() -> str:
    """Check that PC Bridge works: computer name, enabled modules, workspace folder, running jobs and tools."""
    lines = [
        f"PC Bridge {VERSION} is online.",
        f"Computer: {socket.gethostname()} - {platform.system()} {platform.release()} ({platform.machine()}), "
        f"user {getpass.getuser()}, Python {platform.python_version()}",
        f"Local time: {datetime.now():%Y-%m-%d %H:%M:%S}",
        f"Workspace: {WORKSPACE}",
        f"File access: {'whole disk' if FULL_DISK else 'workspace folder only'}",
        "Modules: files ON, " + ", ".join(f"{name} {'ON' if on else 'off'}" for name, on in MODULES.items()),
    ]
    if MODULES["shell"]:
        lines.append(f"Shell: {shell_name()}")
    if MODULES["blender"]:
        lines.append(f"Blender: {CFG.get('blender_path') or 'not found'}")
    if MODULES["roblox"]:
        lines.append(f"Roblox Studio: {find_studio() or 'not found'}; Rojo: {find_rojo() or 'not found'}")
    if MODULES["screen"]:
        try:
            width, height = pyautogui().size()
            lines.append(f"Screen: {width}x{height}")
        except Exception as e:
            lines.append(f"Screen: unavailable ({e})")
    running = [j.id for j in JOBS.values() if not j.done.is_set()]
    lines.append(f"Running jobs: {', '.join(running) or 'none'}")
    lines.append(f"Tools ({len(REGISTERED)}): {', '.join(REGISTERED)}")
    return "\n".join(lines)


@bridge_tool(read_only=True)
def list_files(path: str = ".", recursive: bool = False, pattern: str = "*", max_entries: int = 300) -> str:
    """List files and folders. Paths are relative to the workspace unless absolute.
    recursive=true also walks subfolders; pattern filters names (e.g. "*.blend")."""
    base = resolve(path, must_exist=True)
    if base.is_file():
        st = base.stat()
        return f"{show(base)}  {human_size(st.st_size)}  {datetime.fromtimestamp(st.st_mtime):%Y-%m-%d %H:%M}"
    max_entries = max(1, min(int(max_entries), 5000))
    rows, truncated = [], False

    def add(entry_path, is_dir):
        nonlocal truncated
        if len(rows) >= max_entries:
            truncated = True
            return False
        rel = os.path.relpath(entry_path, base)
        if is_dir:
            rows.append(f"[DIR]               {rel}{os.sep}")
        else:
            try:
                st = os.stat(entry_path)
                rows.append(f"{human_size(st.st_size):>9}  {datetime.fromtimestamp(st.st_mtime):%Y-%m-%d %H:%M}  {rel}")
            except OSError:
                rows.append(f"        ?                   {rel}")
        return True

    if recursive:
        for current, dirs, files in os.walk(base):
            dirs[:] = sorted(d for d in dirs if d not in (".venv", "__pycache__", ".git", "node_modules"))
            for name in dirs:
                if fnmatch.fnmatch(name, pattern) and not add(os.path.join(current, name), True):
                    break
            for name in sorted(files):
                if fnmatch.fnmatch(name, pattern) and not add(os.path.join(current, name), False):
                    break
            if truncated:
                break
    else:
        with os.scandir(base) as it:
            entries = sorted(it, key=lambda e: (not e.is_dir(), e.name.lower()))
        for entry in entries:
            if fnmatch.fnmatch(entry.name, pattern) and not add(entry.path, entry.is_dir()):
                break
    header = f"{show(base)} ({len(rows)} entries{', more not shown' if truncated else ''})"
    return header + "\n" + ("\n".join(rows) if rows else "(empty)")


@bridge_tool(read_only=True)
def read_text_file(path: str, start: int = 0, max_chars: int = 40000) -> str:
    """Read a text file (UTF-8, UTF-16 or the Windows code page are detected).
    start/max_chars page through long files."""
    target = resolve(path, must_exist=True)
    if target.is_dir():
        raise ToolError(f"{show(target)} is a folder - use list_files")
    size = target.stat().st_size
    if size > 50 * 1024 * 1024:
        raise ToolError(f"{show(target)} is {human_size(size)} - too big for read_text_file; use read_file_base64")
    text = decode_text(target.read_bytes())
    start = max(0, int(start))
    max_chars = max(1, min(int(max_chars), 200_000))
    chunk = text[start:start + max_chars]
    end = start + len(chunk)
    more = f" - more: call again with start={end}" if end < len(text) else ""
    return f"{show(target)}: characters {start}-{end} of {len(text)}{more}\n\n{chunk}"


@bridge_tool(destructive=True)
def write_text_file(path: str, content: str, append: bool = False, encoding: str = "utf-8") -> str:
    """Create or overwrite a text file (folders are created). append=true adds to the end.
    Use encoding="utf-8-sig" for .ps1/.bat files with non-English text."""
    target = resolve(path)
    if target.is_dir():
        raise ToolError(f"{show(target)} is a folder")
    target.parent.mkdir(parents=True, exist_ok=True)
    try:
        "".encode(encoding)
    except LookupError:
        raise ToolError(f"Unknown encoding '{encoding}'")
    with open(target, "a" if append else "w", encoding=encoding, newline="") as f:
        f.write(content)
    return f"{'Appended to' if append else 'Wrote'} {show(target)} ({human_size(target.stat().st_size)} now)"


def _protected(target):
    if target.parent == target:
        return "a drive root"
    if _norm(target) == _norm(WORKSPACE):
        return "the workspace folder itself"
    if is_inside(ROOT, target) or (is_inside(target, ROOT) and not is_inside(target, WORKSPACE)):
        return "part of PC Bridge"
    if _norm(target) == _norm(Path.home()):
        return "the user's home folder"
    return None


@bridge_tool(destructive=True)
def delete_path(path: str, recursive: bool = False) -> str:
    """Delete a file or folder. Non-empty folders need recursive=true."""
    target = resolve(path)
    if not target.exists() and not target.is_symlink():
        raise ToolError(f"Not found: {show(target)}")
    reason = _protected(target)
    if reason:
        raise ToolError(f"Refusing to delete {target}: it is {reason}.")
    if target.is_dir() and not target.is_symlink():
        if any(target.iterdir()) and not recursive:
            raise ToolError(f"{show(target)} is a non-empty folder - pass recursive=true to delete it with its contents")

        def make_writable(func, failed_path, _exc):
            os.chmod(failed_path, 0o700)
            func(failed_path)

        if sys.version_info >= (3, 12):
            shutil.rmtree(target, onexc=make_writable)
        else:
            shutil.rmtree(target, onerror=make_writable)
    else:
        target.unlink()
    return f"Deleted {show(target)}"


@bridge_tool(read_only=True)
def read_file_base64(path: str, offset: int = 0, length: int = 300000) -> str:
    """Read part of any file as base64 so it can be copied off the PC in chunks.
    Repeat with offset=next_offset until eof is true. length is capped at 3 MB per call."""
    target = resolve(path, must_exist=True)
    if not target.is_file():
        raise ToolError(f"{show(target)} is not a file")
    size = target.stat().st_size
    offset = max(0, int(offset))
    length = max(1, min(int(length), 3_000_000))
    with open(target, "rb") as f:
        f.seek(offset)
        data = f.read(length)
    end = offset + len(data)
    return json.dumps({
        "path": show(target), "size": size, "offset": offset, "length": len(data),
        "next_offset": end if end < size else None, "eof": end >= size,
        "data_base64": base64.b64encode(data).decode("ascii"),
    })


@bridge_tool(destructive=True)
def write_file_base64(path: str, data_base64: str, append: bool = False) -> str:
    """Write base64 data to a file, e.g. to send a file to the PC in chunks:
    the first chunk with append=false, the following chunks with append=true."""
    target = resolve(path)
    if target.is_dir():
        raise ToolError(f"{show(target)} is a folder")
    payload = data_base64.strip()
    if payload.startswith("data:") and "," in payload:
        payload = payload.split(",", 1)[1]
    try:
        data = base64.b64decode(re.sub(r"\s+", "", payload), validate=True)
    except ValueError as e:
        raise ToolError(f"data_base64 is not valid base64: {e}")
    target.parent.mkdir(parents=True, exist_ok=True)
    with open(target, "ab" if append else "wb") as f:
        f.write(data)
    return f"{'Appended' if append else 'Wrote'} {human_size(len(data))} to {show(target)} ({human_size(target.stat().st_size)} total)"


@bridge_tool(read_only=True)
def view_image(path: str, max_size: int = 1280) -> list:
    """Show an image file from the PC (PNG, JPG, BMP, GIF, WEBP...), scaled down to max_size pixels."""
    target = resolve(path, must_exist=True)
    try:
        original, shown, content = load_image_preview(target, max(64, min(int(max_size), 4096)))
    except Exception as e:
        raise ToolError(f"Cannot open {show(target)} as an image: {e}")
    return [f"{show(target)} - {original[0]}x{original[1]} (shown at {shown[0]}x{shown[1]})", content]


@bridge_tool(read_only=True)
def job_status(job_id: str = "", tail_chars: int = 4000) -> str:
    """Status and latest output of a background job. Without job_id, lists all jobs."""
    if not job_id:
        if not JOBS:
            return "No jobs yet."
        rows = []
        for job in sorted(JOBS.values(), key=lambda j: j.started, reverse=True)[:40]:
            elapsed = (job.finished or time.time()) - job.started
            rows.append(f"{job.id:<16} {job.status:<9} {elapsed:8.1f}s  {job.title}")
        return "\n".join(rows)
    return job_report(get_job(job_id), max(200, min(int(tail_chars), MAX_TEXT)))


@bridge_tool(destructive=True)
def job_stop(job_id: str) -> str:
    """Stop a running job (command, render, download, Rojo live sync...) and its child processes."""
    job = get_job(job_id)
    if not stop_job(job):
        return f"Job {job.id} has already ended.\n" + job_report(job, 1000)
    job.done.wait(10)
    return job_report(job, 2000)


# -------------------------------------------------------------- internet ----

BROWSER_UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
              "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36")


def http_client(timeout=30):
    return httpx.Client(
        follow_redirects=True,
        timeout=httpx.Timeout(timeout, connect=15),
        headers={"User-Agent": BROWSER_UA, "Accept-Language": "en-US,en;q=0.9,ru;q=0.8"},
    )


def check_url(url):
    url = (url or "").strip()
    if not re.match(r"https?://", url, re.I):
        raise ToolError("Only http:// and https:// addresses are supported")
    return url


class HtmlToText(HTMLParser):
    SKIP = {"script", "style", "noscript", "svg", "template", "iframe", "canvas", "select"}
    BLOCK = {"p", "div", "section", "article", "header", "footer", "main", "aside", "nav", "ul", "ol", "li",
             "table", "tr", "h1", "h2", "h3", "h4", "h5", "h6", "pre", "blockquote", "form", "br", "hr",
             "dd", "dt", "figcaption", "summary", "details"}

    def __init__(self, base_url):
        super().__init__(convert_charrefs=True)
        self.base_url = base_url
        self.parts, self.links = [], []
        self.title, self.in_title, self.skip = "", False, 0
        self.href, self.link_text = None, []

    def handle_starttag(self, tag, attrs):
        if tag in self.SKIP:
            self.skip += 1
            return
        if tag == "title":
            self.in_title = True
        if tag in self.BLOCK:
            self.parts.append("\n")
        if tag == "li":
            self.parts.append("- ")
        if tag in ("td", "th"):
            self.parts.append(" ")
        if tag == "a":
            href = dict(attrs).get("href") or ""
            if href and not href.startswith(("javascript:", "#", "mailto:")):
                self.href, self.link_text = urllib.parse.urljoin(self.base_url, href), []

    def handle_endtag(self, tag):
        if tag in self.SKIP:
            self.skip = max(0, self.skip - 1)
            return
        if tag == "title":
            self.in_title = False
        if tag in self.BLOCK:
            self.parts.append("\n")
        if tag == "a" and self.href:
            self.links.append((" ".join("".join(self.link_text).split()), self.href))
            self.href = None

    def handle_data(self, data):
        if self.skip:
            return
        if self.in_title:
            self.title += data
            return
        self.parts.append(data)
        if self.href is not None:
            self.link_text.append(data)

    def text(self):
        lines = (" ".join(line.split()) for line in "".join(self.parts).split("\n"))
        return re.sub(r"\n{3,}", "\n\n", "\n".join(lines)).strip()


def _decode_page(body, content_type):
    match = re.search(r"charset=([\w-]+)", content_type, re.I)
    if not match:
        match = re.search(rb"<meta[^>]+charset=[\"']?([\w-]+)", body[:4096], re.I)
    if match:
        charset = match.group(1)
        charset = charset.decode("ascii", "ignore") if isinstance(charset, bytes) else charset
        try:
            return body.decode(charset, errors="replace")
        except LookupError:
            pass
    return decode_text(body)


@bridge_tool(module="internet", read_only=True, open_world=True)
def http_get(url: str, max_chars: int = 20000, start: int = 0, links: bool = False) -> str:
    """Open a web page and return its readable text (scripts and styling removed).
    start/max_chars page through long pages; links=true also lists the page's links."""
    url = check_url(url)
    with http_client() as client, client.stream("GET", url) as response:
        content_type = response.headers.get("content-type", "")
        body, truncated = bytearray(), False
        for chunk in response.iter_bytes():
            body += chunk
            if len(body) > 15 * 1024 * 1024:
                truncated = True
                break
        final_url, status = str(response.url), response.status_code
    head = f"URL: {final_url} (HTTP {status})"
    kind = content_type.split(";")[0].strip().lower()
    textual = (not kind or kind.startswith("text/") or "json" in kind or "xml" in kind
               or "javascript" in kind)
    if not textual:
        return f"{head}\nBinary content ({kind}, {human_size(len(body))}{'+' if truncated else ''}). Use download_file to save it."
    raw = _decode_page(bytes(body), content_type)
    title, link_list = "", []
    if "html" in kind or (not kind and "<html" in raw[:2000].lower()):
        parser = HtmlToText(final_url)
        parser.feed(raw)
        parser.close()
        text, title, link_list = parser.text(), " ".join(parser.title.split()), parser.links
    else:
        text = raw
    start = max(0, int(start))
    max_chars = max(100, min(int(max_chars), 100_000))
    chunk = text[start:start + max_chars]
    end = start + len(chunk)
    out = [head]
    if title:
        out.append(f"Title: {title}")
    more = f" - more: call again with start={end}" if end < len(text) else ""
    out.append(f"Text characters {start}-{end} of {len(text)}{more}\n")
    out.append(chunk)
    if links and link_list:
        seen, rows = set(), []
        for label, href in link_list:
            if href not in seen:
                seen.add(href)
                rows.append(f"- {label[:80] or '(no text)'}: {href}")
        out.append(f"\nLinks ({len(rows)}):\n" + "\n".join(rows[:200]))
    return clip("\n".join(out))


class DuckDuckGoParser(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.results, self.field, self.buffer = [], None, []

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        classes = (attrs.get("class") or "").split()
        if tag == "a" and "result__a" in classes:
            self.results.append({"url": _ddg_target(attrs.get("href") or ""), "title": "", "snippet": ""})
            self.field, self.buffer = "title", []
        elif "result__snippet" in classes and self.results:
            self.field, self.buffer = "snippet", []

    def handle_endtag(self, tag):
        if self.field and tag in ("a", "div", "td"):
            self.results[-1][self.field] = " ".join("".join(self.buffer).split())
            self.field = None

    def handle_data(self, data):
        if self.field:
            self.buffer.append(data)


def _ddg_target(href):
    if href.startswith("//"):
        href = "https:" + href
    parsed = urllib.parse.urlparse(href)
    if parsed.netloc.endswith("duckduckgo.com") and parsed.path.startswith("/l/"):
        target = urllib.parse.parse_qs(parsed.query).get("uddg")
        if target:
            return target[0]
    return href


def _search_duckduckgo(query, limit):
    with http_client(20) as client:
        response = client.post("https://html.duckduckgo.com/html/", data={"q": query, "kl": "wt-wt"})
    if response.status_code != 200:
        raise RuntimeError(f"HTTP {response.status_code}")
    parser = DuckDuckGoParser()
    parser.feed(response.text)
    results = [r for r in parser.results if r["url"].startswith("http") and "duckduckgo.com/y.js" not in r["url"]]
    return results[:limit]


def _search_bing(query, limit):
    with http_client(20) as client:
        response = client.get("https://www.bing.com/search", params={"q": query, "format": "rss", "count": limit})
    if response.status_code != 200:
        raise RuntimeError(f"HTTP {response.status_code}")
    results = []
    for item in ET.fromstring(response.content).iter("item"):
        results.append({"title": (item.findtext("title") or "").strip(), "url": (item.findtext("link") or "").strip(),
                        "snippet": " ".join((item.findtext("description") or "").split())})
    return results[:limit]


@bridge_tool(module="internet", read_only=True, open_world=True)
def web_search(query: str, max_results: int = 8) -> str:
    """Search the internet (DuckDuckGo, Bing as fallback). Returns titles, links and snippets;
    open a result with http_get."""
    limit = max(1, min(int(max_results), 25))
    errors = []
    for name, engine in (("DuckDuckGo", _search_duckduckgo), ("Bing", _search_bing)):
        try:
            results = engine(query, limit)
        except Exception as e:
            errors.append(f"{name}: {type(e).__name__}: {e}")
            continue
        if results:
            rows = [f"{i}. {r['title'] or '(no title)'}\n   {r['url']}" + (f"\n   {r['snippet']}" if r["snippet"] else "")
                    for i, r in enumerate(results, 1)]
            return f"Results from {name} for: {query}\n\n" + "\n".join(rows)
        errors.append(f"{name}: no results")
    return "No results. " + "; ".join(errors)


def _safe_filename(name):
    name = re.sub(r'[<>:"/\\|?*\x00-\x1f]', "_", name).strip(" .")[:150]
    if not name:
        return "download.bin"
    if name.split(".")[0].upper() in {"CON", "PRN", "AUX", "NUL", *(f"COM{i}" for i in range(1, 10)),
                                      *(f"LPT{i}" for i in range(1, 10))}:
        name = "_" + name
    return name


def _filename_from_response(response):
    disposition = response.headers.get("content-disposition", "")
    match = re.search(r"filename\*\s*=\s*[\w-]+''([^;]+)", disposition, re.I)
    if match:
        return urllib.parse.unquote(match.group(1).strip().strip('"'))
    match = re.search(r'filename\s*=\s*"?([^";]+)"?', disposition, re.I)
    if match:
        return match.group(1).strip()
    return urllib.parse.unquote(Path(urllib.parse.urlparse(str(response.url)).path).name)


@bridge_tool(module="internet", destructive=True, open_world=True)
def download_file(url: str, filename: str = "", folder: str = "downloads", timeout: int = 50,
                  background: bool = False) -> str:
    """Download a file from the internet into the workspace (folder "downloads" by default).
    Big files keep downloading in the background after `timeout` seconds (see job_status)."""
    url = check_url(url)
    target_dir = resolve(folder)
    target_dir.mkdir(parents=True, exist_ok=True)
    limit = MAX_DOWNLOAD_MB * 1024 * 1024
    job = Job("download", url[:120])

    def work(job):
        part = None
        try:
            with http_client(60) as client, client.stream("GET", url) as response:
                response.raise_for_status()
                dest = target_dir / _safe_filename(filename or _filename_from_response(response))
                total = int(response.headers.get("content-length") or 0)
                if total > limit:
                    raise ToolError(f"File is {human_size(total)}, above the {MAX_DOWNLOAD_MB} MB limit "
                                    "(max_download_mb in config.json)")
                part = dest.with_name(dest.name + ".part")
                received = 0
                with open(part, "wb") as f:
                    for chunk in response.iter_bytes(1 << 20):
                        if job.stop_requested.is_set():
                            raise RuntimeError("stopped with job_stop")
                        received += len(chunk)
                        if received > limit:
                            raise ToolError(f"File is above the {MAX_DOWNLOAD_MB} MB limit (max_download_mb in config.json)")
                        f.write(chunk)
                        job.progress = human_size(received) + (f" of {human_size(total)}" if total else "")
            os.replace(part, dest)
            part = None
            return f"Saved {show(dest)} ({human_size(received)})"
        finally:
            if part is not None and part.exists():
                part.unlink()

    return wait_report(run_in_thread(job, work), timeout, background)


# ----------------------------------------------------------------- shell ----

PS_PRELUDE = (
    "$ProgressPreference = 'SilentlyContinue'\n"
    "try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false } catch {}\n"
    "$OutputEncoding = New-Object System.Text.UTF8Encoding $false\n"
)
PS_EPILOGUE = "\nif ($LASTEXITCODE -is [int] -and $LASTEXITCODE -ne 0) { exit $LASTEXITCODE }\n"


def shell_name():
    if IS_WIN:
        return "Windows PowerShell"
    return "PowerShell (pwsh)" if shutil.which("pwsh") else "bash"


def shell_argv(job, command):
    if IS_WIN or shutil.which("pwsh"):
        # A script file avoids command-line quoting problems; the BOM makes PowerShell 5 read it as UTF-8.
        script = Path(f"{job.stem}.ps1")
        script.write_text(PS_PRELUDE + command + PS_EPILOGUE, encoding="utf-8-sig")
        exe = "pwsh"
        if IS_WIN:
            exe = str(Path(os.environ.get("SystemRoot", r"C:\Windows")) / "System32" / "WindowsPowerShell"
                      / "v1.0" / "powershell.exe")
            if not Path(exe).exists():
                exe = "powershell.exe"
        return [exe, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", str(script)]
    return ["bash", "-c", command]


@bridge_tool(module="shell", destructive=True, open_world=True)
def run_command(command: str, cwd: str = ".", timeout: int = 50, background: bool = False) -> str:
    """Run a PowerShell command or script on the PC and return its output and exit code.
    cwd is the working folder (workspace by default). If it runs longer than `timeout` seconds it keeps
    running in the background (see job_status / job_stop); background=true returns immediately.
    Commands cannot ask for input, so use non-interactive flags (-y, -Force, --yes)."""
    workdir = resolve(cwd, must_exist=True)
    if not workdir.is_dir():
        raise ToolError(f"{show(workdir)} is not a folder")
    job = Job("cmd", " ".join(command.split())[:100])
    launch(job, shell_argv(job, command), workdir)
    return clip(wait_report(job, timeout, background, tail=20000))


# --------------------------------------------------------------- blender ----

BLENDER_RUNNER = r'''# Written by PC Bridge. Runs inside Blender: blender -b [file.blend] --python this.py -- params.json
import json
import os
import sys

import bpy

try:
    sys.stdout.reconfigure(line_buffering=True)
except Exception:
    pass

with open(sys.argv[sys.argv.index("--") + 1], encoding="utf-8") as f:
    params = json.load(f)


def set_engine(scene, name):
    # The engine enum is filled at runtime (Cycles is an add-on), so try names instead of listing them.
    key = name.upper().replace("BLENDER_", "").replace("_NEXT", "")
    wanted = {"EEVEE": ["BLENDER_EEVEE_NEXT", "BLENDER_EEVEE"], "WORKBENCH": ["BLENDER_WORKBENCH"]}.get(key, [key])
    for engine in wanted:
        try:
            scene.render.engine = engine
            return
        except TypeError:
            continue
    raise ValueError("Unknown render engine %r. Use EEVEE, CYCLES or WORKBENCH." % name)


def render(r):
    scene = bpy.context.scene
    if r.get("engine"):
        set_engine(scene, r["engine"])
    if r.get("resolution_x"):
        scene.render.resolution_x = int(r["resolution_x"])
    if r.get("resolution_y"):
        scene.render.resolution_y = int(r["resolution_y"])
    if r.get("resolution_x") or r.get("resolution_y"):
        scene.render.resolution_percentage = 100
    if r.get("samples"):
        if scene.render.engine == "CYCLES":
            scene.cycles.samples = int(r["samples"])
        elif "EEVEE" in scene.render.engine:
            scene.eevee.taa_render_samples = int(r["samples"])
    if r.get("frame") is not None:
        scene.frame_set(int(r["frame"]))
    if scene.camera is None:
        cameras = [o for o in scene.objects if o.type == "CAMERA"]
        if not cameras:
            raise RuntimeError("The scene has no camera. Add one (bpy.ops.object.camera_add) before rendering.")
        scene.camera = cameras[0]
    scene.render.image_settings.file_format = "PNG"
    scene.render.filepath = r["output"]
    os.makedirs(os.path.dirname(r["output"]), exist_ok=True)
    pct = scene.render.resolution_percentage / 100.0
    print("[pc-bridge] rendering with %s at %dx%d" % (scene.render.engine, scene.render.resolution_x * pct,
                                                      scene.render.resolution_y * pct))
    bpy.ops.render.render(write_still=True)
    print("[pc-bridge] render saved:", r["output"])


if params.get("code_path"):
    with open(params["code_path"], encoding="utf-8") as f:
        source = f.read()
    exec(compile(source, params["code_path"], "exec"),
         {"__name__": "__main__", "__file__": params["code_path"], "bpy": bpy, "WORKSPACE": params["workspace"]})
if params.get("render"):
    render(params["render"])
if params.get("save_as"):
    os.makedirs(os.path.dirname(params["save_as"]), exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=params["save_as"])
    print("[pc-bridge] saved:", params["save_as"])
'''


def need_blender():
    path = CFG.get("blender_path") or shutil.which("blender")
    if not path or not Path(path).is_file():
        raise ToolError("Blender was not found on this PC. Install it and run SETTINGS.bat.")
    return path


def start_blender(job, blend, params):
    runner = JOBS_DIR / "blender_runner.py"
    runner.write_text(BLENDER_RUNNER, encoding="utf-8")
    params = {"workspace": str(WORKSPACE), **params}
    params_path = Path(f"{job.stem}.json")
    params_path.write_text(json.dumps(params), encoding="utf-8")
    argv = [need_blender(), "-b"] + ([blend] if blend else [])
    argv += ["--python-exit-code", "1", "--python", runner, "--", params_path]
    return launch(job, argv, WORKSPACE)


@bridge_tool(module="blender", destructive=True)
def blender_run_python(code: str, blend_file: str = "", save_as: str = "", timeout: int = 50,
                       background: bool = False) -> str:
    """Run Python (bpy) code inside Blender without opening its window, and return the printed output.
    blend_file: .blend to open first (default: Blender's start scene with a cube, camera and light).
    save_as: .blend path to save the result to (can be the same file). Relative paths in the code
    point into the workspace (also available as the WORKSPACE variable).
    Waits up to `timeout` seconds, then keeps running as a background job."""
    blend = resolve(blend_file, must_exist=True) if blend_file else None
    out = resolve(save_as) if save_as else None
    job = Job("blender", "python" + (f" on {show(blend)}" if blend else "") + (f" -> {show(out)}" if out else ""))
    code_path = Path(f"{job.stem}.py")
    code_path.write_text(code, encoding="utf-8")
    start_blender(job, blend, {"code_path": str(code_path), "save_as": str(out) if out else None})
    return clip(wait_report(job, timeout, background, tail=8000))


@bridge_tool(module="blender", destructive=True)
def blender_render(blend_file: str = "", output: str = "renders/render.png", engine: str = "",
                   resolution_x: int = 0, resolution_y: int = 0, samples: int = 0, frame: int = -1,
                   timeout: int = 50, background: bool = False) -> list:
    """Render one frame of a .blend file to a PNG and show a preview.
    engine: "EEVEE", "CYCLES" or "WORKBENCH" (empty = the file's setting); resolution/samples/frame
    0 or -1 keep the file's settings. Long renders continue in the background after `timeout`
    seconds; then call job_status and view_image(output) when it has finished."""
    blend = resolve(blend_file, must_exist=True) if blend_file else None
    out = resolve(output)
    if out.suffix.lower() != ".png":
        out = out.with_suffix(".png")
    if out.exists():
        out.unlink()
    job = Job("render", f"{show(blend) if blend else 'start scene'} -> {show(out)}")
    job.on_finish = lambda j: setattr(j, "result", f"Render saved: {show(out)}" if out.exists() else "No image was written.")
    render = {"output": str(out), "engine": engine or None, "resolution_x": resolution_x or None,
              "resolution_y": resolution_y or None, "samples": samples or None,
              "frame": frame if frame >= 0 else None}
    start_blender(job, blend, {"render": render})
    report = wait_report(job, timeout, background, tail=3000)
    if job.done.is_set() and out.exists():
        original, _, content = load_image_preview(out, 1024)
        return [report + f"\nImage size: {original[0]}x{original[1]}", content]
    return [report]


@bridge_tool(module="blender")
def blender_open_gui(blend_file: str = "") -> str:
    """Open Blender with its window on the PC screen (optionally with a .blend file) so the user can look."""
    argv = [need_blender()]
    if blend_file:
        argv.append(resolve(blend_file, must_exist=True))
    open_gui(argv)
    return "Blender is opening on the PC screen" + (f" with {show(argv[1])}" if blend_file else "") + "."


# ---------------------------------------------------------------- roblox ----

ROBLOX_DIR = WORKSPACE / "roblox"
PROJECT_NAME = re.compile(r"[A-Za-z0-9_-]{1,64}")
SERVE_JOB = None


def find_rojo():
    path = CFG.get("rojo_path")
    if path and Path(path).is_file():
        return path
    for candidate in sorted((ROOT / "tools" / "rojo").glob("**/rojo*")):
        if candidate.is_file() and candidate.stem == "rojo":
            return str(candidate)
    return shutil.which("rojo")


def find_studio():
    """Studio updates move it into a new Versions folder, so look again if the saved path is gone."""
    path = CFG.get("studio_path")
    if path and Path(path).is_file():
        return path
    found = []
    for base in (os.environ.get("LOCALAPPDATA"), os.environ.get("ProgramFiles(x86)"), os.environ.get("ProgramFiles")):
        if base:
            found += Path(base, "Roblox", "Versions").glob("*/RobloxStudioBeta.exe")
    return str(max(found, key=lambda p: p.stat().st_mtime)) if found else None


def need_rojo():
    rojo = find_rojo()
    if not rojo:
        raise ToolError("Rojo is not installed. Run SETTINGS.bat with the Roblox module enabled.")
    return rojo


def project_dir(name, must_exist=True):
    if not PROJECT_NAME.fullmatch(name or ""):
        raise ToolError("Project names may only use Latin letters, digits, _ and - (up to 64 characters).")
    path = ROBLOX_DIR / name
    if must_exist and not (path / "default.project.json").is_file():
        existing = sorted(p.parent.name for p in ROBLOX_DIR.glob("*/default.project.json"))
        raise ToolError(f"Roblox project '{name}' not found (create it with roblox_init_project). "
                        f"Existing projects: {', '.join(existing) or 'none'}")
    return path


def project_tree(name):
    return {
        "name": name,
        "tree": {
            "$className": "DataModel",
            "ReplicatedStorage": {"Shared": {"$path": "src/shared"}},
            "ServerScriptService": {"Server": {"$path": "src/server"}},
            "StarterPlayer": {"StarterPlayerScripts": {"Client": {"$path": "src/client"}}},
            "Workspace": {
                "Baseplate": {
                    "$className": "Part",
                    "$properties": {"Anchored": True, "Locked": True, "Position": [0, -10, 0],
                                    "Size": [512, 20, 512], "Color": [0.388, 0.373, 0.384]},
                },
                "SpawnLocation": {
                    "$className": "SpawnLocation",
                    "$properties": {"Anchored": True, "Position": [0, 0.5, 0], "Size": [12, 1, 12]},
                },
            },
        },
    }


def serving_project():
    if SERVE_JOB is not None and not SERVE_JOB.done.is_set():
        return SERVE_JOB.project
    return None


def luau_kind(filename):
    lower = filename.lower()
    if re.search(r"\.server\.luau?$", lower):
        return "Script (server)"
    if re.search(r"\.client\.luau?$", lower):
        return "LocalScript (client)"
    if re.search(r"\.luau?$", lower):
        return "ModuleScript"
    return "data file"


@bridge_tool(module="roblox", destructive=True)
def roblox_init_project(name: str) -> str:
    """Create a Roblox game project (Rojo layout) in workspace/roblox/<name> with a baseplate, a spawn
    and starter scripts. Then write code with roblox_write_script and build or live-sync it."""
    path = project_dir(name, must_exist=False)
    if (path / "default.project.json").exists():
        return f"Project {name} already exists.\n" + list_files(show(path), recursive=True)
    for sub in ("src/server", "src/client", "src/shared", "build"):
        (path / sub).mkdir(parents=True, exist_ok=True)
    (path / "default.project.json").write_text(json.dumps(project_tree(name), indent=2) + "\n", encoding="utf-8")
    starters = {
        "src/server/Main.server.luau": f'print("[{name}] server started")\n',
        "src/client/Main.client.luau": 'local Players = game:GetService("Players")\n\n'
                                       'print("Hello, " .. Players.LocalPlayer.Name)\n',
        "src/shared/Config.luau": f'local Config = {{}}\n\nConfig.GameName = "{name}"\n\nreturn Config\n',
    }
    for rel, code in starters.items():
        (path / rel).write_text(code, encoding="utf-8", newline="\n")
    return (f"Created Roblox project {name} in {show(path)}\n"
            "src/server -> ServerScriptService.Server (*.server.luau = Script)\n"
            "src/client -> StarterPlayerScripts.Client (*.client.luau = LocalScript)\n"
            "src/shared -> ReplicatedStorage.Shared (*.luau = ModuleScript)\n"
            "A folder with init.server.luau / init.luau becomes that script itself.\n"
            "Next: roblox_write_script, then roblox_build + roblox_open_studio, or roblox_serve for live sync.")


@bridge_tool(module="roblox", destructive=True)
def roblox_write_script(project: str, path: str, code: str) -> str:
    """Write a Luau script into a Roblox project. path is relative to the project's src folder, e.g.
    "server/Checkpoints.server.luau" (Script), "client/Camera.client.luau" (LocalScript),
    "shared/Util.luau" (ModuleScript). "default.project.json" edits the Rojo project file."""
    base = project_dir(project)
    rel = path.replace("\\", "/").strip().lstrip("/")
    if rel != "default.project.json" and not rel.startswith("src/"):
        rel = "src/" + rel
    target = Path(os.path.realpath(base / rel))
    if not is_inside(target, base) or target == base:
        raise ToolError("path must point to a file inside the project")
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(code, encoding="utf-8", newline="\n")
    live = " Rojo live sync is on, so Studio receives it right away." if serving_project() == project else ""
    return f"Wrote {show(target)} ({luau_kind(target.name)}, {len(code)} characters).{live}"


def build_project(project, output="", timeout=120):
    rojo = need_rojo()
    base = project_dir(project)
    out = resolve(output) if output else base / "build" / f"{project}.rbxlx"
    if out.suffix.lower() not in (".rbxlx", ".rbxl", ".rbxm", ".rbxmx"):
        raise ToolError("output must end with .rbxlx, .rbxl, .rbxm or .rbxmx")
    out.parent.mkdir(parents=True, exist_ok=True)
    job = Job("rojo-build", f"build {project} -> {show(out)}")
    launch(job, [rojo, "build", base, "--output", out], base)
    if not job.done.wait(max(5, min(int(timeout), 1800))):
        return out, wait_report(job, 0, False)
    if job.exit_code != 0:
        raise ToolError("Rojo build failed:\n" + read_tail(job.log_path, 6000))
    return out, f"Built {show(out)} ({human_size(out.stat().st_size)})."


@bridge_tool(module="roblox", destructive=True)
def roblox_build(project: str, output: str = "", timeout: int = 120) -> str:
    """Build a Roblox project into a place file (default: roblox/<project>/build/<project>.rbxlx)
    that Roblox Studio can open (roblox_open_studio)."""
    return build_project(project, output, timeout)[1]


@bridge_tool(module="roblox", destructive=True)
def roblox_serve(project: str = "", port: int = 34872, stop: bool = False) -> str:
    """Start Rojo live sync for a project: every change written by roblox_write_script appears in
    Roblox Studio immediately after the user presses Plugins -> Rojo -> Connect. stop=true ends it."""
    global SERVE_JOB
    if SERVE_JOB is not None and not SERVE_JOB.done.is_set():
        stop_job(SERVE_JOB)
        SERVE_JOB.done.wait(5)
    if stop:
        return "Rojo live sync stopped."
    if not project:
        raise ToolError("project is required")
    rojo = need_rojo()
    base = project_dir(project)
    port = int(port)
    job = Job("rojo-serve", f"live sync {project} on port {port}")
    job.project = project
    launch(job, [rojo, "serve", base / "default.project.json", "--port", port], base)
    if job.done.wait(3):
        raise ToolError("Rojo live sync did not start:\n" + read_tail(job.log_path, 4000))
    SERVE_JOB = job
    return (f"Rojo live sync for {project} is running on localhost:{port} (job {job.id}).\n"
            f"In Roblox Studio: open a place, Plugins tab -> Rojo -> Connect (port {port}).\n"
            "Stop it with roblox_serve(stop=true).\n" + read_tail(job.log_path, 1500))


@bridge_tool(module="roblox")
def roblox_open_studio(project: str = "", file: str = "") -> str:
    """Open Roblox Studio on the PC screen: with a project's built place (built first if needed),
    with a place file (.rbxl/.rbxlx), or empty."""
    target, note = None, ""
    if file:
        target = resolve(file, must_exist=True)
    elif project:
        target = project_dir(project) / "build" / f"{project}.rbxlx"
        if not target.exists():
            target, note = build_project(project)
            note += "\n"
    studio = find_studio()
    if target is not None:
        try:
            if not IS_WIN:
                raise OSError("not Windows")
            os.startfile(str(target))  # uses Studio's .rbxl/.rbxlx file association
        except OSError:
            if not studio:
                raise ToolError("Roblox Studio was not found. Install it from https://create.roblox.com and run SETTINGS.bat.")
            open_gui([studio, target])
    else:
        if not studio:
            raise ToolError("Roblox Studio was not found. Install it from https://create.roblox.com and run SETTINGS.bat.")
        open_gui([studio])
    if serving_project():
        note += f"Rojo live sync ({serving_project()}) is on: in Studio press Plugins -> Rojo -> Connect.\n"
    return note + "Roblox Studio is opening on the PC screen" + (f" with {show(target)}." if target else ".")


# ---------------------------------------------------------------- screen ----

_pyautogui = None
_screen_lock = threading.Lock()
_scale = [1.0, 1.0]  # screen pixels per screenshot pixel, from the latest screenshot
KEY_ALIASES = {"control": "ctrl", "windows": "win", "cmd": "win", "super": "win", "escape": "esc",
               "return": "enter", "del": "delete", "ins": "insert", "pgup": "pageup", "pgdn": "pagedown",
               "spacebar": "space", "plus": "+", "arrowup": "up", "arrowdown": "down",
               "arrowleft": "left", "arrowright": "right", "option": "alt"}


def pyautogui():
    global _pyautogui
    if _pyautogui is None:
        try:
            import pyautogui as module
        except (Exception, SystemExit) as e:  # its mouseinfo dependency calls sys.exit() on some setups
            raise ToolError(f"Screen control is unavailable: {e}. Run SETTINGS.bat and enable the screen module.")

        module.FAILSAFE = True  # slamming the mouse into a screen corner aborts (README)
        module.PAUSE = 0.05
        _pyautogui = module
    return _pyautogui


def screen_action(fn):
    @functools.wraps(fn)
    def wrapper(*args, **kwargs):
        g = pyautogui()
        with _screen_lock:
            try:
                return fn(*args, **kwargs)
            except g.FailSafeException:
                raise ToolError("Stopped: the mouse was pushed into a screen corner (emergency stop). "
                                "Ask the user before continuing.")
    return wrapper


def to_screen(x, y):
    width, height = pyautogui().size()
    sx = min(max(round(float(x) * _scale[0]), 0), width - 1)
    sy = min(max(round(float(y) * _scale[1]), 0), height - 1)
    return sx, sy


@bridge_tool(module="screen", read_only=True)
@screen_action
def screenshot(max_width: int = 1280) -> list:
    """Take a screenshot of the PC's main screen. Mouse tools take coordinates in the pixels of the
    LATEST screenshot image (they are scaled to the real screen automatically)."""
    g = pyautogui()  # importing it first makes the process DPI-aware on Windows (real pixel sizes)
    from PIL import ImageGrab

    img = ImageGrab.grab()
    width, height = img.size
    max_width = max(320, min(int(max_width), 3840))
    if width > max_width:
        from PIL import Image as PILImage

        img = img.resize((max_width, round(height * max_width / width)), PILImage.LANCZOS)
    _scale[:] = [width / img.size[0], height / img.size[1]]
    mx, my = g.position()
    _, content = image_content(img, max_size=max(img.size))
    return [f"Screen {width}x{height}, image {img.size[0]}x{img.size[1]}. Use image coordinates for mouse tools. "
            f"Mouse is at ({round(mx / _scale[0])}, {round(my / _scale[1])}).", content]


@bridge_tool(module="screen", destructive=True)
@screen_action
def mouse_click(x: int, y: int, button: str = "left", clicks: int = 1) -> str:
    """Click at (x, y) in screenshot coordinates. button: left, right or middle; clicks=2 double-clicks."""
    if button not in ("left", "right", "middle"):
        raise ToolError("button must be left, right or middle")
    sx, sy = to_screen(x, y)
    pyautogui().click(sx, sy, clicks=max(1, min(int(clicks), 3)), interval=0.08, button=button)
    return f"Clicked {button} x{clicks} at ({x}, {y}) = screen ({sx}, {sy})"


@bridge_tool(module="screen", destructive=True)
@screen_action
def mouse_drag(start_x: int, start_y: int, end_x: int, end_y: int, button: str = "left",
               duration: float = 0.5) -> str:
    """Drag with a mouse button held from (start_x, start_y) to (end_x, end_y), in screenshot coordinates."""
    if button not in ("left", "right", "middle"):
        raise ToolError("button must be left, right or middle")
    g = pyautogui()
    x1, y1 = to_screen(start_x, start_y)
    x2, y2 = to_screen(end_x, end_y)
    g.moveTo(x1, y1)
    g.dragTo(x2, y2, duration=max(0.1, min(float(duration), 10)), button=button)
    return f"Dragged from screen ({x1}, {y1}) to ({x2}, {y2})"


@bridge_tool(module="screen", destructive=True)
@screen_action
def scroll(amount: int, x: int = -1, y: int = -1) -> str:
    """Scroll the mouse wheel by `amount` notches: positive = up, negative = down. Optionally move to
    (x, y) in screenshot coordinates first."""
    g = pyautogui()
    if x >= 0 and y >= 0:
        g.moveTo(*to_screen(x, y))
    notches = max(-100, min(int(amount), 100))
    g.scroll(notches * 120 if IS_WIN else notches)  # Windows takes raw wheel units, 120 per notch
    return f"Scrolled {'up' if notches > 0 else 'down'} {abs(notches)} notch(es)"


def set_clipboard_windows(text):
    from ctypes import wintypes

    user32 = ctypes.WinDLL("user32", use_last_error=True)
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    user32.OpenClipboard.argtypes = [wintypes.HWND]
    user32.SetClipboardData.argtypes = [wintypes.UINT, wintypes.HANDLE]
    user32.SetClipboardData.restype = wintypes.HANDLE
    kernel32.GlobalAlloc.argtypes = [wintypes.UINT, ctypes.c_size_t]
    kernel32.GlobalAlloc.restype = wintypes.HGLOBAL
    kernel32.GlobalLock.argtypes = [wintypes.HGLOBAL]
    kernel32.GlobalLock.restype = ctypes.c_void_p
    kernel32.GlobalUnlock.argtypes = [wintypes.HGLOBAL]
    data = text.encode("utf-16-le") + b"\x00\x00"
    for _ in range(20):
        if user32.OpenClipboard(None):
            break
        time.sleep(0.05)
    else:
        raise ToolError("The clipboard is busy, try again")
    try:
        user32.EmptyClipboard()
        handle = kernel32.GlobalAlloc(0x0002, len(data))  # GMEM_MOVEABLE
        pointer = kernel32.GlobalLock(handle)
        ctypes.memmove(pointer, data, len(data))
        kernel32.GlobalUnlock(handle)
        if not user32.SetClipboardData(13, handle):  # CF_UNICODETEXT
            raise ctypes.WinError(ctypes.get_last_error())
    finally:
        user32.CloseClipboard()


@bridge_tool(module="screen", destructive=True)
@screen_action
def type_text(text: str, interval: float = 0.02) -> str:
    """Type text into the focused window. Non-English text (e.g. Russian) is pasted via the clipboard,
    which replaces the clipboard contents."""
    g = pyautogui()
    if all(32 <= ord(ch) < 127 or ch in "\n\t" for ch in text):
        g.write(text, interval=max(0.0, min(float(interval), 0.5)))
        return f"Typed {len(text)} characters"
    if not IS_WIN:
        raise ToolError("Typing non-English text is only supported on Windows")
    set_clipboard_windows(text)
    g.hotkey("ctrl", "v")
    return f"Pasted {len(text)} characters via the clipboard"


@bridge_tool(module="screen", destructive=True)
@screen_action
def press_keys(keys: str, presses: int = 1) -> str:
    """Press a key or shortcut, e.g. "enter", "ctrl+s", "alt+tab", "win+r", "ctrl+shift+esc".
    Several in a row are separated by commas: "ctrl+a, delete". presses repeats the whole sequence."""
    g = pyautogui()
    sequence = []
    for combo in keys.split(","):
        combo = combo.strip().lower()
        if not combo:
            continue
        names = [KEY_ALIASES.get(k.strip(), k.strip()) for k in re.split(r"\+(?!$)", combo)]
        unknown = [k for k in names if k not in g.KEYBOARD_KEYS]
        if unknown:
            raise ToolError(f"Unknown key(s): {', '.join(unknown)}. Examples: enter, esc, tab, ctrl, alt, shift, win, f5, up, a")
        sequence.append(names)
    if not sequence:
        raise ToolError("No keys given")
    for _ in range(max(1, min(int(presses), 50))):
        for names in sequence:
            if len(names) == 1:
                g.press(names[0])
            else:
                g.hotkey(*names)
    return f"Pressed {keys}" + (f" x{presses}" if presses > 1 else "")


# ------------------------------------------------------------------ HTTP ----


class SecretPathGate:
    """Only /<secret>/mcp reaches the MCP app; everything else gets 404."""

    def __init__(self, app):
        self.app = app
        self.secret = SECRET.encode()

    async def __call__(self, scope, receive, send):
        if scope["type"] in ("http", "websocket"):
            secret, _, rest = scope.get("path", "").lstrip("/").partition("/")
            if not (hmac.compare_digest(secret.encode(), self.secret) and rest.rstrip("/") == "mcp"):
                if scope["type"] == "http":
                    await send({"type": "http.response.start", "status": 404,
                                "headers": [(b"content-type", b"text/plain")]})
                    await send({"type": "http.response.body", "body": b"Not found"})
                else:
                    await send({"type": "websocket.close", "code": 1008})
                return
            scope = dict(scope, path="/mcp", raw_path=b"/mcp")
        await self.app(scope, receive, send)


def main():
    app = SecretPathGate(mcp.streamable_http_app())
    log(f"START PC Bridge {VERSION} on port {PORT}; tools: {', '.join(REGISTERED)}")
    # The URL contains the secret, so it is never printed and uvicorn's access log stays off.
    print(f"PC Bridge {VERSION}: MCP server on 127.0.0.1:{PORT} with {len(REGISTERED)} tools", flush=True)
    uvicorn.run(app, host="127.0.0.1", port=PORT, log_level="warning", access_log=False)


if __name__ == "__main__":
    main()
