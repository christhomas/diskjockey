#!/bin/sh
#
# build-gonetworkfs.sh — put the go-networkfs c-archives where the app links
# them.
#
# WHAT CHANGED, AND WHY THIS IS NOW SHORT
#
# This used to carry the build itself: 258 lines that knew Go's flags, the
# driver list, the c-archive invocation and its own stamp-file staleness
# scheme. All of that is knowledge about how to build go-networkfs, and it
# belongs to go-networkfs — which now states it, in its own chores.yml, as
# `chore archives` (build every driver plus the combined dispatcher) and
# `chore artifact` (say where they landed). The same contract every sibling
# Rust crate publishes.
#
# So this script no longer builds anything. It locates the source, asks it to
# build, and copies what it points at. When the driver list or a Go flag
# changes, it changes once, there, and every consumer follows.
#
# WHERE THE SOURCE COMES FROM
#
# A sibling checkout, not a vendored submodule. The submodule was a second
# copy of a repository already on disk — 146 MB of it — and a checkout shared
# with every other project that wants it is the point of the move. Override
# with NETWORKFS_SRC when it lives somewhere else.
#
# Because the source is no longer pinned by a submodule gitlink, WHICH COMMIT
# BUILT THESE ARCHIVES IS NO LONGER RECORDED BY GIT. The version manifest at
# the end is therefore load-bearing rather than a nicety: it is the only
# record of what went into the binary, and it marks a dirty tree.
set -e

SRCROOT="${SRCROOT:-$(pwd)}"
SRCROOT="$(cd "${SRCROOT}" && pwd)"

# Default to the sibling checkout beside this repository.
NETWORKFS_SRC="${NETWORKFS_SRC:-${SRCROOT}/../go-networkfs}"
NETWORKFS_OUT="${NETWORKFS_OUT:-${SRCROOT}/lib/go-networkfs}"
case "$NETWORKFS_SRC" in /*) ;; *) NETWORKFS_SRC="${SRCROOT}/${NETWORKFS_SRC}" ;; esac
case "$NETWORKFS_OUT" in /*) ;; *) NETWORKFS_OUT="${SRCROOT}/${NETWORKFS_OUT}" ;; esac

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [ ! -f "${NETWORKFS_SRC}/go.mod" ]; then
    echo "${RED}ERROR: no go-networkfs at ${NETWORKFS_SRC}${NC}" >&2
    echo "" >&2
    echo "It is a sibling checkout now, not a submodule. Clone it beside this" >&2
    echo "repository, or point NETWORKFS_SRC at an existing one:" >&2
    echo "" >&2
    echo "  git clone https://github.com/christhomas/go-networkfs $(dirname "${SRCROOT}")/go-networkfs" >&2
    echo "  make vendor-gonetworkfs NETWORKFS_SRC=/path/to/go-networkfs" >&2
    exit 1
fi

if ! command -v chore >/dev/null 2>&1; then
    echo "${RED}ERROR: chore is not installed, and it owns the build now.${NC}" >&2
    exit 1
fi

if [ ! -f "${NETWORKFS_SRC}/chores.yml" ]; then
    echo "${RED}ERROR: ${NETWORKFS_SRC} has no chores.yml${NC}" >&2
    echo "That checkout predates the chore migration; update it." >&2
    exit 1
fi

printf "\n%bBuilding go-networkfs archives via chore%b\n" "${YELLOW}" "${NC}"
echo "  source: ${NETWORKFS_SRC}"

# `chore archives` is idempotent — it fingerprints its own sources and says
# "up to date" without rebuilding, which is what replaced the stamp files
# this script used to keep.
( cd "${NETWORKFS_SRC}" && chore archives )

# Asked, not assumed: `artifact` is a value-returning task, and a consumer
# that hardcoded `dist/` would break the moment that crate reorganised.
DIST="$( cd "${NETWORKFS_SRC}" && chore artifact )"
if [ ! -d "${DIST}" ]; then
    echo "${RED}ERROR: chore artifact named ${DIST}, which is not a directory${NC}" >&2
    exit 1
fi

mkdir -p "${NETWORKFS_OUT}"
# Copy the CONTENTS, not the directory — `artifact` prints a directory
# precisely because there is more than one file to take.
cp "${DIST}"/*.a "${DIST}"/*.h "${NETWORKFS_OUT}/"
COPIED=$(ls -1 "${NETWORKFS_OUT}"/*.a 2>/dev/null | wc -l | tr -d ' ')

emit_version_manifest() {
    local lib_name="$1"
    local src_dir="$2"
    local out_file="$3"

    (
        cd "$src_dir"

        local source commit short_commit describe dirty ref ref_type commit_date

        source=$(git config --get remote.origin.url 2>/dev/null || echo "unknown")
        commit=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
        short_commit=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
        describe=$(git describe --always --long --dirty 2>/dev/null || echo "$short_commit")

        if [ -z "$(git status --porcelain 2>/dev/null)" ]; then
            dirty="false"
        else
            dirty="true"
        fi

        if tag=$(git describe --tags --exact-match 2>/dev/null); then
            ref="$tag"
            ref_type="tag"
        elif branch=$(git symbolic-ref --short -q HEAD 2>/dev/null); then
            ref="$branch"
            ref_type="branch"
        else
            ref="HEAD"
            ref_type="detached"
        fi

        # Commit date (ISO 8601 with timezone) — identifies the source, not the
        # local build time. Parseable by Swift's ISO8601DateFormatter.
        commit_date=$(git log -1 --format=%cI 2>/dev/null || echo "unknown")

        {
            echo "lib=${lib_name}"
            echo "source=${source}"
            echo "ref=${ref}"
            echo "ref_type=${ref_type}"
            echo "commit=${commit}"
            echo "short_commit=${short_commit}"
            echo "describe=${describe}"
            echo "dirty=${dirty}"
            echo "commit_date=${commit_date}"
        } > "$out_file"
    )
}


emit_version_manifest "go-networkfs" "${NETWORKFS_SRC}" "${NETWORKFS_OUT}/VERSION-go-networkfs.txt"

echo ""
printf "%bgo-networkfs ready (%s archive(s))%b\n" "${GREEN}" "${COPIED}" "${NC}"
echo "  Output:   ${NETWORKFS_OUT}/"
echo "  Manifest: ${NETWORKFS_OUT}/VERSION-go-networkfs.txt"
