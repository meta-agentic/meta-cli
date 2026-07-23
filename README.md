# meta-cli

**Multi-engine agent CLI multiplexer** — detect installed agent CLIs and fan-out the same prompt to Claude / Gemini / Grok / whatever, with a small run-artifact layout.

| | |
|---|---|
| **Binary** | `meta` |
| **Version** | 0.2.0 |
| **Role** | Process multiplexer only — not a swarm brain |
| **Lanes** | `cli` subprocess · `acp` warm session ([Agent Client Protocol](https://agentclientprotocol.com)) |

This tool implements the **engine adapter** contract used by [meta-os](https://github.com/meta-agentic/meta-os) (`systems/engine.md`). In-session multi-agent coordination (swarms, shared memory, hooks) stays with Ruflo / the host engine.

## Install

```bash
git clone https://github.com/meta-agentic/meta-cli.git ~/code/mova77/meta-cli
# or wherever you keep repos

ln -sf ~/code/mova77/meta-cli/bin/meta ~/.local/bin/meta
chmod +x ~/code/mova77/meta-cli/bin/meta
```

Ensure `~/.local/bin` is on your `PATH`.

Optional env:

| Variable | Effect |
|----------|--------|
| `META_RUNS_DIR` | Parent directory for run artifacts (default: `./.meta-runs`) |
| `META_CLAUDE` / `META_GEMINI` / `META_GROK` / `META_CODEX` | Override CLI binary paths |
| `META_CLAUDE_ACP` / `META_GEMINI_ACP` / … | ACP agent command per provider (claude → `claude-code-acp`) |

## Commands

```bash
meta which                          # provider CLI status + ACP-lane availability
meta run  -p claude -- "prompt"     # one provider (auto lane)
meta run  --engine acp -p claude -- "prompt"  # warm persistent ACP session
meta fan  -p claude,gemini,grok -- "prompt"   # cross-provider diversity
meta fan  -p claude --workers 3 -- "prompt"   # same provider × N
meta collect --run-id <id>          # markdown summary to stdout
meta collect --run-id <id> --to memory/raw    # capture for meta-os vault
```

### Common options (`run` / `fan`)

| Flag | Meaning |
|------|---------|
| `-p, --providers` | Comma-separated: `claude`, `gemini`, `grok`, `codex` |
| `-e, --engine` | Lane: `auto` (default) · `cli` · `acp` (see below) |
| `-w, --workers` | Same-provider parallel workers (`fan` only) |
| `-C, --cwd` | Child working directory |
| `-t, --timeout` | Kill after N seconds |
| `-o, --out` | Runs parent directory |
| `--run-id` | Force run id |
| `--dry-run` | Print planned commands; write dry-run artifacts |
| `--yolo` | Pass auto-approve flags where the adapter supports them |

## Execution lanes

Each run picks *how* the provider process runs, via `--engine`:

| Lane | Mechanism | Session |
|------|-----------|---------|
| `cli` | Spawn the provider CLI as a subprocess (v0.1 behaviour). | Cold per run. |
| `acp` | Speak the [Agent Client Protocol](https://agentclientprotocol.com) to the provider's ACP agent over stdio (`lib/acp-run.mjs`). | **Warm, persistent** — the session id is serialized under the slot's `state/` and resumed via `session/load` next run. |
| `auto` *(default)* | ACP when its prerequisites pass, else CLI **with the fallback reason recorded** in `meta.json`. | Whichever ran. |

**ACP prerequisites:** Node ≥ 22.12 and the provider's ACP agent command
(`claude-code-acp` for claude; override with `META_<PROVIDER>_ACP`). `meta which` shows
per-provider ACP availability. Explicit `--engine acp` **fails loudly** when unavailable;
`auto` silently falls back to CLI.

Implements the two-lane engine contract in
[meta-os `systems/engine.md`](https://github.com/meta-agentic/meta-os/blob/main/systems/engine.md).

## Run layout

```text
.meta-runs/<run-id>/
├── run.json                # + "engine": requested lane
├── prompt.txt
└── <provider>/             # or provider@n for workers
    ├── meta.json           # + "engine" (lane used), "lane_fallback"?, "session_id"?
    ├── stdout.txt
    ├── stderr.txt
    └── state/              # ACP lane only: session handle for the next warm run
```

## Design boundaries

**Does:**

- Detect CLIs (and ACP agents) on `PATH`
- Normalize headless spawn across two lanes (CLI subprocess · ACP session)
- Parallel fan-out + timeout
- Persist ACP session handles for warm resume
- Per-provider logs + collect markdown

**Does not:**

- Replace Ruflo swarm / MCP memory
- Implement worktree isolation (use your engine’s `--worktree` or meta-os swarm harness)
- Fan-out every task by default (cost × N)
- Enforce budgets/quota — that's a control-plane concern (meta-os interface layer)

## Shell aliases

If you use [zsh-suite](https://github.com/mova77/zsh-suite), thin wrappers load when `meta` is on `PATH`:

```zsh
mwhich
mrun -p claude -- "…"
mfan -p claude,gemini,grok -- "…"
mcollect --run-id …
```

## License

MIT — see [LICENSE](LICENSE).
