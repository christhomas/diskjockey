#!/usr/bin/env bash
# Shared helpers for github-guard guards. Source this file; it defines
# functions only and never exits the calling shell.
#
# Fail-open by design: a guard that blocks your work because gh/network/perms
# are unavailable is worse than the mistake it prevents. The local hard-block
# guards (merge commits) are the exception — they need no network.

# Echo the GitHub "owner/repo" slug for origin, or nothing if origin is missing
# or not on github.com.
gg_repo_slug() {
  local url rest host path
  url=$(git remote get-url origin 2>/dev/null) || return 0
  url=${url%.git}
  case "$url" in
    ssh://*|https://*|http://*)
      # scheme://[user@]host[:port]/owner/repo (incl. GitHub SSH-over-443,
      # ssh://git@ssh.github.com:443/owner/repo).
      rest=${url#*://}; rest=${rest#*@}
      host=${rest%%/*}; host=${host%%:*}
      path=${rest#*/}
      ;;
    *:*)
      # scp-style [user@]host:owner/repo (git@github.com:owner/repo).
      host=${url%%:*}; host=${host#*@}
      path=${url#*:}
      ;;
    *)
      return 0 ;;
  esac
  # Only claim a slug for a real GitHub host — never a substring match like
  # https://evil.com/github.com/owner/repo or ssh://git@github.com.example.org/…,
  # which would otherwise let the GitHub guards act on an unrelated repo.
  case "$host" in
    github.com|ssh.github.com) ;;
    *) return 0 ;;
  esac
  printf '%s' "$path"
}

# True if gh is installed and authenticated.
gg_have_gh() { command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; }

# Echo the authenticated GitHub login, or nothing.
gg_login() { gh api user --jq '.login' 2>/dev/null; }

# Return 0 only if the authenticated user OWNS this account: it is their
# personal account, or an org where their membership role is "admin" (owner).
# We change settings only on accounts we own — never other people's orgs, even
# where we happen to have repo-admin. A new org you create matches (you own it).
gg_user_owns() {
  local owner="$1" me role
  me=$(gg_login); [ -n "$me" ] || return 1
  [ "$owner" = "$me" ] && return 0
  role=$(gh api "user/memberships/orgs/$owner" --jq '.role' 2>/dev/null) || return 1
  [ "$role" = "admin" ]
}

# NOTE: deliberately no throttling. The network guards run only on commit/push
# — sparse, event-driven, a few calls each, nowhere near the 5000/hour API
# limit — so the ~1-2s they add to the occasional commit isn't worth a
# stamp-file/TTL mechanism.

# True if this repo keeps a changelog — a root CHANGELOG.md, or a "Changelog"
# (release notes / history) section in the root README.md. Guards that enforce
# changelog discipline self-gate on this: no changelog convention → they no-op,
# so projects without one are unaffected.
gg_has_changelog() {
  local root
  root=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
  [ -f "$root/CHANGELOG.md" ] && return 0
  [ -f "$root/README.md" ] \
    && grep -qiE '^#{2,}[[:space:]]+(change ?log|release notes|recent changes|releases|history)\b' "$root/README.md" \
    && return 0
  return 1
}

# --- Rust helpers (shared by the rust-* guards) ------------------------------

# True if the repo root holds a Cargo.toml (i.e. it's a Cargo project).
gg_is_rust() {
  local root
  root=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
  [ -f "$root/Cargo.toml" ]
}

# Run cargo via the rustup SHIM (`~/.cargo/bin/cargo`) so a repo's
# rust-toolchain.toml pin is honored automatically — local fmt/clippy then use
# the same toolchain as CI. A bare `cargo` can be Homebrew's, which ignores the
# pin entirely; the shim is the rustup proxy and respects it (installing the
# pinned toolchain on first use, as rustup intends). Falls back to whatever
# `cargo` is on PATH if the shim isn't present; returns 2 if there's no cargo
# at all (callers treat that as "skip, don't block").
gg_cargo() {
  local shim="$HOME/.cargo/bin/cargo"
  if [ -x "$shim" ]; then
    "$shim" "$@"
  elif command -v cargo >/dev/null 2>&1; then
    cargo "$@"
  else
    return 2
  fi
}

# --- chore (the task runner) --------------------------------------------------

# Echo the path to a usable `chore`, or nothing (return 1).
#
# WHY A SEARCH AND NOT JUST `command -v`. A git hook does not run with your
# login PATH. From a terminal `chore` is found; from Tower, VS Code or Xcode's
# source control, PATH is frequently cut back to /usr/bin:/bin:/usr/sbin:/sbin,
# and Homebrew's bin is not on it. A guard that forwards to `chore` would then
# do nothing at all, from the client a lot of commits are made with.
#
# It looks for a chore and STOPS THERE. It does NOT check the version: chore
# already refuses to run a file that needs a newer one, naming both versions
# and the fix —
#
#   chore: chore 0.6.0 is too old: <file> requires chore_min_version 99.0.0.
#     Upgrade with `brew upgrade chore`, or run an older copy of the file.
#
# — and diskjockey's chores.yml declares `chore_min_version`. A version test
# here would be a second, worse copy of that, and it would drift.
#
# Windows is deliberately not guessed at. These hooks run under macOS git for a
# macOS app; under Git Bash `command -v chore` already resolves chore.exe, and
# the `.exe` probe below covers a PATH-less MSYS shell without anyone inventing
# an install location they cannot test. No path here is speculative.
gg_chore_path() {
  local c d
  if c=$(command -v chore 2>/dev/null) && [ -n "$c" ]; then
    printf '%s' "$c"; return 0
  fi
  for d in /opt/homebrew/bin /usr/local/bin "$HOME/.local/bin" "$HOME/go/bin" \
           "$HOME/bin" /opt/local/bin /usr/bin; do
    [ -n "$d" ] || continue
    if [ -x "$d/chore" ]; then printf '%s' "$d/chore"; return 0; fi
    if [ -x "$d/chore.exe" ]; then printf '%s' "$d/chore.exe"; return 0; fi
  done
  return 1
}

# Print the standard "no chore anywhere" explanation on stderr.
#
# It lives here rather than in each guard so the brew line has ONE home. The
# caller prints its own first line saying what it could not do, then calls this.
#
# A caller must FAIL after this, never skip. common.sh is otherwise fail-open by
# design (see the header), and this is the documented exception alongside the
# merge-commit guards: a guard that shrugs stops doing its job and reports
# nothing, which is worse than the mistake it was written to prevent.
gg_chore_not_found() {
  echo "  This forwards to 'chore'. If you are committing from a GUI client, its PATH" >&2
  echo "  is probably /usr/bin:/bin:/usr/sbin:/sbin and Homebrew's bin is not on it." >&2
  echo "  Install it, or run the command from a terminal:" >&2
  echo "    brew install antimatter-studios/tap/chore" >&2
  echo "  See https://github.com/antimatter-studios/chore" >&2
}
