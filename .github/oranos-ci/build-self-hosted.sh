#!/usr/bin/env bash
# Persistent, manually dispatched Chromium build on the trusted Oranos runner.
# Never run this script from untrusted pull-request code.
set -Eeuo pipefail

MODE="${1:-smoke}"
case "$MODE" in
  smoke|bootstrap|android|linux) ;;
  *) echo "Unsupported build mode: $MODE" >&2; exit 2 ;;
esac

fail() { echo "::error::$*" >&2; exit 1; }
require_mount() {
  local actual
  actual="$(findmnt -rn --target "$1" -o TARGET)" || fail "Missing filesystem for $1"
  [[ "$actual" == "$1" ]] || fail "$1 is not a dedicated mount (resolved: $actual)"
}
free_gib() {
  local available_kib
  available_kib="$(df -Pk "$1" | awk 'NR==2 {print $4}')"
  echo "$((available_kib / 1024 / 1024))"
}

readonly CHECKOUT="/srv/oranos/build/workspaces/chromium"
readonly SRC="$CHECKOUT/src"
readonly DEPOT_TOOLS="/var/lib/oranos-runner/depot_tools"
readonly GIT_CACHE_PATH="/var/cache/oranos/git"
readonly CIPD_CACHE_DIR="/var/cache/oranos/cipd"
readonly ARTIFACT_BASE="/srv/oranos/data/artifacts"
export GIT_CACHE_PATH CIPD_CACHE_DIR

[[ "$(id -un)" == "oranos-runner" ]] || fail "Run as oranos-runner, never root."
require_mount /srv/oranos/build
require_mount /srv/oranos/data
for dir in "$CHECKOUT" "$GIT_CACHE_PATH" "$CIPD_CACHE_DIR"   /var/lib/oranos-runner/work "$ARTIFACT_BASE"; do
  [[ -d "$dir" && -w "$dir" ]] || fail "Missing or unwritable directory: $dir"
done
[[ "$(readlink -f "$CHECKOUT")" == /srv/oranos/build/* ]] ||
  fail "Chromium checkout is not on its dedicated SSD."
[[ "$(readlink -f "$GIT_CACHE_PATH")" == /var/cache/oranos/* ]] ||
  fail "Git cache is not on the OS SSD."
[[ "$(readlink -f "$CIPD_CACHE_DIR")" == /var/cache/oranos/* ]] ||
  fail "CIPD cache is not on the OS SSD."

echo "Runner: ${RUNNER_NAME:-local} / mode: $MODE"
df -hT / /srv/oranos/build /srv/oranos/data
echo "Free source/build SSD: $(free_gib /srv/oranos/build) GiB"
echo "Free OS/cache SSD: $(free_gib /) GiB"

if [[ "$MODE" == smoke ]]; then
  echo "Smoke test passed. No checkout, download or build performed."
  exit 0
fi

SOURCE_SHA="${BUILD_SOURCE_SHA:?BUILD_SOURCE_SHA must contain the full source commit SHA}"
[[ "$SOURCE_SHA" =~ ^[a-f0-9]{40}$ ]] || fail "Invalid 40-character Git SHA."
for cmd in git python3 curl df findmnt; do
  command -v "$cmd" >/dev/null || fail "Missing required command: $cmd"
done

# A prior fetch may create .gclient before it ever creates src.
# Reuse it on the next attempt without deleting any source or cache.
if [[ ! -d "$SRC/.git" ]]; then
  [[ ! -e "$SRC" ]] ||
    fail "src exists without .git; inspect manually. CI will not delete data."
  (( $(free_gib /srv/oranos/build) >= 100 )) ||
    fail "Initial Chromium checkout requires >=100 GiB free on build SSD."
  (( $(free_gib /) >= 15 )) ||
    fail "Initial Git/CIPD cache requires >=15 GiB free on OS SSD."
else
  git -C "$SRC" rev-parse --is-inside-work-tree >/dev/null ||
    fail "Existing checkout is invalid; refusing to reset it."
  [[ "$(git -C "$SRC" rev-parse --show-toplevel)" == "$SRC" ]] ||
    fail "Unexpected Git checkout root; inspect it manually."
  (( $(free_gib /srv/oranos/build) >= 15 )) ||
    fail "Less than 15 GiB free on build SSD."
  (( $(free_gib /) >= 5 )) ||
    fail "Less than 5 GiB free on OS/cache SSD."
fi

if [[ ! -d "$DEPOT_TOOLS/.git" ]]; then
  [[ ! -e "$DEPOT_TOOLS" ]] || fail "Incomplete depot_tools: $DEPOT_TOOLS"
  git clone --depth=1 https://chromium.googlesource.com/chromium/tools/depot_tools.git "$DEPOT_TOOLS"
fi
export PATH="$PATH:$DEPOT_TOOLS"

if [[ ! -d "$SRC/.git" ]]; then
  ( cd "$CHECKOUT" && fetch --nohooks --git-cache android )
fi

# Reuse a single checkout for Android and Linux. The Android checkout includes
# Linux host dependencies; target_os makes both sets explicit for future syncs.
# The initial Android fetch may already define target_os. Configure both
# platforms without appending a duplicate assignment, and make the fork the
# authoritative solution source for subsequent pinned gclient syncs.
python3 - "$CHECKOUT/.gclient" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
config = path.read_text()
upstream = "https://chromium.googlesource.com/chromium/src.git"
oranos = "https://github.com/hatefsystems/oranos.git"
if upstream in config:
    config = config.replace(upstream, oranos, 1)
elif oranos not in config:
    raise SystemExit("Unexpected Chromium solution URL in .gclient")
assignments = list(re.finditer(r"(?m)^[ \t]*target_os[ \t]*=[^\n]*$", config))
if len(assignments) > 1:
    raise SystemExit("Duplicate target_os assignments in .gclient")
replacement = 'target_os = ["android", "linux"]'
if assignments:
    match = assignments[0]
    config = config[:match.start()] + replacement + config[match.end():]
else:
    config = config.rstrip() + "\n" + replacement + "\n"
path.write_text(config)
PY

git -C "$SRC" remote set-url origin https://github.com/hatefsystems/oranos.git

if ! git -C "$SRC" remote get-url oranos >/dev/null 2>&1; then
  git -C "$SRC" remote add oranos https://github.com/hatefsystems/oranos.git
fi
[[ "$(git -C "$SRC" remote get-url oranos)" ==    "https://github.com/hatefsystems/oranos.git" ]] ||
   fail "Unexpected oranos Git remote."

# Do not use a moving ref for source provenance. Preserve shared Git history.
git -C "$SRC" fetch --no-tags oranos "$SOURCE_SHA"
git -C "$SRC" checkout --detach "$SOURCE_SHA"
( cd "$CHECKOUT" && gclient sync --nohooks --revision "src@$SOURCE_SHA" )
[[ "$(git -C "$SRC" rev-parse HEAD)" == "$SOURCE_SHA" ]] ||
  fail "gclient moved the source away from the requested Oranos SHA."

# Chromium's build timestamp requires real Gerrit commit-position metadata.
metadata_time() {
  git -C "$SRC" log -1 --format='%ct' --grep="^$1:" HEAD
}
valid_time() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( $1 > 946684800 ))
}
change_time="$(metadata_time Change-Id)"
position_time="$(metadata_time Cr-Commit-Position)"
valid_time "$change_time" && valid_time "$position_time" ||
  fail "Required Gerrit commit metadata missing; refusing a synthetic build timestamp."

if [[ "$MODE" == bootstrap ]]; then
  echo "Checkout ready at $SRC"
  echo "Next, run once as root: $SRC/build/install-build-deps.sh --no-prompt"
  echo "Then manually dispatch android or linux. CI will never run apt/sudo."
  exit 0
fi

( cd "$SRC" && gclient runhooks )
lastchange="$SRC/build/util/LASTCHANGE.committime"
[[ -s "$lastchange" ]] || fail "Missing Chromium LASTCHANGE.committime."
timestamp="$(cat "$lastchange")"
valid_time "$timestamp" || fail "Invalid Chromium LASTCHANGE.committime: $timestamp"

readonly JOBS="${ORANOS_BUILD_JOBS:-4}"
[[ "$JOBS" =~ ^[1-9][0-9]?$ ]] || fail "Invalid job count: $JOBS"
readonly RUN_ID="${GITHUB_RUN_ID:?Missing GitHub run ID}"
readonly RUN_ATTEMPT="${GITHUB_RUN_ATTEMPT:?Missing GitHub run attempt}"
[[ "$RUN_ID" =~ ^[0-9]+$ && "$RUN_ATTEMPT" =~ ^[0-9]+$ ]] ||
  fail "Invalid run identifiers."
readonly ARTIFACT_DIR="$ARTIFACT_BASE/oranos-$RUN_ID-$RUN_ATTEMPT"
mkdir -p "$ARTIFACT_DIR"
cd "$SRC"

case "$MODE" in
  android)
    gn gen out/oranos-android --args='target_os="android" target_cpu="arm64" is_debug=false is_component_build=false symbol_level=0 use_remoteexec=false'
    autoninja -C out/oranos-android -j "$JOBS" chrome_public_apk
    apk="out/oranos-android/apks/ChromePublic.apk"
    [[ -s "$apk" ]] || fail "Expected Android APK missing: $apk"
    cp "$apk" "$ARTIFACT_DIR/ChromePublic-arm64.apk"
    ;;
  linux)
    gn gen out/oranos-linux --args='target_os="linux" target_cpu="x64" is_debug=false is_component_build=false symbol_level=0 use_remoteexec=false'
    autoninja -C out/oranos-linux -j "$JOBS" chrome
    binary="out/oranos-linux/chrome"
    [[ -s "$binary" ]] || fail "Expected Linux chrome executable missing: $binary"
    cp "$binary" "$ARTIFACT_DIR/chrome-linux-x64"
    printf '%s\n'       'Development binary only. It is NOT a standalone Linux package.'       'Resources, libraries and a distribution-specific packaging step may be required.'       > "$ARTIFACT_DIR/LINUX-ARTIFACT-NOTE.txt"
    ;;
esac

printf 'repository=hatefsystems/oranos\nsource_sha=%s\ntarget=%s\nrunner=%s\nrelease_signed=false\n'   "$SOURCE_SHA" "$MODE" "${RUNNER_NAME:-unknown}" > "$ARTIFACT_DIR/build-info.txt"
case "$MODE" in
  android) ( cd "$ARTIFACT_DIR" && sha256sum ChromePublic-arm64.apk > SHA256SUMS.txt ) ;;
  linux) ( cd "$ARTIFACT_DIR" && sha256sum chrome-linux-x64 > SHA256SUMS.txt ) ;;
esac
echo "Artifacts: $ARTIFACT_DIR"
