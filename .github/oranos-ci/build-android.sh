#!/usr/bin/env bash
# Build the Chromium public Android APK from an EXACT Oranos source commit.
# This is a development build. It is NOT Oranos-branded or release-signed.
set -Eeuo pipefail

WORKSPACE="${1:?Usage: build-android.sh WORKSPACE SOURCE_COMMIT_SHA}"
SOURCE_SHA="${2:?Usage: build-android.sh WORKSPACE SOURCE_COMMIT_SHA}"
if [[ ! "$SOURCE_SHA" =~ ^[a-f0-9]{40}$ ]]; then
  echo "::error::Expected an exact 40-character source commit SHA." >&2
  exit 2
fi

if [[ -e "$WORKSPACE/src" || -e "$WORKSPACE/.gclient" ]]; then
  echo "::error::Build checkout already exists. Start with a clean workspace." >&2
  exit 2
fi

mkdir -p "$WORKSPACE"
git clone --depth=1 https://chromium.googlesource.com/chromium/tools/depot_tools.git "$RUNNER_TEMP/depot_tools"
export PATH="$PATH:$RUNNER_TEMP/depot_tools"

cd "$WORKSPACE"
fetch --nohooks --no-history android
cd src

git remote add oranos https://github.com/hatefsystems/oranos.git
# Pull only the commit used to start this workflow, not a moving branch HEAD.
git fetch --no-tags --depth=1 oranos "$SOURCE_SHA"
git checkout --detach "$SOURCE_SHA"

# Synchronize DEPS to the commit under test.
gclient sync --nohooks --revision "src@$SOURCE_SHA"
test "$(git rev-parse HEAD)" = "$SOURCE_SHA"

# Chromium's build/util/lastchange.py needs an ancestor containing Gerrit
# Change-Id and Cr-Commit-Position footers. Both --no-history and --depth=1
# can hide those commits, causing LASTCHANGE.committime=0 and a negative
# build timestamp (-2142000), which breaks DevTools Node.js generators.
get_metadata_timestamp() {
  local footer="$1"
  git log -1 --format='%ct' --grep="^$footer:" HEAD
}

metadata_is_valid() {
  local change_time position_time
  change_time="$(get_metadata_timestamp Change-Id)"
  position_time="$(get_metadata_timestamp Cr-Commit-Position)"
  [[ "$change_time" =~ ^[0-9]+$ ]] &&
    [[ "$position_time" =~ ^[0-9]+$ ]] &&
    (( change_time > 946684800 && position_time > 946684800 ))
}

if ! metadata_is_valid; then
  for deepen_by in 16 64 256 512; do
    if [[ "$(git rev-parse --is-shallow-repository)" != true ]]; then
      break
    fi
    echo "Chromium commit metadata not visible; deepening checkout by $deepen_by commits."
    git fetch --no-tags --deepen="$deepen_by" oranos "$SOURCE_SHA"
    if metadata_is_valid; then
      break
    fi
  done
fi

if ! metadata_is_valid; then
  echo "::error::Missing valid Chromium Change-Id or Cr-Commit-Position history after deepening. Refusing to generate LASTCHANGE.committime=0." >&2
  exit 1
fi
test "$(git rev-parse HEAD)" = "$SOURCE_SHA"
echo "Chromium Change-Id commit time: $(get_metadata_timestamp Change-Id)"
echo "Chromium Cr-Commit-Position commit time: $(get_metadata_timestamp Cr-Commit-Position)"

./build/install-build-deps.sh --no-prompt
gclient runhooks

# Guard against fallback timestamps even if upstream hook behavior changes.
if [[ ! -s build/util/LASTCHANGE.committime ]]; then
  echo "::error::Missing generated LASTCHANGE.committime." >&2
  exit 1
fi
lastchange_timestamp="$(<build/util/LASTCHANGE.committime)"
if [[ ! "$lastchange_timestamp" =~ ^[0-9]+$ ]] ||
   (( lastchange_timestamp <= 946684800 )); then
  echo "::error::Invalid LASTCHANGE.committime=$lastchange_timestamp; refusing a negative build timestamp." >&2
  exit 1
fi
echo "Validated Chromium LASTCHANGE.committime=$lastchange_timestamp"

gn gen out/oranos-android --args='target_os="android" target_cpu="arm64" is_debug=false is_component_build=false symbol_level=0 use_remoteexec=false'
autoninja -C out/oranos-android -j 4 chrome_public_apk

APK="out/oranos-android/apks/ChromePublic.apk"
if [[ ! -s "$APK" ]]; then
  echo "::error::Missing ChromePublic.apk after successful build." >&2
  find out/oranos-android -name '*.apk' -type f -print || true
  exit 1
fi

mkdir -p "$WORKSPACE/artifacts"
cp "$APK" "$WORKSPACE/artifacts/ChromePublic-arm64.apk"
printf 'repository=hatefsystems/oranos\nsource_sha=%s\ntarget=chrome_public_apk\nrelease_signed=false\n' "$SOURCE_SHA" > "$WORKSPACE/artifacts/build-info.txt"
(cd "$WORKSPACE/artifacts" && sha256sum ChromePublic-arm64.apk > SHA256SUMS.txt)
