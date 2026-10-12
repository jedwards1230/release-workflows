#!/usr/bin/env bash
# Run: bash tests/semver-bump.test.sh
set -euo pipefail
cd "$(dirname "$0")/.."

fail=0
check() {
  local got
  got=$(scripts/semver-bump.sh "$1" "$2")
  if [ "$got" != "$3" ]; then echo "FAIL: $1 $2 -> $got (want $3)"; fail=1; else echo "ok: $1 $2 -> $got"; fi
}

check v1.2.3 patch v1.2.4
check v1.2.3 minor v1.3.0
check v1.2.3 major v2.0.0
check 1.9.9 patch v1.9.10

exit $fail
