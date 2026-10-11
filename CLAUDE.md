# release-workflows

@CONTRIBUTING.md

Reusable GitHub Actions workflows for automated release management.
Published by `jedwards1230` and consumed by repos that pin `@v1`.

## Repo at a glance

```
.github/workflows/
├── ai-release.yml           # Primary reusable: version + tag + AI release notes
├── claude-pr-review.yml     # Reusable: AI PR review via claude-code-action@v1
├── claude-pr-review-cancel.yml  # Reusable: cancel an in-flight review when its PR merges/closes
├── claude-pr-review-caller.yml  # This repo's own PR review (calls claude-pr-review.yml@v1 + cancel)
└── release.yml              # This repo's own release (calls ai-release.yml, moves @v0 tag)
```

## Workflows

### `ai-release.yml` — AI Release

Full release pipeline: computes the next semver, optionally bumps a Helm
`Chart.yaml` into the tagged commit (not pushed to `main`), assembles
AI-generated release notes, and either creates the GitHub Release directly
or returns a base64-encoded body for the caller to chain build/publish jobs.

**Required permissions on the caller:** `contents: write`, `pull-requests: read`

**Inputs (all `workflow_call`):**

| Input | Type | Required | Default | Notes |
|---|---|---|---|---|
| `service_name` | string | yes | — | Short ID used in commit messages |
| `service_description` | string | no | `""` | One-liner for the AI prompt |
| `bump_type` | string | yes | — | `patch`, `minor`, or `major` |
| `version_override` | string | no | `""` | Explicit `X.Y.Z`; overrides `bump_type` |
| `tag_prefix` | string | no | `""` | Prefix before the `v` (e.g. `host-` → `host-v1.2.3`). Scopes both the previous-version lookup and the created tag, so a monorepo can release several artifacts on independent version lines. Empty = plain `vX.Y.Z`. |
| `chart_path` | string | no | `""` | Path to `Chart.yaml` to bump (committed into tag only) |
| `release_branch` | string | no | `main` | Branch to release from |
| `dry_run` | boolean | no | `false` | Preview without tagging or releasing |
| `create_release` | boolean | no | `false` | Create the GitHub Release directly |
| `latest` | boolean | no | `true` | Mark as "latest" (only when `create_release: true`) |

**Secrets:**

| Secret | Required | Notes |
|---|---|---|
| `ANTHROPIC_API_KEY` | no | AI notes (Haiku for patch, Sonnet for minor/major). Falls back to GitHub's native `generate-notes`, then a minimal commit-list body. Subscription OAuth tokens (`CLAUDE_CODE_OAUTH_TOKEN`) are **not** used here — the workflow's Messages API call authenticates via the `x-api-key` header, which rejects them (401). They do work as `Authorization: Bearer` against the same endpoint (verified 2026-07), but that path is undocumented and subscription OAuth is policy-scoped to Anthropic's official tools — so the supported route to subscription billing is reworking this workflow onto the Claude CLI (`claude -p`). |

**Outputs:**

| Output | Notes |
|---|---|
| `tag` | e.g. `v1.2.3`, or `host-v1.2.3` when `tag_prefix` is set |
| `version` | e.g. `1.2.3` |
| `prev_tag` | Previous semver tag (or root commit) |
| `changelog_ref` | Diff baseline (cumulative for minor/major) |
| `bump_type` | Resolved bump type |
| `release_body` | **Base64-encoded** markdown. Decode before use: `echo "$body" | base64 -d > body.md` |

**Calling patterns:**

```yaml
# One-shot: release created inline
jobs:
  release:
    uses: jedwards1230/release-workflows/.github/workflows/ai-release.yml@v1
    with:
      service_name: my-tool
      bump_type: ${{ inputs.bump_type }}
      create_release: true
    secrets:
      ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
```

```yaml
# Build-chain: tag first, build artifacts, then publish release
jobs:
  prepare:
    uses: jedwards1230/release-workflows/.github/workflows/ai-release.yml@v1
    with:
      service_name: my-app
      bump_type: ${{ inputs.bump_type }}
    secrets:
      ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}

  build:
    needs: prepare
    uses: ./.github/workflows/build.yml
    with:
      ref: ${{ needs.prepare.outputs.tag }}

  release:
    needs: [prepare, build]
    runs-on: ubuntu-latest
    permissions: { contents: write }
    steps:
      - run: echo "${{ needs.prepare.outputs.release_body }}" | base64 -d > body.md
      - uses: softprops/action-gh-release@v3
        with:
          tag_name: ${{ needs.prepare.outputs.tag }}
          body_path: body.md
```

---

### `claude-pr-review.yml` — Claude PR Review

Runs `anthropics/claude-code-action@v1` in Haiku PR-review mode. Bakes in the
`review-team@jedwards1230-plugins` plugin and a read-only tool set; all inputs
are **additive** (they append to the defaults, not replace them).

Frontloads the PR diff, changed-file list, and prior-round bot comments into
the prompt so the agent reviews from context instead of re-querying. The diff
is annotated with new-file line numbers so the reviewer can anchor inline
comments directly, and the prompt's output contract requires every actionable
finding to be posted as an inline comment (the merge-blocking channel) rather
than listed in the summary.

**The summary is ranked, not flat.** A one-line `### <emoji> <verdict>` heading
(🔴 blocking issue · 🟡 changes recommended · 🟢 no actionable problems) plus at
most two sentences stay
visible; everything else goes into **separate labeled `<details>` blocks**, one
topic each, from a preferred set (`What I checked`, `Verified clean`,
`Architectural notes`, `Cross-cutting risk`, `Non-issues considered`, `Review
approach`). Two to four is the normal range, five the ceiling, and none at all
is correct when there's nothing to say — a clean review whose whole summary is
one verdict line is a good review. One grab-bag block defeats the purpose: the
`<summary>` label is what lets a reader expand only the part they want.
`<details>` is for context only — collapsing a real finding is treated as the
same mistake as leaving it in prose, since both are invisible to the merge
gate.

**Skill-first review depth, per part of the diff.** The agent first lists the
skills and agents available to it and splits the diff by language/domain.
Parts a domain skill covers (e.g. a language-quality plugin's review
checklist) it reviews inline with that skill loaded. Parts **no** domain skill
covers it delegates to the best-fitting agent (Task tool), even on a small diff
and even when another part is covered: with no matching skill the reviewer
works from general knowledge, and the failure mode is a confident wrong claim
about a half-known API, not silence. The always-installed generic
`review-team:review-team` skill does not count as domain coverage. Covered
parts are delegated too for large diffs (~300+ changed lines), several
dimensions needing real scrutiny, or high-stakes surfaces
(security/auth/data-integrity/destructive infra). Capped at 3 agents,
preferring a skill-preloaded language-quality reviewer over a generic one.
Only the trivial class (docs, comments, config values, dependency bumps) skips
both. Repos with a matching quality plugin should pass it via `extra_plugins`
(e.g. `go-quality@jedwards1230-plugins`) so both the skill and its reviewer
agent are available at review time.

The verdict is delivered by `track_progress`'s live comment. As a safety net, a
final `Ensure review verdict reached the PR` step posts the agent's result text
as a comment **only if** it isn't already on the PR — recovering the case (seen
on clean-pass re-reviews) where the progress comment is left as a placeholder
and a passing review would otherwise leave no visible output. It's idempotent
(no double-post when the progress comment worked) and never fails the job.

**Failure surfacing.** `claude-code-action` exits 0 even when the agent run
itself errored — a `401` (expired `CLAUDE_CODE_OAUTH_TOKEN` or bad/rotated
`ANTHROPIC_API_KEY`), `429` rate limit, or
`529` Anthropic overload all come back as `is_error: true` in the result JSON
while the step stays green, so a broken review looks identical to a clean pass. A
final `Fail if the review did not complete` step converts that into a real
**red check**: it reads the execution-output JSON and fails the job when
`is_error: true` (annotating the `api_error_status`/`subtype`). When there's *no*
execution output at all — the expected `claude-code-action` workflow-validation
skip (the PR's workflow file differs from the default branch, e.g. a PR that
edits the workflow or whose branch predates a workflow change on `main`) — it
does **not** fail, but emits a `::warning::` + summary note so the no-review is
visible (rebase the PR onto the default branch to get a review).

**Skipped by default.** The `review` job's `if:` skips **draft** PRs (opt out
per repo with `review_drafts: true`) and **Dependabot** PRs (not configurable)
— dependency bumps and WIP iteration are low-signal for AI review. Dependabot
is guarded two ways: `github.actor == 'dependabot[bot]'` catches the PR
Dependabot opens, and a `startsWith(github.event.pull_request.head.ref,
'dependabot/')` head-branch check catches later `synchronize` events on the
same branch whose actor is *not* dependabot (a user rebase or a github-actions
push) — those slipped past the actor-only check and cost 2–3 paid review rounds
per dependabot PR. A job-level skip reports the check as `skipped`, which GitHub
counts as passing, so it never blocks merge. Other bot actors are governed by
`allowed_bots` (default `github-actions`), passed into claude-code-action.

**Docs-only skip.** A `Detect docs-only diff` step also skips the actual
Claude call (`skip_docs_only: true` by default) when every changed file ends
in `.md` — a docs-only PR is low-signal for the multi-agent review-team
treatment and this avoids repeated full-cost re-reviews on doc-only PRs (e.g.
CONTRIBUTING/README rollouts). Set `skip_docs_only: false` to always review
docs changes too. Unlike the draft/Dependabot skip, this still runs the cheap
checkout + diff steps; the `Detect docs-only diff` step annotates the skip in
the job summary, and the later `Fail if the review did not complete` step
recognizes the same deliberate-skip condition and exits early — it does NOT
fall through to the generic "no execution output" warning path (that path is
reserved for the unexpected workflow-validation skip).

**Required permissions on the caller:** `contents: read`, `actions: read`,
`pull-requests: write`, `id-token: write`

**Secrets** (at least one required — checked at runtime, not startup):

| Secret | Required | Notes |
|---|---|---|
| `CLAUDE_CODE_OAUTH_TOKEN` | one of the two | **Preferred.** Claude subscription OAuth token (`claude setup-token`, Pro/Max/Team plan) — reviews bill to the subscription instead of the metered API. ~1-year lifetime, **no auto-refresh**: a 401-failed review usually means it expired (regenerate + update the secret). |
| `ANTHROPIC_API_KEY` | one of the two | Fallback, used only when the OAuth token is absent (metered pay-per-token billing). |
| `LITELLM_CI_KEY` | no | LiteLLM virtual key — enables the gateway route below. |
| `LENS_TRACING_KEY` | no | LiteLLM Lens upload-only tracing key — enables telemetry below. |

**LiteLLM gateway + Lens telemetry (optional, best-effort).** On by default
whenever the caller repo carries the config; otherwise skipped silently (forks,
repos not opted in, callers outside the `jedwards1230` owner). The workflow joins a Tailscale tailnet via GitHub OIDC
workload identity (`tailscale/github-action`, `tags: tag:ci-llm`, no stored
Tailscale secret), probes each endpoint with a 10s timeout (the gateway probe
also presents the LiteLLM key), and:

- **Gateway** (`LITELLM_CI_BASE_URL` + `LITELLM_CI_KEY`): routes the review's
  model calls through the LiteLLM `/anthropic` pass-through
  (`ANTHROPIC_BASE_URL`). The caller's own Anthropic credential passes through
  untouched; the LiteLLM key goes only in an `x-litellm-api-key: Bearer …`
  header (`ANTHROPIC_CUSTOM_HEADERS`).
- **Telemetry** (`LENS_CI_OTLP_ENDPOINT` + `LENS_TRACING_KEY`): Claude Code
  exports OTel **traces + logs with full content** (prompts, assistant
  responses, tool input/output) over OTLP `http/protobuf` to
  `<endpoint>/v1/traces` and `/v1/logs`, bearer-authenticated; metrics off.
  Resource attributes: `gen_ai.agent.name=claude-pr-review`, `vcs.owner.name`,
  `vcs.repository.name`, `vcs.change.id` (PR number),
  `cicd.pipeline.run.id`/`.attempt`.

The two halves gate independently. A failed tailnet join, an endpoint that
doesn't answer at the start of the run (no response or 5xx), or LiteLLM
rejecting the key falls back to direct Anthropic / no telemetry with a
`::notice::`, and the review still runs. If nothing routes, the runner leaves
the tailnet before the review. A gateway that fails *mid-review* still fails
the run, and that surfaces as the usual red `is_error` check. The job summary
records which route each review took. claude-code-action forwards only an
allowlist of env names to Claude, so the allowlisted ones (base URL, headers,
the common `OTEL_*`) are set as step env and the rest (traces exporter, content
flags, enhanced-telemetry beta) go through the action's `settings` input; no
secret is in the settings JSON.

The tailnet join **must** stay in this reusable file. The Tailscale federated
identity trusts only OIDC tokens with `sub = repo:jedwards1230/*` (the caller
repo) **and** `job_workflow_ref = jedwards1230/release-workflows/.github/workflows/*`.
So a caller's own workflow (or a composite action) cannot join, and neither can
a third-party repo calling this reusable. Callers reach the gateway only through
a release-workflows reusable.

Two things to know before opting a repo in:

- **The model credential transits LiteLLM.** The caller's
  `CLAUDE_CODE_OAUTH_TOKEN` / `ANTHROPIC_API_KEY` is forwarded through the
  pass-through. LiteLLM's logging must not record forwarded auth headers.
- **The vars show up in Actions logs.** `vars.*` are not masked, so a public
  caller repo's logs show the tailnet hostnames and the Tailscale client ID and
  audience. None of them is usable without a matching OIDC token or tailnet
  membership. The two keys are secrets and stay masked.

| Caller repo variable (`vars.*`) | Notes |
|---|---|
| `TS_OAUTH_CLIENT_ID` | Tailscale federated-identity client ID (required for either half) |
| `TS_AUDIENCE` | Tailscale federated-identity audience (required for either half) |
| `LITELLM_CI_BASE_URL` | LiteLLM `/anthropic` pass-through URL on the tailnet, e.g. `https://<host>.<tailnet>.ts.net/anthropic` |
| `LENS_CI_OTLP_ENDPOINT` | Lens OTLP ingest base URL (no `/v1/...` suffix), e.g. `https://<host>.<tailnet>.ts.net/lens-ingest` |

Variables resolve from the calling repo. The two secrets must be passed
explicitly (or via `secrets: inherit`) like the Anthropic ones.

**Optional inputs:**

| Input | Default | Notes |
|---|---|---|
| `focus` | `""` | Repo-specific guidance appended under `### Focus` |
| `extra_plugins` | `""` | Newline-separated `name@marketplace` entries. Recommended: the repo's language-quality plugin(s), e.g. `go-quality@jedwards1230-plugins` |
| `extra_plugin_marketplaces` | `""` | Newline-separated marketplace git URLs |
| `extra_allowed_tools` | `""` | Comma-separated extra tools appended to the default set |
| `model` | `claude-haiku-5-5` | Model override |
| `max_turns` | `50` | Max agent turns |
| `allowed_bots` | `github-actions` | Bot actors allowed to trigger review |
| `draft_on_blocking` | `true` | ON by default. A review that posts blocking inline comments flips the PR to draft (`gh pr ready --undo`), pausing auto-reviews until the author resolves threads and marks it ready. Batches re-reviews on churn-heavy PRs into author-controlled cycles — the main run-count/cost reducer. Opt out with `draft_on_blocking: false` where bot-initiated drafting is unwanted. |
| `review_drafts` | `false` | When true, disables the default draft-PR skip so draft PRs get reviewed too. |
| `skip_docs_only` | `true` | When true (default), skip review when every changed file is markdown. Set false to always review docs changes. |

**Minimal caller:**

```yaml
on:
  pull_request:
    types: [opened, synchronize, ready_for_review, reopened]

permissions:
  contents: read
  actions: read
  pull-requests: write
  id-token: write

jobs:
  review:
    uses: jedwards1230/release-workflows/.github/workflows/claude-pr-review.yml@v1
    secrets:
      CLAUDE_CODE_OAUTH_TOKEN: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }} # preferred (subscription)
      ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }} # fallback (metered API)
      LITELLM_CI_KEY: ${{ secrets.LITELLM_CI_KEY }} # optional: LiteLLM gateway
      LENS_TRACING_KEY: ${{ secrets.LENS_TRACING_KEY }} # optional: Lens telemetry
```

---

### `claude-pr-review-cancel.yml` — Claude PR Review Cancel

Cancels an in-flight `claude-pr-review.yml` run when its PR is **merged or
closed**. Needed because the review workflow only triggers on
opened/synchronize/ready_for_review/reopened, and its `concurrency:
cancel-in-progress` only supersedes a run on a re-push — a **merge** fires
`pull_request: closed`, which nothing listens to, so an in-flight review would
otherwise run to completion, burn tokens, and post comments onto an
already-merged PR. (GitHub does not auto-cancel runs on merge.)

A reusable workflow cannot self-trigger on `closed` (it only runs via
`workflow_call`), so the `closed` trigger lives in the **caller**; this reusable
holds the cancel logic. It finds in-progress/queued runs of the review workflow
for the PR's head branch and cancels them (excluding its own run).

A cancelled review (from this workflow, or superseded by a re-push through the
concurrency group) rewrites its own unfinished `track_progress` checklist
comment to a one-line "Review cancelled" note in a `cancelled()` step of
`claude-pr-review.yml`, so the PR is not left showing a review in progress.
claude-code-action exposes no comment id, so the step matches `claude[bot]`
comments created after its review step started that never reached the
"Claude finished" / "encountered an error" state. It needs no permission beyond
the review's existing `pull-requests: write`; this canceller stays `actions:
write` only.

**Required permissions on the calling job:** `actions: write`

**Optional inputs:**

| Input | Default | Notes |
|---|---|---|
| `review_workflow` | `Claude PR Review` | Display name of the review workflow whose runs to cancel — override if your caller workflow is named differently. |

**Caller wiring** — add `closed` to the review caller's triggers and a guarded job:

```yaml
on:
  pull_request:
    types: [opened, synchronize, ready_for_review, reopened, closed]

jobs:
  review:
    if: github.event.action != 'closed'
    uses: jedwards1230/release-workflows/.github/workflows/claude-pr-review.yml@v1
    secrets:
      CLAUDE_CODE_OAUTH_TOKEN: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
      ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}

  cancel-review:
    if: github.event.action == 'closed'
    permissions:
      actions: write
    uses: jedwards1230/release-workflows/.github/workflows/claude-pr-review-cancel.yml@v1
```

> The `if:` guards keep the review off `closed` events and the canceller off the
> review events. This repo's own `claude-pr-review-caller.yml` dogfoods it via a
> local-path call (`./.github/workflows/claude-pr-review-cancel.yml`).

---

## Version pinning and moving tags

This repo publishes **immutable** `vX.Y.Z` tags plus **moving** major/minor
tags (`v1`, `v1.2`). Consumers pin the moving tag:

```yaml
uses: jedwards1230/release-workflows/.github/workflows/ai-release.yml@v1
```

The moving tags are updated by `release.yml`'s `moving-tags` job after each
release via force-push. `ai-release.yml` itself only creates immutable tags.

Current stable: `@v1` (v1.x.x line). `@v0` is frozen.

## Conventions

- All workflows include a `$GITHUB_STEP_SUMMARY` block.
- `release_body` output is always base64-encoded (survives GitHub Actions job
  output character restrictions).
- Chart bumps go into the tagged commit only — never pushed back to `main`.
- Minor/major releases use a **cumulative diff** from the previous `X.Y.0` /
  `X.0.0` baseline so AI notes summarize the full release arc.
- Diff sent to the AI is scoped to files touched by merge commits; direct
  pushes to `main` are excluded. On squash-merge repos (no merge commits in the
  range) it falls back to first-parent non-merge commits, so squashed PRs still
  get AI notes — the AI step only truly skips when the range is genuinely empty.
- Model selection: Haiku for patch (fast/cheap), Sonnet for minor/major. Both
  use undated model IDs (`claude-haiku-5-5`, `claude-sonnet-4-6`) to match the
  PR-review default; Sonnet's is a **floating alias**, while Haiku 5.5's ID is
  itself fixed (no dated snapshot/alias split). Trade-off:
  model *capability* can shift over time, so re-running a release on a later date
  may word the notes differently. Notes were never byte-reproducible anyway (the
  diff/commits differ per run, no `temperature: 0`); a consumer that needs a
  frozen toolchain should pin an immutable `@vX.Y.Z` of this workflow rather than
  `@v1`.
