# Release Workflows

![Version](https://img.shields.io/github/v/release/jedwards1230/release-workflows?style=flat-square&color=blue)
![License](https://img.shields.io/github/license/jedwards1230/release-workflows?style=flat-square)

Reusable GitHub Actions workflows for automated release management with semantic versioning, AI-generated release notes, and GitHub Releases.

For Claude Code plugin marketplace validation, see [jedwards1230/claude-plugin-actions](https://github.com/jedwards1230/claude-plugin-actions).

## Features

- **AI Release Notes**: Anthropic-API-backed release notes with model selection by bump type (Haiku for patch, Sonnet for minor/major) and cumulative diff scoping (`ai-release.yml`)
- **Semantic Version Calculation**: Automatically calculates next version from existing tags
- **Helm Chart Bump**: Optionally bumps `version` + `appVersion` in a `Chart.yaml`, committed into the tagged commit (not pushed to main)
- **GitHub Releases**: Creates releases with proper tagging and artifact handling
- **Moving Tags**: Maintains major and minor version tags (e.g., `v1`, `v1.2`) for reusable-workflow consumers

## Workflow

### AI Release (`ai-release.yml`)

Full-featured release workflow: computes the next version (semver bump or explicit override), optionally bumps a Helm chart version into the tagged commit, generates AI release notes (Haiku for patch, Sonnet for minor/major, cumulative diff for non-patch), and either creates the GitHub Release directly or hands the body back to the caller to chain build/publish jobs.

#### Inputs

| Input | Description | Required | Default |
|-------|-------------|----------|---------|
| `service_name` | Short service identifier (e.g. `"my-app"`) used in commit messages | Yes | - |
| `service_description` | One-line description used in the AI prompt | No | - |
| `bump_type` | `patch`, `minor`, or `major` | Yes | - |
| `version_override` | Explicit `X.Y.Z` (ignores `bump_type`) | No | - |
| `chart_path` | Path to a `Chart.yaml` to bump (committed into tag, not pushed to main) | No | - |
| `release_branch` | Branch to release from | No | `main` |
| `dry_run` | Compute and preview without tagging | No | `false` |
| `create_release` | Create the GitHub Release directly | No | `false` |
| `latest` | Mark the release as "latest" | No | `true` |

#### Secrets

| Secret | Required | Behavior |
|--------|----------|----------|
| `ANTHROPIC_API_KEY` | No | AI-generated notes (Haiku for patch, Sonnet for minor/major). When absent or the API call fails, the workflow falls back to GitHub's native release-notes API (`POST /repos/{owner}/{repo}/releases/generate-notes` — same content as `gh release create --generate-notes` produces). Final fallback (if both fail) is a minimal commit-list body. |

#### Outputs

| Output | Description |
|--------|-------------|
| `tag` | Release tag (e.g. `v1.2.3`) |
| `version` | Version without leading `v` |
| `prev_tag` | Previous semver tag |
| `changelog_ref` | Diff baseline used for release notes (cumulative for minor/major) |
| `bump_type` | Resolved bump type |
| `release_body` | **Base64-encoded** release body markdown. Callers MUST decode before use — see the example below. Base64 is used because GitHub Actions strips newlines and limits character set on job outputs. |

#### Example: caller creates the release after build/publish

```yaml
jobs:
  prepare:
    uses: jedwards1230/release-workflows/.github/workflows/ai-release.yml@v0
    with:
      service_name: my-service
      service_description: "a thing that does X"
      bump_type: ${{ inputs.bump_type }}
      chart_path: charts/my-service/Chart.yaml
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
          name: Release ${{ needs.prepare.outputs.version }}
          body_path: body.md
```

#### Example: one-shot (no build steps in between)

```yaml
jobs:
  release:
    uses: jedwards1230/release-workflows/.github/workflows/ai-release.yml@v0
    with:
      service_name: my-tool
      bump_type: ${{ inputs.bump_type }}
      create_release: true
    secrets:
      ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
```

## Version Pinning

You can pin to specific versions of these workflows:

- **Latest stable**: `@v0` (recommended for production)
- **Specific version**: `@v0.0.1` (for maximum stability)
- **Latest changes**: `@main` (for development/testing)

## Tagging Strategy

The workflows create three types of tags:

1. **Specific version tags**: `v1.2.3` - Exact version
2. **Minor version tags**: `v1.2` - Latest patch in the minor version
3. **Major version tags**: `v1` - Latest release in the major version

This allows for flexible version pinning in consuming repositories.

## Requirements

- Repository must have semantic version tags (e.g., `v1.0.0`, `v1.2.3`)
- Workflows require `contents: write` permissions for creating releases and tags
- For version badges, use the dynamic [shields.io endpoint](https://shields.io/badges/git-hub-release) (e.g., `https://img.shields.io/github/v/release/owner/repo`) — it auto-tracks the latest release without needing CI to rewrite the badge file

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for build/test/lint commands, branch and commit conventions, PR process, and release instructions.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
