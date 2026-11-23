# captantan fork of Sunshine

This is a fork of [Sunshine](https://github.com/SunshineStream/Sunshine) (formerly `LizardByte/Sunshine`) with one
addition: a `pre_display_cmd` hook that runs before Sunshine sets up the display. It is used with
[Virtual Display Driver](https://github.com/VirtualDrivers/Virtual-Display-Driver) (VDD, MIT) so that each Moonlight
device streams at its own resolution and refresh rate from its first connection, as Apollo did. The owner streams
from a Windows gaming tower (usually connected only to a TV that is off) to a Samsung Tab S12 Ultra and a phone.

- Branch `captantan` is the default branch. It holds upstream's newest **stable** release plus our changes.
  `master` is upstream's and is not used.
- Releases are tagged `v<upstream version>-captantan.<N>`, for example `v2026.914.233613-captantan.1`.
- Only stable upstream releases are merged, never pre-releases (#5942, in the pre-releases after v2026.914.233613,
  breaks switching to a virtual display).
- First release: `v2026.914.233613-captantan.1`, based on upstream `v2026.914.233613` (2026-09-15).
- Setting up the tower: [captantan/TOWER-SETUP.md](captantan/TOWER-SETUP.md).

## Why a fork

In `src/nvhttp.cpp`, `launch()` and `resume()` call `display_device::configure_display()` (only when no stream is
active), then `video::probe_encoders()`, and only after that `proc::proc.execute()`, which runs the app's prep
commands with the `SUNSHINE_CLIENT_*` variables. If the virtual display does not offer the client's mode,
libdisplaydevice returns `DisplayModePrepFailed`, undoes the whole display switch and does not retry. So a prep
command is too late to add the mode, and Sunshine has no earlier hook. Upstream PR #5808 adds one, but it is 1,159
lines and waits on `LizardByte/roadmap#38`; it was only a reference here.

## Our changes

Kept small on purpose, so merges stay easy. Upstream files get about 30 lines; everything else is in new files.

| What | Files | Why |
| --- | --- | --- |
| The hook: runs `pre_display_cmd`, waits up to 90 s, gives it `SUNSHINE_CLIENT_WIDTH`, `_HEIGHT`, `_FPS`, `_HDR`, `_NAME` | `src/captantan/pre_display_cmd.cpp`, `.h` (new) | The variables are built here, not in `src/process.cpp`, whose block of client variables changes in most releases |
| Two calls, each right before `display_device::configure_display(config::video, *launch_session);` | `src/nvhttp.cpp` (`launch()` and `resume()`, plus one `#include`) | Inside upstream's existing `session_count() == 0` blocks, so the hook runs only when no stream is active. A non-zero exit, a start failure or the timeout returns HTTP 503 with a message such as `pre_display_cmd failed with exit code 4`, which Moonlight shows; the launch stops before the display is touched. The lines around these two call sites changed once in seven stable releases since v2025.122 |
| One option, `pre_display_cmd` | `src/config.cpp` (one `string_f` line before `vars.find("flags"s)`, plus one `#include`) | No web UI. The web UI keeps unknown keys when it saves, so editing other settings there does not drop it. The value is used as typed (quotes kept); `#` starts a comment in `sunshine.conf`, so the command must not contain one |
| Build list | `cmake/compile_definitions/common.cmake` (two lines after `src/nvhttp.h`) | Compiles the new file |
| The VDD script, installed to `C:\Program Files\Sunshine\scripts\captantan\vdd-prepare.ps1` | `captantan/vdd-prepare.ps1` (new), `cmake/packaging/windows.cmake` (one `install()` before "Configurable options for the service") | The installer puts it in a folder only admins can change, and every release updates it |
| Our Windows build | `.github/workflows/captantan-windows.yml` (new) | See "Build and release" |
| Upstream workflows removed | `.github/workflows/*` | See below |
| Merge check | `captantan/check-fork.sh` (new) | Confirms all of the above after a merge |
| Test data | `captantan/test/vdd_settings.sample.xml` (new) | VDD's own sample file (VDD `master` at `d7244969b2aa`, MIT), used by the workflow's script test |
| These notes | `CAPTANTAN.md`, `CLAUDE.md`, `captantan/TOWER-SETUP.md` (new) | |

### How the hook runs

- It runs with Sunshine's own rights. Sunshine on Windows runs as the service, so that is SYSTEM, which can restart
  devices and write the VDD settings, and it works before anyone has signed in. (Upstream's prep commands with
  `elevated` use the signed-in user's token instead, and fail when nobody is signed in.)
- No window and no console output (stdin, stdout and stderr go to null); the command keeps its own log.
- Sunshine's log shows `pre_display_cmd: running [...] for WxH@FPS`, then `pre_display_cmd: done` or the error.
- Empty or missing option: nothing runs, Sunshine behaves exactly like upstream.
- A second client joining a running stream does not run it (a stream is active). Resuming a running app after
  everyone disconnected does run it; if that client's mode is new, the virtual display restarts under the running
  game, which some games may not survive. Quitting the app first avoids that.

### The VDD script (`captantan/vdd-prepare.ps1`)

- Reads `SUNSHINE_CLIENT_WIDTH`, `_HEIGHT`, `_FPS` (or `-Width -Height -Fps` by hand).
- Finds the settings file where the driver does: the registry value `HKLM\SOFTWARE\MikeTheTech\VirtualDisplayDriver`
  `VDDPATH`, else `C:\VirtualDisplayDriver`, file `vdd_settings.xml`.
- The driver builds its modes as every `<global><g_refresh_rate>` times every `<resolutions><resolution>`, plus each
  resolution's own `<refresh_rate>` (read from VDD's `Driver.cpp`). So: a missing resolution is added to
  `<resolutions>` (as `width`, `height`, `refresh_rate`, the order the driver needs); a refresh rate found neither in
  the global list nor in that resolution's own entry is added to the global list.
- After a change it restarts the VDD device (`Disable-PnpDevice`, `Enable-PnpDevice`; found by hardware ID
  `Root\MttVDD`, else by the name "Virtual Display Driver"), because the driver reads the file only when the device
  starts; its pipe command `RELOAD_DRIVER` only calls `InitAdapter()` and does not re-read it. It then waits (up to
  45 s) until the device is OK and has as many monitors as `<monitors><count>`, waits 2 s more, and exits 0.
- If the mode is already in the file and the device is OK, it exits 0 at once (no restart). It also restarts when
  the device is not OK, or when an earlier run changed the file but did not finish its restart (marker file).
- Exit codes: 0 ready, 1 no width/height/fps, 2 settings file problem, 3 no VDD device, 4 restart failed, 5 busy
  (another run held the lock for 60 s).
- Files, all in Sunshine's config folder (`C:\Program Files\Sunshine\config`, admin-only): `vdd-prepare.log`
  (rotated at 1 MB), `vdd_settings.original.xml` (the file as it was before the first change),
  `vdd-prepare.restart-pending`.
- It writes the new file under a random name and renames it over the old one, and refuses if the folder or file is
  a link: `C:\VirtualDisplayDriver` inherits write access for all signed-in users from `C:\`, and the script runs
  as SYSTEM.
- Test switches: `-SettingsPath <file> -LogDir <dir> -NoRestart` edit a copy without touching the device;
  `-ForceRestart` restarts even when nothing changed.

## Upstream workflows: removed

All of upstream's workflows were deleted on this branch (they publish to upstream's places and need upstream's
secrets; GitHub enables every workflow of a fork as soon as Actions are turned on). Removed at
`v2026.914.233613`: `_codeql`, `_common-lint`, `_release-notifier`, `_top-issues`, `_update-changelog`,
`_update-docs`, `_update-flathub-repo`, `_update-homebrew-repo`, `_update-pacman-repo`, `_update-winget-repo`,
`ci-alpine`, `ci-archlinux`, `ci-bundle`, `ci-cloudsmith`, `ci-copr`, `ci-flatpak`, `ci-freebsd`, `ci-homebrew`,
`ci-linux`, `ci-macos`, `ci-powershell`, `ci-release`, `ci-windows`, `ci`, `localize`, `publish-artifacts`,
`publish-screenshots`, `update-pages` (all `.yml`).

**Every merge must keep them out.** A workflow upstream changed shows up as a modify/delete conflict; a workflow
upstream added arrives silently. `captantan/check-fork.sh` catches both. Never push a merge that has any workflow
besides `captantan-windows.yml`: once on the default branch, scheduled ones would start running.

Other things under `.github/` (issue templates, matchers, renovate settings) are kept; they do nothing in a fork.

The fork's `master` branch still has upstream's workflows. Leave it alone: don't use GitHub's "Sync fork" button on
it and don't push to it, since a push there would run upstream's `ci.yml` (it would fail for want of secrets).
Upstream's tags are fetched from the `upstream` remote, not from `master`.

## Build and release

`.github/workflows/captantan-windows.yml`, three jobs, about 30 minutes in all:

1. **Test vdd-prepare.ps1** (Windows PowerShell 5.1, about 1 minute): runs the script with `-NoRestart` on a copy of
   the sample settings file and checks what it adds, that a repeat run changes nothing, that comments survive and
   that missing input fails.
2. **Windows-AMD64**: upstream's `ci-windows.yml` steps for AMD64 (MSYS2 UCRT64, the same packages, dotnet for WiX,
   Node, Python and uv, cmake and ninja, the linkage check, `cpack -G WIX`), without ARM64, signing, docs, tests,
   coverage and tray screenshots. Unlike upstream, `-DBUILD_WERROR` is off: MSYS2's packages are rolling, so an older
   tag meets newer libraries whose deprecation warnings would stop the build (`v2026.914.233613` against OpenSSL 4.1).
   After a build, check our own file has no warnings:
   `gh run view <id> -R captantan/Sunshine --log | grep -i "captantan/.*warning"`. It checks that the WiX sources include
   `vdd-prepare.ps1`.
3. **Release** (tags only): a GitHub release named after the tag with `Sunshine-Windows-AMD64-installer.msi`, its
   `.sha256` file, and the SHA-256 and commit in the notes.

Triggers: pushing a `v*-captantan.*` tag, or a manual start (Actions > captantan Windows build > Run workflow). A
manual start with the `tag` input empty builds the chosen branch and makes no release; with an existing tag it
builds and releases that tag.

**Version:** Sunshine takes its version from `BUILD_VERSION` (`cmake/prep/build_version.cmake`: strips a leading
`v`, reads year, month and day only from an exact `YYYY.MDD.N`, and uses it for the MSI version). The workflow
strips our suffix, so `v2026.914.233613-captantan.1` builds as `2026.914.233613`, exactly upstream's version. So
Sunshine shows upstream's version, its update notice works as upstream's, and the MSI installs over upstream's or
ours (its `MajorUpgrade` has `AllowDowngrades="yes"` and the product code changes each build). The suffix is only
in the tag and the release. A build without a tag reports `0.0.0`.

**Unsigned:** upstream signs with its Azure secrets, which a fork does not have. Windows SmartScreen warns once
("More info", "Run anyway"), and **Smart App Control blocks unsigned programs entirely**: on a PC where it is on,
this build cannot run.

## Merging a new stable upstream release

A parallel setup (the owner's home-lab repo, builder VM) sends an ntfy notice for each new stable Sunshine
release; the owner then starts a Claude Code session in this folder to merge it. Steps:

1. Find the newest stable release and read its notes, plus those of any stable release skipped:
   ```
   gh release list -R SunshineStream/Sunshine --exclude-pre-releases --limit 5
   ```
   Note anything that touches `nvhttp.cpp`, display configuration (`display_device`, libdisplaydevice), the
   config parser, or the Windows packaging. If the release is a pre-release, stop.
2. Fetch and merge (call the new tag `vNEW`):
   ```
   git fetch upstream --tags
   git switch captantan
   git status                      # must be clean
   git merge --no-ff vNEW -m "Merge upstream vNEW"
   ```
3. Resolve conflicts:
   - `.github/workflows/*` modify/delete conflicts: `git rm` the file (keep it deleted).
   - `src/nvhttp.cpp`: keep upstream's new code and put each hook block back right before
     `display_device::configure_display(config::video, *launch_session);`, inside the "no active sessions" branch
     of `launch()` and of `resume()`. If upstream moved display setup elsewhere (into another function, or after
     `proc::proc.execute()`), the hook must still run before it and only when no stream is active; read upstream's
     change and PR #5808's handling first.
   - `src/config.cpp`, `cmake/compile_definitions/common.cmake`, `cmake/packaging/windows.cmake`: keep upstream's
     version and re-add our lines.
   - If `launch_session_t` fields (`width`, `height`, `fps`, `enable_hdr`, `client_name` in `src/rtsp.h`) were
     renamed, update `src/captantan/pre_display_cmd.cpp`.
4. Then:
   ```
   git rm $(git ls-files .github/workflows | grep -v '^.github/workflows/captantan-windows.yml$')   # if any
   git submodule update --init --recursive
   ./captantan/check-fork.sh       # must say "All good."
   git commit                      # if the merge stopped for conflicts
   ```
   Compare upstream's `.github/workflows/ci-windows.yml` at `vNEW` with ours
   (`git diff vOLD vNEW -- .github/workflows/ci-windows.yml`) and carry over changes to packages, action versions or
   build steps.
5. Tag and push, then watch the build (about 30 minutes):
   ```
   git tag vNEW-captantan.1
   git push origin captantan vNEW-captantan.1
   gh run watch -R captantan/Sunshine $(gh run list -R captantan/Sunshine -L 1 --json databaseId -q '.[0].databaseId')
   ```
   On a failure, read only the failing step: `gh run view <id> -R captantan/Sunshine --log-failed | grep -iE "error|fail" | head -50`.
   A failed tag build makes no release, so fix, commit, and move the tag:
   `git push origin :refs/tags/vNEW-captantan.1 && git tag -f vNEW-captantan.1 && git push origin vNEW-captantan.1`.
   Never move a tag that already has a release; use `-captantan.2` instead.
6. Check the release: `gh release view vNEW-captantan.1 -R captantan/Sunshine` lists the `.msi` and `.msi.sha256`.
7. Record the merge in "History" below, commit and push.

A change of ours alone (no upstream merge) is released as the next number on the same base, for example
`v2026.914.233613-captantan.2`.

## Installing on the tower

The owner does every step on the tower; Claude cannot reach it. First install: [captantan/TOWER-SETUP.md](captantan/TOWER-SETUP.md).
An update is:

1. Download `Sunshine-Windows-AMD64-installer.msi` from the release, and check it in PowerShell:
   `(Get-FileHash .\Sunshine-Windows-AMD64-installer.msi).Hash` must equal the SHA-256 in the release notes.
2. Run it (SmartScreen: "More info", "Run anyway"). It replaces the installed Sunshine and keeps
   `C:\Program Files\Sunshine\config` (settings, pairings, apps, our log).
3. Connect from Moonlight. The Sunshine log should show `pre_display_cmd: done`.

## Rolling back

Install the previous release's MSI the same way: the installer allows downgrades and the settings stay. Upstream's
own stable MSI also installs over ours; it ignores `pre_display_cmd` (it only logs "Unrecognized configurable
option"), so new resolutions then fail again until the mode is in `vdd_settings.xml`. To undo the script's edits
to VDD, copy `C:\Program Files\Sunshine\config\vdd_settings.original.xml` back over `vdd_settings.xml` and restart
the VDD device (Device Manager, Display adapters, Virtual Display Driver: Disable, then Enable).

## History

- 2026-11-22: fork created from upstream `v2026.914.233613`; hook, VDD script and workflow added;
  `v2026.914.233613-captantan.1` released from commit `888c7530` (run 45079815442, 17 minutes; MSI 34,056,821
  bytes, SHA-256 `3dfcbe6b…931c0e23`). The tag was moved four times before that, each time with no release made.
  Lessons for the next merge:
  - Read upstream's code at the tag being merged, never at `master`: `src/compat/boost_process.h` exists only on
    `master`, so including it broke the build.
  - Keep the MSYS2 package list identical to upstream's: the build needs `libtiff-4`, which only arrives as a
    dependency of `graphviz`.
  - A build without `-Werror` is required for older tags (OpenSSL 4.1 deprecated `ASN1_STRING_length`, used in
    `src/crypto.cpp`).
  - In the workflow's Windows PowerShell test step, end with `exit 0`: the runner exits with the last
    `$LASTEXITCODE`.
- 2026-11-22: `v2026.914.233613-captantan.2`, a fix to the VDD script only. On the tower `.1` exited 1 on every
  connect, before writing its log: Windows PowerShell 5.1 leaves `$PSScriptRoot` empty in parameter defaults when a
  script runs with `-File`, so the default `-LogDir` could not be worked out. The default is now computed in the
  script body. CI had passed every parameter by hand; test 5 now runs the script the way Sunshine does (installed
  layout, input only from `SUNSHINE_CLIENT_*`, default log folder), and the missing-input test checks the script's
  own message, since PowerShell also exits 1 on any error it does not catch.
  Lesson: test the script through the same command line Sunshine uses, with nothing passed by hand.
