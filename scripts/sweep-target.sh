#!/usr/bin/env bash
# Reap stale cargo artifacts, across this repo AND every sibling it builds.
# Detached, locked per-root, parallel, and refuses to touch a root with a live
# build under it.
#
# WHY. cargo never removes anything: each build emits codegen-unit objects named
# by a content hash and leaves the previous set forever. Measured on a five-crate
# project, target/debug/deps held 14,312 files. Left alone this filled a 238 GB
# volume. `cargo clean` is the WRONG tool — it removes what the last build
# produced, so the next build is cold. `cargo sweep --time N` takes only what
# nothing has touched for N days.
#
# SIBLINGS. Since the migration to `includes:`, the artifacts are built in
# ../rust-* rather than here, so sweeping $ROOT alone would reap nothing that
# matters. The list is DERIVED from chores.yml's includes so it cannot drift
# from what actually gets built.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DAYS="${DISKJOCKEY_SWEEP_DAYS:-7}"
LOCKDIR="${TMPDIR:-/tmp}"

# One root per line: this repo, plus each sibling chores.yml actually includes.
roots() {
  printf '%s\n' "$ROOT"
  sed -n 's/^[[:space:]]*taskfile:[[:space:]]*\(\.\.\/[^[:space:]]*\).*/\1/p' "$ROOT/chores.yml" 2>/dev/null |
    while IFS= read -r rel; do
      [ -n "$rel" ] || continue
      ( cd "$ROOT/$rel" 2>/dev/null && pwd ) || true
    done
}

# Sweep one root. Locked by PATH, not by project: two consumers sharing a
# sibling must not sweep it at once.
sweep_one() {
  local dir="$1"
  [ -d "$dir" ] || return 0
  local key lock
  key=$(printf '%s' "$dir" | shasum -a 256 | cut -c1-12)
  lock="$LOCKDIR/cargo-sweep-$key.lock"

  # mkdir is the atomic primitive: macOS has no flock(1), and a lockfile written
  # with `>` is not atomic.
  mkdir "$lock" 2>/dev/null || return 0
  # NOT `exec` below: exec replaces the shell, the EXIT trap never fires, the
  # lock leaks, and every later sweep exits early as "already running" — the
  # reaper silently stops reaping. Found by testing, not by reading.
  # DOUBLE quotes: $lock must expand NOW. Single-quoted, it expands when the
  # trap fires — by which time `local lock` is out of scope, and under `set -u`
  # every subshell dies with "lock: unbound variable" while the script still
  # exits 0 and leaks every lock. Measured, 14 of 14.
  trap "rmdir '$lock' 2>/dev/null || true" EXIT

  # Never sweep under a live build. Match the resolved binary and its cwd —
  # `pgrep -f cargo` also matches any shell that merely MENTIONS the word,
  # including the one asking. cargo AND rustc: `cargo tauri dev` execs
  # cargo-tauri, and rustc is what holds artifacts open.
  local pid cwd
  for pid in $(pgrep -x cargo 2>/dev/null || true) $(pgrep -x rustc 2>/dev/null || true); do
    cwd=$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' || true)
    case "$cwd" in "$dir"*) return 0 ;; esac
  done

  # --hidden is load-bearing: --recursive SKIPS any directory beginning with a
  # dot, and agent worktrees live in .claude/worktrees/. That was 8.1 GB of
  # trove's 56 GB — the largest single category — and without this flag the
  # sweep walks past it while reporting success.
  cargo sweep --time "$DAYS" --recursive --hidden "$dir" >/dev/null 2>&1 || true
}

# Parallel: each root is independent and holds its own lock. Subshells so one
# root's trap cannot clear another's lock.
while IFS= read -r d; do
  [ -n "$d" ] || continue
  ( sweep_one "$d" ) &
done < <(roots | sort -u)
wait
