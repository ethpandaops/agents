# ethpandaops/agents

Definitions for ethpandaops automation agents, packaged for [`mc`](https://github.com/qu0b/mc) — a one-source-of-truth config tool for managed coding agents. This repo is the **single source of truth** for what our agents say and do; improving an agent means opening a PR here, not touching the deploy pipeline.

Currently shipped:

| Agent | What it does |
|---|---|
| [`reviewer`](agents/reviewer/) | Posts one high-signal code-review comment per pull request on `ethpandaops/*`. |

## How an agent is defined

This repo is itself an `mc` project (note the committed `.mc/mc.json`). Each agent is a directory under `agents/`:

```
agents/reviewer/
├── agent.json     # composition — runtime, model, provider, toolset, required env
├── prompt.md      # the agent's system prompt (the prose you'll most often edit)
└── overrides/     # optional file-level overrides (unused for now)

toolsets.json      # named tool bundles, shared across all agents (the allowlist)
```

`agent.json` is `mc`'s cross-runtime **superset** schema: a canonical core (`model`, `provider`, `thinking`, `prompt`, `capabilities`, `env`) plus optional fields, and `runtime` selects which runner the agent emits to (`pi` | `claude` | `hermes` | `openclaw`). `prompt.md` declares *what* the agent does; `agent.json` declares *how* it runs — kept separate so prose changes don't touch config and vice-versa.

```jsonc
// agents/reviewer/agent.json
{
  "name": "reviewer",
  "description": "Automated PR code reviewer for ethpandaops/*",
  "model": "minimax-m2.7",
  "provider": "anthropic",
  "thinking": "medium",
  "prompt": "./prompt.md",
  "capabilities": { "skills": [], "commands": [], "extensions": [], "toolset": "reviewer" },
  "env": { "required": ["ANTHROPIC_API_KEY"], "optional": ["ANTHROPIC_BASE_URL"] },
  "runtime": "pi"
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

Validate locally before pushing — the same check CI runs on every PR and on
every push to `main`:

```sh
./scripts/validate.sh        # checks every agent.json + toolsets.json + cross-refs; exit 1 on error
```

(`scripts/validate.sh` is pure bash + `jq` — it mirrors the contract the live
container parses, so it needs no `mc`/Zig toolchain. `mc validate` /
`mc run reviewer --dry-run` remain useful locally once an `mc` binary is built.)

## Consumption

The reviewer pipeline treats this repo as the project and invokes the agent per PR:

```sh
git clone https://github.com/ethpandaops/agents && cd agents
# the repo under review is checked out into the cwd; PR context written to pr-context.md
mc run reviewer -- @pr-context.md
```

`mc run` resolves the toolset, checks required env vars are present (fails fast otherwise), reads `prompt.md`, and exec's:

```
pi -p <prompt.md> --provider local-llm --model starflinger-anthropic --thinking high \
   --tools bash,read,grep,ls --no-skills --no-extensions  @pr-context.md
```

(The live events-ingress container reproduces this exact invocation from
`agent.json` using `jq` rather than the `mc` binary — see *CI / deploy*.)

`prompt.md` is the first message (the standing instructions); the per-PR context (`@pr-context.md`) is appended as the next message.

## CI / deploy

There is **no build step and no deploy step** for an agent change. The
events-ingress reviewer container clones this repo `@main` on every PR and reads
the package with `jq` (no `mc` binary in the container), so **a merge to `main`
is the deploy** — the next review picks it up.

The [`validate`](.github/workflows/validate.yml) workflow (`scripts/validate.sh`)
is the gate that protects that live path: it runs on every PR and on every push
to `main`, asserting JSON validity, required fields, a real `thinking` level,
existing prompt files, and that each agent's toolset resolves. A malformed agent
fails the check before (PR) or as (main) it would otherwise go live.

## Open items (pre-contributor)

- [x] **PR/main validation gate** — `scripts/validate.sh` via GitHub Actions (jq-based; no `mc` binary needed).
- [x] **Provider wiring verified** — `pi` ignores `ANTHROPIC_BASE_URL`; routing to the LiteLLM gateway (`ai.starflinger.eu`) is done with `provider: local-llm` + `base_url` + `api_key_env`, materialised into pi's `models.json`. The live container does exactly this.
- [x] **Container wired to this repo** — the events-ingress container clones `ethpandaops/agents@main` and consumes the mc-format package via `jq` (deliberately not the `mc` binary, to avoid a Zig-0.16 build in Docker).
- [ ] **Publish an `mc` binary** — `mc` is Zig source (requires Zig 0.16) at [qu0b/mc](https://github.com/qu0b/mc); a built `linux/amd64` binary would let local authors use `mc run reviewer --dry-run`. Not on the deploy critical path.
