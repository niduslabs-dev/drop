#!/bin/sh
# Runs the opt-in corpus tests against the real sample DMGs in .claude/samples/.
# The Extractor's fidelity test needs Finder-style reference copies of 8 apps (about
# 4.4 GB), so this makes them, runs the tests, and always deletes them afterwards.
# Usage: scripts/corpus.sh [swift test arguments, e.g. --filter ExtractorTests]
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
REFERENCE="$ROOT/.build/fixtures/reference"
trap 'rm -rf "$REFERENCE"' EXIT INT TERM
"$ROOT/scripts/reference-apps.sh"
DROP_CORPUS=1 "$ROOT/scripts/swift.sh" test "$@"
