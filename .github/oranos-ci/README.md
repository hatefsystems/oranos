# Oranos Android CI on Standard GitHub-hosted Runners

**Status:** CI validation and runner resource probe. A full Android APK build is not yet verified.

## Where CI lives

The browser build workflow is located in the browser source repository:

- Workflow: [`.github/workflows/android-apk.yml`](../workflows/android-apk.yml)
- Build script: [`.github/oranos-ci/build-android.sh`](build-android.sh)
- Documentation repository: https://github.com/hatefsystems/oranos-docs

The fork's `main` branch is the product integration branch. The `chromium-upstream` branch remains a clean Chromium mirror and **must not be modified by Oranos CI**.

## Runner and current feasibility

The workflow uses `runs-on: ubuntu-24.04`, which is a **standard GitHub-hosted runner**. No self-hosted runner is required.

According to GitHub, standard public-repository Ubuntu runners offer approximately **4 CPU cores, 16 GB RAM, and 14 GB SSD**. Chromium's official Android build guide requires **at least 100 GB of free disk**. Consequently, a full Chromium APK **cannot be reasonably expected to build** on this standard runner.

The Android job prints actual free disk/RAM and **fails before fetching Chromium** if free disk is below the documented 100 GiB requirement. This avoids exhausting the runner mid-checkout. This is an intentional, explainable failure, not a claim of APK success.

- GitHub runner specs: https://docs.github.com/en/actions/reference/runners/github-hosted-runners
- Chromium Android build requirements: https://chromium.googlesource.com/chromium/src/+/main/docs/android_build_instructions.md

## Triggers

- **Pull request modifying the CI files:** validate only.
- **Push to `main` modifying the CI files:** validate, then run the capacity check and attempt the build only if it passes.
- **Actions > Android APK (standard GitHub runner) > Run workflow:** same as the push path, building the triggering source commit.

The build uses `github.sha` and is intended to fetch that specific revision from the Oranos fork. A successful build produces `ChromePublic-arm64.apk`, SHA256SUMS and build-info as downloadable workflow artifacts.

## What to do if GitHub Actions are disabled

GitHub can disable Actions in a newly created fork. Open https://github.com/hatefsystems/oranos/actions and enable Actions for the repository if GitHub offers that step.

## Future production build

To produce an actual APK, choose a GitHub-hosted runner with adequate resources (a larger runner where eligible) **or** a supported remote build infrastructure. Before public release, pin a Chromium stable base, add Oranos branding, sign the APK securely, and run Android device tests.

Do not interpret a passing validation job as a browser build. No Chromium APK is produced by CI validation.
