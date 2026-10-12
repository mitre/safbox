#!/usr/bin/env bash
# Static checks for the validation profile. `cinc-auditor check` skips a
# control file that fails to parse and still reports the profile valid, and
# the threshold has no floor on how many controls run, so a broken file would
# silently drop its controls from every gate. Check syntax directly, and that
# every declared control is loaded.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
PROFILE=${1:-$ROOT/verify/inspec-safbox}

# CINC Auditor's embedded Ruby, so the syntax is checked by the parser that
# will load the profile.
RUBY=$(dirname "$(readlink -f "$(command -v cinc-auditor)" 2>/dev/null || command -v cinc-auditor)")/ruby
if [ ! -x "$RUBY" ]; then RUBY=/opt/cinc-auditor/embedded/bin/ruby; fi
if [ ! -x "$RUBY" ]; then RUBY=$(command -v ruby); fi

fails=0
for f in "$PROFILE"/controls/*.rb; do
  if ! out=$("$RUBY" -c "$f" 2>&1); then
    echo "FAIL: $f does not parse: $out" >&2; fails=1
  fi
done
[ "$fails" -eq 0 ] || exit 1

declared=$(grep -hcE "^control '" "$PROFILE"/controls/*.rb | paste -sd+ - | bc)
loaded=$(cinc-auditor json "$PROFILE" --chef-license accept-silent 2>/dev/null \
  | "$RUBY" -rjson -e "puts JSON.parse(\$stdin.read)['controls'].length")
if [ "$declared" != "$loaded" ]; then
  echo "FAIL: $declared controls declared but $loaded loaded" >&2; exit 1
fi
echo "PASS: profile parses and loads all $loaded declared controls"
