# shellcheck shell=bash
# Spawn helpers for the CLI lane: never inherit stdin, always bound timeout kills.

# Recursively signal a pid and its descendants. Used because provider CLIs (claude,
# grok, …) spawn helper processes; killing only the parent leaves them running and
# can make `wait` appear to hang.
meta_kill_pid_tree() {
  local pid="$1" sig="${2:-TERM}" child
  [[ -n "$pid" ]] || return 0
  while IFS= read -r child; do
    [[ -n "$child" ]] && meta_kill_pid_tree "$child" "$sig"
  done < <(pgrep -P "$pid" 2>/dev/null || true)
  kill "-${sig}" "$pid" 2>/dev/null || true
}

# Run META_CMD_ARR with stdin from /dev/null, capturing stdout/stderr to files.
# A timeout of 0 waits indefinitely. On timeout: SIGTERM tree, then SIGKILL, return 124.
# gemini_trust=1 sets GEMINI_CLI_TRUST_WORKSPACE on this child only.
#
# Why /dev/null: claude/gemini/codex all read stdin in print/headless mode. If the
# parent keeps a pipe open (agent harness, `sleep | meta`, a TTY the user isn't
# typing at), the child waits for EOF forever. Claude even warns:
#   "redirect stdin explicitly: < /dev/null to skip"
meta_spawn_logged() {
  local stdout_file="$1" stderr_file="$2" timeout="${3:-0}" cwd="${4:-}" gemini_trust="${5:-0}"
  local pid waited=0

  # Set or remove it inside the child (prefix or the cd-subshell), never in this shell:
  # a fan runs other providers in sibling processes that must not inherit it.
  if [[ -n "$cwd" ]]; then
    if [[ "$gemini_trust" == 1 ]]; then
      ( cd "$cwd" && { export GEMINI_CLI_TRUST_WORKSPACE=true; exec "${META_CMD_ARR[@]}"; } ) < /dev/null >"$stdout_file" 2>"$stderr_file" &
    else
      ( cd "$cwd" && { unset GEMINI_CLI_TRUST_WORKSPACE; exec "${META_CMD_ARR[@]}"; } ) < /dev/null >"$stdout_file" 2>"$stderr_file" &
    fi
  else
    if [[ "$gemini_trust" == 1 ]]; then
      GEMINI_CLI_TRUST_WORKSPACE=true "${META_CMD_ARR[@]}" < /dev/null >"$stdout_file" 2>"$stderr_file" &
    else
      env -u GEMINI_CLI_TRUST_WORKSPACE "${META_CMD_ARR[@]}" < /dev/null >"$stdout_file" 2>"$stderr_file" &
    fi
  fi
  pid=$!

  if [[ "$timeout" -gt 0 ]]; then
    while kill -0 "$pid" 2>/dev/null; do
      if [[ "$waited" -ge "$timeout" ]]; then
        meta_kill_pid_tree "$pid" TERM
        sleep 0.5
        meta_kill_pid_tree "$pid" KILL
        echo "meta: timed out after ${timeout}s" >>"$stderr_file"
        wait "$pid" 2>/dev/null || true
        return 124
      fi
      sleep 1
      waited=$((waited + 1))
    done
  fi
  wait "$pid"
  return $?
}
