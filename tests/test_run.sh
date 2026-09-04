#!/usr/bin/env bash
# Hang-vector tests for `meta run`. Uses a stub provider — no network.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
META="${ROOT}/bin/meta"
STUB="${ROOT}/tests/stubs/claude"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/meta-test.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT

chmod +x "$STUB" "$META"

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

echo
echo "all hang-vector tests passed"
