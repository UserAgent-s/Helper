#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - "$@" <<'PY'
import pathlib, re, sys
roots = [pathlib.Path("Sources"), pathlib.Path("Tests"), pathlib.Path("Package.swift")]
files = []
for r in roots:
    files += [r] if r.is_file() else sorted(r.rglob("*.swift"))
web = sorted(p for ext in ("*.js", "*.css", "*.html") for p in pathlib.Path("Sources").rglob(ext))
def strip_quoted(line):
    out, i, n, quote = [], 0, len(line), None
    while i < n:
        c = line[i]
        if quote:
            if c == "\\":
                i += 2
                continue
            if c == quote:
                quote = None
            i += 1
            continue
        if c in "\"'`":
            quote = c
            i += 1
            continue
        out.append(c)
        i += 1
    return "".join(out)
def strip_strings(line):
    out, i, n = [], 0, len(line)
    in_str = False
    while i < n:
        c = line[i]
        if in_str:
            if c == "\\":
                i += 2
                continue
            if c == '"':
                in_str = False
            i += 1
            continue
        if c == '"':
            in_str = True
            i += 1
            continue
        out.append(c)
        i += 1
    return "".join(out)
hits = []
for f in files:
    in_multiline = False
    for no, raw in enumerate(f.read_text(encoding="utf-8").splitlines(), 1):
        if str(f) == "Package.swift" and no == 1 and raw.startswith("// swift-tools-version"):
            continue
        if raw.count('"""') % 2 == 1:
            in_multiline = not in_multiline
            continue
        if in_multiline:
            continue
        code = strip_strings(raw)
        if "//" in code or "/*" in code:
            hits.append(f"{f}:{no}: {raw.strip()}")
for f in web:
    for no, raw in enumerate(f.read_text(encoding="utf-8").splitlines(), 1):
        code = strip_quoted(raw)
        markers = {".js": ("//", "/*"), ".css": ("/*",), ".html": ("<!--",)}[f.suffix]
        if any(m in code for m in markers):
            hits.append(f"{f}:{no}: {raw.strip()}")
files += web
if hits:
    print("Comments are not allowed (CLAUDE.md). Move rationale to docs/implementation-status.md or docs/adr:")
    print("\n".join(hits))
    sys.exit(1)
print(f"no-comments: {len(files)} files clean")
PY
