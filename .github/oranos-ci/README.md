# Oranos Chromium CI: persistent self-hosted builder

**Status:** CI configuration implemented; a full Android or Linux build has not
yet been verified on `oranos-build-01`.

The Oranos source repository has two deliberately separate workflows:

| Workflow | Trigger | Runner | Purpose |
| --- | --- | --- | --- |
| [CI validation](../workflows/android-apk.yml) | PR, targeted push, manual | GitHub-hosted Ubuntu | Validate scripts safely without compiling Chromium |
| [Self-hosted Chromium](../workflows/self-hosted-chromium.yml) | Manual, `main` only | `oranos-build-01` | Persistent checkout, bootstrap, Android or Linux build |
| [Bootstrap validation](../workflows/validate-bootstrap.yml) | PR / targeted push | GitHub-hosted Ubuntu | Bash syntax and live Git progress formatter tests |

No `pull_request` or `push` event can schedule a job on the home runner from
these workflows. The home runner still executes arbitrary code from the trusted
repository revision; only trusted maintainers should be permitted to alter or
manually dispatch its workflows. For stronger isolation, move execution to a
private orchestration repository with a dedicated runner.

The product development branch is `main`. The clean `chromium-upstream` mirror
must never be updated or force-reset by these workflows.

## Required host storage layout

| Component | Path | Physical storage |
| --- | --- | --- |
| Ubuntu, runner binary | `/`, `/opt/actions-runner` | 112 GB OS SSD |
| Runner work | `/var/lib/oranos-runner/work` | 112 GB OS SSD |
| Shared Git cache | `/var/cache/oranos/git` | 112 GB OS SSD |
| CIPD cache | `/var/cache/oranos/cipd` | 112 GB OS SSD |
| Shared Chromium checkout | `/srv/oranos/build/workspaces/chromium` | 250 GB build SSD |
| Android output | `src/out/oranos-android` | 250 GB build SSD |
| Linux output | `src/out/oranos-linux` | 250 GB build SSD |
| Build archives | `/srv/oranos/data/artifacts` | 2 TB HDD |
| Nexus application data | `/srv/oranos/data/nexus` | 2 TB HDD |

The checkout and `out` directories share one ext4 filesystem. **Do not use the
old HDD-to-SSD bind mount** at
`/srv/oranos/data/workspaces/android/src/out`: the checkout now lives on the
build SSD itself.

Provision directories as root after verifying the physical mounts:

```bash
findmnt /
findmnt /srv/oranos/build
findmnt /srv/oranos/data

id oranos-runner || sudo useradd -m -s /bin/bash oranos-runner

sudo install -d -o oranos-runner -g oranos-runner \
  /opt/actions-runner \
  /var/lib/oranos-runner \
  /var/lib/oranos-runner/work \
  /var/cache/oranos/git \
  /var/cache/oranos/cipd \
  /srv/oranos/build/workspaces/chromium \
  /srv/oranos/data/artifacts
```

The existing runner registration can retain `--work _work` provided
`/opt/actions-runner/_work` resolves to
`/var/lib/oranos-runner/work`. Do not blindly replace an active work
directory: inspect and migrate it safely if necessary.

In the runner's systemd override, use:

```ini
[Unit]
RequiresMountsFor=/srv/oranos/build /srv/oranos/data
```

Apply the override with `systemctl daemon-reload` and restart the actual
`actions.runner.*.service` service. The build script independently checks
both mounts to fail closed if storage is unavailable.

Required system commands include Git, Python 3, curl, tar, unzip and other
standard Chromium prerequisites. The long-lived runner runs as
`oranos-runner`, **without passwordless sudo or Docker group membership**.

The runner must have the labels `self-hosted`, `Linux`, `X64` and
`oranos-android`. The same physical runner performs Linux builds serially.

## First-time operation: three stages

The workflow is available under **GitHub Actions → Oranos Self-hosted
Chromium → Run workflow** once merged into the default branch.

1. Dispatch **`smoke`**. It checks the runner user, mount points,
   writable directories and disk capacity. It does not download anything.
2. Dispatch **`bootstrap`**. It reuses persistent `depot_tools` under
   `/var/lib/oranos-runner/depot_tools`, initializes the source Git repository
   directly from `https://github.com/hatefsystems/oranos.git`, fetches the
   exact workflow commit with `--filter=blob:none`, checks out the source
   and runs a DEPS-pinned `gclient sync --nohooks`. A prior `.gclient`-only
   checkout is recovered automatically. Git progress is streamed to Actions,
   with a 30-second heartbeat reporting source and cache disk usage.
   The initial checkout and dependency sync may still take many hours.
3. On the build host, **once after bootstrap**, install Chromium OS
   dependencies as an administrator:

   ```bash
   sudo /srv/oranos/build/workspaces/chromium/src/build/install-build-deps.sh --no-prompt
   ```

   Review the package changes before proceeding, particularly on a machine
   that also hosts Nexus. These privileged commands are deliberately **not
   run by CI**. If Chromium upgrades require additional packages, rerun as
   an administrator.

Then dispatch **`android`** or **`linux`**. Both reuse the same checkout and
Git/CIPD caches, synchronize to the workflow's **exact `github.sha`**, run
Chromium hooks and compile a development target.

| Mode | Build command | Artifact |
| --- | --- | --- |
| `android` | `autoninja -C out/oranos-android -j 4 chrome_public_apk` | `ChromePublic-arm64.apk` |
| `linux` | `autoninja -C out/oranos-linux -j 4 chrome` | `chrome-linux-x64` (not standalone) |

The Android APK is **unbranded and unsigned for release**. The Linux binary
alone is **not a portable distro package**; it may require resource files,
libraries and packaging before distribution. Both artifacts include source SHA
provenance and SHA-256 digests. GitHub Actions also uploads the artifacts for
seven days; the HDD copy remains until explicitly removed.

Only one run uses the persistent checkout at a time. Do not change the
checkout's Git branch, use `git clean -fdx`, or delete `out` from another
shell while a job is running.

## Troubleshooting and resource policy

- The source/build SSD has about 234 GiB usable capacity. The checkout and two
  full GN output directories may not fit simultaneously. Prefer **one build
  target at a time**, archive older outputs to HDD, and monitor disk usage.
- The OS SSD contains the shared Git cache for Chromium dependencies, CIPD,
  and runner work. The Oranos source's partial Git object store resides on
  the build SSD. The script refuses an initial checkout with less than
  15 GiB free on the OS SSD or 100 GiB free on the build SSD.
- Do not rely on Nexus as a universal Chromium cache. `GIT_CACHE_PATH`,
  `CIPD_CACHE_DIR` and a persistent `src` directory are still necessary.
- The script never deletes partial checkouts or caches automatically. A previous
  `.gclient` file with no `src`, or an existing valid Git repository, can be
  reused. Git/gclient network operations retry up to three times. A directory
  `src` without a valid `.git` still requires manual inspection to avoid
  overwriting valuable data. Git object progress is NOT a precise measure of
  total bootstrap bytes, and incomplete Git packfiles may need retransmission.
- Chromium metadata must include valid `Change-Id:` and
  `Cr-Commit-Position:` ancestry to avoid the historical negative
  `--build-timestamp` failure.
- GitHub-hosted CI validates the scripts but **does not prove** the host
  installation, network reachability, full compile or resulting APK works.
- The main Oranos source now comes from GitHub, but Chromium DEPS, depot_tools,
  Google storage and CIPD still require network access. Initial bootstrap is
  online; fully offline builds require warmed caches and additional testing.

## Source references

- Android: https://chromium.googlesource.com/chromium/src/+/main/docs/android_build_instructions.md
- Linux: https://chromium.googlesource.com/chromium/src/+/main/docs/linux/build_instructions.md
- GitHub runner security: https://docs.github.com/en/actions/security-for-github-actions/security-guides/security-hardening-for-github-actions

Previous hosted workflow and historical timestamp failure:
https://github.com/hatefsystems/oranos/actions/runs/40555019512/job/122368744083
