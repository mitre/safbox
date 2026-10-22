#!/bin/sh
# Stub scripts/validate.sh for tests/scripts/*.bats: records
# in $STUB_DIR/scanned that the release gate ran, and its arguments, one
# per line, in $STUB_DIR/validate.args.
echo scanned > "$STUB_DIR/scanned"
printf '%s\n' "$@" > "$STUB_DIR/validate.args"
