# Contributing to release-workflows

Reusable GitHub Actions workflows for automated release management with semantic versioning, AI-generated release notes, and GitHub Releases. All changes go through the workflow below.

## Prerequisites

- [pre-commit](https://pre-commit.com/) for local git hooks
- [actionlint](https://github.com/rhysd/actionlint) for workflow linting (optional but recommended)

## Build, test & lint

This repo contains GitHub Actions workflow files only. Run these locally before opening a PR:

```bash
# Validate YAML syntax, whitespace, and line endings
pre-commit run --all-files

# Lint workflow files for Actions-specific correctness
actionlint
```

## Documentation

Keep documentation current as part of the change, not as a follow-up — update the README and any affected sections in the same PR. A new or changed workflow input/output → the relevant table in `README.md`; a changed release mechanic → the Releases section below.

## Before you open a PR

- Make sure all CI checks pass locally first — run the formatter, linter, and tests.
- Run `pre-commit run --all-files` (this repo uses pre-commit hooks).

## Branching & commits

- Branch off `main`; never commit directly to `main`.
- Use [Conventional Commits](https://www.conventionalcommits.org/) prefixes (`feat:`, `fix:`, `docs:`, `chore:`, `refactor:`, `test:`, …).
- Sign your commits where possible (`git commit -S`).
- Keep each PR focused; delete dead code rather than commenting it out.

## Pull requests

- Open the PR against `main`.
- Every PR runs CI. Resolve **all** review threads before the PR is merged.
- An automated code review runs on each PR via this repo's own `claude-pr-review.yml@v1` reusable (dogfooded in `claude-pr-review-caller.yml`); address and resolve its threads like any other review.
- A PR can be merged once CI is green and all review threads are resolved.

## Releases

Releases are triggered by manual `workflow_dispatch` on [`.github/workflows/release.yml`](.github/workflows/release.yml). Choose a `version_type` (`patch`, `minor`, or `major`) or supply a `custom_version`. The workflow calls `ai-release.yml` to cut an immutable `vX.Y.Z` tag with AI-generated release notes, then the `moving-tags` job force-moves the major and major.minor tags — `v<MAJOR>` and `v<MAJOR>.<MINOR>`, today `v1` and `v1.8` — so consumers pinning `@v1` automatically receive the new release. Moving major/minor tags are intentional here — as a reusable-workflows repo, consumers pin `@v1`, not `@v1.2.3`. No `semver:*` label is needed.
