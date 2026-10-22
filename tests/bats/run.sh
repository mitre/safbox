#!/usr/bin/env bash
# Run the bats suites, TAP output: every *.bats file under tests/, or the
# files and directories given. Installs the pinned bats first
# (tests/bats/install.sh). Each test gets its own temporary directory under
# $TMPDIR (BATS_TEST_TMPDIR), which bats removes afterwards.
#
#   tests/bats/run.sh                       every suite
#   tests/bats/run.sh tests/scripts/build-env.bats
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
export SAFBOX_BATS_DIR=${SAFBOX_BATS_DIR:-$ROOT/.build/bats}
"$ROOT/tests/bats/install.sh"
# bats_load_library finds bats-support, bats-assert and bats-file here.
export BATS_LIB_PATH=$SAFBOX_BATS_DIR
[ $# -gt 0 ] || set -- "$ROOT/tests"
exec "$SAFBOX_BATS_DIR/bats-core/bin/bats" --formatter tap --recursive "$@"
