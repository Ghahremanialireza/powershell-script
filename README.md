# Update-Control

A PowerShell script that controls **Windows Update** and the auto-update of **Microsoft Edge, Google Chrome and Mozilla Firefox** on Windows 10 and 11.

It was written for offices where many PCs start updating at the same time (start of the work day) and saturate the internet link.

- **Version:** 1.0.0
- **Author:** A. Ghahremani
- **Date:** 2026-10-17

## Requirements

- Windows 10 or 11
- Windows PowerShell 5.1 or later
- A PowerShell window opened **as Administrator** (the script does not ask for or store any credentials)

## Usage

```powershell
# Show help (also: -h, --help)
.\Update-Control.ps1 -Help

# Turn automatic updates off (Windows Update + Edge + Chrome + Firefox)
.\Update-Control.ps1 -Mode Disable

# Keep updates on, but limit their bandwidth (default 20%)
.\Update-Control.ps1 -Mode Throttle -ThrottlePercent 20

# Show the current state, change nothing
.\Update-Control.ps1 -Status

# Undo everything this script changed
.\Update-Control.ps1 -Revert
```

If script execution is blocked, run it like this:

```powershell
powershell -ExecutionPolicy Bypass -File .\Update-Control.ps1 -Mode Disable
```

## Flags

| Flag | Description |
|------|-------------|
| `-Mode Disable` | Turns automatic updates off: Windows Update policies, services (`wuauserv`, `UsoSvc`, `WaaSMedicSvc`, `DoSvc`), scheduled tasks, Delivery Optimization (HTTP only), Store auto-updates, driver updates, and the Edge / Chrome / Firefox updaters. |
| `-Mode Throttle` | Keeps updates on but limits bandwidth (Delivery Optimization), enables LAN peering and sets active hours 08:00-18:00. Browsers are not changed. |
| `-ThrottlePercent N` | Bandwidth percentage (5-100) for `-Mode Throttle`. Default `20`. |
| `-Revert` | Restores registry values, service start types, scheduled tasks and Firefox `policies.json` from the saved state. |
| `-Status` | Read-only report of the related services and policies. |
| `-Help`, `-h`, `--help` | Shows the built-in help. Does not need Administrator rights. |

## Files and logs

| Path | Purpose |
|------|---------|
| `C:\ProgramData\UpdateControl\update-control.log` | Log of every action and warning |
| `C:\ProgramData\UpdateControl\state.json` | Original values, used by `-Revert` |
| `C:\ProgramData\UpdateControl\Backup\` | Backups of changed files |

## Notes

- Running `-Mode Disable` twice is safe: original values are saved only once.
- Some scheduled tasks (for example `UpdateOrchestrator\Schedule Scan`) deny even Administrators. The script disables them through a temporary task running as SYSTEM.
- Reboot after `-Mode Disable` or `-Revert`.
- Test on a single PC before deploying to many.

## Disclaimer

Provided "as is", without warranty. **Disabling updates means the PC receives no security patches.** Plan a manual update window (for example monthly), or prefer `-Mode Throttle` / a local update server (WSUS) where possible.
