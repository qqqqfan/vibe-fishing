#!/usr/bin/env python3
"""Integration tests against a built relayctl; no AI client or user config required."""
import concurrent.futures
import json
import os
from pathlib import Path
import shlex
import stat
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
BINARY = Path(os.environ.get("RELAYCTL_BIN", ROOT / ".build/debug/relayctl"))
GENERATOR = ROOT / "scripts/generate-hook-config.py"


class HookBridgeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="moyu hook tests ")
        self.root = Path(self.temporary.name)
        self.inbox = self.root / "inbox"
        self.env = dict(os.environ, MOYU_RELAY_INBOX=str(self.inbox))

    def tearDown(self):
        self.temporary.cleanup()

    def hook(self, name, source="codex", session="session-1", turn="turn-1", **extra):
        payload = {"hook_event_name": name, "session_id": session}
        if turn is not None:
            payload["turn_id"] = turn
        payload.update(extra)
        result = subprocess.run([str(BINARY), "hook", source], input=json.dumps(payload),
                                capture_output=True, text=True, env=self.env, timeout=3)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout.strip(), "{}")
        self.assertEqual(result.stderr, "")
        return result

    def events(self):
        return sorted((json.loads(path.read_text()) for path in self.inbox.glob("*.json")),
                      key=lambda event: event["timestamp"])

    def test_lifecycle_and_no_sensitive_content(self):
        secret = "SECRET_PROMPT_CONTENT_NEVER_WRITE"
        self.hook("UserPromptSubmit", prompt=secret, transcript_path=secret)
        self.hook("PostToolUse", tool_response=secret)
        self.hook("PermissionRequest", tool_input={"command": secret})
        self.hook("PostToolUse")
        self.hook("Stop", last_assistant_message=secret)
        self.hook("Stop")
        events = self.events()
        self.assertEqual([event["state"] for event in events], ["running", "needsInput", "running", "completed"])
        self.assertEqual(set(events[0]), {"id", "source", "session_id", "turn_id", "state", "timestamp"})
        for path in self.inbox.rglob("*"):
            if path.is_file():
                self.assertNotIn(secret.encode(), path.read_bytes())
                self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(self.inbox.stat().st_mode), 0o700)

    def test_old_turn_and_terminal_events_cannot_reactivate(self):
        self.hook("UserPromptSubmit")
        self.hook("UserPromptSubmit", turn="turn-2")
        self.hook("Stop", turn="turn-1")
        self.hook("UserPromptSubmit", turn="turn-1")
        self.hook("Stop", turn="turn-2")
        self.hook("PermissionRequest", turn="turn-2")
        self.hook("PostToolUse", turn="turn-2")
        self.assertEqual([(e["turn_id"], e["state"]) for e in self.events()],
                         [("turn-1", "running"), ("turn-2", "running"), ("turn-2", "completed")])

    def test_subagents_unknown_events_and_missing_ids_ignored(self):
        self.hook("UserPromptSubmit", agent_id="child")
        self.hook("SubagentStop")
        self.hook("SomethingNew")
        self.hook("UserPromptSubmit", turn=None)
        self.hook("Stop", turn="unseen-turn")
        self.hook("StopFailure")  # Not a documented Codex event.
        self.assertEqual(self.events(), [])
        self.hook("UserPromptSubmit")
        self.hook("PermissionRequest", agent_id="child")
        self.hook("Stop", agent_transcript_path="private/subagents/path")
        self.assertEqual([e["state"] for e in self.events()], ["running"])

    def test_claude_local_turn_and_prompt_id(self):
        self.hook("UserPromptSubmit", source="claude", turn=None)
        first = self.events()[-1]["turn_id"]
        self.hook("Stop", source="claude", turn=None)
        self.assertEqual(self.events()[-1]["turn_id"], first)
        self.hook("UserPromptSubmit", source="claude", turn=None)
        self.assertNotEqual(self.events()[-1]["turn_id"], first)
        self.hook("StopFailure", source="claude", turn=None)
        self.hook("UserPromptSubmit", source="claude", turn=None, prompt_id="prompt-3")
        self.hook("Stop", source="claude", turn=None, prompt_id="old-prompt")
        self.hook("Stop", source="claude", turn=None, prompt_id="prompt-3")
        self.assertEqual(self.events()[-1]["turn_id"], "prompt-3")
        self.assertEqual([e["state"] for e in self.events()],
                         ["running", "completed", "running", "failed", "running", "completed"])

    def test_interrupt_and_session_end_without_turn(self):
        self.hook("UserPromptSubmit")
        self.hook("Interrupt")
        self.hook("UserPromptSubmit", turn="turn-2")
        self.hook("SessionEnd", turn=None)
        self.assertEqual([e["state"] for e in self.events()], ["running", "cancelled", "running", "cancelled"])

    def test_bad_input_is_nonblocking(self):
        for payload in ["not JSON", "{}", "[]", "x" * 1_048_577]:
            start = time.monotonic()
            result = subprocess.run([str(BINARY), "hook", "codex"], input=payload, text=True,
                                    capture_output=True, env=self.env, timeout=3)
            self.assertEqual((result.returncode, result.stdout.strip()), (0, "{}"))
            self.assertLess(time.monotonic() - start, 2)
        process = subprocess.Popen([str(BINARY), "hook", "codex"], stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=self.env)
        process.wait(timeout=2)  # An open stdin with no EOF must not hang the Agent.
        self.assertEqual(process.returncode, 0)
        process.stdin.close()
        self.assertEqual(process.stdout.read().strip(), b"{}")
        process.stdout.close()
        process.stderr.close()
        self.assertEqual(self.events(), [])

    def test_concurrent_duplicate_completion_is_one_event(self):
        self.hook("UserPromptSubmit")
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            list(pool.map(lambda _: self.hook("Stop"), range(12)))
        self.assertEqual([e["state"] for e in self.events()], ["running", "completed"])

    def test_symlink_inbox_is_refused(self):
        target = self.root / "elsewhere"
        target.mkdir()
        self.inbox.symlink_to(target, target_is_directory=True)
        self.hook("UserPromptSubmit")
        self.assertEqual(list(target.iterdir()), [])

    def test_generator_quotes_paths_merges_and_backs_up(self):
        executable = self.root / "App's path" / "relayctl"
        executable.parent.mkdir()
        executable.symlink_to(BINARY)
        command = ["python3", str(GENERATOR), "--source", "codex", "--relayctl", str(executable),
                   "--inbox", str(self.inbox)]
        fragment = json.loads(subprocess.check_output(command, text=True))
        self.assertNotIn("StopFailure", fragment["hooks"])
        handler = fragment["hooks"]["UserPromptSubmit"][0]["hooks"][0]
        shell_arguments = shlex.split(handler["command"], comments=True)
        self.assertEqual(shell_arguments[-3:], [str(executable), "hook", "codex"])
        config = self.root / "hooks.json"
        existing = {"keep": {"approval": "unchanged"}, "hooks": {"Stop": [
            {"hooks": [{"type": "command", "command": "existing-hook"}]}]}}
        config.write_text(json.dumps(existing))
        for _ in range(2):
            subprocess.run(command + ["--install", str(config)], capture_output=True, check=True)
        actual = json.loads(config.read_text())
        self.assertEqual(actual["keep"], existing["keep"])
        self.assertEqual(len(actual["hooks"]["Stop"]), 2)
        self.assertEqual(len(list(self.root.glob("hooks.json.moyu-backup-*"))), 2)
        self.assertEqual(stat.S_IMODE(config.stat().st_mode), 0o600)
        # Run the generated shell command to prove quoting survives spaces/apostrophes.
        subprocess.run(handler["command"], shell=True, input=json.dumps({"hook_event_name": "UserPromptSubmit",
                       "session_id": "generated", "turn_id": "t1"}), text=True, capture_output=True, check=True)
        self.assertEqual(self.events()[-1]["session_id"], "generated")


if __name__ == "__main__":
    unittest.main()
