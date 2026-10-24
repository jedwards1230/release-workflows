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
Only the trivial class (docs, comments, plain config-value edits, dependency
bumps) skips both; permissions, secrets, auth and conditions never count as
trivial. Repos with a matching quality plugin should pass it via `extra_plugins`
(e.g. `go-quality@jedwards1230-plugins`) so both the skill and its reviewer
agent are available at review time.

**Delegation is foreground, and the review must finish before the turn ends.**
The prompt tells the lead to set `run_in_background: false` on every Task call
(all in one message so they run in parallel), wait for every agent to return
before writing the verdict, and never end its turn, or write a "will post once
the reviewer reports back" message, while one is outstanding. The run is
headless, so it ends when the lead ends its turn and an agent still working is
killed with it. Without the instruction the Agent tool starts a subagent in the
background (seen on a caller's review in October 2026): the lead said it would
post once the reviewer reported back, ended its turn, and the PR was left with
the placeholder. The prompt is backed by `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1`
(documented in Claude Code's env-vars reference), which removes
`run_in_background` from the subagent tool and stops subagents being moved to
the background. It is set through the action's `settings` input (`env` key),
not step env, and is always on: `settings` is one JSON input, so the Run step
falls back to a literal JSON when the telemetry route emitted none, and the
route step's JSON carries the key too. The prompt is the
primary control and the env var is belt and braces; neither could be exercised
end to end outside Actions, so the safety net below is what catches a lead that
backgrounds anyway.

**The agent writes the verdict; the action does not.** `claude-code-action`
never posts the agent's final chat message. `track_progress` creates a
placeholder comment up front ("I'll analyze this and get back to you."), and
the comment only gets the summary when the agent calls
`mcp__github_comment__update_claude_comment` with it as the whole body (the
prompt tells it to, after its inline comments and after every delegated agent
has returned). When the run ends the action prepends
`**Claude finished @user's task in Ns** —— [View job](run URL)`, a blank line
and `---` to whatever body is there, whether or not the agent ever wrote one, so
a placeholder reads as a finished review.

**The safety net looks for the verdict, not the header.** A final `Ensure review
verdict reached the PR` step treats the verdict as delivered only if this run
attempt's bot comment (one created since the review step started; the run URL
carries no attempt number, so a re-run must not inherit an earlier attempt's
verdict) has, after the one-line header and its `---` line, the `###` verdict
heading (🔴 / 🟡 / 🟢) the prompt mandates, outside code fences and `<details>`
blocks (the same view the backstop classifies on). A body that is still the
placeholder, or only an interim checklist, has none. Otherwise it posts the agent's result
text as a comment, recovering the case where the progress comment never got a
verdict. It does not key on the "Claude finished" header, which the action adds
even over a placeholder, and it does not compare against the placeholder text, so
a reworded placeholder is caught too. The backstop and `Assess review
completeness` key on the same heading. Any other layout or summary format reads
as "not delivered", so drift costs a cosmetic double-post, never a suppressed
verdict. It is idempotent and never fails the job.

**An unfinished review is reported, not recovered.** A new `Assess review
completeness` step marks a run incomplete when the result message's
`subagent_stats` shows delegated agents that never reported back
(`spawned > completed + failed`, missing fields count as 0; a `failed` agent
reported back, a `killed` one did not), or when an agent was started in the
background (`started_in_background > 0`) and the lead never wrote a `###`
verdict heading (the agent can finish just after the lead exits, so the counts
alone read as balanced). For an incomplete run the safety net does not post the
lead's result text, which is only "waiting on the reviewer". It posts one
notice per run attempt, marked `<!-- claude-review-incomplete run=… attempt=…
-->`: "Review incomplete: N delegated agent(s) had not finished when the lead
agent exited — re-run the review." The request-changes backstop never dismisses
on a clear verdict from an incomplete review, since the missing agent may be the
one that would have found the blocker. `is_error` takes precedence over all of
this.

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
visible (rebase the PR onto the default branch to get a review). The same step
also fails the job, with an `::error title=Claude review incomplete` annotation
and a step-summary block, when `Assess review completeness` flagged the run
incomplete (see above): `is_error` is false there, so without this a review the
lead abandoned mid-delegation would stay green.

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

**Blocking reviews.** Two independent inputs act on the same signal. The agent
decides, after posting its inline comments and before writing the summary,
whether the review found a BLOCKING issue (a correctness bug, a security or
data-integrity flaw, a broken build/interface, or clearly wrong behavior,
raised as an inline comment; never nits, style, or "consider" suggestions) and
leads its `###` verdict heading with 🔴 if and only if it did. A blocking issue
from an earlier round that is still unaddressed counts too: the agent does not
re-post the comment but still leads with 🔴.

- `request_changes_on_blocking` (**default on**): on a blocking verdict the agent
  submits a formal `REQUEST_CHANGES` review, authored by the Claude app
  (`claude[bot]`). It cannot do that with `gh pr review`, which stays on the deny
  floor: a plain allow would also let a prompt-injected PR run `--approve`, and
  prefix/glob rules are bypassable (body text containing `--request-changes`,
  quote-splitting). Instead the compose step generates
  `$RUNNER_TEMP/bin/claude-request-changes`, with the repo and PR number baked in
  from workflow contexts, and grants the agent only `Bash(<that absolute
  path>:*)`. The wrapper reads the review body from stdin, refuses an empty
  body, appends the marker `<!-- claude-review-request-changes -->`, rejects
  every argument (so no `--approve`, `--comment`, or other PR), and runs exactly
  `gh pr review <pr> --repo <repo> --request-changes --body-file -`. The deny
  floor is byte-identical in every flag combination.
- `draft_on_blocking` (default off, opt-in): the agent also runs
  `gh pr ready N --undo`, which is the only reason `Bash(gh pr ready:*)` is
  granted, and only when this input is on. With both on, the request for changes
  is submitted first and drafting is the final action.

**The backstop step.** `Request-changes backstop`, after `Ensure review verdict
reached the PR`, is the deterministic net under the agent and the only thing
that dismisses. It reads the verdict from the execution output: the last
main-thread `update_claude_comment` call whose body has a `###` verdict heading
(the run's final `result` text is only a prose recap, so it is a fallback). A
heading that starts with 🔴 is blocking and one that starts with 🟡 or 🟢 is
clear; a 🔴 in prose or a table, or a heading quoted inside a code fence or a
`<details>` block, never counts. Our reviews are identified by author
(`claude[bot]` from the agent's wrapper, or `github-actions[bot]` from this
step) + `CHANGES_REQUESTED` + the body marker. A blocking verdict with one of
ours outstanding changes nothing; with none outstanding (the agent forgot, or
the wrapper failed) the step submits one itself as `github-actions[bot]`. A
clear verdict dismisses every one of ours, unless the run is incomplete
(`Assess review completeness`): a verdict written while a delegated agent was
still outstanding dismisses nothing. No verdict heading (an errored, cancelled,
docs-only-skipped, or unfinished run) changes nothing. The step is
best-effort: an API failure (a fork PR with a read-only token, a PR authored by
the same account, a dismissal restriction) is a `::warning::` and a job-summary
line, never a red check. It needs no permission beyond the
`pull-requests: write` the job already holds.

How the two interact: without drafting (the default) every push re-reviews, so
the run count is higher but a request for changes clears itself on the next
review that finds no blocking issue. With `draft_on_blocking` on, a blocking
review drafts the PR, and draft PRs are skipped, so the review that clears the
request only runs after the author marks the PR ready for review. A docs-only
skip, an errored or unfinished review, and a cancelled run all leave an
existing request in place until the next completed review (the step dismisses
only on a positive 🟡/🟢 verdict, never on silence). `draft_on_blocking`
defaulted to on before request-changes became the default; callers that set it
explicitly keep drafting until they change it (at the time of the flip: Agmente,
anyctl, dredge, earmark, gpu-arbiter, homelab-ansible, homelab-k8s and scrim).

Caveat: this repo's ruleset has `required_approving_review_count: 0`, so a
`CHANGES_REQUESTED` review is expected to be advisory rather than merge-blocking
wherever approvals are not required. Verify on rollout before relying on it as
a gate. Callers opt out with `request_changes_on_blocking: false`.

**Required permissions on the caller:** `contents: read`, `actions: read`,
`pull-requests: write`, `id-token: write`

**Secrets** (at least one required — checked at runtime, not startup):

| Secret | Required | Notes |
|---|---|---|
| `CLAUDE_CODE_OAUTH_TOKEN` | one of the two | **Preferred.** Claude subscription OAuth token (`claude setup-token`, Pro/Max/Team plan) — reviews bill to the subscription instead of the metered API. ~1-year lifetime, **no auto-refresh**: a 401-failed review usually means it expired (regenerate + update the secret). |
| `ANTHROPIC_API_KEY` | one of the two | Fallback, used only when the OAuth token is absent (metered pay-per-token billing). |
| `LITELLM_CI_KEY` | no | LiteLLM virtual key — enables the gateway route below. |
| `LENS_TRACING_KEY` | no | LiteLLM Lens upload-only tracing key — enables telemetry below. |
| `TS_OAUTH_CLIENT_ID` | no | Tailscale federated-identity client ID (required for either half below) |
| `TS_AUDIENCE` | no | Tailscale federated-identity audience (required for either half below) |
| `LITELLM_CI_BASE_URL` | no | LiteLLM `/anthropic` pass-through URL on the tailnet, e.g. `https://<host>.<tailnet>.ts.net/anthropic` |
| `LENS_CI_OTLP_ENDPOINT` | no | Lens OTLP ingest base URL (no `/v1/...` suffix), e.g. `https://<host>.<tailnet>.ts.net/lens-ingest` |

**LiteLLM gateway + Lens telemetry (optional, best-effort).** On by default
whenever the caller passes the config; otherwise skipped silently (forks,
repos not opted in, callers outside the `jedwards1230` owner). The workflow joins a Tailscale tailnet via GitHub OIDC
workload identity (`tailscale/github-action`, `tags: tag:ci-llm`, no stored
Tailscale credential), probes each endpoint with a 10s timeout (the gateway probe
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
- **All six values are secrets, so they stay out of public logs.** The
  Tailscale client ID and audience and the two endpoint URLs are configuration,
  not credentials, but they are secrets rather than repo variables: `vars.*`
  print unmasked in run logs, and a public caller repo's logs are public. The
  runner masks each exact string, which also covers every URL built on top of
  one. Before the tailnet join, a `Mask gateway / telemetry hostnames` step
  masks two forms the exact-string masks miss, the bare hostname and the
  `<tailnet>.ts.net` domain, since a failed join or connection can print either
  in its stderr. The join runs with `log-mode: quiet`, so even a debug re-run
  doesn't echo `tailscale status --json`, which lists bare node labels that no
  mask covers. Masks are per job, so a new job that uses these secrets needs
  the same step.

All six must be passed explicitly (or via `secrets: inherit`) like the
Anthropic ones. Earlier releases read the four non-key values from caller repo
variables; this one reads only the secrets. A caller with the four still set as
variables (and not passed as secrets) reviews direct to Anthropic with no
telemetry, the same as an unconfigured caller. Mapping the four secrets against
a pin older than the release that declares them fails workflow validation
(`Invalid secret ... is not defined in the referenced workflow`), so re-pin in
the same change.

**Optional inputs:**

| Input | Default | Notes |
|---|---|---|
| `focus` | `""` | Repo-specific guidance appended under `### Focus` |
| `extra_plugins` | `""` | Newline-separated `name@marketplace` entries. Recommended: the repo's language-quality plugin(s), e.g. `go-quality@jedwards1230-plugins` |
| `extra_plugin_marketplaces` | `""` | Newline-separated marketplace git URLs |
| `extra_allowed_tools` | `""` | Comma-separated extra tools appended to the default set. The `permission_mode` deny floor wins over these in every mode; an entry it fully or partly overrides (e.g. `Edit(src/*)`, `Bash(gh:*)`) draws a warning annotation |
| `model` | `claude-haiku-5-5` | Model override |
| `max_turns` | `50` | Max agent turns |
| `permission_mode` | `""` | `""` = allowlist only (other tool calls silently denied). `auto` = Claude Code auto mode: non-allowlisted calls go to the safety classifier (extra model call, default Sonnet 5 — must be routable through LiteLLM) instead of being denied, so the agent can run read-only verification. A fixed deny list (Edit/Write, push/commit, `gh pr merge/close/review`, `gh api`, curl/wget/nc, WebFetch) applies in every mode; the one narrow grant on top is the generated `claude-request-changes` wrapper when `request_changes_on_blocking` is on (see **Blocking reviews**). `bypassPermissions` is rejected. |
| `allowed_bots` | `github-actions` | Bot actors allowed to trigger review |
| `draft_on_blocking` | `false` | OFF by default (opt-in; it was on before request-changes became the default). A review that posts blocking inline comments flips the PR to draft (`gh pr ready --undo`), pausing auto-reviews until the author resolves threads and marks it ready. Batches re-reviews on churn-heavy PRs into author-controlled cycles, lowering run count and cost. Left off, every push re-reviews (more runs), but a request-changes review clears itself on the next clean review. |
| `request_changes_on_blocking` | `true` | ON by default. A review that posts blocking inline comments (same bar as `draft_on_blocking`) gets a formal GitHub `REQUEST_CHANGES` review, authored by `claude[bot]`, and a later review with no blocking issue dismisses it. The agent submits it through a generated no-argument wrapper (it never gets raw `gh pr review`, which would also allow `--approve`); a workflow step is the backstop that submits if the agent did not and does the dismissing. Independent of `draft_on_blocking`; see **Blocking reviews** above. Opt out with `false`. |
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
      # optional: LiteLLM gateway + Lens telemetry
      LITELLM_CI_KEY: ${{ secrets.LITELLM_CI_KEY }}
      LENS_TRACING_KEY: ${{ secrets.LENS_TRACING_KEY }}
      TS_OAUTH_CLIENT_ID: ${{ secrets.TS_OAUTH_CLIENT_ID }}
      TS_AUDIENCE: ${{ secrets.TS_AUDIENCE }}
      LITELLM_CI_BASE_URL: ${{ secrets.LITELLM_CI_BASE_URL }}
      LENS_CI_OTLP_ENDPOINT: ${{ secrets.LENS_CI_OTLP_ENDPOINT }}
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
"Claude finished" / "encountered an error" state. It uses the review's existing
`pull-requests: write` token (expected to suffice for editing another author's
PR comment, not yet confirmed by a live run; a refused PATCH only logs `WARN`).
This canceller stays `actions: write` only.

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
- Commits and diff sent to the AI come from the release branch's mainline
  (`git log --first-parent`): one entry per PR whether it landed as a merge
  commit or a squash, and nothing from inside feature branches. Direct pushes
  to `main` are included. The job log prints commit, file and diff-byte counts,
  then `Response model:` (the model the API reports, not the requested alias)
  and token counts.
- The notes prompt states the bump type and forbids claims the input doesn't
  support, including a Breaking Changes section without a visible break.
- Model selection: Haiku for patch (fast/cheap), Sonnet for minor/major. Both
  use undated model IDs (`claude-haiku-5-5`, `claude-sonnet-4-6`) to match the
  PR-review default; Sonnet's is a **floating alias**, while Haiku 5.5's ID is
  itself fixed (no dated snapshot/alias split). Trade-off:
  model *capability* can shift over time, so re-running a release on a later date
  may word the notes differently. Notes were never byte-reproducible anyway (the
  diff/commits differ per run, no `temperature: 0`); a consumer that needs a
  frozen toolchain should pin an immutable `@vX.Y.Z` of this workflow rather than
  `@v1`.
