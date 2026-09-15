#!/usr/bin/env bash
# Runs all tests. Needs no network and no Drive account.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

failed=0

# Syntax check always, shellcheck if installed (R12).
for script in ../gdrive-sync ../gdrive-watch ../open-url-shortcut ../install.sh; do
  if bash -n "$script"; then
    printf 'bash -n %s: ok\n' "$(basename "$script")"
  else
    printf 'bash -n %s: FAILED\n' "$(basename "$script")"
    failed=1
  fi
done

# The test files are checked too, so a quoting bug in a test cannot quietly make
# a test pass. -x follows the sourced files, which is what the directives in them
# point at.
if command -v shellcheck >/dev/null; then
  if (cd .. && shellcheck -x gdrive-sync gdrive-watch open-url-shortcut install.sh tests/*.sh); then
    printf 'shellcheck: ok\n'
  else
    printf 'shellcheck: FAILED\n'
    failed=1
  fi
else
  printf 'shellcheck: SKIPPED (not installed)\n'
fi

for t in test-*.sh; do
  printf '\n== %s\n' "$t"
  timeout 60s bash "$t" || failed=1
done

printf '\n'
if (( failed )); then
  printf 'TESTS FAILED\n'
else
  printf 'all tests passed\n'
fi
exit $failed
