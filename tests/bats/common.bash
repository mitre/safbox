# shellcheck shell=bash
# Shared by every bats suite: the helper libraries (bats-support for
# messages, bats-assert for output and value checks, bats-file for paths),
# found through BATS_LIB_PATH, which tests/bats/run.sh sets, and ROOT, the
# checkout the suite belongs to.
bats_load_library bats-support
bats_load_library bats-assert
bats_load_library bats-file
ROOT=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
export ROOT
