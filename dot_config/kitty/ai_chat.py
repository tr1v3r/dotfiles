#!/usr/bin/env python3
"""Open a tab-scoped AI pane (or an explicit AI tab), reusing its live draft.

Called by kitty launch --type=background with plain-text stdin. Never inject
terminal keystrokes: only a verified TUI process receives local socket messages.
"""

import fcntl
import hashlib
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import time


MAX_CONTEXT_BYTES = 48_000
WINDOW_VAR = "kitty_ai_chat"
LAUNCH_SCRIPT = 'exec dsh --profile dsh-tui --patch "$HOME/.config/kitty/ai.patch.yml"'


def cache_dir():
    return Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache") / "kitty-ai"


def remote(*args):
    # Background launch grants access through a dedicated inherited fd, not
    # necessarily a filesystem socket. subprocess otherwise closes that fd.
    address = os.environ.get("KITTY_LISTEN_ON", "")
    inherited = (int(address[3:]),) if address.startswith("fd:") else ()
    result = subprocess.run(
        ["kitten", "@", *args], capture_output=True, text=True, check=True,
        timeout=15, pass_fds=inherited,
    )
    return result.stdout.strip()


def workspace_key(cwd):
    return hashlib.sha256(os.fsencode(cwd)).hexdigest()[:24]


def make_prompt(context, mode):
    if not context.strip():
        return ""
    encoded = context.encode("utf-8")
    truncated = len(encoded) > MAX_CONTEXT_BYTES
    if truncated:
        context = encoded[:MAX_CONTEXT_BYTES].decode("utf-8", errors="ignore")
    source = "the text selected in my terminal" if mode == "selection" else "the output of my last command"
    # A fixed prefix also prevents TUI shell gestures (!/!!) and slash commands.
    prompt = (
        f"Here is {source}, for context in this conversation:\n\n"
        "<terminal-context>\n" + context + "\n</terminal-context>"
    )
    if truncated:
        prompt += "\n(Content exceeds 48 KB; only the beginning is included.)"
    return prompt


def find_window(windows, key):
    for os_window in windows:
        for tab in os_window.get("tabs", []):
            for window in tab.get("windows", []):
                if window.get("user_vars", {}).get(WINDOW_VAR) == key:
                    return window
    return None


def belongs_to_process(pid, root_pid):
    """Match the TUI or one of the launched window's descendants, not just cwd."""
    for _ in range(32):
        if pid == root_pid:
            return True
        if pid <= 1:
            return False
        result = subprocess.run(
            ["ps", "-o", "ppid=", "-p", str(pid)],
            capture_output=True, text=True, timeout=3,
        )
        if result.returncode or not result.stdout.strip():
            return False
        parent = int(result.stdout.strip())
        if parent == pid:
            return False
        pid = parent
    return False


def find_endpoint(window, cwd, records):
    roots = {window.get("pid")}
    roots.update(p.get("pid") for p in window.get("foreground_processes", []))
    roots.discard(None)
    inject_dir = Path.home() / ".dsh-tui" / "inject"
    for record in records:
        if not isinstance(record, dict):
            continue
        recorded_cwd = record.get("cwd")
        if not isinstance(recorded_cwd, str) or not Path(recorded_cwd).is_absolute():
            continue
        try:
            # TUI may normalise a nested source directory to its Git root.
            # Still require the exact tagged window's process below, not cwd alone.
            Path(cwd).relative_to(recorded_cwd)
        except ValueError:
            continue
        pid = record.get("pid")
        session = record.get("sessionId")
        if not isinstance(pid, int) or not isinstance(session, str):
            continue
        expected_path = inject_dir / (session + ".sock")
        if expected_path.parent != inject_dir or record.get("socketPath") != str(expected_path):
            continue
        if any(belongs_to_process(pid, root) for root in roots):
            return str(expected_path)
    return None


def append_context(endpoint, prompt):
    # Deliberately no prompt.submit: never send an existing user draft implicitly.
    message = {"type": "prompt.append", "text": "\n\n" + prompt + "\n"}
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(3)
        client.connect(endpoint)
        client.sendall((json.dumps(message, ensure_ascii=False) + "\n").encode("utf-8"))
    # The upstream protocol has no ACK. Do not retry automatically or claim delivery.


def wait_for_endpoint(window_id, cwd, timeout=30):
    """Wait for this new TUI's input socket, without sending any model request."""
    windows = json.loads(remote("ls"))
    window = next((w for o in windows for t in o.get("tabs", [])
                   for w in t.get("windows", []) if w.get("id") == window_id), None)
    if window is None:
        raise RuntimeError("AI 窗口已关闭，未填入上下文。")
    discovery = Path.home() / ".dsh-tui" / "inject" / "servers.json"
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            records = json.loads(discovery.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            records = []
        endpoint = find_endpoint(window, cwd, records if isinstance(records, list) else [])
        if endpoint is not None:
            return endpoint
        # Bounded startup readiness wait; a message is never sent more than once.
        time.sleep(0.1)
    raise RuntimeError("AI 输入框尚未就绪，未填入上下文；请等界面出现后重试。")


def source_tab(windows, source_id):
    for os_window in windows:
        for tab in os_window.get("tabs", []):
            if any(str(w.get("id")) == str(source_id) for w in tab.get("windows", [])):
                return os_window["id"], tab["id"]
    raise RuntimeError("来源窗口已关闭，请从当前终端重试。")


def open_chat(cwd, source_id, prompt, target="pane"):
    if target not in ("pane", "tab"):
        raise RuntimeError("未知的 AI 窗口类型。")
    workspace = workspace_key(cwd)
    windows = json.loads(remote("ls"))
    os_id, tab_id = source_tab(windows, source_id)
    # One pane per source tab; explicit AI tabs are separate and workspace-scoped.
    key = f"pane:{os_id}:{tab_id}" if target == "pane" else "tab:" + workspace
    existing = find_window(windows, key)
    same_workspace = existing is not None and existing.get("user_vars", {}).get("kitty_ai_workspace") == workspace
    if same_workspace:
        if prompt:
            discovery = Path.home() / ".dsh-tui" / "inject" / "servers.json"
            try:
                records = json.loads(discovery.read_text(encoding="utf-8"))
            except (OSError, ValueError) as error:
                raise RuntimeError("AI 对话尚未就绪；请等界面出现后再试。") from error
            endpoint = find_endpoint(existing, cwd, records if isinstance(records, list) else [])
            if endpoint is None:
                raise RuntimeError("未找到此 AI 窗口的活动会话；请在窗口内新建会话，或关闭后重试。")
            append_context(endpoint, prompt)
        remote("focus-window", "--match=id:" + str(existing["id"]))
        return existing["id"]
    # Launch the fresh project session successfully before retiring the old pane.
    # This is an explicit workspace boundary, not a request to reuse old history.
    args = [
        "launch", "--source-window=id:" + str(source_id), "--match=id:" + str(tab_id),
        "--type=window" if target == "pane" else "--type=tab",
        "--location=split" if target == "pane" else "--location=after",
        "--cwd=" + cwd, "--title=AI · " + (Path(cwd).name or "/"),
        "--var=" + WINDOW_VAR + "=" + key,
        "--var=kitty_ai_workspace=" + workspace,
        "--env=DSH_TUI_NO_LAUNCHPAD=1", "--env=DSH_TUI_WORKSPACE_TARGET=" + cwd,
    ]
    if target == "pane":
        args.append("--next-to=id:" + str(source_id))
    else:
        args.append("--tab-title=AI · " + (Path(cwd).name or "/"))
    # Never pass context as app argv: TUI treats positional text as auto-submit.
    new_id = int(remote(*args, "/bin/zsh", "-lic", LAUNCH_SCRIPT, "kitty-ai"))
    if prompt:
        append_context(wait_for_endpoint(new_id, cwd), prompt)
    if existing is not None:
        remote("close-window", "--match=id:" + str(existing["id"]))
    return new_id


def report_error(error, source_id):
    message = "kitty AI：" + str(error)
    print(message, file=sys.stderr)
    args = ["launch", "--type=overlay", "--hold"]
    if source_id:
        args.append("--source-window=id:" + source_id)
    remote(*args, "/bin/sh", "-c", 'printf "%s\\n" "$1"', "kitty-ai-error", message)


def main():
    # Background children have no KITTY_WINDOW_ID. kitty expands the launch
    # argument @active-kitty-window-id before spawning the helper.
    source_id = sys.argv[2] if len(sys.argv) > 2 else os.environ.get("KITTY_WINDOW_ID", "")
    try:
        if not source_id.isdecimal():
            raise RuntimeError("请从 kitty 快捷键启动。")
        mode = sys.argv[1] if len(sys.argv) > 1 else "selection"
        target = sys.argv[3] if len(sys.argv) > 3 else "pane"
        if mode not in ("selection", "output"):
            raise RuntimeError("未知的上下文类型。")
        if target not in ("pane", "tab"):
            raise RuntimeError("未知的 AI 窗口类型。")
        # Read bounded input; never evaluate terminal data as code or shell syntax.
        context = sys.stdin.buffer.read(MAX_CONTEXT_BYTES + 4).decode("utf-8", errors="replace")
        prompt = make_prompt(context, mode)
        cwd = str(Path.cwd().resolve())
        lock_dir = cache_dir()
        lock_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
        # Serialise discovery + launch, including concurrent workspace changes.
        with (lock_dir / "windows.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            open_chat(cwd, source_id, prompt, target)
        return 0
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        try:
            report_error(error, source_id)
        except (OSError, subprocess.SubprocessError):
            print("kitty AI 启动失败：" + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
