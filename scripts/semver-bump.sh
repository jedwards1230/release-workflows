#!/usr/bin/env bash
# Bump a semantic version: semver-bump.sh <version> <major|minor|patch>
# Spec: https://semver.org/spec/v2.0.0.html
set -euo pipefail

version=${1#v}
part=${2:-patch}

IFS=. read -r major minor patch <<< "$version"

case $part in
  major) major=$((major + 1)); minor=0 ;;
  minor) minor=$((minor + 1)) ;;
  patch) patch=$((patch + 1)) ;;
  *) echo "unknown part: $part" >&2; exit 2 ;;
esac

echo "v$major.$minor.$patch"
