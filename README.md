# ethpandaops/agents

Definitions for ethpandaops automation agents, packaged for [`mc`](https://git.starflinger.eu/starflinger/mc) — a zero-copy package manager for coding assistants. This repo is the **single source of truth** for what our agents say and do; improving an agent means opening a PR here, not touching the deploy pipeline.

Currently shipped:

| Agent | What it does |
|---|---|
| [`reviewer`](agents/reviewer/) | Posts one high-signal code-review comment per pull request on `ethpandaops/*`. |

## How an agent is defined

This repo is itself an `mc` project (note the committed `.mc/mc.json`). Each agent is a directory under `agents/`:

```
agents/reviewer/
├── agent.json     # composition — runner, model, toolset, required env
├── prompt.md      # the agent's system prompt (the prose you'll most often edit)
└── overrides/     # optional file-level overrides (unused for now)

toolsets.json      # named tool bundles, shared across all agents (the allowlist)
```

`agent.json` declares *how* the agent runs; `prompt.md` declares *what* it does. They're deliberately separate so prose changes don't touch config and vice-versa.

```jsonc
// agents/reviewer/agent.json
{
  "name": "reviewer",
  "prompt": "./prompt.md",
  "capabilities": { "skills": [], "commands": [], "extensions": [], "toolset": "reviewer" },
  "env": { "required": ["ANTHROPIC_API_KEY"], "optional": ["ANTHROPIC_BASE_URL"] },
  "runner": "pi",
  "runner_opts": { "provider": "anthropic", "model": "minimax-m2.7", "thinking": "medium" }
}
```

### Toolsets are the allowlist

An agent doesn't list raw tools — it names a **toolset** from `toolsets.json`, and toolsets compose via `includes`:

- `read-only` → `read`, `grep`, `ls`
- `reviewer` → `read-only` + `bash` (so it can verify advisories/semantics; never `edit`/`write`)

To widen what an agent *can* do, you change the toolset definition (a reviewable, shared decision), not a free-floating flag.

## Improving an agent

1. Edit `agents/<name>/prompt.md` (behaviour) and/or `agents/<name>/agent.json` (model, toolset, thinking).
2. Open a PR. Keep prompt changes focused — this is a shared reviewer running across many repos.
3. On merge, the next review picks up the change (see *Consumption* — no container rebuild).

Validate locally before pushing:

```sh
mc validate            # checks every agent.json + toolsets.json + cross-refs; exit 1 on error
mc run reviewer --dry-run    # prints the exact pi argv + the composed prompt, runs nothing
```

## Consumption

The reviewer pipeline treats this repo as the project and invokes the agent per PR:

```sh
git clone https://github.com/ethpandaops/agents && cd agents
# the repo under review is checked out into the cwd; PR context written to pr-context.md
mc run reviewer -- @pr-context.md
```

`mc run` resolves the toolset, checks required env vars are present (fails fast otherwise), reads `prompt.md`, and exec's:

```
pi -p <prompt.md> --provider anthropic --model minimax-m2.7 --thinking medium \
   --tools bash,read,grep,ls --no-skills --no-extensions  @pr-context.md
```

`prompt.md` is the first message (the standing instructions); the per-PR context (`@pr-context.md`) is appended as the next message.

## Open items (pre-contributor)

This repo is wired but not yet load-bearing. Before opening it to outside contributors:

- [ ] **`mc validate` PR gate** — a required GitHub Action that runs `mc validate` on every PR, so a malformed agent can't reach the live reviewer. Pending a published `mc` binary (mc is Zig source today).
- [ ] **Verify the provider wiring** — confirm `pi`'s `anthropic` provider honours `ANTHROPIC_BASE_URL` pointed at the LiteLLM gateway (`ai.starflinger.eu`) serving `minimax-m2.7`. If not, switch `runner_opts.provider` to `local` and configure pi's local provider instead. One-line change in `agent.json`.
- [ ] **Wire the events-ingress reviewer container** to clone this repo and `mc run reviewer` instead of hand-rolling the `pi` invocation.
