# Release Workflows

![Version](https://img.shields.io/github/v/release/jedwards1230/release-workflows?style=flat-square&color=blue)
![License](https://img.shields.io/github/license/jedwards1230/release-workflows?style=flat-square)

Reusable GitHub Actions workflows for automated release management with semantic versioning, changelog generation, and GitHub releases.

For Claude Code plugin marketplace validation, see [jedwards1230/claude-plugin-actions](https://github.com/jedwards1230/claude-plugin-actions).

## Features

- **Semantic Version Calculation**: Automatically calculates next version based on conventional commits
- **Changelog Generation**: Creates detailed changelogs from commit history
- **GitHub Releases**: Creates releases with artifacts and proper tagging
- **Moving Tags**: Maintains major and minor version tags (e.g., `v1`, `v1.2`) for easy consumption
- **Flexible Configuration**: Supports custom versions, working directories, and release options

## Workflows

### 1. Calculate Version (`calculate-version.yml`)

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

### 2. Generic Release (`generic-release.yml`)

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
  pull-requests: write

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
        uses: actions/checkout@v4
      
      - name: Build project
        run: |
          # Add your build steps here
          echo "Building version ${{ needs.calculate-version.outputs.new_version }}"
          
      - name: Upload artifacts
        uses: actions/upload-artifact@v4
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