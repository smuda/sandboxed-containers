#!/usr/bin/env bash
# Self-check: summarize the fixture results and diff against the
# hand-computed expected CSV.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/summarize-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# Copy so summarize.sh never writes into the checked-in fixture.
cp -R "$here/testdata/results" "$tmp/results"
"$here/summarize.sh" "$tmp/results"

if diff -u "$here/testdata/expected-summary.csv" "$tmp/results/summary.csv"; then
  echo "PASS: summary.csv matches expected"
else
  echo "FAIL: summary.csv differs from testdata/expected-summary.csv" >&2
  exit 1
fi
