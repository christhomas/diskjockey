#!/usr/bin/env bash
# guard: project-vendor-pins (diskjockey-local)
#
# Keeps VENDOR_PINS.txt true of the checkouts this app actually builds from,
# by REGENERATING it and STAGING it — not by complaining that it is stale.
#
# WHY IT REGENERATES ON EVERY COMMIT, where the old version had a trigger.
# The old guard fired only when a `vendor/` submodule gitlink was staged,
# because that was the one visible signal that a dependency had moved. The
# dependencies are SIBLING CHECKOUTS now (../rust-fs-ext4 and friends), and a
# sibling moving its HEAD stages nothing here — it leaves no signal in this
# repository at all. There is nothing left to key off, so the manifest is
# rebuilt each time and staged only when it actually changed.
#
# WHY A HOOK IS ALLOWED TO MODIFY AND STAGE A FILE.
# It changes what is committed after the author reviewed it, which for hand-
# written code would be indefensible. VENDOR_PINS.txt is generated output whose
# own first line says "Do not edit by hand" — the author never reviewed it as
# prose, and a manifest that disagrees with the checkouts is worse than one
# that arrives without being read. Do not "fix" this by making it read-only:
# complaining is what it used to do, and the complaint was silently wrong for
# every sibling-backed library.
#
# rust-fmt.sh in this directory is the precedent, and its caveat does not apply
# here. That guard re-stages only FULLY staged files, because `cargo fmt`
# rewrites whole files and a blind `git add` would sweep a developer's unstaged
# work into the commit. There is no work to sweep in a generated manifest: this
# file's entire content is derived, so overwriting it destroys nothing a person
# wrote.
#
# ONLY EVER `git add VENDOR_PINS.txt`. Naming the path is a standing rule here
# and a broad add has caused real incidents; a hook that stages by wildcard
# would sweep whatever the author had deliberately left out of this commit.
#
# It forwards to `chore pins` and holds no logic of its own. chores.yml has the
# one generator; scripts/check-vendor-pins.sh used to hold a second one, read
# submodule gitlinks the sibling move had left behind, and disagreed silently.
# That script is superseded and nothing calls it.
#
# Note `chore` runs this repo's `lifecycle.after_all`, so a commit also kicks
# off the detached cargo sweep. It is backgrounded and locked, so it does not
# slow the commit down, but it is a consequence of forwarding rather than an
# accident.
set -u
dir=$(cd "$(dirname "$0")/.." && pwd)   # .githooks/
# shellcheck source=../lib/common.sh
. "$dir/lib/common.sh"

root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
cd "$root" || exit 1

# The resolver lives in common.sh so seven guards do not each carry their own
# copy of a search path and a brew line. FAIL here, never skip: a permissive
# fallback means the manifest silently stops being regenerated, which is the
# failure this guard exists to prevent, and nothing would report it.
CHORE=$(gg_chore_path) || {
  echo "project-vendor-pins: cannot find 'chore', so VENDOR_PINS.txt cannot be regenerated." >&2
  gg_chore_not_found
  exit 1
}

PINS="VENDOR_PINS.txt"

# --- snapshot, so a bad regeneration can be put back exactly ------------------
snapshot=$(mktemp "${TMPDIR:-/tmp}/vendor-pins.XXXXXX") || exit 1
had_file=0
if [ -f "$PINS" ]; then had_file=1; cp "$PINS" "$snapshot"; fi
restore() {
  if [ "$had_file" = 1 ]; then cp "$snapshot" "$PINS"; else rm -f "$PINS"; fi
}
trap 'rm -f "$snapshot"' EXIT

# --- regenerate --------------------------------------------------------------
# stdout is captured rather than piped: reading an exit status through a pipe
# reads the pipe's last command, not the one that failed.
log=$(mktemp "${TMPDIR:-/tmp}/vendor-pins-log.XXXXXX") || exit 1
"$CHORE" pins >"$log" 2>&1
code=$?
if [ "$code" -ne 0 ]; then
  echo "project-vendor-pins: 'chore pins' failed (exit $code):" >&2
  cat "$log" >&2
  rm -f "$log"
  restore
  exit 1
fi
rm -f "$log"

# --- refuse to write an (absent) row over a real sha --------------------------
#
# `chore pins` reports what the checkout in front of it can answer for. In a
# clone with none of the sibling repositories — a contributor, a fresh CI-ish
# checkout — every row comes back "(absent)", and staging that would replace
# fourteen real pins with a record that this machine could not find them.
#
# Not a hard failure: a clone without the siblings is a legitimate place to
# commit from, and blocking every commit there would be hostile. The manifest
# is put back exactly as it was, which is the truthful outcome, and the reason
# is said out loud rather than skipped in silence.
absent=$(grep -c '(absent)' "$PINS")
if [ "${absent:-0}" -gt 0 ]; then
  echo "project-vendor-pins: $absent librar(y|ies) could not be resolved from this checkout," >&2
  echo "  so $PINS was left exactly as it was rather than overwritten with '(absent)'." >&2
  echo "  Unresolvable here:" >&2
  grep '(absent)' "$PINS" | awk '{print "    " $1}' >&2
  restore
  exit 0
fi

# --- stage, only if it actually moved ----------------------------------------
# Compared against the INDEX (`git show :<path>`), not the working tree: the
# question a pre-commit hook has to answer is what is about to be committed.
staged=$(mktemp "${TMPDIR:-/tmp}/vendor-pins-idx.XXXXXX") || exit 1
if git show ":$PINS" >"$staged" 2>/dev/null && cmp -s "$staged" "$PINS"; then
  rm -f "$staged"
  exit 0
fi
rm -f "$staged"

git add -- "$PINS" || {
  echo "project-vendor-pins: could not stage $PINS." >&2
  exit 1
}
echo "project-vendor-pins: $PINS regenerated and staged."

# MEASURED, on a throwaway repo, 2026-08-27: under `git commit -a` (and the
# same is true of `git commit <paths>`) git runs the hook against a TEMPORARY
# index and discards what the hook writes to it — `git status` afterwards shows
# the regenerated file as modified-not-staged, and that commit carries the old
# pins. It is picked up by the next ordinary `git commit`. The file on disk is
# correct either way, so nothing is lost; the manifest simply lags one commit
# for anyone who commits exclusively with -a.
exit 0
