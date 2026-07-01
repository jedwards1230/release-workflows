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
| `chart_path` | string | no | `""` | Path to `Chart.yaml` to bump (committed into tag only) |
| `release_branch` | string | no | `main` | Branch to release from |
| `dry_run` | boolean | no | `false` | Preview without tagging or releasing |
| `create_release` | boolean | no | `false` | Create the GitHub Release directly |
| `latest` | boolean | no | `true` | Mark as "latest" (only when `create_release: true`) |

**Secrets:**

| Secret | Required | Notes |
|---|---|---|
| `ANTHROPIC_API_KEY` | no | AI notes (Haiku for patch, Sonnet for minor/major). Falls back to GitHub's native `generate-notes`, then a minimal commit-list body. |

**Outputs:**

| Output | Notes |
|---|---|
| `tag` | e.g. `v1.2.3` |
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
the prompt so the agent reviews from context instead of re-querying.

The verdict is delivered by `track_progress`'s live comment. As a safety net, a
final `Ensure review verdict reached the PR` step posts the agent's result text
as a comment **only if** it isn't already on the PR — recovering the case (seen
on clean-pass re-reviews) where the progress comment is left as a placeholder
and a passing review would otherwise leave no visible output. It's idempotent
(no double-post when the progress comment worked) and never fails the job.

**Failure surfacing.** `claude-code-action` exits 0 even when the agent run
itself errored — a `401` (bad/rotated `ANTHROPIC_API_KEY`), `429` rate limit, or
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
per repo with `review_drafts: true`) and **Dependabot** PRs (`github.actor ==
'dependabot[bot]'`, not configurable) — dependency bumps and WIP iteration are
low-signal for AI review. A job-level skip reports the check as `skipped`,
which GitHub counts as passing, so it never blocks merge. Other bot actors are
governed by `allowed_bots` (default `github-actions`), passed into
claude-code-action.

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

**Secrets:**

| Secret | Required |
|---|---|
| `ANTHROPIC_API_KEY` | yes |

**Optional inputs:**

| Input | Default | Notes |
|---|---|---|
| `focus` | `""` | Repo-specific guidance appended under `### Focus` |
| `extra_plugins` | `""` | Newline-separated `name@marketplace` entries |
| `extra_plugin_marketplaces` | `""` | Newline-separated marketplace git URLs |
| `extra_allowed_tools` | `""` | Comma-separated extra tools appended to the default set |
| `model` | `claude-haiku-4-5` | Model override |
| `max_turns` | `50` | Max agent turns |
| `allowed_bots` | `github-actions` | Bot actors allowed to trigger review |
| `draft_on_blocking` | `false` | When on, a review that posts blocking inline comments flips the PR to draft (`gh pr ready --undo`), pausing auto-reviews until the author resolves threads and marks it ready. Batches re-reviews on churn-heavy PRs into author-controlled cycles. Opt in per repo (e.g. private repos). |
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
      ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
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
  use **floating aliases** (`claude-haiku-4-5`, `claude-sonnet-4-6`) to match the
  PR-review default and avoid pinning a snapshot that goes stale. Trade-off:
  model *capability* can shift over time, so re-running a release on a later date
  may word the notes differently. Notes were never byte-reproducible anyway (the
  diff/commits differ per run, no `temperature: 0`); a consumer that needs a
  frozen toolchain should pin an immutable `@vX.Y.Z` of this workflow rather than
  `@v1`.
