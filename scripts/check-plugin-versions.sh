#!/usr/bin/env bash
#
# check-plugin-versions.sh
#
# Validates that plugin versions are bumped in plugin.json when plugin files
# change, and that marketplace.json's metadata.version is bumped alongside.
#
# plugin.json is the sole source of truth for plugin versions — per the
# Claude Code plugins reference, setting `version` on a marketplace plugin
# entry is silently ignored when plugin.json also sets it. This script
# fails if it finds a `version` field on any marketplace plugin entry.
#
# Usage: ./scripts/check-plugin-versions.sh <base-ref>
#   base-ref: Git reference to compare against (e.g., origin/main)
#
# Environment variables:
#   MARKETPLACE_PATH  Path to marketplace.json (default: .claude-plugin/marketplace.json)
#   PLUGINS_DIR       Directory containing plugin subdirectories (default: plugins)
#
# Exit codes:
#   0 - All checks passed
#   1 - Version validation failed
#   2 - Script error (missing dependencies, invalid arguments)

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

MARKETPLACE_FILE="${MARKETPLACE_PATH:-.claude-plugin/marketplace.json}"
PLUGINS_DIR="${PLUGINS_DIR:-plugins}"
ERRORS_FOUND=0

declare -a PLUGIN_RESULTS=()
declare -a ERROR_MESSAGES=()
METADATA_RESULT=""
MARKETPLACE_VERSION_DRIFT_RESULT=""

check_dependencies() {
    if ! command -v jq &> /dev/null; then
        echo -e "${RED}ERROR: jq is required but not installed${NC}"
        exit 2
    fi
}

error() {
    echo -e "${RED}ERROR: $1${NC}"
    ERROR_MESSAGES+=("$1")
}

success() {
    echo -e "${GREEN}$1${NC}"
}

info() {
    echo -e "${YELLOW}$1${NC}"
}

# Get version from plugin.json at a specific git ref
# Arguments: $1 = plugin name, $2 = git ref
get_plugin_version() {
    local plugin_name="$1"
    local ref="$2"
    local plugin_json="${PLUGINS_DIR}/${plugin_name}/.claude-plugin/plugin.json"

    git show "${ref}:${plugin_json}" 2>/dev/null | jq -r '.version // empty' 2>/dev/null || echo ""
}

# Get metadata.version from marketplace.json at a specific git ref
# Arguments: $1 = git ref
get_metadata_version() {
    local ref="$1"

    git show "${ref}:${MARKETPLACE_FILE}" 2>/dev/null | jq -r '.metadata.version // empty' 2>/dev/null || echo ""
}

# Get list of changed plugins from git diff
# Arguments: $1 = base ref
get_changed_plugins() {
    local base_ref="$1"

    git diff --name-only "${base_ref}"...HEAD -- "${PLUGINS_DIR}/" 2>/dev/null | \
        grep -E "^${PLUGINS_DIR}/[^/]+/" | \
        sed "s|^${PLUGINS_DIR}/\([^/]*\)/.*|\1|" | \
        sort -u || true
}

# Check if marketplace.json itself was changed
# Arguments: $1 = base ref
marketplace_changed() {
    local base_ref="$1"

    git diff --name-only "${base_ref}"...HEAD -- "${MARKETPLACE_FILE}" 2>/dev/null | grep -q . && return 0 || return 1
}

# Check if a plugin is new (doesn't exist in base ref)
# Arguments: $1 = plugin name, $2 = base ref
is_new_plugin() {
    local plugin_name="$1"
    local base_ref="$2"
    local base_version

    base_version=$(get_plugin_version "$plugin_name" "$base_ref")
    [[ -z "$base_version" ]]
}

# Fail if any plugin entry in marketplace.json defines a `version` field.
# plugin.json is authoritative — duplicating here creates silent drift.
check_no_marketplace_plugin_versions() {
    echo ""
    echo "Checking marketplace.json for stray plugin version fields"
    echo "----------------------------------------"

    if [[ ! -f "$MARKETPLACE_FILE" ]]; then
        error "${MARKETPLACE_FILE} not found"
        ((ERRORS_FOUND++))
        MARKETPLACE_VERSION_DRIFT_RESULT="fail|marketplace.json not found"
        return 1
    fi

    local offenders
    offenders=$(jq -r '[.plugins[]? | select(has("version")) | .name] | join(", ")' "$MARKETPLACE_FILE")

    if [[ -n "$offenders" ]]; then
        error "marketplace.json plugin entries must not set 'version': ${offenders}"
        error "  plugin.json is the source of truth; marketplace-side versions are silently ignored"
        ((ERRORS_FOUND++))
        MARKETPLACE_VERSION_DRIFT_RESULT="fail|Entries with version: ${offenders}"
        return 1
    fi

    success "No stray plugin version fields in marketplace.json"
    MARKETPLACE_VERSION_DRIFT_RESULT="pass|Clean"
    return 0
}

# Validate a single plugin
# Arguments: $1 = plugin name, $2 = base ref
validate_plugin() {
    local plugin_name="$1"
    local base_ref="$2"
    local has_errors=0
    local plugin_status="pass"
    local plugin_details=""

    echo ""
    echo "Checking plugin: ${plugin_name}"
    echo "----------------------------------------"

    local base_plugin_version
    local head_plugin_version

    base_plugin_version=$(get_plugin_version "$plugin_name" "$base_ref")
    head_plugin_version=$(get_plugin_version "$plugin_name" "HEAD")

    # Check if plugin was removed
    if [[ -z "$head_plugin_version" ]]; then
        info "Plugin removed - skipping validation"
        PLUGIN_RESULTS+=("${plugin_name}|pass|Removed (was ${base_plugin_version:-unknown})")
        return 0
    fi

    # For new plugins, just confirm plugin.json has a version
    if is_new_plugin "$plugin_name" "$base_ref"; then
        info "New plugin detected - skipping bump check"
        success "plugin.json version: ${head_plugin_version}"
        PLUGIN_RESULTS+=("${plugin_name}|pass|New plugin, version ${head_plugin_version}")
        return 0
    fi

    # Check that plugin.json version was bumped
    if [[ "$base_plugin_version" == "$head_plugin_version" ]]; then
        error "plugin.json version not bumped for ${plugin_name}"
        error "  Base version:    ${base_plugin_version}"
        error "  Current version: ${head_plugin_version}"
        error "  Please increment the version when changing plugin files"
        ((ERRORS_FOUND++))
        has_errors=1
        plugin_status="fail"
        plugin_details="plugin.json not bumped (${base_plugin_version})"
    else
        success "plugin.json version bumped: ${base_plugin_version} -> ${head_plugin_version}"
        plugin_details="${base_plugin_version} → ${head_plugin_version}"
    fi

    PLUGIN_RESULTS+=("${plugin_name}|${plugin_status}|${plugin_details}")
    return $has_errors
}

# Check if metadata.version was bumped when plugins changed
# Arguments: $1 = base ref
check_metadata_version() {
    local base_ref="$1"

    echo ""
    echo "Checking marketplace metadata version"
    echo "----------------------------------------"

    local base_metadata_version
    local head_metadata_version

    base_metadata_version=$(get_metadata_version "$base_ref")
    head_metadata_version=$(get_metadata_version "HEAD")

    if [[ -z "$head_metadata_version" ]]; then
        error "metadata.version not found in marketplace.json"
        ((ERRORS_FOUND++))
        METADATA_RESULT="fail|metadata.version not found"
        return 1
    fi

    if [[ "$base_metadata_version" == "$head_metadata_version" ]]; then
        error "metadata.version not bumped in marketplace.json"
        error "  Base version:    ${base_metadata_version}"
        error "  Current version: ${head_metadata_version}"
        error "  Please bump metadata.version when plugins change"
        ((ERRORS_FOUND++))
        METADATA_RESULT="fail|Not bumped (${base_metadata_version})"
        return 1
    fi

    success "metadata.version bumped: ${base_metadata_version} -> ${head_metadata_version}"
    METADATA_RESULT="pass|${base_metadata_version} → ${head_metadata_version}"
    return 0
}

print_fix_instructions() {
    echo ""
    echo "To fix version errors:"
    echo "  1. Bump the version in ${PLUGINS_DIR}/<name>/.claude-plugin/plugin.json"
    echo "  2. Bump metadata.version in ${MARKETPLACE_FILE}"
    echo "  3. Remove any 'version' fields from marketplace.json plugin entries"
    echo "     (plugin.json is the sole source of truth)"
}

write_summary() {
    if [[ -z "${GITHUB_STEP_SUMMARY:-}" ]]; then
        return
    fi

    {
        echo "## Plugin Version Check"
        echo ""

        if [[ ${#PLUGIN_RESULTS[@]} -eq 0 && -z "$METADATA_RESULT" && -z "$MARKETPLACE_VERSION_DRIFT_RESULT" ]]; then
            echo "No plugin changes detected."
        else
            if [[ ${#PLUGIN_RESULTS[@]} -gt 0 ]]; then
                echo "### Plugin Results"
                echo ""
                echo "| Plugin | Status | Details |"
                echo "|--------|--------|---------|"
                for result in "${PLUGIN_RESULTS[@]}"; do
                    IFS='|' read -r name status details <<< "$result"
                    if [[ "$status" == "pass" ]]; then
                        echo "| \`${name}\` | :white_check_mark: Pass | ${details} |"
                    else
                        echo "| \`${name}\` | :x: Fail | ${details} |"
                    fi
                done
                echo ""
            fi

            if [[ -n "$MARKETPLACE_VERSION_DRIFT_RESULT" ]]; then
                echo "### Marketplace Entry Hygiene"
                echo ""
                IFS='|' read -r status details <<< "$MARKETPLACE_VERSION_DRIFT_RESULT"
                if [[ "$status" == "pass" ]]; then
                    echo ":white_check_mark: \`${MARKETPLACE_FILE}\` plugin entries have no \`version\` fields: ${details}"
                else
                    echo ":x: \`${MARKETPLACE_FILE}\` plugin entry hygiene: ${details}"
                fi
                echo ""
            fi

            if [[ -n "$METADATA_RESULT" ]]; then
                echo "### Marketplace Metadata"
                echo ""
                IFS='|' read -r status details <<< "$METADATA_RESULT"
                if [[ "$status" == "pass" ]]; then
                    echo ":white_check_mark: \`${MARKETPLACE_FILE}\` **metadata.version**: ${details}"
                else
                    echo ":x: \`${MARKETPLACE_FILE}\` **metadata.version**: ${details}"
                fi
                echo ""
            fi
        fi

        if [[ $ERRORS_FOUND -gt 0 ]]; then
            echo "### :x: Check Failed"
            echo ""
            echo "Found **${ERRORS_FOUND} error(s)**. Please fix the version issues above."
            echo ""
            echo "<details>"
            echo "<summary>How to fix</summary>"
            echo ""
            echo "1. Bump the version in \`${PLUGINS_DIR}/<name>/.claude-plugin/plugin.json\`"
            echo "2. Bump \`metadata.version\` in \`${MARKETPLACE_FILE}\`"
            echo "3. Remove any \`version\` fields from marketplace.json plugin entries"
            echo ""
            echo "**Version bump conventions for metadata.version:**"
            echo "- Plugin added/removed: Major bump (1.2.3 → 2.0.0)"
            echo "- Core metadata changes: Minor bump (1.2.3 → 1.3.0)"
            echo "- Plugin version changes: Patch bump (1.2.3 → 1.2.4)"
            echo ""
            echo "</details>"
        else
            echo "### :white_check_mark: All Checks Passed"
        fi
    } >> "$GITHUB_STEP_SUMMARY"
}

main() {
    if [[ $# -ne 1 ]]; then
        echo "Usage: $0 <base-ref>" >&2
        echo "  base-ref: Git reference to compare against (e.g., origin/main)" >&2
        echo "" >&2
        echo "Environment variables:" >&2
        echo "  MARKETPLACE_PATH  Path to marketplace.json (default: .claude-plugin/marketplace.json)" >&2
        echo "  PLUGINS_DIR       Directory containing plugin subdirectories (default: plugins)" >&2
        exit 2
    fi

    local base_ref="$1"

    check_dependencies

    echo "Plugin Version Check"
    echo "===================="
    echo "Marketplace file: ${MARKETPLACE_FILE}"
    echo "Plugins dir:      ${PLUGINS_DIR}"
    echo "Comparing HEAD against ${base_ref}"

    # Always enforce: marketplace.json plugin entries must not set `version`
    check_no_marketplace_plugin_versions || true

    local changed_plugins
    changed_plugins=$(get_changed_plugins "$base_ref")

    if [[ -z "$changed_plugins" ]]; then
        if marketplace_changed "$base_ref"; then
            info "No plugin files changed, but marketplace.json was modified"
            check_metadata_version "$base_ref" || true
        else
            success "No plugin changes detected - nothing to validate"
        fi
    else
        echo ""
        echo "Changed plugins: $(echo "$changed_plugins" | tr '\n' ' ')"

        for plugin in $changed_plugins; do
            validate_plugin "$plugin" "$base_ref" || true
        done

        check_metadata_version "$base_ref" || true
    fi

    echo ""
    echo "=========================================="
    if [[ $ERRORS_FOUND -gt 0 ]]; then
        error "Version check failed with ${ERRORS_FOUND} error(s)"
        print_fix_instructions
        write_summary
        exit 1
    else
        success "All version checks passed!"
        write_summary
        exit 0
    fi
}

main "$@"
