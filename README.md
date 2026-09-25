# ethpandaops/agents

Definitions for ethpandaops automation agents, packaged for [`mc`](https://github.com/qu0b/mc) — a one-source-of-truth config tool for managed coding agents. This repo is the **single source of truth** for what our agents say and do; improving an agent means opening a PR here, not touching the deploy pipeline.

Currently shipped:

| Agent | What it does |
|---|---|
| [`reviewer`](agents/reviewer/) | Posts one high-signal code-review comment per pull request on `ethpandaops/*`. |
| [`responder`](agents/responder/) | Answers when summoned (`redpanda …`) in a PR conversation, an inline review thread, or an issue. |
| [`ci-doctor`](agents/ci-doctor/) | Diagnoses a PR's failed CI jobs from their logs and the code: cause, category, minimal fix. |

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
3. Merge, then move `AGENTS_REF` in bruno's `events-ingress/worker/wrangler.toml` to the new commit. The change goes live with that Worker deploy, and no container rebuild is needed (see *CI / deploy*).

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

### What the runtime provides beyond the toolset

The events-ingress container runs the agent as its own unprivileged user, with
an empty environment except for:

- **`gh`**, logged in with a **read-only** token (`contents`, `issues`,
  `pull_requests`, `actions`) that is revoked when pi exits. Its *installation
  scope* follows the PR's visibility, and the per-PR context states it:
  - **Public PR:** the token is scoped to that one repository
    (`installation/repositories` lists only it). It can still read other
    **public** repositories, as any token can (cross-refs are cloned that way),
    but it reads no private repository.
  - **Private PR:** the token covers the owner's whole installation (today
    every repository of that owner), so it also reads the owner's private
    repositories, never another owner's.

  Permission-gated endpoints such as `collaborators` need more than read and
  return 403 everywhere. As a result, private data never reaches a run that
  answers in public.
- **`react <emoji>` / `react --remove <emoji>`**, a shell command (call it
  through `bash`, it is not a pi tool) that adds or removes the bot's reaction
  on this PR — or this issue, in issue mode — and nothing else. The agent holds
  no token that can write: GitHub's least permission that can react can also
  approve and comment.
- **Every command is capped at 180 s**, whatever `timeout` the agent passes.
- **The PR cannot configure the agent.** The checkout's `.pi/`, `AGENTS.md` and
  `CLAUDE.md` are renamed to `*.from-pr` before pi starts. pi would otherwise
  load them as settings (`shellCommandPrefix` runs on every command) and as
  system-prompt instructions. They stay readable as ordinary files.
- **The 👍 is the pipeline's**, not the prompt's. It is set on zero findings
  and withdrawn otherwise, like the approval (bruno `events-ingress`
  `run-review.sh`, since image v44). The prompt owned it until it was measured:
  the agent's closing step ran 2 times in 6. Observed in production on
  `qu0b/reviewer-sandbox-private#1`, 2026-09-25: a 🔴 finding withdrew a
  standing 👍 (15:29Z), and the fix push set it again with the approval
  (15:30Z).

These commands exist only in that container. A prompt that relies on them
does nothing under a plain `mc run`.

### Runs, and which agent each one gets

| Mode | Trigger | Agent | Context file | What the pipeline posts |
|---|---|---|---|---|
| `review` | PR opened / pushed; or the `redpanda-review` label | `reviewer` | `pr-context.md` | the review, threads, approval (see below) |
| `question` | a PR conversation comment starting `redpanda …` | `responder` | `question-context.md` | a reply comment |
| `thread` | a reply in an inline review thread — ours, or any thread when it starts `redpanda …` | `responder` | `thread-context.md` | a thread reply; resolves our own finding only when a later change addressed it (see below) |
| `ci` | a PR's workflow run failed | `ci-doctor` | `ci-context.md` | one CI comment per PR, edited in place; collapsed once the PR's head has no failed run |
| `issue` | an issue comment starting `redpanda …`, or the label on an issue (off by default: the Worker's `ISSUE_MODE`) | `responder` | `issue-context.md` | a reply comment |

`IGNORED_REPOS` (bruno's Worker config) suppresses only automatic work —
push-triggered reviews and CI diagnosis. Every explicit human action still works
there: the label, a `redpanda …` comment, a reply in one of our threads. PRs
over the size limits are skipped in review mode, on-demand included; thread,
question and ci runs are not size-gated.

Every context may carry two sections the prompts are written against:

- **Since the last review** (review mode) — the head sha we last reviewed, the
  current head, whether one is an ancestor of the other, `git log` between them
  and our open finding threads. The history is fetched into the checkout, so the
  agent chooses its own scope with `git diff LAST..HEAD`.
- **Repository guidance** — the maintainers' `AGENTS.md` (and `CLAUDE.md` when
  it is a different file) read from the **base** branch, never the PR head,
  capped at 16 KB each. It shapes what is worth flagging; it cannot change the
  task or the output. The PR's own copies stay renamed `*.from-pr`.

**The structure is enforced after the agent, not trusted from it.** Once pi
exits cleanly, `finalize-structured.js` (bruno `events-ingress`) replays the
session to `starflinger-openai` with one more user turn and a strict JSON
schema, which the engine enforces: `{summary, findings[]}` for review,
`{reply, resolve}` for thread, `{summary, failures[]}` for ci. That step may add
nothing the session did not establish, and keeps each finding's `title` and
`inline` as the agent's block set them. The reviewer's closing `json` block
stays in the prompt as the draft, and as the fallback: if pi failed, or
finalizing fails within what is left of the run's 15-minute budget, review mode
parses the last `json` block as before (`findings_source: text` in the outcome),
while thread and ci runs fail. The schemas live in that script, so **changing a
field means changing the prompt and the script together**, then moving the pin.

What a finding may cause is decided by code, not by that step alone:

- **Approval** (and the 👍) needs the structured findings empty **and** the
  agent's own `json` block present, valid and empty — a session cut off before
  its block never approves. Only a PR by an allowlisted author, an owner, an
  org member or a collaborator is approved — never a bot's.
- **Resolving a thread** needs our finding's thread to be outdated on GitHub
  (the code at it changed since) **and** the reply to say a later change
  addressed it. A finding that was wrong gets a reply and stays for a human.

## CI / deploy

There is **no build step** for an agent change, but a merge is **not** the
deploy. The events-ingress reviewer container fetches this repo at a **pinned
commit**, `AGENTS_REF` in bruno's `events-ingress/worker/wrangler.toml`, and
reads the package with `jq` (no `mc` binary in the container). A change goes
live when that pin moves, which is a Worker deploy of a few seconds. The pin
exists because the prompt and the container share the findings contract.

The [`validate`](.github/workflows/validate.yml) workflow (`scripts/validate.sh`)
is the gate that protects that live path: it runs on every PR and on every push
to `main`, asserting JSON validity, required fields, a real `thinking` level,
existing prompt files, and that each agent's toolset resolves. A malformed agent
fails the check before (PR) or as (main) it would otherwise go live.

## Open items (pre-contributor)

- [x] **PR/main validation gate** — `scripts/validate.sh` via GitHub Actions (jq-based; no `mc` binary needed).
- [x] **Provider wiring verified** — `pi` ignores `ANTHROPIC_BASE_URL`; routing to the LiteLLM gateway (`ai.starflinger.eu`) is done with `provider: local-llm` + `base_url` + `api_key_env`, materialised into pi's `models.json`. The live container does exactly this.
- [x] **Container wired to this repo** — the events-ingress container fetches `ethpandaops/agents` at the pinned `AGENTS_REF` and consumes the mc-format package via `jq` (deliberately not the `mc` binary, to avoid a Zig-0.16 build in Docker).
- [ ] **Publish an `mc` binary** — `mc` is Zig source (requires Zig 0.16) at [qu0b/mc](https://github.com/qu0b/mc); a built `linux/amd64` binary would let local authors use `mc run reviewer --dry-run`. Not on the deploy critical path.
