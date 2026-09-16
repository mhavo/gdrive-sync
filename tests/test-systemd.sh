#!/usr/bin/env bash
# §6: validity of the systemd units and the settings they must carry.
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

UNITS="$REPO_ROOT/systemd"

command -v systemd-analyze >/dev/null || {
  printf '  skip %s (systemd-analyze missing)\n' "$(basename "$0")"
  exit 0
}

# ExecStart points at the ~/.local/bin/ symlink, which does not exist in the
# repo; that warning is filtered out. Unknown keys are not acceptable.
#
# The units are templates, so systemd-analyze is pointed at the template file
# itself: it instantiates the name it is given, which resolves %i and proves
# the instance a user actually starts is valid.
for unit in gdrive-sync@.service gdrive-watch@.service; do
  out="$(systemd-analyze verify "$UNITS/$unit" 2>&1 \
    | grep -v -e 'is not executable' \
              -e 'Failed to turn off SO_PASSRIGHTS on user lookup socket, ignoring: Operation not permitted' \
              -e 'Failed to enable SO_PASSCRED on handoff timestamp socket: Operation not permitted')"
  if [[ -z "$out" ]]; then
    pass "$unit is valid to systemd"
  else
    fail "$unit is valid to systemd" "$out"
  fi
done

sync_unit="$(cat "$UNITS/gdrive-sync@.service")"
assert_contains "gdrive-sync@.service: SuccessExitStatus=75" "$sync_unit" "SuccessExitStatus=75"
# Both units log the whole run to the journal; systemd's default rate limit
# would drop the excess silently.
assert_contains "gdrive-sync@.service: LogRateLimitIntervalSec=0" "$sync_unit" "LogRateLimitIntervalSec=0"

watch_unit="$(cat "$UNITS/gdrive-watch@.service")"
for key in "Type=simple" "Restart=always" "RestartSec=2" "StartLimitIntervalSec=0" \
           "LogRateLimitIntervalSec=0" \
           "WantedBy=default.target" "GDRIVE_SYNC_BIN=%h/.local/bin/gdrive-sync"; do
  assert_contains "gdrive-watch@.service: $key" "$watch_unit" "$key"
done

# The instance name is the profile, and it reaches the scripts as an
# environment variable. Without this line every instance would sync whichever
# profile the resolution rules happened to pick, which for more than one
# profile is a refusal — the timer would fail instead of syncing.
assert_contains "gdrive-sync@.service: Environment=GDRIVE_PROFILE=%i" "$sync_unit" "Environment=GDRIVE_PROFILE=%i"
assert_contains "gdrive-watch@.service: Environment=GDRIVE_PROFILE=%i" "$watch_unit" "Environment=GDRIVE_PROFILE=%i"

# The timer activates gdrive-sync@<instance>.service by name, so a Unit= line
# would only be a second place for the two names to disagree.
timer_unit="$(cat "$UNITS/gdrive-sync@.timer")"
assert_contains "gdrive-sync@.timer: RandomizedDelaySec=60" "$timer_unit" "RandomizedDelaySec=60"
if [[ "$timer_unit" == *"Unit="* ]]; then
  fail "gdrive-sync@.timer names no Unit=" "it does"
else
  pass "gdrive-sync@.timer names no Unit="
fi

# StartLimitIntervalSec belongs in the [Unit] section; in [Service] systemd
# ignores it silently, which would leave the start limit in force.
section=""
in_unit=0
while IFS= read -r line; do
  [[ "$line" == \[*\] ]] && section="$line"
  [[ "$line" == StartLimitIntervalSec=* && "$section" == "[Unit]" ]] && in_unit=1
done < "$UNITS/gdrive-watch@.service"
assert_eq "StartLimitIntervalSec is in the [Unit] section" 1 "$in_unit"

finish
