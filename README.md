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

## Workflows

### 1. AI Release (`ai-release.yml`) — **Preferred**

Full standard release workflow: computes the next version (semver bump or explicit override), optionally bumps a Helm chart version into the tagged commit, generates AI release notes (Haiku for patch, Sonnet for minor/major, cumulative diff for non-patch), and either creates the GitHub Release directly or hands the body back to the caller to chain build/publish jobs.

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

### 2. Calculate Version (`calculate-version.yml`)

Calculates the next semantic version based on the latest Git tags and generates a changelog.

#### Inputs

| Input | Description | Required | Default |
|-------|-------------|----------|---------|
| `version_type` | Version bump type (`major`, `minor`, `patch`) | Yes | `patch` |
| `custom_version` | Custom version (overrides version_type) | No | - |
| `working_directory` | Working directory for the workflow | No | `.` |

#### Outputs

| Output | Description |
|--------|-------------|
| `current_version` | The current version before bumping |
| `new_version` | The new version that was calculated |
| `changelog` | Path to the generated changelog file |
| `changelog_content` | Content of the generated changelog |

#### Example Usage

```yaml
jobs:
  calculate-version:
    uses: jedwards1230/release-workflows/.github/workflows/calculate-version.yml@v0
    with:
      version_type: "minor"
      working_directory: "."
    secrets: inherit
```

### 3. Generic Release (`generic-release.yml`)

Creates a GitHub release with proper tagging, changelog, and artifact handling.

#### Inputs

| Input | Description | Required | Default |
|-------|-------------|----------|---------|
| `new_version` | The version to release (e.g., v1.2.3) | Yes | - |
| `current_version` | The current version before this release | Yes | - |
| `changelog_content` | Content for the release changelog | Yes | - |
| `changelog_artifact_name` | Name of the changelog artifact to download | No | - |
| `draft` | Create as draft release | No | `false` |
| `prerelease` | Mark as prerelease | No | `false` |
| `create_release` | Create GitHub release | No | `true` |
| `artifacts_pattern` | Glob pattern for release artifacts | No | - |
| `working_directory` | Working directory for the workflow | No | `.` |

#### Outputs

| Output | Description |
|--------|-------------|
| `version` | The version that was released |
| `release_url` | URL of the created release |

#### Example Usage

```yaml
jobs:
  release:
    uses: jedwards1230/release-workflows/.github/workflows/generic-release.yml@v0
    with:
      new_version: ${{ needs.calculate-version.outputs.new_version }}
      current_version: ${{ needs.calculate-version.outputs.current_version }}
      changelog_content: ${{ needs.calculate-version.outputs.changelog_content }}
      create_release: true
      artifacts_pattern: "dist/*"
    secrets: inherit
```

## Complete Release Example

Here's a complete example that demonstrates how to use both workflows together:

```yaml
name: Release

on:
  workflow_dispatch:
    inputs:
      version_type:
        description: "Version bump type"
        required: true
        default: "patch"
        type: choice
        options:
          - major
          - minor
          - patch
      custom_version:
        description: "Custom version (optional, overrides version_type)"
        required: false
        type: string
      draft:
        description: "Create as draft release"
        required: false
        default: false
        type: boolean

permissions:
  contents: write

jobs:
  calculate-version:
    uses: jedwards1230/release-workflows/.github/workflows/calculate-version.yml@v0
    with:
      version_type: ${{ github.event.inputs.version_type }}
      custom_version: ${{ github.event.inputs.custom_version }}
      working_directory: "."
    secrets: inherit

  build:
    needs: calculate-version
    runs-on: ubuntu-latest
    steps:
      - name: Checkout code
        uses: actions/checkout@v6

      - name: Build project
        run: |
          # Add your build steps here
          echo "Building version ${{ needs.calculate-version.outputs.new_version }}"

      - name: Upload artifacts
        uses: actions/upload-artifact@v7
        with:
          name: release-binaries
          path: dist/

  release:
    needs: [calculate-version, build]
    uses: jedwards1230/release-workflows/.github/workflows/generic-release.yml@v0
    with:
      new_version: ${{ needs.calculate-version.outputs.new_version }}
      current_version: ${{ needs.calculate-version.outputs.current_version }}
      changelog_content: ${{ needs.calculate-version.outputs.changelog_content }}
      draft: ${{ github.event.inputs.draft == 'true' }}
      create_release: true
      artifacts_pattern: "dist/*"
    secrets: inherit
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

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test the workflows
5. Submit a pull request

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.