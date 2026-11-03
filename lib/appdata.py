#!/usr/bin/env python3
"""Extract an untrusted guest tar privately; compare the last two completed pulls."""
import difflib
import hashlib
import os
from pathlib import Path, PurePosixPath
import sys
import tarfile


def inside(root, path):
    if not path.resolve().is_relative_to(root):
        raise ValueError(f"archive path escapes output: {path.name}")
    return path


def extract(root, stream):
    root.mkdir(mode=0o700)
    root = root.resolve()
    with tarfile.open(fileobj=stream, mode="r|*") as archive:
        for member in archive:
            name = PurePosixPath(member.name)
            if name.is_absolute() or ".." in name.parts:
                raise ValueError(f"unsafe archive path: {member.name}")
            path = inside(root, root / name)
            # Never write through a link, including an earlier archive member.
            if path.is_symlink() or any(p.is_symlink() for p in path.parents if p != root.parent):
                raise ValueError(f"archive path uses a symlink: {member.name}")
            if member.isdir():
                path.mkdir(mode=0o700, parents=True, exist_ok=True)
                continue
            if path == root:
                raise ValueError("non-directory archive root")
            path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            if member.isfile():
                with archive.extractfile(member) as source, path.open("xb") as target:
                    os.chmod(path, 0o600)
                    while chunk := source.read(1024 * 1024):
                        target.write(chunk)
            elif member.issym():
                if PurePosixPath(member.linkname).is_absolute():
                    raise ValueError("absolute archive symlink")
                inside(root, path.parent / member.linkname)
                path.symlink_to(member.linkname)
            elif member.islnk():
                source = inside(root, root / member.linkname)
                if source.is_symlink() or not source.is_file():
                    raise ValueError("hard link target must be an extracted regular file")
                os.link(source, path)
            else:
                raise ValueError(f"unsupported archive member: {member.name}")


def inventory(root):
    result = {}
    def visit(directory):
        for path in sorted(directory.iterdir()):
            name = path.relative_to(root).as_posix()
            if path.is_symlink():
                result[name] = ("symlink", os.readlink(path))
            elif path.is_dir():
                result[name] = ("directory", "")
                visit(path)
            elif path.is_file():
                digest = hashlib.sha256()
                with path.open("rb") as stream:
                    while chunk := stream.read(1024 * 1024):
                        digest.update(chunk)
                result[name] = ("file", digest.hexdigest())
            else:
                raise ValueError(f"unsupported local file: {name}")
    visit(root)
    return result


def text(path):
    if not path.is_file() or path.is_symlink():
        return ""
    # shortcut: large files and SQLite are compared by hash; use database tools for row diffs.
    if path.stat().st_size > 1024 * 1024:
        return None
    raw = path.read_bytes()
    if b"\x00" in raw:
        return None
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError:
        return None


def diff(parent):
    pulls = sorted((p for p in parent.iterdir() if p.is_dir() and (p / "data").is_dir()),
                   key=lambda p: (p.stat().st_mtime_ns, p.name))
    if len(pulls) < 2:
        raise ValueError("appdata diff needs two completed pulls for this package")
    before, after = pulls[-2:]
    print(f"Before: {before}\nAfter:  {after}")
    old, new = inventory(before / "data"), inventory(after / "data")
    changed = 0
    for name in sorted(old.keys() | new.keys()):
        if old.get(name) == new.get(name):
            continue
        changed += 1
        status = "added" if name not in old else "removed" if name not in new else "changed"
        print(f"{status}: {name}")
        kinds = {entry[0] for entry in (old.get(name), new.get(name)) if entry}
        if kinds == {"file"}:
            left, right = text(before / "data" / name), text(after / "data" / name)
            if left is not None and right is not None:
                for line in difflib.unified_diff(left.splitlines(), right.splitlines(),
                                                 fromfile=f"before/{name}", tofile=f"after/{name}", lineterm=""):
                    print(line)
            else:
                print(f"  binary/large file SHA-256: {old.get(name)} -> {new.get(name)}")
        else:
            print(f"  {old.get(name)} -> {new.get(name)}")
    print(f"{changed} path(s) changed")


def main():
    try:
        if sys.argv[1] == "extract":
            extract(Path(sys.argv[2]), sys.stdin.buffer)
        elif sys.argv[1] == "diff":
            diff(Path(sys.argv[2]))
        else:
            raise ValueError("unknown appdata action")
    except (OSError, ValueError, tarfile.TarError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
