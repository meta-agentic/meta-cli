# shellcheck shell=bash
# meta-cli library — adapters + run/fan/collect

meta_log() { printf 'meta: %s\n' "$*" >&2; }
meta_die() { meta_log "error: $*"; exit 1; }

# ── providers ───────────────────────────────────────────────────────────────

meta_providers_all() {
  printf '%s\n' claude gemini grok codex
}

meta_bin_for() {
  local p="$1"
  case "$p" in
    claude) echo "${META_CLAUDE:-claude}" ;;
    gemini) echo "${META_GEMINI:-gemini}" ;;
    grok)   echo "${META_GROK:-grok}" ;;
    codex)  echo "${META_CODEX:-codex}" ;;
    *) return 1 ;;
  esac
}

meta_resolve_bin() {
  local p="$1" bin
  bin="$(meta_bin_for "$p")" || return 1
  if [[ "$bin" == */* ]]; then
    [[ -x "$bin" ]] && { echo "$bin"; return 0; }
    return 1
  fi
  command -v "$bin" 2>/dev/null
}

# Build argv for a headless run. Prints null-separated? No — we use bash arrays via nameref.
# meta_build_cmd <provider> <prompt> <yolo:0|1> → sets global META_CMD_ARR
meta_build_cmd() {
  local provider="$1" prompt="$2" yolo="${3:-0}"
  local bin
  bin="$(meta_resolve_bin "$provider")" || return 1
  META_CMD_ARR=()
  case "$provider" in
    claude)
      META_CMD_ARR=("$bin" -p "$prompt")
      if [[ "$yolo" == 1 ]]; then
        META_CMD_ARR+=(--dangerously-skip-permissions)
      fi
      ;;
    gemini)
      META_CMD_ARR=("$bin" -p "$prompt")
      if [[ "$yolo" == 1 ]]; then
        META_CMD_ARR+=(--yolo)
      fi
      ;;
    grok)
      # -p / --single: single-turn headless
      META_CMD_ARR=("$bin" -p "$prompt")
      if [[ "$yolo" == 1 ]]; then
        META_CMD_ARR+=(--always-approve)
      fi
      ;;
    codex)
      # Best-effort: prefer non-interactive if present; adjust when you verify codex flags
      META_CMD_ARR=("$bin" exec "$prompt")
      ;;
    *)
      return 1
      ;;
  esac
}

meta_cmd_which() {
  local p bin path ver status
  printf '%-10s %-8s %-40s %s\n' "PROVIDER" "STATUS" "PATH" "NOTE"
  printf '%-10s %-8s %-40s %s\n' "--------" "------" "----" "----"
  while IFS= read -r p; do
    bin="$(meta_bin_for "$p")"
    path="$(meta_resolve_bin "$p" || true)"
    if [[ -n "$path" ]]; then
      status="ok"
      ver="$("$path" --version 2>/dev/null | head -1 | tr -d '\r' || true)"
      [[ -z "$ver" ]] && ver="installed"
      printf '%-10s %-8s %-40s %s\n' "$p" "$status" "$path" "$ver"
    else
      status="missing"
      local envhint
      envhint="META_$(echo "$p" | tr '[:lower:]' '[:upper:]')"
      printf '%-10s %-8s %-40s %s\n' "$p" "$status" "(not on PATH)" "set ${envhint} or install"
    fi
  done < <(meta_providers_all)
}

# ── runs dir / ids ──────────────────────────────────────────────────────────

meta_default_runs_parent() {
  if [[ -n "${META_RUNS_DIR:-}" ]]; then
    echo "$META_RUNS_DIR"
  else
    echo "${PWD}/.meta-runs"
  fi
}

meta_new_run_id() {
  local ts rand
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  rand="$(od -An -N2 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n' || echo $$)"
  echo "${ts}-${rand}"
}

meta_iso_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

meta_json_escape() {
  # minimal JSON string escape
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

# ── shared option parse ─────────────────────────────────────────────────────

# Sets: META_OPT_PROVIDERS META_OPT_WORKERS META_OPT_CWD META_OPT_TIMEOUT
#        META_OPT_OUT META_OPT_RUN_ID META_OPT_DRY META_OPT_YOLO META_OPT_PROMPT
meta_parse_run_opts() {
  META_OPT_PROVIDERS=""
  META_OPT_WORKERS=1
  META_OPT_CWD=""
  META_OPT_TIMEOUT=0
  META_OPT_OUT=""
  META_OPT_RUN_ID=""
  META_OPT_DRY=0
  META_OPT_YOLO=0
  META_OPT_PROMPT=""

  local -a rest=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -p|--providers|--provider)
        META_OPT_PROVIDERS="${2:-}"; shift 2 || meta_die "missing value for $1" ;;
      -w|--workers)
        META_OPT_WORKERS="${2:-1}"; shift 2 || meta_die "missing value for $1" ;;
      -C|--cwd)
        META_OPT_CWD="${2:-}"; shift 2 || meta_die "missing value for $1" ;;
      -t|--timeout)
        META_OPT_TIMEOUT="${2:-0}"; shift 2 || meta_die "missing value for $1" ;;
      -o|--out)
        META_OPT_OUT="${2:-}"; shift 2 || meta_die "missing value for $1" ;;
      --run-id)
        META_OPT_RUN_ID="${2:-}"; shift 2 || meta_die "missing value for $1" ;;
      --dry-run) META_OPT_DRY=1; shift ;;
      --yolo) META_OPT_YOLO=1; shift ;;
      --) shift; rest+=("$@"); break ;;
      -h|--help) usage; exit 0 ;;
      -*)
        meta_die "unknown option: $1" ;;
      *)
        rest+=("$1"); shift ;;
    esac
  done

  if [[ ${#rest[@]} -eq 0 ]]; then
    meta_die "prompt required (after options or after --)"
  fi
  META_OPT_PROMPT="${rest[*]}"

  if [[ -z "$META_OPT_PROVIDERS" ]]; then
    meta_die "providers required (-p claude|gemini|grok|…)"
  fi
  if [[ -z "$META_OPT_OUT" ]]; then
    META_OPT_OUT="$(meta_default_runs_parent)"
  fi
  if [[ -z "$META_OPT_RUN_ID" ]]; then
    META_OPT_RUN_ID="$(meta_new_run_id)"
  fi
  if [[ -n "$META_OPT_CWD" && ! -d "$META_OPT_CWD" ]]; then
    meta_die "cwd is not a directory: $META_OPT_CWD"
  fi
}

meta_split_providers() {
  local raw="$1"
  local IFS=','
  # shellcheck disable=SC2206
  META_PROVIDER_LIST=($raw)
  local i
  for i in "${!META_PROVIDER_LIST[@]}"; do
    META_PROVIDER_LIST[$i]="$(echo "${META_PROVIDER_LIST[$i]}" | tr '[:upper:]' '[:lower:]' | xargs)"
  done
}

# Run one worker; write slot dir. Returns child exit code.
meta_exec_one() {
  local provider="$1" slot="$2" prompt="$3" run_dir="$4" cwd="$5" timeout="$6" yolo="$7" dry="$8"
  local slot_dir="${run_dir}/${slot}"
  mkdir -p "$slot_dir"

  if ! meta_build_cmd "$provider" "$prompt" "$yolo"; then
    echo '{"error":"unknown or unresolvable provider"}' >"${slot_dir}/meta.json"
    echo "provider not available: $provider" >"${slot_dir}/stderr.txt"
    : >"${slot_dir}/stdout.txt"
    return 127
  fi

  local started ended duration exit_code=0
  started="$(meta_iso_now)"
  local cmd_str
  cmd_str="$(printf '%q ' "${META_CMD_ARR[@]}")"

  if [[ "$dry" == 1 ]]; then
    meta_log "dry-run [${slot}]: ${cmd_str}"
    cat >"${slot_dir}/meta.json" <<EOF
{
  "provider": "$(meta_json_escape "$provider")",
  "slot": "$(meta_json_escape "$slot")",
  "cmd": "$(meta_json_escape "$cmd_str")",
  "cwd": "$(meta_json_escape "${cwd:-}")",
  "started_at": "$(meta_json_escape "$started")",
  "ended_at": "$(meta_json_escape "$started")",
  "duration_ms": 0,
  "exit_code": 0,
  "dry_run": true
}
EOF
    echo "(dry-run — not executed)" >"${slot_dir}/stdout.txt"
    : >"${slot_dir}/stderr.txt"
    return 0
  fi

  local start_s end_s
  start_s="$(date +%s)"

  set +e
  if [[ -n "$cwd" ]]; then
    if [[ "$timeout" -gt 0 ]]; then
      (
        cd "$cwd" && exec "${META_CMD_ARR[@]}"
      ) >"${slot_dir}/stdout.txt" 2>"${slot_dir}/stderr.txt" &
      local pid=$!
      local waited=0
      while kill -0 "$pid" 2>/dev/null; do
        if [[ $waited -ge $timeout ]]; then
          kill "$pid" 2>/dev/null || true
          sleep 0.5
          kill -9 "$pid" 2>/dev/null || true
          echo "meta: timed out after ${timeout}s" >>"${slot_dir}/stderr.txt"
          exit_code=124
          break
        fi
        sleep 1
        waited=$((waited + 1))
      done
      if [[ $exit_code -ne 124 ]]; then
        wait "$pid"
        exit_code=$?
      fi
    else
      (
        cd "$cwd" && exec "${META_CMD_ARR[@]}"
      ) >"${slot_dir}/stdout.txt" 2>"${slot_dir}/stderr.txt"
      exit_code=$?
    fi
  else
    if [[ "$timeout" -gt 0 ]]; then
      "${META_CMD_ARR[@]}" >"${slot_dir}/stdout.txt" 2>"${slot_dir}/stderr.txt" &
      local pid=$!
      local waited=0
      while kill -0 "$pid" 2>/dev/null; do
        if [[ $waited -ge $timeout ]]; then
          kill "$pid" 2>/dev/null || true
          sleep 0.5
          kill -9 "$pid" 2>/dev/null || true
          echo "meta: timed out after ${timeout}s" >>"${slot_dir}/stderr.txt"
          exit_code=124
          break
        fi
        sleep 1
        waited=$((waited + 1))
      done
      if [[ $exit_code -ne 124 ]]; then
        wait "$pid"
        exit_code=$?
      fi
    else
      "${META_CMD_ARR[@]}" >"${slot_dir}/stdout.txt" 2>"${slot_dir}/stderr.txt"
      exit_code=$?
    fi
  fi
  set -e

  end_s="$(date +%s)"
  ended="$(meta_iso_now)"
  duration=$(( (end_s - start_s) * 1000 ))

  cat >"${slot_dir}/meta.json" <<EOF
{
  "provider": "$(meta_json_escape "$provider")",
  "slot": "$(meta_json_escape "$slot")",
  "cmd": "$(meta_json_escape "$cmd_str")",
  "cwd": "$(meta_json_escape "${cwd:-}")",
  "started_at": "$(meta_json_escape "$started")",
  "ended_at": "$(meta_json_escape "$ended")",
  "duration_ms": ${duration},
  "exit_code": ${exit_code},
  "dry_run": false
}
EOF
  return "$exit_code"
}

meta_write_run_json() {
  local run_dir="$1" run_id="$2" status="$3" prompt="$4" providers_csv="$5" started="$6" ended="$7"
  cat >"${run_dir}/run.json" <<EOF
{
  "schema_version": 1,
  "run_id": "$(meta_json_escape "$run_id")",
  "status": "$(meta_json_escape "$status")",
  "providers": "$(meta_json_escape "$providers_csv")",
  "started_at": "$(meta_json_escape "$started")",
  "ended_at": "$(meta_json_escape "$ended")",
  "prompt_bytes": ${#prompt}
}
EOF
  printf '%s' "$prompt" >"${run_dir}/prompt.txt"
}

meta_cmd_run() {
  meta_parse_run_opts "$@"
  meta_split_providers "$META_OPT_PROVIDERS"
  if [[ ${#META_PROVIDER_LIST[@]} -ne 1 ]]; then
    meta_die "run expects exactly one provider; use 'meta fan' for multiple"
  fi
  local provider="${META_PROVIDER_LIST[0]}"
  if ! meta_resolve_bin "$provider" >/dev/null && [[ "$META_OPT_DRY" != 1 ]]; then
    # allow dry-run even if missing
    if ! meta_bin_for "$provider" >/dev/null 2>&1; then
      meta_die "unknown provider: $provider"
    fi
    if ! meta_resolve_bin "$provider" >/dev/null; then
      meta_die "provider not installed: $provider"
    fi
  fi
  if [[ "$META_OPT_DRY" != 1 ]] && ! meta_resolve_bin "$provider" >/dev/null; then
    meta_die "provider not installed: $provider (meta which)"
  fi
  if [[ "$META_OPT_DRY" == 1 ]] && ! meta_bin_for "$provider" >/dev/null 2>&1; then
    meta_die "unknown provider: $provider"
  fi

  local run_dir="${META_OPT_OUT}/${META_OPT_RUN_ID}"
  mkdir -p "$run_dir"
  local started ended status="ok" ec=0
  started="$(meta_iso_now)"
  meta_log "run ${META_OPT_RUN_ID} → ${provider} (out: ${run_dir})"
  set +e
  meta_exec_one "$provider" "$provider" "$META_OPT_PROMPT" "$run_dir" \
    "$META_OPT_CWD" "$META_OPT_TIMEOUT" "$META_OPT_YOLO" "$META_OPT_DRY"
  ec=$?
  set -e
  ended="$(meta_iso_now)"
  [[ $ec -ne 0 ]] && status="failed"
  meta_write_run_json "$run_dir" "$META_OPT_RUN_ID" "$status" "$META_OPT_PROMPT" \
    "$provider" "$started" "$ended"
  meta_log "done status=${status} exit=${ec} dir=${run_dir}"
  echo "$run_dir"
  return "$ec"
}

meta_cmd_fan() {
  meta_parse_run_opts "$@"
  meta_split_providers "$META_OPT_PROVIDERS"
  local workers="${META_OPT_WORKERS}"
  if ! [[ "$workers" =~ ^[0-9]+$ ]] || [[ "$workers" -lt 1 ]]; then
    meta_die "workers must be a positive integer"
  fi

  local run_dir="${META_OPT_OUT}/${META_OPT_RUN_ID}"
  mkdir -p "$run_dir"
  local started ended
  started="$(meta_iso_now)"

  # Expand slots: multi-provider (workers must be 1 unless single provider) OR single × workers
  local -a slots=()
  local -a slot_providers=()
  if [[ ${#META_PROVIDER_LIST[@]} -gt 1 ]]; then
    if [[ "$workers" -gt 1 ]]; then
      meta_die "cross-provider fan uses workers=1; drop --workers or use a single -p"
    fi
    local p
    for p in "${META_PROVIDER_LIST[@]}"; do
      slots+=("$p")
      slot_providers+=("$p")
    done
  else
    local p="${META_PROVIDER_LIST[0]}" i
    for (( i = 1; i <= workers; i++ )); do
      if [[ "$workers" -eq 1 ]]; then
        slots+=("$p")
      else
        slots+=("${p}@${i}")
      fi
      slot_providers+=("$p")
    done
  fi

  meta_log "fan ${META_OPT_RUN_ID} → ${slots[*]} (out: ${run_dir})"

  local -a pids=()
  local -a slot_ecs=()
  local i slot prov
  if [[ "$META_OPT_DRY" == 1 ]]; then
    for i in "${!slots[@]}"; do
      set +e
      meta_exec_one "${slot_providers[$i]}" "${slots[$i]}" "$META_OPT_PROMPT" "$run_dir" \
        "$META_OPT_CWD" "$META_OPT_TIMEOUT" "$META_OPT_YOLO" 1
      slot_ecs+=($?)
      set -e
    done
  else
    for i in "${!slots[@]}"; do
      (
        meta_exec_one "${slot_providers[$i]}" "${slots[$i]}" "$META_OPT_PROMPT" "$run_dir" \
          "$META_OPT_CWD" "$META_OPT_TIMEOUT" "$META_OPT_YOLO" 0
      ) &
      pids+=($!)
    done
    for i in "${!pids[@]}"; do
      set +e
      wait "${pids[$i]}"
      slot_ecs+=($?)
      set -e
    done
  fi

  ended="$(meta_iso_now)"
  local ok=0 fail=0 ec
  for ec in "${slot_ecs[@]}"; do
    if [[ "$ec" -eq 0 ]]; then ok=$((ok + 1)); else fail=$((fail + 1)); fi
  done
  local status
  if [[ $fail -eq 0 ]]; then status="ok"
  elif [[ $ok -eq 0 ]]; then status="failed"
  else status="partial"
  fi

  local providers_csv
  providers_csv=$(IFS=,; echo "${META_PROVIDER_LIST[*]}")
  meta_write_run_json "$run_dir" "$META_OPT_RUN_ID" "$status" "$META_OPT_PROMPT" \
    "$providers_csv" "$started" "$ended"
  meta_log "done status=${status} ok=${ok} fail=${fail} dir=${run_dir}"
  echo "$run_dir"
  [[ "$status" == "failed" ]] && return 1
  return 0
}

meta_cmd_collect() {
  local run_id="" dir="" to=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --run-id) run_id="${2:-}"; shift 2 || meta_die "missing --run-id" ;;
      --dir) dir="${2:-}"; shift 2 || meta_die "missing --dir" ;;
      --to) to="${2:-}"; shift 2 || meta_die "missing --to" ;;
      -h|--help) usage; exit 0 ;;
      *) meta_die "unknown collect option: $1" ;;
    esac
  done

  if [[ -z "$dir" ]]; then
    [[ -n "$run_id" ]] || meta_die "collect needs --run-id or --dir"
    dir="$(meta_default_runs_parent)/${run_id}"
  fi
  [[ -d "$dir" ]] || meta_die "run directory not found: $dir"
  [[ -f "${dir}/run.json" ]] || meta_die "missing run.json in $dir"

  local run_id_resolved
  run_id_resolved="$(basename "$dir")"
  local prompt=""
  [[ -f "${dir}/prompt.txt" ]] && prompt="$(cat "${dir}/prompt.txt")"

  local md
  md="$(meta_render_collect_md "$dir" "$run_id_resolved" "$prompt")"

  if [[ -z "$to" ]]; then
    printf '%s\n' "$md"
    return 0
  fi

  local out_file
  # Directory if: exists as dir, ends with /, or does not look like a .md file path
  if [[ -d "$to" || "$to" == */ || "$to" != *.md ]]; then
    mkdir -p "$to"
    out_file="${to%/}/meta-run-${run_id_resolved}.md"
  else
    mkdir -p "$(dirname "$to")"
    out_file="$to"
  fi
  printf '%s\n' "$md" >"$out_file"
  meta_log "wrote ${out_file}"
  echo "$out_file"
}

meta_render_collect_md() {
  local dir="$1" run_id="$2" prompt="$3"
  local ts providers status
  ts="$(meta_iso_now)"
  providers=""
  status="unknown"
  if command -v jq >/dev/null 2>&1; then
    providers="$(jq -r '.providers // empty' "${dir}/run.json" 2>/dev/null || true)"
    status="$(jq -r '.status // empty' "${dir}/run.json" 2>/dev/null || true)"
  else
    providers="$(grep -o '"providers"[[:space:]]*:[[:space:]]*"[^"]*"' "${dir}/run.json" | head -1 | sed 's/.*"\([^"]*\)"$/\1/' || true)"
    status="$(grep -o '"status"[[:space:]]*:[[:space:]]*"[^"]*"' "${dir}/run.json" | head -1 | sed 's/.*"\([^"]*\)"$/\1/' || true)"
  fi

  cat <<EOF
---
type: note
tags: [engine/run, meta-cli]
engine: multi
run_id: ${run_id}
providers: ${providers}
status: ${status}
ts: ${ts}
---
# Meta-cli run \`${run_id}\`

## Prompt

\`\`\`
${prompt}
\`\`\`

## Results
EOF

  local slot_dir slot name meta_json exit_code
  for slot_dir in "$dir"/*/; do
    [[ -d "$slot_dir" ]] || continue
    name="$(basename "$slot_dir")"
    exit_code="?"
    if [[ -f "${slot_dir}/meta.json" ]]; then
      if command -v jq >/dev/null 2>&1; then
        exit_code="$(jq -r '.exit_code // "?"' "${slot_dir}/meta.json" 2>/dev/null || echo '?')"
      else
        exit_code="$(grep -o '"exit_code"[[:space:]]*:[[:space:]]*[0-9-]*' "${slot_dir}/meta.json" | head -1 | grep -o '[0-9-]*$' || echo '?')"
      fi
    fi
    cat <<EOF

### ${name} (exit ${exit_code})

#### stdout

\`\`\`
$(cat "${slot_dir}/stdout.txt" 2>/dev/null || echo "(empty)")
\`\`\`

#### stderr

\`\`\`
$(cat "${slot_dir}/stderr.txt" 2>/dev/null || echo "(empty)")
\`\`\`
EOF
  done
}
