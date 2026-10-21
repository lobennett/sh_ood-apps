"""Exercise the rendered app; only cluster/module/agent boundaries are faked."""
import getpass
import html
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile
import time
import unittest
from urllib.parse import parse_qs, unquote, urlsplit

APP = Path(__file__).resolve().parents[1]
DEFAULTS = dict(supacode_agent="claude", sh_workspace="$HOME", bc_queue="russpold",
                sh_cpus="8", sh_mem="32", bc_num_hours="8", sh_modules="")
NODE = "sh03-01n01"
USER = getpass.getuser()


class AppTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="supacode-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.stage = self.root / "stage with 'quotes' & %"
        self.workspace = self.root / "project with 'quotes' & %"
        self.stage.mkdir()
        self.workspace.mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}",
                        SLURM_JOB_ID="12345", SLURMD_NODENAME=NODE,
                        FAKE_NODE=NODE, FAKE_ROW=f"12345|{USER}|RUNNING|{NODE}",
                        MODULE_LOG=str(self.root / "modules"), AGENT_LOG=str(self.root / "agent"))
        self.stub("hostname", 'printf "%s\\n" "$FAKE_NODE"')
        self.stub("squeue", '[[ ${SQUEUE_FAIL:-0} == 0 ]] || exit 1\nprintf "%s\\n" "$FAKE_ROW"')
        for agent in ("claude", "codex"):
            self.stub(agent, f'printf "%s\\n" "{agent}" "$PWD" "$*" > "$AGENT_LOG"')
        startup = self.root / "bashenv"
        startup.write_text('module() { printf "%s\\n" "$*" >> "$MODULE_LOG"; '
                           '[[ ${MODULE_FAIL:-0} == 0 ]]; }; export -f module\n')
        self.env["BASH_ENV"] = str(startup)

    def stub(self, name, body):
        p = self.bin / name
        p.write_text("#!/usr/bin/env bash\n" + body + "\n")
        p.chmod(0o755)

    def render(self, name, values=None, as_yaml=False):
        path = APP / name
        self.assertTrue(path.exists(), f"Missing app template: {path}")
        values = dict(DEFAULTS, **(values or {}))
        p = subprocess.run(["ruby", str(APP / "test/render.rb"), str(path), json.dumps(values),
                            "yaml" if as_yaml else "text"], capture_output=True, text=True)
        self.assertEqual(p.returncode, 0, p.stderr)
        return json.loads(p.stdout) if as_yaml else p.stdout

    def stage_app(self, **values):
        values = dict(sh_workspace=str(self.workspace), **values)
        for name in ("before.sh", "script.sh", "after.sh", "agent.sh"):
            (self.stage / name).write_text(self.render(f"template/{name}.erb", values))
        p = subprocess.run(["bash", "-c", 'source "$1" && env -0', "bash", str(self.stage / "before.sh")],
                           cwd=self.stage, env=self.env, capture_output=True)
        self.assertEqual(p.returncode, 0, p.stderr.decode())
        self.env.update(dict(item.decode().split("=", 1) for item in p.stdout.split(b"\0") if b"=" in item))

    def agent(self, arg="12345", **env):
        return subprocess.run(["bash", str(self.stage / "agent.sh"), arg], cwd=self.workspace,
                              env=dict(self.env, **env), capture_output=True, text=True, timeout=10)

    def test_submission_rejects_invalid_resources_and_keeps_time_and_partition(self):
        submit = self.render("submit.yml.erb", as_yaml=True)
        self.assertEqual(submit["batch_connect"]["template"], "basic")
        self.assertEqual(submit["script"]["native"], ["-N", "1", "-c", "8", "--mem", "32G"])
        form = self.render("form.yml.erb", as_yaml=True)
        for field in ("bc_num_hours", "bc_queue"):
            self.assertIn(field, form["form"])
        for field, value in (("sh_cpus", "0"), ("sh_mem", "-1"), ("bc_num_hours", "oops"),
                             ("bc_queue", "normal;touch x"), ("supacode_agent", "bad")):
            p = subprocess.run(["ruby", str(APP / "test/render.rb"), str(APP / "submit.yml.erb"),
                                json.dumps(dict(DEFAULTS, **{field: value}))], capture_output=True)
            self.assertNotEqual(p.returncode, 0, (field, value))

    def test_job_scripts_are_executable_and_parse(self):
        self.stage_app()
        for name in ("script.sh", "agent.sh"):
            self.assertTrue(os.access(APP / f"template/{name}.erb", os.X_OK))
        for name in ("before.sh", "script.sh", "after.sh", "agent.sh"):
            p = subprocess.run(["bash", "-n", str(self.stage / name)], capture_output=True)
            self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(self.env["supacode_workspace"], str(self.workspace.resolve()))
        self.assertEqual(self.env["supacode_staging_dir"], str(self.stage.resolve()))

    def test_each_agent_loads_modules_and_preserves_current_worktree(self):
        for agent in ("claude", "codex"):
            with self.subTest(agent=agent):
                self.stage_app(supacode_agent=agent, sh_modules="python/3.12 custom-module")
                p = self.agent()
                self.assertEqual(p.returncode, 0, p.stderr)
                self.assertEqual((self.root / "agent").read_text().splitlines(), [agent, str(self.workspace), ""])
                modules = (self.root / "modules").read_text()
                self.assertIn("load system git", modules)
                self.assertIn("claude-code" if agent == "claude" else "codex", modules)
                self.assertIn("python/3.12", modules)

    def test_check_only_loads_dependencies_without_starting_agent(self):
        self.stage_app()
        p = self.agent("--check")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertFalse((self.root / "agent").exists())

    def test_rejects_expired_foreign_pending_wrong_node_and_malformed_jobs(self):
        self.stage_app()
        cases = [dict(FAKE_ROW=""), dict(FAKE_ROW=f"12345|{USER}|PENDING|{NODE}"),
                 dict(FAKE_ROW=f"12345|other|RUNNING|{NODE}"), dict(FAKE_NODE="sh02-ln01"),
                 dict(FAKE_ROW=f"12345|{USER}|RUNNING|sh03-[01n01,01n02]"),
                 dict(FAKE_ROW=f"12345|{USER}|RUNNING|{NODE}|extra"),
                 dict(FAKE_ROW=f"12345|{USER}|RUNNING|{NODE}\n12345|{USER}|RUNNING|{NODE}"),
                 dict(SQUEUE_FAIL="1")]
        for env in cases:
            with self.subTest(env=env):
                p = self.agent(**env)
                self.assertNotEqual(p.returncode, 0, p.stdout)
                self.assertFalse((self.root / "agent").exists())
        for arg in ("", "12345;touch bad", "67890"):
            self.assertNotEqual(self.agent(arg).returncode, 0)

    def test_missing_modules_or_agent_fail_before_launch(self):
        self.stage_app()
        self.assertNotEqual(self.agent(MODULE_FAIL="1").returncode, 0)
        (self.bin / "claude").unlink()
        # The test isolates PATH to avoid accidentally finding a user's real CLI.
        for cmd in ("bash", "id", "dirname"):
            target = f"/usr/bin/{cmd}" if Path(f"/usr/bin/{cmd}").exists() else f"/bin/{cmd}"
            (self.bin / cmd).symlink_to(target)
        p = self.agent(PATH=str(self.bin))
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("claude", p.stderr.lower())
        self.assertFalse((self.root / "agent").exists())

    def test_quoting_never_executes_workspace_or_module_text(self):
        self.workspace = self.root / '$(touch PWNED); project'
        self.workspace.mkdir()
        self.stage_app(sh_modules="'module; touch PWNED'")
        p = self.agent()
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertFalse((self.workspace / "PWNED").exists())
        self.assertFalse((self.stage / "PWNED").exists())

    def test_deeplink_roundtrips_remote_worktree_and_shell_command(self):
        self.stage_app()
        view = self.render("view.html.erb", self.env)
        href = html.unescape(re.search(r'href="(supacode:[^"]+)"', view).group(1))
        url = urlsplit(href)
        self.assertEqual(url.netloc, "worktree")
        self.assertEqual(unquote(url.path.split("/")[1]), f"{USER}@{NODE}{self.workspace}")
        command = parse_qs(url.query)["input"][0]
        self.assertEqual(shlex.split(command), ["bash", "-l", str(self.stage / "agent.sh"), "12345"])
        unsafe_view = self.render("view.html.erb", dict(self.env, supacode_workspace="/a/<img>&'"))
        self.assertNotIn("<img>", unsafe_view)
        self.assertIn("&lt;img&gt;", unsafe_view)
        self.assertIn("ProxyJump sherlock", view)
        self.assertNotIn("/rnode/", view)

    def test_lifecycle_readiness_and_cancel_cleanup(self):
        self.stage_app()
        log = open(self.root / "job.log", "w+")
        self.addCleanup(log.close)
        proc = subprocess.Popen(["bash", str(self.stage / "script.sh")], cwd=self.workspace,
                                env=self.env, stdout=log, stderr=log)
        self.addCleanup(lambda: proc.kill() if proc.poll() is None else None)
        marker = self.stage / "supacode-ready"
        deadline = time.monotonic() + 5
        while not marker.exists() and proc.poll() is None and time.monotonic() < deadline:
            time.sleep(0.02)
        log.flush()
        self.assertTrue(marker.exists(), (self.root / "job.log").read_text())
        p = subprocess.run(["bash", "-c", 'set +e +u; clean_up() { exit "$1"; }; '
                            'source "$1"; [[ $- != *e* && $- != *u* ]]', "bash",
                            str(self.stage / "after.sh")], cwd=self.workspace, env=self.env,
                           capture_output=True, text=True)
        self.assertEqual(p.returncode, 0, p.stderr)
        proc.terminate()
        proc.wait(timeout=5)
        self.assertFalse(marker.exists())
        self.assertTrue(self.workspace.exists())
        self.assertFalse((self.root / "agent").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
