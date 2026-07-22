# meta-cli

**Multi-engine agent CLI multiplexer** — detect installed agent CLIs and fan-out the same prompt to Claude / Gemini / Grok / whatever, with a small run-artifact layout.

| | |
|---|---|
| **Binary** | `meta` |
| **Version** | 0.1.0 |
| **Role** | Process multiplexer only — not a swarm brain |

This tool implements the **engine adapter** contract used by [meta-os](https://github.com/mova77/meta-os) (`systems/engine.md`). In-session multi-agent coordination (swarms, shared memory, hooks) stays with Ruflo / the host engine.

## Install

```bash
git clone https://github.com/meta-aos/meta-cli.git ~/code/mova77/meta-cli
# or wherever you keep repos

ln -sf ~/code/mova77/meta-cli/bin/meta ~/.local/bin/meta
chmod +x ~/code/mova77/meta-cli/bin/meta
```

Ensure `~/.local/bin` is on your `PATH`.

Optional env:

| Variable | Effect |
|----------|--------|
| `META_RUNS_DIR` | Parent directory for run artifacts (default: `./.meta-runs`) |
| `META_CLAUDE` / `META_GEMINI` / `META_GROK` / `META_CODEX` | Override binary paths |

## Commands

```bash
meta which                          # which providers are installed
meta run  -p claude -- "prompt"     # one provider
meta fan  -p claude,gemini,grok -- "prompt"   # cross-provider diversity
meta fan  -p claude --workers 3 -- "prompt"   # same provider × N
meta collect --run-id <id>          # markdown summary to stdout
meta collect --run-id <id> --to memory/raw    # capture for meta-os vault
```

### Common options (`run` / `fan`)

| Flag | Meaning |
|------|---------|
| `-p, --providers` | Comma-separated: `claude`, `gemini`, `grok`, `codex` |
| `-w, --workers` | Same-provider parallel workers (`fan` only) |
| `-C, --cwd` | Child working directory |
| `-t, --timeout` | Kill after N seconds |
| `-o, --out` | Runs parent directory |
| `--run-id` | Force run id |
| `--dry-run` | Print planned commands; write dry-run artifacts |
| `--yolo` | Pass auto-approve flags where the adapter supports them |

## Run layout

```text
.meta-runs/<run-id>/
├── run.json
├── prompt.txt
└── <provider>/          # or provider@n for workers
    ├── meta.json
    ├── stdout.txt
    └── stderr.txt
```

## Design boundaries

**Does:**

- Detect CLIs on `PATH`
- Normalize headless spawn
- Parallel fan-out + timeout
- Per-provider logs + collect markdown

**Does not:**

- Replace Ruflo swarm / MCP memory
- Implement worktree isolation (use your engine’s `--worktree` or meta-os swarm harness)
- Fan-out every task by default (cost × N)

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
