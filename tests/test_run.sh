#!/usr/bin/env bash
# Hang-vector tests for `meta run`. Uses a stub provider — no network.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
META="${ROOT}/bin/meta"
STUB="${ROOT}/tests/stubs/claude"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/meta-test.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT

chmod +x "$STUB" "$META" "${ROOT}/tests/stubs/codex" "${ROOT}/tests/stubs/gemini"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok - $*"; }

export META_CLAUDE="$STUB"
export META_RUNS_DIR="$OUT"

# 1. dry-run of the README example still plans a command
dry="$("$META" run -p claude --dry-run --run-id dry1 -- "Summarize this repo's README in 5 bullets" 2>/dev/null | tail -1)"
[[ -d "$dry" ]] || fail "dry-run did not print a run dir"
grep -q 'stub-claude' "$dry/claude/meta.json" || grep -q -- '-p' "$dry/claude/meta.json" || fail "dry-run meta.json missing cmd"
pass "dry-run README example"

# 2. stdin is /dev/null even when the parent keeps a pipe open.
#    A bash pipeline (`sleep 30 | meta`) would wait for sleep even if meta exits,
#    so hold the write end of a pipe in Python instead.
export META_STUB_CAT_STDIN=1
python3 - "$META" "$OUT" <<'PY'
import os, subprocess, sys, time
meta, outdir = sys.argv[1], sys.argv[2]
r, w = os.pipe()
env = os.environ.copy()
t0 = time.time()
p = subprocess.Popen(
    [meta, "run", "-p", "claude", "--run-id", "stdin1", "--", "hi"],
    stdin=r, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env,
)
os.close(r)
try:
    stdout, stderr = p.communicate(timeout=10)
except subprocess.TimeoutExpired:
    p.kill()
    p.communicate()
    sys.stderr.write("FAIL: meta hung with an open stdin pipe\n")
    sys.exit(1)
os.close(w)
elapsed = time.time() - t0
if elapsed >= 10:
    sys.stderr.write(f"FAIL: stdin inherited — blocked {elapsed:.1f}s\n")
    sys.exit(1)
open(os.path.join(outdir, "stdin-elapsed"), "w").write(str(int(elapsed)))
open(os.path.join(outdir, "stdin-stdout"), "wb").write(stdout)
sys.exit(p.returncode)
PY
export META_STUB_CAT_STDIN=0
grep -q 'stdin=0' "$OUT/stdin1/claude/stdout.txt" || fail "stub saw stdin bytes (expected 0 from /dev/null)"
pass "stdin is /dev/null ($(cat "$OUT/stdin-elapsed")s)"

# 3. timeout kills a sleeping child and returns 124
export META_STUB_SLEEP=30
set +e
"$META" run -p claude -t 2 --run-id to1 -- "hi" >"$OUT/to.out" 2>"$OUT/to.err"
ec=$?
set -e
export META_STUB_SLEEP=0
[[ "$ec" -eq 124 ]] || fail "timeout exit=$ec want 124"
grep -q 'timed out after 2s' "$OUT/to1/claude/stderr.txt" || fail "missing timeout stderr"
pass "timeout kills child (exit 124)"

# 4. live stub run prints the provider stdout (README UX)
out="$("$META" run -p claude --run-id live1 -- "Summarize this repo's README in 5 bullets" 2>/dev/null)"
echo "$out" | grep -q 'stub-ok' || fail "meta run did not print provider stdout"
echo "$out" | grep -q "$OUT/live1" || fail "meta run did not print run dir"
pass "run prints provider stdout + run dir"

# 5. codex --yolo is workspace-write; without it the sandbox stays read-only.
export META_CODEX="${ROOT}/tests/stubs/codex"
export META_GEMINI="${ROOT}/tests/stubs/gemini"

"$META" run -p codex --engine cli --yolo --dry-run --run-id codex-yolo -- "edit a file" >/dev/null
grep -q -- '-s workspace-write' "$OUT/codex-yolo/codex/meta.json" \
  || fail "codex --yolo argv missing -s workspace-write"
pass "codex --yolo adds -s workspace-write"

"$META" run -p codex --engine cli --dry-run --run-id codex-ro -- "edit a file" >/dev/null
if grep -q 'workspace-write' "$OUT/codex-ro/codex/meta.json"; then
  fail "codex without --yolo should stay read-only (no -s workspace-write)"
fi
pass "codex without --yolo stays read-only"

# 6. --skip-git-repo-check only when the run cwd is not a git work tree.
gitcwd="$ROOT"
if ! git -C "$gitcwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  fail "test repo is not a git work tree"
fi
nongit="${OUT}/nongit"
mkdir -p "$nongit"
if git -C "$nongit" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  fail "non-git fixture is inside a work tree"
fi

"$META" run -p codex --engine cli --dry-run -C "$nongit" --run-id codex-nogit -- "edit a file" >/dev/null
grep -q -- '--skip-git-repo-check' "$OUT/codex-nogit/codex/meta.json" \
  || fail "non-git cwd missing --skip-git-repo-check"
pass "codex skips git check outside a repo"

"$META" run -p codex --engine cli --dry-run -C "$gitcwd" --run-id codex-git -- "edit a file" >/dev/null
if grep -q -- '--skip-git-repo-check' "$OUT/codex-git/codex/meta.json"; then
  fail "git cwd should not pass --skip-git-repo-check"
fi
pass "codex keeps git check inside a repo"

# 7. gemini child trusts the workspace; a sibling provider must not inherit it.
"$META" run -p gemini --engine cli --run-id gem-trust -- "hi" >/dev/null
grep -q 'GEMINI_CLI_TRUST_WORKSPACE=true' "$OUT/gem-trust/gemini/stdout.txt" \
  || fail "gemini child did not see GEMINI_CLI_TRUST_WORKSPACE=true"
"$META" run -p gemini --engine cli -C "$nongit" --run-id gem-trust-cwd -- "hi" >/dev/null
grep -q 'GEMINI_CLI_TRUST_WORKSPACE=true' "$OUT/gem-trust-cwd/gemini/stdout.txt" \
  || fail "gemini -C child did not see GEMINI_CLI_TRUST_WORKSPACE=true"
export GEMINI_CLI_TRUST_WORKSPACE=true
"$META" fan -p gemini,codex --engine cli --run-id fan-trust -- "hi" >/dev/null
grep -q 'GEMINI_CLI_TRUST_WORKSPACE=true' "$OUT/fan-trust/gemini/stdout.txt" \
  || fail "fan gemini child did not see GEMINI_CLI_TRUST_WORKSPACE=true"
grep -q 'GEMINI_CLI_TRUST_WORKSPACE=<unset>' "$OUT/fan-trust/codex/stdout.txt" \
  || fail "codex child inherited GEMINI_CLI_TRUST_WORKSPACE"
unset GEMINI_CLI_TRUST_WORKSPACE
pass "gemini trusts workspace; other providers do not"

# 8. usage is parsed from provider output, never estimated.
"$META" run -p codex --engine cli --run-id codex-usage -- "hi" >/dev/null
"$META" run -p claude --engine cli --run-id claude-usage -- "hi" >/dev/null
python3 - "$OUT/codex-usage/codex/meta.json" "$OUT/claude-usage/claude/meta.json" <<'PY'
import json, sys
codex = json.load(open(sys.argv[1]))
claude = json.load(open(sys.argv[2]))
if "usage" not in codex or "usage" not in claude:
    sys.stderr.write("FAIL: meta.json missing usage\n")
    sys.exit(1)
u = codex["usage"]
if not isinstance(u, dict) or u.get("total") != 1234 or u.get("input") is not None or u.get("output") is not None:
    sys.stderr.write("FAIL: codex usage want total 1234 and null input/output, got %r\n" % (u,))
    sys.exit(1)
if claude["usage"] is not None:
    sys.stderr.write("FAIL: claude usage want null, got %r\n" % (claude["usage"],))
    sys.exit(1)
PY
pass "codex usage total 1234; claude usage null"

# 9. A non-numeric Codex usage line must produce valid JSON with a null usage.
export META_STUB_CODEX_USAGE=n/a
"$META" run -p codex --engine cli --run-id codex-usage-invalid -- "hi" >/dev/null
unset META_STUB_CODEX_USAGE
python3 -m json.tool "$OUT/codex-usage-invalid/codex/meta.json" >/dev/null \
  || fail "invalid Codex usage made meta.json invalid JSON"
grep -q '"usage": null' "$OUT/codex-usage-invalid/codex/meta.json" \
  || fail "invalid Codex usage should be null"
pass "invalid codex usage is null and meta.json is valid JSON"

echo
echo "all hang-vector tests passed"
