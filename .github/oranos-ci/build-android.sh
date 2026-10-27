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
export DEPOT_TOOLS_UPDATE=0

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
./build/install-build-deps.sh --no-prompt
gclient runhooks

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
