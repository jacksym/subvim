#!/bin/sh
# Run the subvim test suite: test/run.sh [test_name ...]
# Each test gets a fresh svn repository and working copy in a temp dir.
# Requires vim (with +timers, 9.1+ for diff()), svn and svnadmin.
set -u
T=$(cd "$(dirname "$0")" && pwd)
PLUGIN=$(dirname "$T")
TMP=$(mktemp -d "${TMPDIR:-/tmp}/subvim-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
OUT=$TMP/out.txt
tests=${*:-$(sed -n 's/^function! T_\([a-z_]*\).*/\1/p' "$T/cases.vim")}
for t in $tests; do
  "$T/fixture.sh" "$TMP/fx" >/dev/null
  PLUGIN=$PLUGIN OUT=$OUT WC=$TMP/fx/wc TESTS=$T/cases.vim TEST=$t \
    timeout 60 vim -N -u NONE -i NONE -es -S "$T/run.vim" </dev/null >/dev/null 2>&1 ||
    echo "FAIL $t (vim exited with $?)" >> "$OUT"
done
grep -av '^DONE$' "$OUT" | sed 's#command line\.\.script [^ ]*cases\.vim\[[0-9]*\]\.\.function Test\[3\]\.\.##'
pass=$(grep -ac '^PASS ' "$OUT"); fail=$(grep -ac '^FAIL ' "$OUT")
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
