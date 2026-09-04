# shellcheck shell=bash
# meta-cli library — adapters + run/fan/collect

meta_log() { printf 'meta: %s\n' "$*" >&2; }
meta_die() { meta_log "error: $*"; exit 1; }

# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/exec.sh"

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

# ── ACP lane (Agent Client Protocol) ────────────────────────────────────────
# The warm/persistent execution lane. Provider's ACP agent command, overridable
# via META_<PROVIDER>_ACP. Empty ⇒ that provider is CLI-only.
meta_acp_cmd_for() {
  case "$1" in
    claude) echo "${META_CLAUDE_ACP:-claude-code-acp}" ;;
    gemini) echo "${META_GEMINI_ACP:-}" ;;
    grok)   echo "${META_GROK_ACP:-}" ;;
    codex)  echo "${META_CODEX_ACP:-}" ;;
    *) echo "" ;;
  esac
}

# Node >= 22.12 (the ACP agent packages target it).
meta_node_ok() {
  command -v node >/dev/null 2>&1 || return 1
  local v maj min
  v="$(node --version 2>/dev/null | sed 's/^v//')"
  maj="${v%%.*}"; min="${v#*.}"; min="${min%%.*}"
  [[ "$maj" =~ ^[0-9]+$ ]] || return 1
  (( maj > 22 )) && return 0
  (( maj == 22 )) && [[ "$min" =~ ^[0-9]+$ ]] && (( min >= 12 )) && return 0
  return 1
}

# Is the ACP lane usable for a provider? (agent command defined + resolvable + node ok)
meta_acp_available() {
  local p="$1" cmd
  cmd="$(meta_acp_cmd_for "$p")"
  [[ -n "$cmd" ]] || return 1
  meta_node_ok || return 1
  if [[ "$cmd" == */* ]]; then
    [[ -x "$cmd" ]] || return 1
  else
    command -v "$cmd" >/dev/null 2>&1 || return 1
  fi
  return 0
}

# Human-readable reason the ACP lane is unavailable (for auto-fallback diagnostics).
meta_acp_unavailable_reason() {
  local p="$1" cmd
  cmd="$(meta_acp_cmd_for "$p")"
  if [[ -z "$cmd" ]]; then echo "no ACP agent for ${p}"; return; fi
  if ! meta_node_ok; then echo "node>=22.12 required for ACP lane"; return; fi
  echo "ACP agent '${cmd}' not on PATH"
}

# Locate the ACP client shipped with meta-cli.
meta_acp_script() {
  if [[ -n "${META_ROOT:-}" && -f "${META_ROOT}/lib/acp-run.mjs" ]]; then
    echo "${META_ROOT}/lib/acp-run.mjs"; return 0
  fi
  if [[ -n "${SCRIPT_DIR:-}" && -f "${SCRIPT_DIR}/lib/acp-run.mjs" ]]; then
    echo "${SCRIPT_DIR}/lib/acp-run.mjs"; return 0
  fi
  return 1
}

# Resolve the lane to actually run. Sets META_RESOLVED_LANE and META_LANE_FALLBACK.
# Returns 1 when an *explicit* acp request cannot be satisfied (caller fails loudly).
meta_resolve_lane() {
  local provider="$1" engine="$2"
  META_RESOLVED_LANE=""
  META_LANE_FALLBACK=""
  case "$engine" in
    cli) META_RESOLVED_LANE="cli" ;;
    acp)
      if meta_acp_available "$provider"; then META_RESOLVED_LANE="acp"; else return 1; fi
      ;;
    auto|"")
      if meta_acp_available "$provider"; then
        META_RESOLVED_LANE="acp"
      else
        META_RESOLVED_LANE="cli"
        META_LANE_FALLBACK="$(meta_acp_unavailable_reason "$provider")"
      fi
      ;;
    *) return 2 ;;
  esac
  return 0
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
      # Flags before -p so they apply in print mode. --permission-prompts none
      # auto-denies gated tools instead of blocking on an invisible TTY prompt
      # (stdout/stderr are files). --yolo still bypasses checks entirely.
      META_CMD_ARR=("$bin" --output-format text --permission-prompts none -p "$prompt")
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
      # -p / --single: single-turn headless. --output-format plain keeps the TUI off.
      META_CMD_ARR=("$bin" -p "$prompt" --output-format plain)
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
  local p bin path ver status acp
  local node_note; meta_node_ok && node_note="node $(node --version 2>/dev/null)" || node_note="node<22.12 (ACP off)"
  printf '%-10s %-8s %-6s %-34s %s\n' "PROVIDER" "CLI" "ACP" "PATH" "NOTE"
  printf '%-10s %-8s %-6s %-34s %s\n' "--------" "---" "---" "----" "----"
  while IFS= read -r p; do
    path="$(meta_resolve_bin "$p" || true)"
    meta_acp_available "$p" && acp="yes" || acp="no"
    if [[ -n "$path" ]]; then
      status="ok"
      ver="$("$path" --version 2>/dev/null | head -1 | tr -d '\r' || true)"
      [[ -z "$ver" ]] && ver="installed"
      printf '%-10s %-8s %-6s %-34s %s\n' "$p" "$status" "$acp" "$path" "$ver"
    else
      status="missing"
      local envhint
      envhint="META_$(echo "$p" | tr '[:lower:]' '[:upper:]')"
      printf '%-10s %-8s %-6s %-34s %s\n' "$p" "$status" "$acp" "(not on PATH)" "set ${envhint} or install"
    fi
  done < <(meta_providers_all)
  printf '\nACP lane: %s; agent per provider via META_<PROVIDER>_ACP (claude→claude-code-acp).\n' "$node_note"
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
  META_OPT_ENGINE="auto"
  META_OPT_PROMPT=""

  local -a rest=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -p|--providers|--provider)
        META_OPT_PROVIDERS="${2:-}"; shift 2 || meta_die "missing value for $1" ;;
      -e|--engine)
        META_OPT_ENGINE="${2:-}"; shift 2 || meta_die "missing value for $1" ;;
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
  case "$META_OPT_ENGINE" in
    auto|cli|acp) : ;;
    *) meta_die "invalid --engine: ${META_OPT_ENGINE} (want auto|cli|acp)" ;;
  esac
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
# Write a slot's meta.json (both lanes, dry and real).
meta_write_slot_meta() {
  local slot_dir="$1" provider="$2" slot="$3" cmd_str="$4" cwd="$5" \
        started="$6" ended="$7" duration="$8" exit_code="$9" dry="${10}" \
        lane="${11}" fallback="${12}" session_id="${13}"
  {
    echo "{"
    echo "  \"provider\": \"$(meta_json_escape "$provider")\","
    echo "  \"slot\": \"$(meta_json_escape "$slot")\","
    echo "  \"engine\": \"$(meta_json_escape "$lane")\","
    [[ -n "$fallback" ]]   && echo "  \"lane_fallback\": \"$(meta_json_escape "$fallback")\","
    [[ -n "$session_id" ]] && echo "  \"session_id\": \"$(meta_json_escape "$session_id")\","
    echo "  \"cmd\": \"$(meta_json_escape "$cmd_str")\","
    echo "  \"cwd\": \"$(meta_json_escape "${cwd:-}")\","
    echo "  \"started_at\": \"$(meta_json_escape "$started")\","
    echo "  \"ended_at\": \"$(meta_json_escape "$ended")\","
    echo "  \"duration_ms\": ${duration},"
    echo "  \"exit_code\": ${exit_code},"
    echo "  \"dry_run\": ${dry}"
    echo "}"
  } >"${slot_dir}/meta.json"
}

meta_exec_one() {
  local provider="$1" slot="$2" prompt="$3" run_dir="$4" cwd="$5" timeout="$6" yolo="$7" dry="$8" engine="${9:-auto}"
  local slot_dir="${run_dir}/${slot}"
  mkdir -p "$slot_dir"

  # Resolve the execution lane (may fall back cli under auto; fails under explicit acp).
  if ! meta_resolve_lane "$provider" "$engine"; then
    echo "engine=acp requested but ACP lane unavailable: $(meta_acp_unavailable_reason "$provider")" >"${slot_dir}/stderr.txt"
    : >"${slot_dir}/stdout.txt"
    meta_write_slot_meta "$slot_dir" "$provider" "$slot" "" "${cwd:-}" \
      "$(meta_iso_now)" "$(meta_iso_now)" 0 2 "false" "acp" "unavailable" ""
    return 2
  fi
  local lane="$META_RESOLVED_LANE" fallback="$META_LANE_FALLBACK"

  # Build the command for the chosen lane. The ACP lane runs the shipped Node client and
  # takes cwd itself (so we clear exec_cwd and skip the spawn-side cd).
  local exec_cwd="$cwd"
  if [[ "$lane" == "acp" ]]; then
    local acp_cmd script
    acp_cmd="$(meta_acp_cmd_for "$provider")"
    if ! script="$(meta_acp_script)"; then
      echo "meta: ACP client lib/acp-run.mjs not found" >"${slot_dir}/stderr.txt"
      : >"${slot_dir}/stdout.txt"
      meta_write_slot_meta "$slot_dir" "$provider" "$slot" "" "${cwd:-}" \
        "$(meta_iso_now)" "$(meta_iso_now)" 0 127 "false" "acp" "client missing" ""
      return 127
    fi
    META_CMD_ARR=(node "$script" --agent-cmd "$acp_cmd" --prompt "$prompt" --state-dir "${slot_dir}/state")
    [[ -n "$cwd" ]] && META_CMD_ARR+=(--cwd "$cwd")
    [[ "$timeout" -gt 0 ]] && META_CMD_ARR+=(--timeout "$timeout")
    [[ "$yolo" == 1 ]] && META_CMD_ARR+=(--yolo)
    exec_cwd=""
  else
    if ! meta_build_cmd "$provider" "$prompt" "$yolo"; then
      echo "provider not available: $provider" >"${slot_dir}/stderr.txt"
      : >"${slot_dir}/stdout.txt"
      meta_write_slot_meta "$slot_dir" "$provider" "$slot" "" "${cwd:-}" \
        "$(meta_iso_now)" "$(meta_iso_now)" 0 127 "false" "cli" "$fallback" ""
      return 127
    fi
  fi

  local started ended duration exit_code=0
  started="$(meta_iso_now)"
  local cmd_str
  cmd_str="$(printf '%q ' "${META_CMD_ARR[@]}")"

  if [[ "$dry" == 1 ]]; then
    meta_log "dry-run [${slot}] engine=${lane}: ${cmd_str}"
    meta_write_slot_meta "$slot_dir" "$provider" "$slot" "$cmd_str" "${cwd:-}" \
      "$started" "$started" 0 0 "true" "$lane" "$fallback" ""
    echo "(dry-run — not executed)" >"${slot_dir}/stdout.txt"
    : >"${slot_dir}/stderr.txt"
    return 0
  fi

  local orig_cwd="$cwd"   # for meta.json; acp records its cwd here even though it self-cds
  local start_s end_s
  start_s="$(date +%s)"

  set +e
  meta_spawn_logged "${slot_dir}/stdout.txt" "${slot_dir}/stderr.txt" "$timeout" "$exec_cwd"
  exit_code=$?
  set -e

  end_s="$(date +%s)"
  ended="$(meta_iso_now)"
  duration=$(( (end_s - start_s) * 1000 ))

  # ACP lane emits `session_id=<id>` on stderr; capture it as the resume handle.
  local session_id=""
  if [[ "$lane" == "acp" && -f "${slot_dir}/stderr.txt" ]]; then
    session_id="$(grep -o 'session_id=[^[:space:]]*' "${slot_dir}/stderr.txt" | head -1 | cut -d= -f2 || true)"
  fi

  meta_write_slot_meta "$slot_dir" "$provider" "$slot" "$cmd_str" "$orig_cwd" \
    "$started" "$ended" "$duration" "$exit_code" "false" "$lane" "$fallback" "$session_id"
  return "$exit_code"
}

meta_write_run_json() {
  local run_dir="$1" run_id="$2" status="$3" prompt="$4" providers_csv="$5" started="$6" ended="$7" engine="${8:-auto}"
  cat >"${run_dir}/run.json" <<EOF
{
  "schema_version": 1,
  "run_id": "$(meta_json_escape "$run_id")",
  "status": "$(meta_json_escape "$status")",
  "engine": "$(meta_json_escape "$engine")",
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

  # Explicit acp must fail loudly if the lane is unavailable (never silently downgrade).
  if [[ "$META_OPT_ENGINE" == "acp" && "$META_OPT_DRY" != 1 ]] && ! meta_acp_available "$provider"; then
    meta_die "engine=acp requested but ACP lane unavailable for ${provider}: $(meta_acp_unavailable_reason "$provider")"
  fi

  local run_dir="${META_OPT_OUT}/${META_OPT_RUN_ID}"
  mkdir -p "$run_dir"
  local started ended status="ok" ec=0
  started="$(meta_iso_now)"
  meta_log "run ${META_OPT_RUN_ID} → ${provider} engine=${META_OPT_ENGINE} (out: ${run_dir})"
  set +e
  meta_exec_one "$provider" "$provider" "$META_OPT_PROMPT" "$run_dir" \
    "$META_OPT_CWD" "$META_OPT_TIMEOUT" "$META_OPT_YOLO" "$META_OPT_DRY" "$META_OPT_ENGINE"
  ec=$?
  set -e
  ended="$(meta_iso_now)"
  [[ $ec -ne 0 ]] && status="failed"
  meta_write_run_json "$run_dir" "$META_OPT_RUN_ID" "$status" "$META_OPT_PROMPT" \
    "$provider" "$started" "$ended" "$META_OPT_ENGINE"
  # Surface the provider's answer. Artifacts stay under the run dir; without this
  # the README example looks hung — one log line, then silence, then only a path.
  if [[ -s "${run_dir}/${provider}/stdout.txt" ]]; then
    cat "${run_dir}/${provider}/stdout.txt"
    printf '\n'
  fi
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

  # Explicit acp: every provider in the fan must have the lane, else fail loudly.
  if [[ "$META_OPT_ENGINE" == "acp" && "$META_OPT_DRY" != 1 ]]; then
    local _p _missing=""
    for _p in "${META_PROVIDER_LIST[@]}"; do
      meta_acp_available "$_p" || _missing+="${_p} "
    done
    [[ -n "$_missing" ]] && meta_die "engine=acp unavailable for: ${_missing}(node>=22.12 + each provider's ACP agent)"
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
        "$META_OPT_CWD" "$META_OPT_TIMEOUT" "$META_OPT_YOLO" 1 "$META_OPT_ENGINE"
      slot_ecs+=($?)
      set -e
    done
  else
    for i in "${!slots[@]}"; do
      (
        meta_exec_one "${slot_providers[$i]}" "${slots[$i]}" "$META_OPT_PROMPT" "$run_dir" \
          "$META_OPT_CWD" "$META_OPT_TIMEOUT" "$META_OPT_YOLO" 0 "$META_OPT_ENGINE"
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
    "$providers_csv" "$started" "$ended" "$META_OPT_ENGINE"
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
