# release-workflows

Reusable GitHub Actions workflows for automated release management.
Published by `jedwards1230` and consumed by repos that pin `@v1`.

## Repo at a glance

```
.github/workflows/
├── ai-release.yml           # Primary reusable: version + tag + AI release notes
├── claude-pr-review.yml     # Reusable: AI PR review via claude-code-action@v1
├── claude-pr-review-caller.yml  # This repo's own PR review (calls claude-pr-review.yml@v1)
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

## Version pinning and moving tags

This repo publishes **immutable** `vX.Y.Z` tags plus **moving** major/minor
tags (`v1`, `v1.2`). Consumers pin the moving tag:

```yaml
uses: jedwards1230/release-workflows/.github/workflows/ai-release.yml@v1
```

The moving tags are updated by `release.yml`'s `moving-tags` job after each
release via force-push. `ai-release.yml` itself only creates immutable tags.

Current stable: `@v1` (v1.x.x line). `@v0` is frozen.

## Releasing this repo

Manual dispatch only (`workflow_dispatch` on `release.yml`). Choose `version_type`
or supply `custom_version`. The workflow calls `ai-release.yml` then moves the
`v0` / `v0.x` moving tags. No `semver:*` label needed (this repo is its own
release gate).

## Conventions

- All workflows include a `$GITHUB_STEP_SUMMARY` block.
- `release_body` output is always base64-encoded (survives GitHub Actions job
  output character restrictions).
- Chart bumps go into the tagged commit only — never pushed back to `main`.
- Minor/major releases use a **cumulative diff** from the previous `X.Y.0` /
  `X.0.0` baseline so AI notes summarize the full release arc.
- Diff sent to the AI is scoped to files touched by merge commits; direct
  pushes to `main` are excluded.
- Model selection: Haiku for patch (fast/cheap), Sonnet for minor/major. Both
  use **floating aliases** (`claude-haiku-4-5`, `claude-sonnet-4-6`) to match the
  PR-review default and avoid pinning a snapshot that goes stale. Trade-off:
  model *capability* can shift over time, so re-running a release on a later date
  may word the notes differently. Notes were never byte-reproducible anyway (the
  diff/commits differ per run, no `temperature: 0`); a consumer that needs a
  frozen toolchain should pin an immutable `@vX.Y.Z` of this workflow rather than
  `@v1`.
