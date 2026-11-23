# Setting up the gaming tower

From Apollo to this fork of Sunshine plus Virtual Display Driver (VDD). Every step is done on the tower, signed in
as an administrator. Background: [CAPTANTAN.md](../CAPTANTAN.md).

## 0. Before you start

- **Smart App Control.** Windows Security > App & browser control > Smart App Control settings. If it says **On**,
  Windows will block this build, because it is unsigned. If it says Off, nothing to do. (On many Windows 11
  versions, turning it off cannot be undone without reinstalling Windows, so decide that one yourself.)
- Keep a copy of Apollo's settings for reference: copy the folder `C:\Program Files\Apollo\config` somewhere (for
  example your Documents). Its `apps.json` lists the apps you will recreate.

## 1. Remove Apollo and its SudoVDA driver

1. Settings > Apps > Installed apps > **Apollo** > Uninstall.
2. Device Manager > Display adapters: if **SudoMaker Virtual Display Adapter** (SudoVDA) is still there, right-click >
   Uninstall device, tick "Attempt to remove the driver for this device", Uninstall.
3. Check that no copy of the driver is left. In PowerShell **as administrator**:
   ```powershell
   pnputil /enum-drivers | Select-String -Context 1,5 -Pattern 'sudo'
   ```
   For each `Published Name` it shows (for example `oem42.inf`): `pnputil /delete-driver oem42.inf /uninstall /force`
4. Restart the tower.

## 2. Install Virtual Display Driver

1. From https://github.com/VirtualDrivers/Virtual-Display-Driver/releases/latest download `VDD.Control.<version>.zip`
   (25.7.23 on 2026-11-22), extract it, run VDD Control and use it to install the driver.
2. Check:
   - Device Manager > Display adapters shows **Virtual Display Driver**.
   - `C:\VirtualDisplayDriver\vdd_settings.xml` exists, and `<monitors><count>` in it is `1`.
3. If Windows now extends the desktop onto the virtual screen while the TV is in use (the mouse disappears off an
   edge, windows open off-screen): with the TV on, Settings > System > Display > "Show only on 1" (the TV). Sunshine
   switches to the virtual screen for each stream and back afterwards.

Later, if you save settings in VDD Control, check that the resolutions the script added are still in
`vdd_settings.xml`; if not, the next connection adds them again (with one restart of the virtual display).

## 3. Install our Sunshine build

1. From https://github.com/captantan/Sunshine/releases/latest download `Sunshine-Windows-AMD64-installer.msi`.
2. In PowerShell, in the download folder, check it:
   ```powershell
   (Get-FileHash .\Sunshine-Windows-AMD64-installer.msi).Hash
   ```
   It must equal the SHA-256 in the release notes.
3. Run it. SmartScreen warns because it is unsigned: "More info" > "Run anyway". Keep the default options.
4. Open https://localhost:47990 (accept the certificate warning), create the Sunshine username and password.

The VDD script comes with the installer: `C:\Program Files\Sunshine\scripts\captantan\vdd-prepare.ps1`. Check that
only administrators can change it:
```powershell
icacls "C:\Program Files\Sunshine\scripts\captantan\vdd-prepare.ps1"
```
`BUILTIN\Users` must have only `(RX)` (or `(I)(RX)`); `Administrators` and `SYSTEM` have `(F)`.

## 4. Settings

1. Find the virtual display's ID. In the web UI: Troubleshooting > Logs, search for
   `Currently available display devices`. In the list after it, copy the `device_id` (looks like
   `{12345678-90ab-...}`) of the entry whose name is the VDD monitor, not the TV.
2. Web UI > Configuration > Audio/Video:
   - Display Id (`output_name`): the ID from step 1.
   - Device configuration (`dd_configuration_option`): **Deactivate other displays and activate only the specified
     display** (`ensure_only_display`). Not "Activate the display and set it as primary display"
     (`ensure_primary`): that keeps the TV in the desktop beside the virtual display, and with the TV off Windows can
     drop it in the middle of the switch and end with no display on at all (seen on 2026-11-22).
   - Resolution, Refresh rate and HDR (`dd_resolution_option`, `dd_refresh_rate_option`, `dd_hdr_option`): leave
     them at "Use resolution provided by the client (default)", "Use FPS value provided by the client (default)"
     and "Switch on/off the HDR mode as requested by the client (default)". That is `auto`, the default, so the
     web UI does not write these three to the file.
   - Save.
3. Add the hook, which has no web UI: open Notepad **as administrator**, open
   `C:\Program Files\Sunshine\config\sunshine.conf` and add this as one line at the end:
   ```
   pre_display_cmd = C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "C:\Program Files\Sunshine\scripts\captantan\vdd-prepare.ps1"
   ```
   The file should now also have these two lines (and no `dd_resolution_option`, `dd_refresh_rate_option` or
   `dd_hdr_option` set to anything but `auto`):
   ```
   output_name = {the ID}
   dd_configuration_option = ensure_only_display
   ```
   Save, then web UI > Troubleshooting > Restart Sunshine. Later saves in the web UI keep the `pre_display_cmd` line.
4. Web UI > Applications: recreate your apps (Desktop and Steam Big Picture are there already). Apollo's
   `apps.json` from step 0 shows what you had.

## 5. Moonlight (tablet, phone)

1. Delete the old Apollo entry for the tower (long-press it > Delete PC).
2. Settings: turn on **Optimize game settings** (without it Sunshine keeps the virtual display's current
   resolution). Set Resolution to Native, or the one you want, and the frame rate you want.
3. Add the tower again and pair: Moonlight shows a PIN; enter it in the web UI's PIN tab.

The current Moonlight app works for all of this. The new `dev.captantan.moonlight` build pairs separately, as its
own client.

## 6. Tests

Useful on the tower during the tests, in PowerShell:
```powershell
Get-Content "C:\Program Files\Sunshine\config\vdd-prepare.log" -Tail 15
Select-String -Path "C:\Program Files\Sunshine\config\sunshine.log" -Pattern 'pre_display_cmd|DisplayModePrepFailed' | Select-Object -Last 10
```

1. **A new resolution works on the first connect.** Use a device whose resolution is not in `vdd_settings.xml`
   (VDD's defaults are 1920x1080, 2560x1440 and 3840x2160; the tablet's native resolution is not among them).
   Start Desktop. Expected: a few seconds of black while the virtual display restarts, then the stream at the
   device's resolution and frame rate (Moonlight's performance overlay shows both). The script's log shows
   `added resolution WxH`, `VDD back with 1 monitor(s)` and `ready`; Sunshine's log shows `pre_display_cmd: done`
   and no `DisplayModePrepFailed`.
2. **A second connect skips the restart.** Quit the session (Moonlight: long-press the app > Quit session) and
   connect again from the same device. The script's log shows `mode already offered; no restart needed`, and the
   stream starts without the black pause.
3. **Displays are restored after the stream.** Quit the session, then turn the TV on: the desktop is on the TV as
   before, and the virtual display is back to how it was before the stream.
4. **It works with the TV off.** Repeat 1 and 2 with the TV off, using a resolution not yet used (the phone, or
   another resolution in Moonlight's settings).

If the stream fails, Moonlight shows the reason: `pre_display_cmd failed with exit code N` means the script
stopped (its log says why; the codes are in CAPTANTAN.md); `DisplayModePrepFailed` in Sunshine's log means the mode
was still missing when Sunshine set up the display (send both logs to Claude).

Every first connect should log `pre_display_cmd: running` in Sunshine's log, just before `Scheduling display device
configuration`. If it is not there, the `pre_display_cmd` line is missing from `sunshine.conf` (or this is not our
build: `C:\Program Files\Sunshine\scripts\captantan\vdd-prepare.ps1` must exist).

Moonlight's `Failed to initialize video capture/encoding. Is a display connected and turned on?`, with `No display
devices are active` in Sunshine's log, means the tower was left with no display on. Turn the TV on: Sunshine retries
putting the old layout back whenever a display appears. If the TV stays black after half a minute, restart the tower.

To run the script by hand, in
PowerShell as administrator:
```powershell
& "C:\Program Files\Sunshine\scripts\captantan\vdd-prepare.ps1" -Width 2560 -Height 1600 -Fps 120
```

## Updating and rolling back

See "Installing on the tower" and "Rolling back" in [CAPTANTAN.md](../CAPTANTAN.md). In short: run the newer (or
the previous) release's MSI; the settings in `C:\Program Files\Sunshine\config` stay.
