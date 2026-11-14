"""Offline kitty AI helper regression tests.

Run: python3 -B scripts/test_kitty_ai.py
No real kitty/TUI, process enumeration, discovery file or socket is accessed.
"""

import importlib.util
import io
import json
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location(
    "kitty_ai_chat", ROOT / "dot_config/kitty/ai_chat.py"
)
ai = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ai)


HOME = Path("/mock-home")
CWD = "/workspace/中文 project"
INJECT = HOME / ".dsh-tui/inject"


def record(pid=200, cwd=CWD, session="session-test", **overrides):
    result = {
        "pid": pid,
        "cwd": cwd,
        "sessionId": session,
        "socketPath": str(INJECT / (session + ".sock")),
        "startedAt": 12345,
    }
    result.update(overrides)
    return result


def window(pid=100, key=None, ident=42, workspace=None, **overrides):
    result = {
        "id": ident,
        "pid": pid,
        "foreground_processes": [],
        "user_vars": {} if key is None else {
            ai.WINDOW_VAR: key,
            "kitty_ai_workspace": ai.workspace_key(CWD) if workspace is None else workspace,
        },
    }
    result.update(overrides)
    return result


def tree(*items, source_id=12, os_id=1, tab_id=7):
    windows = list(items)
    if source_id is not None and not any(w.get("id") == source_id for w in windows):
        windows.insert(0, window(ident=source_id))
    return [{"id": os_id, "tabs": [{"id": tab_id, "windows": windows}]}]


class OfflineTestCase(unittest.TestCase):
    def setUp(self):
        # Every subprocess/socket call must be explicitly mocked by the test.
        self.process_guard = mock.patch.object(
            ai.subprocess, "run", side_effect=AssertionError("Unexpected subprocess")
        )
        self.socket_guard = mock.patch.object(
            ai.socket, "socket", side_effect=AssertionError("Unexpected socket")
        )
        self.read_guard = mock.patch.object(
            ai.Path, "read_text", side_effect=AssertionError("Unexpected file read")
        )
        self.process_guard.start()
        self.socket_guard.start()
        self.read_guard.start()
        self.addCleanup(self.process_guard.stop)
        self.addCleanup(self.socket_guard.stop)
        self.addCleanup(self.read_guard.stop)
        home = mock.patch.object(ai.Path, "home", return_value=HOME)
        home.start()
        self.addCleanup(home.stop)
        environment = mock.patch.dict(ai.os.environ, {"XDG_CACHE_HOME": ""})
        environment.start()
        self.addCleanup(environment.stop)


class RemoteTransportTests(OfflineTestCase):
    def test_background_remote_socket_fd_is_inherited_by_kitten(self):
        with mock.patch.dict(ai.os.environ, {"KITTY_LISTEN_ON": "fd:17"}), \
                mock.patch.object(ai.subprocess, "run", return_value=SimpleNamespace(stdout=" []\n")) as run:
            self.assertEqual(ai.remote("ls"), "[]")
        self.assertEqual(run.call_args.kwargs["pass_fds"], (17,))
        self.assertEqual(run.call_args.args[0], ["kitten", "@", "ls"])

    def test_filesystem_socket_does_not_inherit_unrelated_fds(self):
        with mock.patch.dict(ai.os.environ, {"KITTY_LISTEN_ON": "unix:/tmp/kitty-test"}), \
                mock.patch.object(ai.subprocess, "run", return_value=SimpleNamespace(stdout="")) as run:
            ai.remote("focus-window", "--match=id:42")
        self.assertEqual(run.call_args.kwargs["pass_fds"], ())


class PromptTests(OfflineTestCase):
    def test_empty_and_whitespace_do_not_invent_request(self):
        for value in ("", " ", "\t\n\r", "\u3000"):
            with self.subTest(value=value):
                self.assertEqual(ai.make_prompt(value, "selection"), "")

    def test_chinese_and_shell_metacharacters_are_literal(self):
        value = '!!echo 不执行\n$(touch /should-not-exist) `exit 93` %s "quoted" \'single\' \\path'
        prompt = ai.make_prompt(value, "selection")
        self.assertIn("<terminal-context>\n" + value + "\n</terminal-context>", prompt)
        self.assertTrue(prompt.startswith("Here is the text selected in my terminal"))
        self.assertFalse(prompt.startswith(("!", "/")))

    def test_output_mode_labels_context_source(self):
        self.assertEqual(ai.make_prompt("普通输出示例", "output"),
                         "Here is the output of my last command, for context in this conversation:\n\n<terminal-context>\n普通输出示例\n</terminal-context>")

    def test_context_uses_only_agreed_source_label_and_original_content(self):
        self.assertEqual(ai.make_prompt("这是正常内容。", "selection"),
                         "Here is the text selected in my terminal, for context in this conversation:\n\n<terminal-context>\n这是正常内容。\n</terminal-context>")
        for mode in ("selection", "output"):
            with self.subTest(mode=mode):
                prompt = ai.make_prompt("这是正常内容。", mode)
                for instruction in ("请用中文", "报错", "异常", "排查", "修复", "确认收到", "询问", "授权", "不要"):
                    self.assertNotIn(instruction, prompt)

    def test_terminal_gestures_stay_behind_fixed_prefix(self):
        for value in ("!rm sensitive", "!!echo example", "/exit", "--resume=other"):
            with self.subTest(value=value):
                prompt = ai.make_prompt(value, "selection")
                self.assertTrue(prompt.startswith("Here is"))
                self.assertIn("\n" + value + "\n", prompt)

    def test_exact_byte_limit_is_not_marked_truncated(self):
        prompt = ai.make_prompt("a" * ai.MAX_CONTEXT_BYTES, "output")
        self.assertNotIn("only the beginning is included", prompt)

    def test_truncation_respects_utf8_and_preserves_wrapper(self):
        original = "中" * (ai.MAX_CONTEXT_BYTES // 3 + 10)
        prompt = ai.make_prompt(original, "output")
        context = prompt.split("<terminal-context>\n", 1)[1].split("\n</terminal-context>", 1)[0]
        self.assertLessEqual(len(context.encode("utf-8")), ai.MAX_CONTEXT_BYTES)
        self.assertEqual(context, "中" * (ai.MAX_CONTEXT_BYTES // 3))
        self.assertNotIn("\ufffd", context)
        self.assertIn("only the beginning is included", prompt)
        self.assertTrue(prompt.startswith("Here is"))

    def test_split_multibyte_boundary_drops_only_partial_character(self):
        original = "a" * (ai.MAX_CONTEXT_BYTES - 1) + "中文"
        prompt = ai.make_prompt(original, "selection")
        self.assertIn("<terminal-context>\n" + "a" * (ai.MAX_CONTEXT_BYTES - 1) + "\n</terminal-context>", prompt)
        self.assertNotIn("\ufffd", prompt)


class WorkspaceAndWindowTests(OfflineTestCase):
    def test_workspace_key_is_stable_and_isolates_directories(self):
        key = ai.workspace_key(CWD)
        self.assertEqual(key, ai.workspace_key(CWD))
        self.assertRegex(key, r"^[0-9a-f]{24}$")
        self.assertNotEqual(key, ai.workspace_key(CWD + "/child"))
        self.assertNotEqual(key, ai.workspace_key("/different/中文 project"))

    def test_match_uses_exact_tag_not_title_or_cwd(self):
        key = ai.workspace_key(CWD)
        ordinary = window(cwd=CWD, title="AI · 中文 project")
        other = window(key=key + "0", ident=43)
        target = window(key=key, ident=44)
        self.assertIs(ai.find_window(tree(ordinary, other, target), key), target)

    def test_searches_multiple_os_windows_and_tabs(self):
        key = ai.workspace_key(CWD)
        target = window(key=key)
        windows = [{"tabs": []}, {"tabs": [{"windows": []}, {"windows": [target]}]}]
        self.assertIs(ai.find_window(windows, key), target)

    def test_empty_or_untagged_windows_do_not_match(self):
        key = ai.workspace_key(CWD)
        for windows in ([], [{}], [{"tabs": [{}]}], tree(window(cwd=CWD))):
            with self.subTest(windows=windows):
                self.assertIsNone(ai.find_window(windows, key))


class ProcessOwnershipTests(OfflineTestCase):
    def test_exact_root_matches_without_process_scan(self):
        self.assertTrue(ai.belongs_to_process(100, 100))

    def test_descendant_walk_matches_root(self):
        with mock.patch.object(ai.subprocess, "run", side_effect=[
            SimpleNamespace(returncode=0, stdout="150\n"),
            SimpleNamespace(returncode=0, stdout="100\n"),
        ]) as run:
            self.assertTrue(ai.belongs_to_process(200, 100))
        self.assertEqual(run.call_count, 2)
        self.assertEqual(run.call_args_list[0].args[0], ["ps", "-o", "ppid=", "-p", "200"])

    def test_dead_pid_and_no_parent_are_rejected(self):
        for result in (SimpleNamespace(returncode=1, stdout=""), SimpleNamespace(returncode=0, stdout="")):
            with self.subTest(result=result), mock.patch.object(ai.subprocess, "run", return_value=result):
                self.assertFalse(ai.belongs_to_process(999999, 100))

    def test_init_and_negative_pids_are_not_descendants(self):
        for pid in (1, 0, -1):
            with self.subTest(pid=pid):
                self.assertFalse(ai.belongs_to_process(pid, 100))

    def test_self_parent_and_bounded_cycle_are_rejected(self):
        with mock.patch.object(ai.subprocess, "run", return_value=SimpleNamespace(returncode=0, stdout="200\n")):
            self.assertFalse(ai.belongs_to_process(200, 100))
        with mock.patch.object(ai.subprocess, "run", side_effect=[
            SimpleNamespace(returncode=0, stdout=("201\n" if i % 2 == 0 else "200\n"))
            for i in range(32)
        ]) as run:
            self.assertFalse(ai.belongs_to_process(200, 100))
            self.assertEqual(run.call_count, 32)


class EndpointTests(OfflineTestCase):
    def test_endpoint_belongs_to_tagged_window_process_tree(self):
        with mock.patch.object(ai, "belongs_to_process", return_value=True) as belongs:
            endpoint = ai.find_endpoint(window(), CWD, [record()])
        self.assertEqual(endpoint, str(INJECT / "session-test.sock"))
        belongs.assert_called_once_with(200, 100)

    def test_nested_source_accepts_absolute_git_root_with_owned_process(self):
        nested = CWD + "/src/子目录"
        with mock.patch.object(ai, "belongs_to_process", return_value=True) as belongs:
            endpoint = ai.find_endpoint(window(), nested, [record(cwd=CWD)])
        self.assertEqual(endpoint, str(INJECT / "session-test.sock"))
        belongs.assert_called_once_with(200, 100)

    def test_git_root_ancestor_still_requires_exact_window_process_ownership(self):
        with mock.patch.object(ai, "belongs_to_process", return_value=False) as belongs:
            self.assertIsNone(ai.find_endpoint(window(), CWD + "/src", [record(cwd=CWD)]))
        belongs.assert_called_once_with(200, 100)

    def test_siblings_and_descendants_are_not_accepted_as_source_ancestors(self):
        for recorded_cwd in (CWD + "-sibling", CWD + "/child", "/workspace/other"):
            with self.subTest(recorded_cwd=recorded_cwd), mock.patch.object(ai, "belongs_to_process") as belongs:
                self.assertIsNone(ai.find_endpoint(window(), CWD, [record(cwd=recorded_cwd)]))
            belongs.assert_not_called()

    def test_relative_or_malformed_recorded_cwd_is_rejected(self):
        for recorded_cwd in ("workspace/中文 project", ".", "", None, 42):
            with self.subTest(recorded_cwd=recorded_cwd), mock.patch.object(ai, "belongs_to_process") as belongs:
                self.assertIsNone(ai.find_endpoint(window(), CWD, [record(cwd=recorded_cwd)]))
            belongs.assert_not_called()

    def test_foreground_process_is_also_an_ownership_root(self):
        target = window(foreground_processes=[{"pid": 150}])
        with mock.patch.object(ai, "belongs_to_process", side_effect=lambda pid, root: root == 150):
            self.assertIsNotNone(ai.find_endpoint(target, CWD, [record()]))

    def test_unrelated_tui_with_same_cwd_is_rejected(self):
        with mock.patch.object(ai, "belongs_to_process", return_value=False):
            self.assertIsNone(ai.find_endpoint(window(), CWD, [record()]))

    def test_wrong_cwd_never_reaches_ownership_probe(self):
        with mock.patch.object(ai, "belongs_to_process") as belongs:
            self.assertIsNone(ai.find_endpoint(window(), CWD, [record(cwd=CWD + "/other")]))
        belongs.assert_not_called()

    def test_noninteger_fake_pid_and_malformed_records_are_rejected(self):
        malformed = [None, [], "fake", {}, record(pid="200"), record(pid=None), record(sessionId=42)]
        with mock.patch.object(ai, "belongs_to_process") as belongs:
            self.assertIsNone(ai.find_endpoint(window(), CWD, malformed))
        belongs.assert_not_called()

    def test_dead_fake_pid_is_rejected_by_process_probe(self):
        with mock.patch.object(ai.subprocess, "run", return_value=SimpleNamespace(returncode=1, stdout="")):
            self.assertIsNone(ai.find_endpoint(window(), CWD, [record(pid=999999)]))

    def test_path_traversal_and_absolute_session_paths_are_rejected(self):
        for session in ("../outside", "sub/session", "/tmp/outside", "sub/../session"):
            with self.subTest(session=session), mock.patch.object(ai, "belongs_to_process") as belongs:
                self.assertIsNone(ai.find_endpoint(window(), CWD, [record(session=session)]))
                belongs.assert_not_called()

    def test_discovery_socket_path_must_be_exact(self):
        for socket_path in ("/tmp/elsewhere.sock", str(INJECT / "other.sock"), str(INJECT / "../session-test.sock")):
            with self.subTest(socket_path=socket_path), mock.patch.object(ai, "belongs_to_process") as belongs:
                self.assertIsNone(ai.find_endpoint(window(), CWD, [record(socketPath=socket_path)]))
                belongs.assert_not_called()

    def test_window_without_pid_cannot_claim_endpoint(self):
        with mock.patch.object(ai, "belongs_to_process") as belongs:
            self.assertIsNone(ai.find_endpoint({"foreground_processes": []}, CWD, [record()]))
        belongs.assert_not_called()


class InjectionTests(OfflineTestCase):
    def test_socket_sends_one_append_message_without_submit(self):
        prompt = ai.make_prompt('中文\n$(exit 91) "quoted"', "selection")
        with mock.patch.object(ai.socket, "socket") as factory:
            client = factory.return_value.__enter__.return_value
            ai.append_context("/mock/session.sock", prompt)
        factory.assert_called_once_with(ai.socket.AF_UNIX, ai.socket.SOCK_STREAM)
        client.settimeout.assert_called_once_with(3)
        client.connect.assert_called_once_with("/mock/session.sock")
        client.sendall.assert_called_once()
        wire = client.sendall.call_args.args[0].decode("utf-8")
        self.assertTrue(wire.endswith("\n"))
        self.assertEqual(len(wire.splitlines()), 1)
        self.assertEqual(json.loads(wire), {"type": "prompt.append", "text": "\n\n" + prompt + "\n"})
        self.assertNotIn("prompt.submit", wire)

    def test_socket_failure_is_not_automatically_retried(self):
        with mock.patch.object(ai.socket, "socket") as factory:
            client = factory.return_value.__enter__.return_value
            client.sendall.side_effect = OSError("mock disconnect")
            with self.assertRaises(OSError):
                ai.append_context("/mock/session.sock", "解释数据")
        client.sendall.assert_called_once()


class StartupDraftTests(OfflineTestCase):
    def test_new_tui_endpoint_is_matched_to_its_window_without_submitting(self):
        with mock.patch.object(ai, "remote", return_value=json.dumps(tree(window(ident=77)))) as remote, \
                mock.patch.object(ai.Path, "read_text", return_value=json.dumps([record()])), \
                mock.patch.object(ai, "belongs_to_process", return_value=True), \
                mock.patch.object(ai.time, "monotonic", side_effect=[0, 0]), \
                mock.patch.object(ai.time, "sleep") as sleep:
            self.assertEqual(ai.wait_for_endpoint(77, CWD), str(INJECT / "session-test.sock"))
        remote.assert_called_once_with("ls")
        sleep.assert_not_called()

    def test_discovery_can_appear_after_launch_without_resending_messages(self):
        with mock.patch.object(ai, "remote", return_value=json.dumps(tree(window(ident=77)))), \
                mock.patch.object(ai.Path, "read_text", side_effect=[FileNotFoundError(), json.dumps([record()])]), \
                mock.patch.object(ai, "belongs_to_process", return_value=True), \
                mock.patch.object(ai.time, "monotonic", side_effect=[0, 0, 0.1]), \
                mock.patch.object(ai.time, "sleep") as sleep:
            self.assertEqual(ai.wait_for_endpoint(77, CWD), str(INJECT / "session-test.sock"))
        sleep.assert_called_once_with(0.1)

    def test_startup_timeout_fails_without_sending_input(self):
        with mock.patch.object(ai, "remote", return_value=json.dumps(tree(window(ident=77)))), \
                mock.patch.object(ai.Path, "read_text") as read, \
                mock.patch.object(ai.time, "monotonic", side_effect=[0, 31]):
            with self.assertRaisesRegex(RuntimeError, "输入框尚未就绪"):
                ai.wait_for_endpoint(77, CWD)
        read.assert_not_called()

    def test_closed_new_window_is_not_replaced_by_another_session(self):
        with mock.patch.object(ai, "remote", return_value=json.dumps(tree())), \
                mock.patch.object(ai.Path, "read_text") as read:
            with self.assertRaisesRegex(RuntimeError, "窗口已关闭"):
                ai.wait_for_endpoint(77, CWD)
        read.assert_not_called()


class SourceTabTests(OfflineTestCase):
    def test_source_lookup_accepts_string_or_integer_id(self):
        for source in (12, "12"):
            with self.subTest(source=source):
                self.assertEqual(ai.source_tab(tree(), source), (1, 7))

    def test_source_lookup_searches_os_windows_and_tabs(self):
        windows = tree(source_id=22, os_id=2, tab_id=8) + tree(os_id=4, tab_id=9)
        self.assertEqual(ai.source_tab(windows, "12"), (4, 9))

    def test_missing_source_is_rejected(self):
        for windows in ([], tree(source_id=None), tree(source_id=99)):
            with self.subTest(windows=windows), self.assertRaisesRegex(RuntimeError, "来源窗口已关闭"):
                ai.source_tab(windows, "12")


class OpenChatTests(OfflineTestCase):
    def setUp(self):
        super().setUp()
        waiting = mock.patch.object(ai, "wait_for_endpoint", return_value="/mock/new.sock")
        appending = mock.patch.object(ai, "append_context")
        self.waiting = waiting.start()
        self.appending = appending.start()
        self.addCleanup(waiting.stop)
        self.addCleanup(appending.stop)

    def test_launch_uses_normal_tui_with_patch_and_no_preference_isolation(self):
        self.assertEqual(ai.LAUNCH_SCRIPT, 'exec dsh --profile dsh-tui --patch "$HOME/.config/kitty/ai.patch.yml"')
        self.assertNotIn("$1", ai.LAUNCH_SCRIPT)
        for removed in ("NODE_OPTIONS", "KITTY_AI_PREFS_DIR", "ai_tui_", "DSH_TUI_BACKEND"):
            self.assertNotIn(removed, ai.LAUNCH_SCRIPT)

    def test_default_pane_launch_fills_draft_without_passing_context_as_argv(self):
        prompt = ai.make_prompt('中文 $(exit 91) `exit 92` "quote"\nline two', "selection")
        with mock.patch.object(ai, "remote", side_effect=[json.dumps(tree()), "77"]) as remote:
            self.assertEqual(ai.open_chat(CWD, "12", prompt), 77)
        self.assertEqual(remote.call_args_list, [
            mock.call("ls"),
            mock.call(
                "launch", "--source-window=id:12", "--match=id:7", "--type=window",
                "--location=split", "--cwd=" + CWD, "--title=AI · 中文 project",
                "--var=" + ai.WINDOW_VAR + "=pane:1:7",
                "--var=kitty_ai_workspace=" + ai.workspace_key(CWD),
                "--env=DSH_TUI_NO_LAUNCHPAD=1", "--env=DSH_TUI_WORKSPACE_TARGET=" + CWD,
                "--next-to=id:12", "/bin/zsh", "-lic", ai.LAUNCH_SCRIPT, "kitty-ai",
            ),
        ])
        self.assertNotIn(prompt, str(remote.call_args_list))
        self.waiting.assert_called_once_with(77, CWD)
        self.appending.assert_called_once_with("/mock/new.sock", prompt)

    def test_explicit_tab_launch_uses_workspace_scope_and_after_location(self):
        with mock.patch.object(ai, "remote", side_effect=[json.dumps(tree()), "78"]) as remote:
            self.assertEqual(ai.open_chat(CWD, "12", "解释数据", "tab"), 78)
        self.assertEqual(remote.call_args_list, [
            mock.call("ls"),
            mock.call(
                "launch", "--source-window=id:12", "--match=id:7", "--type=tab",
                "--location=after", "--cwd=" + CWD, "--title=AI · 中文 project",
                "--var=" + ai.WINDOW_VAR + "=tab:" + ai.workspace_key(CWD),
                "--var=kitty_ai_workspace=" + ai.workspace_key(CWD),
                "--env=DSH_TUI_NO_LAUNCHPAD=1", "--env=DSH_TUI_WORKSPACE_TARGET=" + CWD,
                "--tab-title=AI · 中文 project", "/bin/zsh", "-lic", ai.LAUNCH_SCRIPT,
                "kitty-ai",
            ),
        ])
        self.assertFalse(any(arg.startswith("--next-to") for arg in remote.call_args.args))

    def test_ordinary_tui_same_cwd_is_not_adopted(self):
        ordinary = window(cwd=CWD, title="dsh-tui")
        with mock.patch.object(ai, "remote", side_effect=[json.dumps(tree(ordinary)), "78"]) as remote, \
                mock.patch.object(ai.Path, "read_text") as read, \
                mock.patch.object(ai, "append_context") as append:
            self.assertEqual(ai.open_chat(CWD, "12", "解释数据"), 78)
        self.assertEqual(remote.call_args_list[-1].args[0], "launch")
        read.assert_not_called()
        self.waiting.assert_called_once_with(78, CWD)
        append.assert_called_once_with("/mock/new.sock", "解释数据")

    def test_reuse_appends_and_focuses_without_launch_or_submit(self):
        target = window(key="pane:1:7")
        prompt = ai.make_prompt("新上下文", "output")
        with mock.patch.object(ai, "remote", side_effect=[json.dumps(tree(target)), ""]) as remote, \
                mock.patch.object(ai.Path, "read_text", return_value=json.dumps([record()])) as read, \
                mock.patch.object(ai, "belongs_to_process", return_value=True), \
                mock.patch.object(ai, "append_context") as append:
            self.assertEqual(ai.open_chat(CWD, "12", prompt), 42)
        append.assert_called_once_with(str(INJECT / "session-test.sock"), prompt)
        read.assert_called_once_with(encoding="utf-8")
        self.assertEqual(remote.call_args_list, [mock.call("ls"), mock.call("focus-window", "--match=id:42")])

    def test_nested_workspace_reuses_owned_tui_normalised_to_git_root(self):
        nested = CWD + "/src"
        target = window(key="pane:1:7", workspace=ai.workspace_key(nested))
        with mock.patch.object(ai, "remote", side_effect=[json.dumps(tree(target)), ""]) as remote, \
                mock.patch.object(ai.Path, "read_text", return_value=json.dumps([record(cwd=CWD)])), \
                mock.patch.object(ai, "belongs_to_process", return_value=True), \
                mock.patch.object(ai, "append_context") as append:
            self.assertEqual(ai.open_chat(nested, "12", "子目录日志"), 42)
        append.assert_called_once_with(str(INJECT / "session-test.sock"), "子目录日志")
        self.assertEqual([call.args[0] for call in remote.call_args_list], ["ls", "focus-window"])

    def test_same_tab_other_source_reuses_single_pane(self):
        target = window(key="pane:1:7")
        windows = tree(window(ident=13), target)
        with mock.patch.object(ai, "remote", side_effect=[json.dumps(windows), ""]) as remote:
            self.assertEqual(ai.open_chat(CWD, "13", ""), 42)
        self.assertEqual(remote.call_args_list, [mock.call("ls"), mock.call("focus-window", "--match=id:42")])

    def test_empty_reuse_only_focuses_without_discovery(self):
        target = window(key="pane:1:7")
        with mock.patch.object(ai, "remote", side_effect=[json.dumps(tree(target)), ""]) as remote, \
                mock.patch.object(ai.Path, "read_text") as read, \
                mock.patch.object(ai, "append_context") as append:
            self.assertEqual(ai.open_chat(CWD, "12", ""), 42)
        read.assert_not_called()
        append.assert_not_called()
        self.assertEqual(remote.call_args_list[-1], mock.call("focus-window", "--match=id:42"))

    def test_empty_first_launch_opens_without_prompt_or_model_request(self):
        with mock.patch.object(ai, "remote", side_effect=[json.dumps(tree()), "79"]) as remote:
            self.assertEqual(ai.open_chat(CWD, "12", ""), 79)
        self.assertEqual(remote.call_args.args[-1], "kitty-ai")
        self.waiting.assert_not_called()
        self.appending.assert_not_called()

    def test_same_workspace_different_source_tab_does_not_reuse_pane(self):
        other = window(key="pane:1:7")
        windows = tree(other, source_id=11) + tree(os_id=1, tab_id=8)
        with mock.patch.object(ai, "remote", side_effect=[json.dumps(windows), "80"]) as remote:
            self.assertEqual(ai.open_chat(CWD, "12", "解释数据"), 80)
        args = remote.call_args.args
        self.assertIn("--match=id:8", args)
        self.assertIn("--var=" + ai.WINDOW_VAR + "=pane:1:8", args)
        self.assertNotIn("close-window", [call.args[0] for call in remote.call_args_list])

    def test_same_tab_id_in_different_os_window_does_not_reuse_pane(self):
        other = window(key="pane:1:7")
        windows = tree(other, source_id=11) + tree(os_id=2)
        with mock.patch.object(ai, "remote", side_effect=[json.dumps(windows), "81"]) as remote:
            self.assertEqual(ai.open_chat(CWD, "12", ""), 81)
        self.assertIn("--var=" + ai.WINDOW_VAR + "=pane:2:7", remote.call_args.args)
        self.assertNotIn("close-window", [call.args[0] for call in remote.call_args_list])

    def test_project_change_launches_fresh_history_before_closing_old_pane(self):
        old = window(key="pane:1:7", workspace=ai.workspace_key("/workspace/old"))
        with mock.patch.object(ai, "remote", side_effect=[json.dumps(tree(old)), "82", ""]) as remote, \
                mock.patch.object(ai, "append_context") as append:
            self.assertEqual(ai.open_chat(CWD, "12", "新项目上下文"), 82)
        self.assertEqual([call.args[0] for call in remote.call_args_list], ["ls", "launch", "close-window"])
        self.assertEqual(remote.call_args, mock.call("close-window", "--match=id:42"))
        launch_args = remote.call_args_list[1].args
        self.assertIn("--cwd=" + CWD, launch_args)
        self.assertIn("--var=kitty_ai_workspace=" + ai.workspace_key(CWD), launch_args)
        self.assertNotIn("新项目上下文", launch_args)
        self.assertFalse(any(arg.startswith("--resume") for arg in launch_args))
        append.assert_called_once_with("/mock/new.sock", "新项目上下文")

    def test_project_change_launch_failure_does_not_close_old_pane(self):
        old = window(key="pane:1:7", workspace=ai.workspace_key("/workspace/old"))
        failure = ai.subprocess.CalledProcessError(1, ["kitten", "@", "launch"])
        with mock.patch.object(ai, "remote", side_effect=[json.dumps(tree(old)), failure]) as remote, \
                mock.patch.object(ai, "append_context") as append:
            with self.assertRaises(ai.subprocess.CalledProcessError):
                ai.open_chat(CWD, "12", "新项目上下文")
        self.assertEqual([call.args[0] for call in remote.call_args_list], ["ls", "launch"])
        append.assert_not_called()

    def test_project_change_draft_startup_failure_keeps_old_pane(self):
        old = window(key="pane:1:7", workspace=ai.workspace_key("/workspace/old"))
        self.waiting.side_effect = RuntimeError("AI 输入框尚未就绪")
        with mock.patch.object(ai, "remote", side_effect=[json.dumps(tree(old)), "82"]) as remote:
            with self.assertRaisesRegex(RuntimeError, "输入框尚未就绪"):
                ai.open_chat(CWD, "12", "新项目上下文")
        self.assertEqual([call.args[0] for call in remote.call_args_list], ["ls", "launch"])
        self.appending.assert_not_called()

    def test_project_change_invalid_launch_id_does_not_close_old_pane(self):
        old = window(key="pane:1:7", workspace=ai.workspace_key("/workspace/old"))
        with mock.patch.object(ai, "remote", side_effect=[json.dumps(tree(old)), "not-a-window"]) as remote:
            with self.assertRaises(ValueError):
                ai.open_chat(CWD, "12", "")
        self.assertEqual([call.args[0] for call in remote.call_args_list], ["ls", "launch"])

    def test_missing_workspace_var_is_not_treated_as_matching_history(self):
        legacy = window(key="pane:1:7", user_vars={ai.WINDOW_VAR: "pane:1:7"})
        with mock.patch.object(ai, "remote", side_effect=[json.dumps(tree(legacy)), "83", ""]) as remote:
            self.assertEqual(ai.open_chat(CWD, "12", ""), 83)
        self.assertEqual([call.args[0] for call in remote.call_args_list], ["ls", "launch", "close-window"])

    def test_explicit_tab_same_workspace_reuses_across_source_tabs(self):
        target = window(key="tab:" + ai.workspace_key(CWD))
        windows = tree(target, source_id=11) + tree(os_id=2, tab_id=9)
        with mock.patch.object(ai, "remote", side_effect=[json.dumps(windows), ""]) as remote:
            self.assertEqual(ai.open_chat(CWD, "12", "", "tab"), 42)
        self.assertEqual(remote.call_args_list, [mock.call("ls"), mock.call("focus-window", "--match=id:42")])

    def test_explicit_tab_reuses_socket_without_autosubmitting_draft(self):
        target = window(key="tab:" + ai.workspace_key(CWD))
        with mock.patch.object(ai, "remote", side_effect=[json.dumps(tree(target)), ""]) as remote, \
                mock.patch.object(ai.Path, "read_text", return_value=json.dumps([record()])), \
                mock.patch.object(ai, "belongs_to_process", return_value=True), \
                mock.patch.object(ai, "append_context") as append:
            self.assertEqual(ai.open_chat(CWD, "12", "新上下文", "tab"), 42)
        append.assert_called_once_with(str(INJECT / "session-test.sock"), "新上下文")
        self.assertEqual([call.args[0] for call in remote.call_args_list], ["ls", "focus-window"])

    def test_explicit_tab_does_not_take_over_other_project_tab(self):
        other = window(key="tab:" + ai.workspace_key("/workspace/other"), workspace=ai.workspace_key("/workspace/other"))
        with mock.patch.object(ai, "remote", side_effect=[json.dumps(tree(other)), "84"]) as remote:
            self.assertEqual(ai.open_chat(CWD, "12", "解释数据", "tab"), 84)
        self.assertEqual([call.args[0] for call in remote.call_args_list], ["ls", "launch"])

    def test_tab_and_pane_never_take_over_each_other(self):
        for target, existing_key, expected_type in (
            ("pane", "tab:" + ai.workspace_key(CWD), "--type=window"),
            ("tab", "pane:1:7", "--type=tab"),
        ):
            with self.subTest(target=target), \
                    mock.patch.object(ai, "remote", side_effect=[json.dumps(tree(window(key=existing_key))), "85"]) as remote:
                self.assertEqual(ai.open_chat(CWD, "12", "", target), 85)
            self.assertEqual([call.args[0] for call in remote.call_args_list], ["ls", "launch"])
            self.assertIn(expected_type, remote.call_args.args)

    def test_closed_source_is_rejected_before_launch_or_reuse(self):
        for target in ("pane", "tab"):
            existing_key = "pane:1:7" if target == "pane" else "tab:" + ai.workspace_key(CWD)
            windows = tree(window(key=existing_key), source_id=None)
            with self.subTest(target=target), mock.patch.object(ai, "remote", return_value=json.dumps(windows)) as remote:
                with self.assertRaisesRegex(RuntimeError, "来源窗口已关闭"):
                    ai.open_chat(CWD, "12", "", target)
            remote.assert_called_once_with("ls")

    def test_invalid_target_is_rejected_before_remote_or_file_access(self):
        for target in ("overlay", "", None):
            with self.subTest(target=target), mock.patch.object(ai, "remote") as remote:
                with self.assertRaisesRegex(RuntimeError, "未知的 AI 窗口类型"):
                    ai.open_chat(CWD, "12", "", target)
            remote.assert_not_called()

    def test_missing_or_invalid_discovery_fails_without_duplicate_launch(self):
        target = window(key="pane:1:7")
        for error in (FileNotFoundError("mock absent"), ValueError("mock JSON")):
            with self.subTest(error=error), \
                    mock.patch.object(ai, "remote", return_value=json.dumps(tree(target))) as remote, \
                    mock.patch.object(ai.Path, "read_text", side_effect=error), \
                    mock.patch.object(ai, "append_context") as append:
                with self.assertRaisesRegex(RuntimeError, "尚未就绪"):
                    ai.open_chat(CWD, "12", "解释数据")
                remote.assert_called_once_with("ls")
                append.assert_not_called()

    def test_unrelated_discovery_fails_instead_of_using_ordinary_tui(self):
        target = window(key="pane:1:7")
        ordinary = window(cwd=CWD, ident=99)
        with mock.patch.object(ai, "remote", return_value=json.dumps(tree(target, ordinary))) as remote, \
                mock.patch.object(ai.Path, "read_text", return_value=json.dumps([record(pid=999)])), \
                mock.patch.object(ai, "belongs_to_process", return_value=False), \
                mock.patch.object(ai, "append_context") as append:
            with self.assertRaisesRegex(RuntimeError, "未找到此 AI 窗口"):
                ai.open_chat(CWD, "12", "解释数据")
        remote.assert_called_once_with("ls")
        append.assert_not_called()

    def test_nonlist_discovery_fails_closed(self):
        target = window(key="pane:1:7")
        with mock.patch.object(ai, "remote", return_value=json.dumps(tree(target))), \
                mock.patch.object(ai.Path, "read_text", return_value='{"pid": 200}'):
            with self.assertRaisesRegex(RuntimeError, "未找到此 AI 窗口"):
                ai.open_chat(CWD, "12", "解释数据")


class MainSourceTests(OfflineTestCase):
    def run_main_mocked(self, argv, text=b""):
        with mock.patch.dict(ai.os.environ, {"KITTY_WINDOW_ID": ""}), \
                mock.patch.object(ai.sys, "argv", argv), \
                mock.patch.object(ai.sys, "stdin", SimpleNamespace(buffer=io.BytesIO(text))), \
                mock.patch.object(ai.Path, "cwd", return_value=Path(CWD)), \
                mock.patch.object(ai.Path, "resolve", return_value=Path(CWD)), \
                mock.patch.object(ai.Path, "mkdir") as mkdir, \
                mock.patch.object(ai.Path, "open", autospec=True) as opened_lock, \
                mock.patch.object(ai.fcntl, "flock") as flock, \
                mock.patch.object(ai, "open_chat") as opened:
            result = ai.main()
        return result, opened, opened_lock, flock, mkdir

    def test_background_source_argument_defaults_to_pane_with_four_arguments(self):
        result, opened, _, _, _ = self.run_main_mocked(["ai_chat.py", "selection", "12"])
        self.assertEqual(result, 0)
        opened.assert_called_once_with(CWD, "12", "", "pane")

    def test_explicit_tab_argument_is_passed_to_open_chat(self):
        result, opened, _, _, _ = self.run_main_mocked(["ai_chat.py", "output", "12", "tab"], "中文日志".encode())
        self.assertEqual(result, 0)
        opened.assert_called_once_with(CWD, "12", ai.make_prompt("中文日志", "output"), "tab")

    def test_both_targets_use_same_global_windows_lock(self):
        for target in ("pane", "tab"):
            with self.subTest(target=target):
                result, _, opened_lock, flock, mkdir = self.run_main_mocked(["ai_chat.py", "selection", "12", target])
            self.assertEqual(result, 0)
            opened_lock.assert_called_once_with(HOME / ".cache/kitty-ai/windows.lock", "a")
            flock.assert_called_once()
            self.assertEqual(flock.call_args.args[1], ai.fcntl.LOCK_EX)
            mkdir.assert_called_once_with(mode=0o700, parents=True, exist_ok=True)

    def test_invalid_target_fails_before_reading_input_or_opening_lock(self):
        stdin = SimpleNamespace(buffer=mock.Mock())
        with mock.patch.dict(ai.os.environ, {"KITTY_WINDOW_ID": ""}), \
                mock.patch.object(ai.sys, "argv", ["ai_chat.py", "selection", "12", "overlay"]), \
                mock.patch.object(ai.sys, "stdin", stdin), \
                mock.patch.object(ai.Path, "open") as opened_lock, \
                mock.patch.object(ai, "open_chat") as opened, \
                mock.patch.object(ai, "report_error") as report:
            self.assertEqual(ai.main(), 1)
        stdin.buffer.read.assert_not_called()
        opened_lock.assert_not_called()
        opened.assert_not_called()
        report.assert_called_once()
        self.assertIn("未知的 AI 窗口类型", str(report.call_args.args[0]))

    def test_missing_or_unexpanded_source_fails_before_reading_input(self):
        for argv in (["ai_chat.py", "selection"], ["ai_chat.py", "selection", "@active-kitty-window-id"]):
            stdin = SimpleNamespace(buffer=mock.Mock())
            with self.subTest(argv=argv), \
                    mock.patch.dict(ai.os.environ, {"KITTY_WINDOW_ID": ""}), \
                    mock.patch.object(ai.sys, "argv", argv), \
                    mock.patch.object(ai.sys, "stdin", stdin), \
                    mock.patch.object(ai, "report_error") as report:
                self.assertEqual(ai.main(), 1)
            report.assert_called_once()
            stdin.buffer.read.assert_not_called()


if __name__ == "__main__":
    unittest.main(verbosity=2)
