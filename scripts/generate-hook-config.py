#!/usr/bin/env python3
"""Generate local hook configuration; only --install mutates an existing config."""
import argparse
import copy
import datetime
import json
import os
from pathlib import Path
import shlex
import stat
import sys
import tempfile

MARKER = " # MoyuRelay"
EVENTS = {
    "codex": ["UserPromptSubmit", "Stop", "PermissionRequest", "PostToolUse", "Interrupt", "SessionEnd"],
    "claude": ["UserPromptSubmit", "Stop", "Notification", "PostToolUse", "SessionEnd"],
}


def fragment(source, executable, inbox=None):
    parts = [str(executable), "hook", source]
    if inbox:
        parts = ["/usr/bin/env", "MOYU_RELAY_INBOX=" + str(inbox)] + parts
    command = shlex.join(parts) + MARKER
    # Synchronous, bounded, sub-millisecond local writes normally preserve event order.
    # Never configure allow/deny decisions, trust bypasses, or unsupported events.
    return {"hooks": {name: [{"hooks": [{"type": "command", "command": command, "timeout": 2}]}]
                      for name in EVENTS[source]}}


def merge(existing, generated):
    if not isinstance(existing, dict):
        raise ValueError("配置根节点必须是 JSON 对象")
    result = copy.deepcopy(existing)
    hooks = result.setdefault("hooks", {})
    if not isinstance(hooks, dict):
        raise ValueError("现有 hooks 字段不是对象，已停止以避免覆盖")
    for name, entries in list(hooks.items()):
        if not isinstance(entries, list):
            raise ValueError(f"现有 {name} 配置不是列表，已停止以避免覆盖")
        kept = []
        for group in entries:
            if not isinstance(group, dict) or not isinstance(group.get("hooks"), list):
                raise ValueError(f"现有 {name} 包含无法识别的配置，已停止以避免覆盖")
            group = copy.deepcopy(group)
            group["hooks"] = [handler for handler in group["hooks"]
                              if not (isinstance(handler, dict) and handler.get("type") == "command"
                                      and str(handler.get("command", "")).endswith(MARKER))]
            if group["hooks"]:
                kept.append(group)
        if kept:
            hooks[name] = kept
        else:
            del hooks[name]
    for name, entries in generated["hooks"].items():
        hooks.setdefault(name, []).extend(copy.deepcopy(entries))
    return result


def write_atomic(path, content):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, temporary = tempfile.mkstemp(prefix=".moyu-", dir=path.parent)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "wb") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def main():
    parser = argparse.ArgumentParser(description="生成 Vibe Fishing hooks；默认只输出 JSON，不改用户配置。")
    parser.add_argument("--source", choices=sorted(EVENTS), required=True)
    parser.add_argument("--relayctl", required=True, type=Path, help="已经构建的 relayctl 绝对路径")
    parser.add_argument("--inbox", type=Path, help="可选：本地收件目录绝对路径")
    output = parser.add_mutually_exclusive_group()
    output.add_argument("--output", type=Path, help="写独立配置片段（文件必须不存在）")
    output.add_argument("--install", type=Path, help="合并到明确指定的配置路径；先备份，不替换其他设置")
    args = parser.parse_args()
    executable = args.relayctl.expanduser().absolute()
    if not executable.is_file() or not os.access(executable, os.X_OK):
        parser.error("--relayctl 必须是已存在且可执行的本地文件；请先构建")
    inbox = args.inbox.expanduser().absolute() if args.inbox else None
    generated = fragment(args.source, executable, inbox)
    target = args.install or args.output
    if not target:
        print(json.dumps(generated, ensure_ascii=False, indent=2))
        return
    target = target.expanduser().absolute()
    if target.is_symlink():
        parser.error("目标是符号链接，已停止；请明确指定真实配置文件")
    if args.output and target.exists():
        parser.error("--output 不覆盖已有文件；请换路径或使用 --install 合并")
    original = target.read_bytes() if target.exists() else None
    if original is not None:
        if not stat.S_ISREG(target.stat().st_mode):
            parser.error("目标不是普通文件")
        result = merge(json.loads(original), generated)
    else:
        result = generated
    encoded = (json.dumps(result, ensure_ascii=False, indent=2) + "\n").encode()
    if original is not None:
        stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S-%f")
        backup = target.with_name(target.name + ".moyu-backup-" + stamp)
        write_atomic(backup, original)
        if target.read_bytes() != original:
            raise ValueError("配置在合并期间发生变化，已停止；请重新运行")
        print("原配置已备份：" + str(backup), file=sys.stderr)
    write_atomic(target, encoded)
    print("已写入：" + str(target), file=sys.stderr)
    print("请在客户端查看并信任这些 hooks；脚本没有更改信任或审批设置。", file=sys.stderr)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError) as error:
        print("配置未完成：" + str(error), file=sys.stderr)
        sys.exit(1)
