#!/bin/sh
# End-to-end tests: they drive Neovim and a real Octave (octave on PATH).
#
#   test/e2e/run.sh              run all suites
#   test/e2e/run.sh hover keys   run some suites
#
# Each run uses a temporary folder as working folder and as XDG_DATA_HOME, so
# that the repository and your Neovim data stay untouched. The exit code is 0
# only when every check passed.
set -u
here=$(cd "$(dirname "$0")" && pwd)
all="stage1 stage2 bpsync hover keys viewer viewer_wiring main main_restart"
suites=${*:-$all}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/octave-dbg-e2e.XXXXXX")
# A time limit per suite, if a timeout command is installed.
limit=""
if command -v timeout >/dev/null 2>&1; then
  limit="timeout 300"
elif command -v gtimeout >/dev/null 2>&1; then
  limit="gtimeout 300"
fi
failed=0
for s in $suites; do
  log="$tmp/$s.log"
  (cd "$tmp" && OCTAVE_DBG_E2E_TMP="$tmp" XDG_DATA_HOME="$tmp/data" \
    $limit nvim --headless --clean -u NONE -c "luafile $here/$s.lua") >"$log" 2>&1
  code=$?
  result=$(grep '^RESULT ' "$log" | tail -n 1)
  if [ -z "$result" ]; then
    echo "$s: did not finish (exit code $code)"
    tail -n 5 "$log" | sed 's/^/    /'
    failed=1
  else
    echo "${result#RESULT }"
    grep '^FAIL ' "$log" | sed 's/^/    /'
    [ "$code" -ne 0 ] && failed=1
  fi
done
rm -rf "$tmp"
exit $failed
