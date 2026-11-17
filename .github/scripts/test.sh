#!/bin/sh
# The checks every release passes, shared by ci.yml and release.yml so the two can't drift:
# lint, the fixture images, then build and run the tests (debug).
#
# Usage: .github/scripts/test.sh [lint] [fixtures] [build] [test]   (no argument: all, in order)
#
# Fixtures: the images and apps the tests read (installer and mount need verifier's).
# Real-app fixtures come from DMGs kept out of git (.claude/samples), so CI skips the tests
# that need them (.github/ci-skip-tests.txt); corpus and timing tests are opt-in and stay off.
set -eu
cd "$(dirname "$0")/../.."
[ $# -gt 0 ] || set -- lint fixtures build test
for STEP in "$@"; do
    echo "::group::$STEP"
    case $STEP in
        lint) scripts/swift.sh format lint --strict --recursive Sources Tests Package.swift ;;
        fixtures)
            scripts/fixtures-diskimage.sh
            scripts/fixtures-hfsplus.sh
            scripts/fixtures-apfs.sh
            scripts/fixtures-verifier.sh
            scripts/fixtures-installer.sh
            scripts/fixtures-mount.sh
            ;;
        build) scripts/swift.sh build --build-tests ;;
        test) scripts/swift.sh test --skip-build --skip "$(grep -v '^#' .github/ci-skip-tests.txt | paste -sd'|' -)" ;;
        *) echo "unknown step: $STEP" >&2; exit 2 ;;
    esac
    echo "::endgroup::"
done
