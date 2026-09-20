#!/usr/bin/env bash
# The source identity of the .app being assembled, as Info.plist keys.
#
# Printed into the plist by dev-app.sh and package-app.sh, and read back at runtime by
# `AppBuildStamp.current`. Without it the app cannot tell you it is behind: a bundle
# knows when it was assembled, but not WHAT it was assembled from, and a file mtime
# cannot answer "is this the commit main is on".
#
# It is a separate script rather than two heredocs because the two assemblers must
# never disagree about the keys — a stamp only the dev path writes is a stamp the
# runtime check has to treat as optional forever.
#
# Everything is best-effort: a tarball with no .git still builds, it just cannot be
# compared, and an empty commit makes the runtime check stand down rather than guess.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TOP="$(git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null || echo "$ROOT")"
SHA="$(git -C "$TOP" rev-parse HEAD 2>/dev/null || true)"
COMMIT_AT="$(git -C "$TOP" log -1 --format=%ct 2>/dev/null || true)"

# Dirty is scoped to apps/native: this stamp is about the app's own source, and a
# sibling agent editing the sidecar in the same tree must not make every bundle look
# hand-modified.
DIRTY=false
git -C "$TOP" diff --quiet HEAD -- apps/native 2>/dev/null || DIRTY=true

cat <<PLIST
  <key>JuancodeSourceRoot</key><string>${TOP}</string>
  <key>JuancodeSourceCommit</key><string>${SHA}</string>
  <key>JuancodeSourceCommitAt</key><string>${COMMIT_AT}</string>
  <key>JuancodeSourceDirty</key><${DIRTY}/>
  <key>JuancodeBundledAt</key><string>$(date +%s)</string>
PLIST
