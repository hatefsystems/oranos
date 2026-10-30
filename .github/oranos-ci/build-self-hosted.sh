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

# The source is fetched from Oranos GitHub, not Google's upstream.
# Blobless Git fetch retains commit/tree history and lazily obtains checkout blobs.
readonly ORANOS_REPO="https://github.com/hatefsystems/oranos.git"
readonly CI_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
readonly PROGRESS_FORMATTER="$CI_DIR/format-git-progress.py"
[[ -f "$PROGRESS_FORMATTER" ]] || fail "Missing Git progress formatter: $PROGRESS_FORMATTER"

git_progress() {
  local -a pipeline_status
  set +e
  "$@" 2>&1 | python3 -u "$PROGRESS_FORMATTER"
  pipeline_status=("${PIPESTATUS[@]}")
  set -e
  if (( pipeline_status[0] != 0 )); then
    return "${pipeline_status[0]}"
  fi
  return "${pipeline_status[1]}"
}

retry_source_fetch() {
  local attempt
  for attempt in 1 2 3; do
    echo "::group::GitHub source fetch (attempt $attempt/3)"
    if git_progress git -C "$SRC" fetch --no-tags --progress \
        --filter=blob:none origin "$SOURCE_SHA"; then
      echo "::endgroup::"
      return 0
    fi
    echo "::endgroup::"
    if (( attempt < 3 )); then
      echo "::warning::GitHub source fetch interrupted; preserving objects and retrying."
      sleep "$((attempt * 20))"
    fi
  done
  fail "GitHub source fetch failed after 3 attempts; no cache was deleted."
}

progress_heartbeat() {
  local started="$SECONDS"
  while sleep 30; do
    echo "[oranos-progress] UTC=$(date -u +%H:%M:%S) elapsed=$((SECONDS - started))s"
    du -sh "$SRC" "$GIT_CACHE_PATH" "$CIPD_CACHE_DIR" 2>/dev/null || true
    df -h "$CHECKOUT" | tail -1
  done
}
progress_heartbeat &
progress_pid=$!
trap 'kill "$progress_pid" 2>/dev/null || true' EXIT

if [[ ! -d "$SRC/.git" ]]; then
  echo "::notice::Initializing persistent Chromium source from Oranos GitHub."
  git init -q "$SRC"
fi
previous_origin="$(git -C "$SRC" remote get-url origin 2>/dev/null || true)"
case "$previous_origin" in
  "") git -C "$SRC" remote add origin "$ORANOS_REPO" ;;
  "$ORANOS_REPO") ;;
  "https://chromium.googlesource.com/chromium/src.git")
    echo "::notice::Migrating previously interrupted upstream origin to Oranos GitHub."
    git -C "$SRC" remote set-url origin "$ORANOS_REPO"
    ;;
  *) fail "Unexpected source origin: $previous_origin. Refusing to overwrite it." ;;
esac
git -C "$SRC" config remote.origin.promisor true
git -C "$SRC" config remote.origin.partialclonefilter blob:none

python3 - "$CHECKOUT/.gclient" "$ORANOS_REPO" "$GIT_CACHE_PATH" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
oranos = sys.argv[2]
git_cache = sys.argv[3]
upstream = "https://chromium.googlesource.com/chromium/src.git"
if path.exists():
    config = path.read_text()
    if '"name": "src"' not in config and "'name': 'src'" not in config:
        raise SystemExit("Unexpected .gclient solution; refusing to rewrite.")
    if upstream in config:
        config = config.replace(upstream, oranos, 1)
    elif oranos not in config:
        raise SystemExit("Unexpected .gclient source URL.")
else:
    config = 'solutions = [{"name": "src", "url": "' + oranos + '", "custom_deps": {}, "custom_vars": {}}]\n'
assignments = list(re.finditer(r"(?m)^[ \t]*target_os[ \t]*=[^\n]*$", config))
if len(assignments) > 1:
    raise SystemExit("Duplicate target_os assignments in .gclient.")
replacement = 'target_os = ["android", "linux"]'
if assignments:
    match = assignments[0]
    config = config[:match.start()] + replacement + config[match.end():]
else:
    config = config.rstrip() + "\n" + replacement + "\n"
if not re.search(r"(?m)^[ \t]*cache_dir[ \t]*=", config):
    config += 'cache_dir = "' + git_cache + '"\n'
path.write_text(config)
PY

if ! git -C "$SRC" cat-file -e "$SOURCE_SHA^{commit}" 2>/dev/null; then
  retry_source_fetch
else
  echo "::notice::Pinned commit already exists in persistent Git objects."
fi

echo "::group::Checkout pinned Oranos source"
git_progress git -C "$SRC" -c advice.detachedHead=false \
  checkout --progress --detach "$SOURCE_SHA"
echo "::endgroup::"
[[ "$(git -C "$SRC" rev-parse HEAD)" == "$SOURCE_SHA" ]] ||
  fail "Checkout did not select requested Oranos source SHA."

for attempt in 1 2 3; do
  echo "::group::Chromium dependencies (gclient sync attempt $attempt/3)"
  if ( cd "$CHECKOUT" && gclient sync --nohooks --revision "src@$SOURCE_SHA" ); then
    echo "::endgroup::"
    break
  fi
  echo "::endgroup::"
  if (( attempt == 3 )); then
    fail "gclient sync failed after 3 attempts; checkout and caches retained."
  fi
  echo "::warning::gclient sync interrupted; preserving dependencies and retrying."
  sleep "$((attempt * 20))"
done
[[ "$(git -C "$SRC" rev-parse HEAD)" == "$SOURCE_SHA" ]] ||
  fail "gclient moved source away from requested Oranos SHA."

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
