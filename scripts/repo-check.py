#!/usr/bin/env python3
"""Fast, offline checks for the exact snapshot about to be committed."""

from __future__ import annotations

import argparse
import csv
import io
import json
import os
import posixpath
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import PurePosixPath
from urllib.parse import unquote


MAX_SCAN_BYTES = 2_000_000
DATED = re.compile(r"\d{4}-\d{2}(?:-\d{2})?")
HISTORICAL = re.compile(
    r"\b(SUPERSEDED|RETIRED|historical record|retained as the record|no longer maintained)\b",
    re.I,
)
LINK = re.compile(r"\]\(([^)]+)\)")
BACKTICK_PATH = re.compile(r"`((?:\.\./)+[^`]+)`")
ABSOLUTE_WORKSPACE = re.compile(
    r"(?:~/|/Users/[^/]+/)(?:atlas|projects|repos/personal)/[A-Za-z0-9_.\-/]+"
)

SECRET_PATTERNS = (
    ("AWS access key id", re.compile(rb"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b")),
    ("private key block", re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH |PGP )?PRIVATE KEY")),
    (
        "password assignment",
        re.compile(
            rb"(?i)\b(?:password|passwd|pwd)\s*[:=]\s*[\"']?[^\s\"'<>{}$,;)\]]{6,}"
        ),
    ),
    (
        "API key or token assignment",
        re.compile(
            rb"(?i)\b(?:api[_-]?key|apikey|secret[_-]?key|access[_-]?token|auth[_-]?token)"
            rb"\s*[:=]\s*[\"']?[A-Za-z0-9_\-./+]{16,}"
        ),
    ),
    ("bearer token", re.compile(rb"(?i)bearer\s+[A-Za-z0-9_\-.]{20,}")),
    ("service token", re.compile(rb"\b(?:xox[baprs]-[A-Za-z0-9-]{10,}|gh[pousr]_[A-Za-z0-9]{30,})\b")),
)
BENIGN_SECRET_LINE = re.compile(
    rb"(?i)(<[A-Z_]+>|\$\{?[A-Z_]+\}?|\.\.\.|xxx|redact|example|placeholder|"
    rb"your[_-]|never commit|password\s*[:=]\s*[\"']?\s*$|password\s+is\s+in)"
)


@dataclass(frozen=True)
class Change:
    status: str
    path: str
    old_path: str | None = None


def run_git(root: str, *args: str, check: bool = True) -> subprocess.CompletedProcess[bytes]:
    result = subprocess.run(
        ("git",) + args,
        cwd=root,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if check and result.returncode:
        detail = result.stderr.decode(errors="replace").strip()
        raise RuntimeError(f"git {' '.join(args)} failed: {detail}")
    return result


def repository_root() -> str:
    result = subprocess.run(
        ("git", "rev-parse", "--show-toplevel"),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode:
        raise RuntimeError("not inside a Git working tree")
    return result.stdout.decode().strip()


def staged_changes(root: str) -> list[Change]:
    raw = run_git(root, "diff", "--cached", "--name-status", "-z", "--find-renames").stdout
    fields = raw.split(b"\0")
    if fields and not fields[-1]:
        fields.pop()
    changes: list[Change] = []
    i = 0
    while i < len(fields):
        status = fields[i].decode(errors="replace")
        i += 1
        if status.startswith(("R", "C")):
            old = fields[i].decode(errors="surrogateescape")
            new = fields[i + 1].decode(errors="surrogateescape")
            i += 2
            changes.append(Change(status[0], new, old))
        else:
            path = fields[i].decode(errors="surrogateescape")
            i += 1
            changes.append(Change(status[0], path))
    return changes


def index_paths(root: str) -> set[str]:
    raw = run_git(root, "ls-files", "-z").stdout
    return {p.decode(errors="surrogateescape") for p in raw.split(b"\0") if p}


def index_blob(root: str, path: str) -> bytes:
    return run_git(root, "show", f":{path}").stdout


def head_blob(root: str, path: str) -> bytes | None:
    result = run_git(root, "show", f"HEAD:{path}", check=False)
    return result.stdout if result.returncode == 0 else None


def under(path: str, parent: str) -> bool:
    parent = parent.strip("/")
    return path == parent or path.startswith(parent + "/")


def historical(path: str, text: str) -> bool:
    return any(DATED.search(part) for part in PurePosixPath(path).parts) or bool(
        HISTORICAL.search(text[:600])
    )


def unsafe_path(path: str) -> str | None:
    parts = PurePosixPath(path).parts
    base = parts[-1] if parts else path
    if base == ".DS_Store":
        return "Finder metadata"
    if base == ".env" or base.endswith(".pem") or base.endswith(".key"):
        return "credential-bearing filename"
    if any(part in {".venv", "venv", "__pycache__"} for part in parts):
        return "generated environment or cache"
    if base.startswith("id_") and not base.endswith(".pub"):
        return "possible private key"
    return None


def scan_secret(path: str, data: bytes) -> list[str]:
    if path.endswith("scripts/repo-check.py") or path == "scripts/repo-check.py":
        return []
    if len(data) > MAX_SCAN_BYTES or b"\0" in data[:8192]:
        return []
    findings: list[str] = []
    for number, line in enumerate(data.splitlines(), 1):
        if len(line) > 2000 or BENIGN_SECRET_LINE.search(line):
            continue
        for label, pattern in SECRET_PATTERNS:
            if pattern.search(line):
                findings.append(f"{path}:{number}: possible {label}")
                break
    return findings


def markdown_problems(path: str, data: bytes, available: set[str]) -> list[str]:
    text = data.decode("utf-8", errors="ignore")
    if historical(path, text):
        return []
    problems: list[str] = []
    for match in ABSOLUTE_WORKSPACE.finditer(text):
        problems.append(f"{path}: live absolute workspace path: {match.group(0)}")
    base = posixpath.dirname(path)
    for match in LINK.finditer(text):
        raw = match.group(1).strip()
        if raw.startswith("<") and ">" in raw:
            raw = raw[1 : raw.index(">")]
        else:
            raw = raw.split(maxsplit=1)[0]
        if raw.startswith(("http://", "https://", "mailto:", "#")):
            continue
        target = unquote(raw.split("#", 1)[0])
        if not target or target.startswith("/"):
            continue
        resolved = posixpath.normpath(posixpath.join(base, target))
        if resolved == ".." or resolved.startswith("../"):
            problems.append(f"{path}: link escapes repository: {raw}")
            continue
        if resolved not in available and not any(p.startswith(resolved.rstrip("/") + "/") for p in available):
            problems.append(f"{path}: broken relative link: {raw}")
    for match in BACKTICK_PATH.finditer(text):
        raw = match.group(1)
        resolved = posixpath.normpath(posixpath.join(base, raw))
        if resolved == ".." or resolved.startswith("../"):
            problems.append(f"{path}: backticked path escapes repository: {raw}")
    return problems


def parse_word_budget(spec: str) -> tuple[str, int]:
    path, raw_limit = spec.rsplit("=", 1)
    return path, int(raw_limit)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--all", action="store_true", help="check every tracked file instead of the staged snapshot")
    parser.add_argument("--csv", action="store_true", help="validate staged CSV shape")
    parser.add_argument("--python", action="store_true", help="compile staged Python source")
    parser.add_argument("--protect-existing", action="append", default=[])
    parser.add_argument("--protect-marked", action="append", default=[], metavar="PARENT:MARKER")
    parser.add_argument("--append-only", action="append", default=[])
    parser.add_argument("--word-budget", action="append", default=[], metavar="PATH=WORDS")
    args = parser.parse_args()

    try:
        root = repository_root()
        available = index_paths(root)
        if args.all:
            changes = [Change("S", path) for path in sorted(available)]
        else:
            changes = staged_changes(root)
    except RuntimeError as error:
        print(f"repo-check: {error}", file=sys.stderr)
        return 1

    problems: list[str] = []
    if not args.all:
        whitespace = run_git(root, "diff", "--cached", "--check", check=False)
        if whitespace.returncode:
            problems.extend(whitespace.stdout.decode(errors="replace").splitlines())

    for change in changes:
        if change.status != "S":
            reason = unsafe_path(change.path)
            if reason and change.status != "D":
                problems.append(f"{change.path}: {reason} must not be committed")

        for protected in args.protect_existing:
            affected = change.old_path or change.path
            if under(affected, protected) and change.status in {"M", "D", "R"}:
                problems.append(f"{affected}: protected record cannot be modified, deleted, or renamed")

        for rule in args.protect_marked:
            parent, marker = rule.split(":", 1)
            affected = change.old_path or change.path
            if not under(affected, parent) or affected == parent:
                continue
            rel = affected[len(parent.strip("/")) + 1 :]
            folder = rel.split("/", 1)[0]
            marker_path = f"{parent.strip('/')}/{folder}/{marker}"
            if head_blob(root, marker_path) is not None and change.status in {"M", "D", "R"}:
                problems.append(f"{affected}: {folder} is marked as a frozen record")

        if change.path in args.append_only and change.status != "S":
            if change.status in {"D", "R"}:
                problems.append(f"{change.path}: append-only file cannot be deleted or renamed")
            elif change.status == "M":
                before = head_blob(root, change.path)
                after = index_blob(root, change.path)
                if before is not None and not after.startswith(before):
                    problems.append(f"{change.path}: existing append-only content was changed")

        if change.status == "D":
            continue
        try:
            data = index_blob(root, change.path)
        except RuntimeError as error:
            problems.append(str(error))
            continue
        problems.extend(scan_secret(change.path, data))

        suffix = PurePosixPath(change.path).suffix.lower()
        if suffix == ".json" and len(data) <= MAX_SCAN_BYTES:
            try:
                json.loads(data)
            except (UnicodeDecodeError, json.JSONDecodeError) as error:
                problems.append(f"{change.path}: invalid JSON: {error}")
        if suffix == ".md" and len(data) <= MAX_SCAN_BYTES:
            problems.extend(markdown_problems(change.path, data, available))
        if args.csv and suffix == ".csv" and len(data) <= MAX_SCAN_BYTES:
            try:
                rows = list(csv.reader(io.StringIO(data.decode("utf-8-sig"))))
                widths = {len(row) for row in rows if row}
                if len(widths) > 1:
                    problems.append(f"{change.path}: inconsistent CSV column counts: {sorted(widths)}")
            except (UnicodeDecodeError, csv.Error) as error:
                problems.append(f"{change.path}: invalid CSV: {error}")
        if args.python and suffix == ".py" and len(data) <= MAX_SCAN_BYTES:
            try:
                compile(data, change.path, "exec")
            except (SyntaxError, ValueError) as error:
                problems.append(f"{change.path}: invalid Python: {error}")

    for spec in args.word_budget:
        path, limit = parse_word_budget(spec)
        if path not in available:
            problems.append(f"{path}: budgeted file is missing")
            continue
        if not args.all and not any(change.path == path and change.status != "D" for change in changes):
            continue
        words = len(index_blob(root, path).decode("utf-8", errors="ignore").split())
        if words > limit:
            problems.append(f"{path}: {words} words exceeds the {limit}-word budget")

    if problems:
        print("repo-check FAILED:")
        for problem in sorted(set(problems)):
            print(f"  {problem}")
        return 1
    scope = "tracked files" if args.all else f"{len(changes)} staged change(s)"
    print(f"repo-check OK — {scope}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
