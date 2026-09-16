#!/usr/bin/env bash
# §Omarchy widget: the plugin manifest, and the one trap that breaks
# installation silently.
#
# `omarchy plugin validate` is the authority and is run here whenever it is
# available. The assertions around it are not a second copy of the schema —
# they cover the two rules this repository can break without noticing (the
# reserved id namespace and a stray symlink) and they run on machines that have
# no Omarchy at all, which is where most of this repository's tests run.
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MANIFEST="$REPO_ROOT/manifest.json"

# The validator looks nowhere else: a manifest in a subdirectory is a plugin
# that cannot be installed.
assert_path "manifest.json is in the repository root" "$MANIFEST"
[[ -f "$MANIFEST" ]] || { finish; exit; }

command -v jq >/dev/null || {
  printf '  skip %s (jq missing)\n' "$(basename "$0")"
  exit 0
}

if jq -e . "$MANIFEST" >/dev/null 2>&1; then
  pass "manifest.json is valid JSON"
else
  fail "manifest.json is valid JSON" "$(jq . "$MANIFEST" 2>&1 | head -3)"
fi

# schemaVersion must be the JSON number 1; the shell rejects the string "1".
assert_eq "schemaVersion is the number 1" true "$(jq -r '.schemaVersion == 1' "$MANIFEST")"

id="$(jq -r '.id // ""' "$MANIFEST")"
assert_eq "id is mhavo.gdrive-sync" "mhavo.gdrive-sync" "$id"
if [[ "$id" == omarchy.* ]]; then
  fail "id stays out of the reserved omarchy.* namespace" "id is $id"
else
  pass "id stays out of the reserved omarchy.* namespace"
fi

assert_eq "kinds declares bar-widget" true \
  "$(jq -r '(.kinds | index("bar-widget")) != null' "$MANIFEST")"
# A declared kind without its entry point installs, enables, and does nothing.
assert_eq "kind bar-widget has its entryPoints.barWidget" true \
  "$(jq -r '.entryPoints | has("barWidget")' "$MANIFEST")"
assert_eq "barWidget.defaultSection is a bar section" true \
  "$(jq -r '["left","center","right"] | index($s) != null' --arg s "$(jq -r '.barWidget.defaultSection // ""' "$MANIFEST")" "$MANIFEST")"

# Every entry point must be a relative path, free of "..", that exists.
while IFS= read -r entry; do
  [[ -n "$entry" ]] || continue
  case "$entry" in
    /*) fail "entry point '$entry' is relative" "absolute paths are refused" ;;
    *..*) fail "entry point '$entry' has no '..'" "'..' is refused" ;;
    *) pass "entry point '$entry' is a safe relative path" ;;
  esac
  assert_path "entry point '$entry' exists" "$REPO_ROOT/$entry"
done < <(jq -r '.entryPoints[]' "$MANIFEST")

# The widget's own files, whether or not the manifest happens to name them.
for file in omarchy/Panel.qml omarchy/Service.qml omarchy/ProfileState.qml omarchy/Model.js; do
  assert_path "$file exists" "$REPO_ROOT/$file"
done

# One widget covers every profile, so a second instance would only duplicate
# the same icon; the popup picks the account instead.
assert_eq "barWidget.allowMultiple stays false" "false" \
  "$(jq -r '.barWidget.allowMultiple' "$MANIFEST")"

# Every settings key the widget reads must be declared, or Omarchy shows the
# user no way to set it. defaultProfile is the only per-profile one: the two
# thresholds are deliberately global and apply to every account.
for key in showLabel defaultProfile staleAfterMin stuckAfterMin; do
  assert_eq "schema declares $key" true \
    "$(jq -r --arg k "$key" '[.barWidget.schema[].key] | index($k) != null' "$MANIFEST")"
  assert_eq "defaults carry $key" true \
    "$(jq -r --arg k "$key" '.barWidget.defaults | has($k)' "$MANIFEST")"
done

# The silent trap: one symlink anywhere in the checkout and the validator
# rejects the whole plugin, for everyone, with no failure until someone runs
# `omarchy plugin add`. .git is excluded exactly as the validator excludes it.
links=()
while IFS= read -r link; do
  [[ -n "$link" ]] && links+=("$link")
done < <(find "$REPO_ROOT" -name .git -prune -o -type l -print 2>/dev/null)
if (( ${#links[@]} == 0 )); then
  pass "the repository contains no symlinks"
else
  fail "the repository contains no symlinks" "found:" "${links[@]}"
fi

# The authority, when this machine has it.
if command -v omarchy >/dev/null; then
  if out="$(omarchy plugin validate "$REPO_ROOT" 2>&1)"; then
    pass "omarchy plugin validate accepts the repository"
  else
    fail "omarchy plugin validate accepts the repository" "$out"
  fi
else
  printf '  skip omarchy plugin validate (omarchy not installed)\n'
fi

finish
