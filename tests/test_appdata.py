#!/usr/bin/env python3
"""App data extraction, diff and CLI checks; guest/root operations are mocked."""
import importlib.util
import io
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("appdata", REPO / "lib/appdata.py")
APPDATA = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(APPDATA)


def archive(entries):
    stream = io.BytesIO()
    with tarfile.open(fileobj=stream, mode="w") as output:
        for name, content, kind in entries:
            entry = tarfile.TarInfo(name)
            if kind == "file":
                raw = content.encode()
                entry.size = len(raw)
                output.addfile(entry, io.BytesIO(raw))
            else:
                entry.type = tarfile.SYMTYPE if kind == "symlink" else tarfile.LNKTYPE
                entry.linkname = content
                output.addfile(entry)
    stream.seek(0)
    return stream


class AppdataTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def test_extract_files_and_internal_links_privately(self):
        target = self.root / "data"
        APPDATA.extract(target, archive([("shared_prefs/p.xml", "before", "file"),
                                       ("link", "shared_prefs/p.xml", "symlink"),
                                       ("hard", "shared_prefs/p.xml", "hardlink")]))
        self.assertEqual((target / "link").read_text(), "before")
        self.assertEqual((target / "hard").read_text(), "before")
        self.assertEqual((target / "shared_prefs/p.xml").stat().st_mode & 0o777, 0o600)
        self.assertEqual(target.stat().st_mode & 0o777, 0o700)

    def test_archive_cannot_escape_or_write_through_links(self):
        attacks = [[("../escape", "bad", "file")], [("/absolute", "bad", "file")],
                   [("link", "../escape", "symlink")], [("hard", "../escape", "hardlink")],
                   [("link", "/tmp", "symlink")],
                   [("file", "safe", "file"), ("link", "file", "symlink"), ("link", "bad", "file")]]
        for index, entries in enumerate(attacks):
            with self.subTest(entries=entries), self.assertRaises((ValueError, OSError)):
                APPDATA.extract(self.root / str(index), archive(entries))
        self.assertFalse((self.root / "escape").exists())

    def test_truncated_archive_fails(self):
        with self.assertRaises(tarfile.TarError):
            APPDATA.extract(self.root / "data", io.BytesIO(b"broken"))

    def cli(self, *args, ok=True):
        result = subprocess.run(["bash", str(self.root / "redroid.sh"), "appdata", *args],
                                env=self.env, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode == 0, ok, result.stdout + result.stderr)
        return result

    def setup_cli(self):
        shutil.copy2(REPO / "redroid.sh", self.root)
        shutil.copy2(REPO / "redroid.env", self.root)
        shutil.copytree(REPO / "lib", self.root / "lib")
        tools = self.root / "bin"
        tools.mkdir()
        fake = f"#!{sys.executable}\n" + r'''
import os
from pathlib import Path
import sys
args = sys.argv[1:]
root = Path(os.environ["APPDATA_TEST_ROOT"])
if Path(sys.argv[0]).name == "docker":
    print("true")
elif args[0] == "connect":
    pass
elif args[2:5] == ["shell", "pm", "list"]:
    print("package:com.example.app uid:10123")
elif args[2:6] == ["exec-out", "su", "0", "tar"]:
    assert args[6:] == ["-C", "/data/data/com.example.app", "-cf", "-", "."], args
    sys.stdout.buffer.write((root / "guest.tar").read_bytes())
else:
    sys.exit("unexpected adb: " + repr(args))
'''
        for name in ("adb", "docker"):
            (tools / name).write_text(fake)
            (tools / name).chmod(0o755)
        self.env = dict(os.environ, PATH=f"{tools}:{os.environ['PATH']}", APPDATA_TEST_ROOT=str(self.root))
        self.env.pop("REDROID_CONFIG", None)

    def test_cli_two_pulls_text_binary_add_remove_diff_and_partial(self):
        self.setup_cli()
        self.cli("diff", "com.example.app", ok=False)
        (self.root / "guest.tar").write_bytes(archive([("prefs.xml", "before", "file"),
                                                     ("db.sqlite", "a\x00", "file"),
                                                     ("gone", "remove", "file")]).getvalue())
        self.cli("pull", "com.example.app")
        (self.root / "guest.tar").write_bytes(archive([("prefs.xml", "after", "file"),
                                                     ("db.sqlite", "b\x00", "file"),
                                                     ("new", "added", "file")]).getvalue())
        self.cli("pull", "com.example.app")
        result = self.cli("diff", "com.example.app")
        for expected in ("-before", "+after", "SHA-256", "added: new", "removed: gone"):
            self.assertIn(expected, result.stdout)
        (self.root / "guest.tar").write_bytes(b"broken")
        self.cli("pull", "com.example.app", ok=False)
        self.assertIn("4 path(s) changed", self.cli("diff", "com.example.app").stdout)
        self.cli("pull", "../escape", ok=False)


if __name__ == "__main__":
    unittest.main()
