# Powershell Swiss Army Knife (99SAK)

A single-file, portable admin toolkit offering 99 everyday operations for Windows. It’s menu-driven, colorized, and logs activity automatically. Built for fast on-host triage and routine systems work.

## What’s inside

- `99PowershellSwissArmyKnife.ps1` – The main script (menu UI + 99 commands)
- `99PowershellSwissArmyKnife.bat` – Windows launcher that elevates to Administrator and runs the PowerShell script
- `99BashSwissArmyKnife.sh` – Minimal Bash helper (placeholder)
- `bad_ports.json` – Example list of risky/common service ports (reference)
- `Logs/` – Daily logs written here (e.g., `yyyy-MM-dd.log`)

## Requirements

- Windows 10/11
- PowerShell 5.1+ (Windows PowerShell) or PowerShell 7+
- Administrator privileges (many actions require elevated access)

## Quick start

Recommended: use the launcher to auto-elevate and bypass execution policy for this run.

1) Double‑click `99PowershellSwissArmyKnife.bat`
   - If not elevated, it will prompt for Administrator.
2) Follow the on‑screen menu.

Run directly (alternative):

```powershell
PowerShell -NoProfile -ExecutionPolicy Bypass -File .\99PowershellSwissArmyKnife.ps1
```

If you see “script is not digitally signed”, use one of:

```powershell
# Temporary (current session only)
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force

# Or unblock just this file (after download)
Unblock-File .\99PowershellSwissArmyKnife.ps1
```

Then run the script again.

## Highlights

- 99 commands grouped into 5 categories:
  - Networking (1–20)
  - System Maintenance (21–40)
  - Security & Privacy (41–60)
  - Utilities (61–80)
  - Misc (81–99)
- Clean, colored menus and info panel
- Built‑in confirmations for disruptive actions
- Optional System Restore Point creation before select changes
- Automatic daily logging to `Logs/yyyy-MM-dd.log`
- Boss Key: press Ctrl+B anywhere to immediately close 99SAK
- Command History: press H on the main menu to view the last 5 executed actions
- Fun extras:
  - Fun easter eggs to discover

## Using the menu

- Launch → main screen shows system info and the main categories.
- Choose a category by letter: A (Networking), B (System), C (Security), D (Utilities), E (Misc).
- Inside a category, enter the number shown (e.g., 7 to flush DNS).
- Press B (or b) to go back to the main menu.
- Press H on the main menu to see “Command history (last 5)”.
- Press Ctrl+B at any prompt to immediately exit (Boss Key).

## Notes on specific features

- Networking: adapters, IP/DNS, connections, routes, Wi‑Fi profiles/passwords, common port checks
- System: SFC, DISM, defrag, services, scheduled tasks, update service, reboot/shutdown, system info export
- Security: Windows Firewall, hosts file block/unblock, Diagnostics Tracking toggle, Defender scans, users, BitLocker status, RDP controls
- Utilities: screenshot, users/passwords, processes, explorer restart, timezone, event logs, ISO mount, device disable, battery/energy reports
- Misc: SMB shares, map/unmap network drive, time sync, registry backup/restore, ARP export, hibernate and RDP port, full script+logs backup

## Logging

- All actions log to `Logs/yyyy-MM-dd.log` with timestamp, user, and host.
- Use the “Backup script and logs” option to zip the whole tool and logs to your Desktop.

## Safety and scope

- Many operations are disruptive; confirmations are required for riskier changes.
- Some commands (e.g., hosts file edit, Defender scans, Windows Update service, RDP settings) change system state.
- Run as Administrator for best results.

## Troubleshooting

- “Script is not digitally signed”: see Quick Start for ExecutionPolicy / Unblock-File guidance.
- “Access denied” or failures: re‑run as Administrator.
- Networking operations: ensure the relevant adapter names are correct (the tool prompts you if needed).
- Defender/BitLocker commands may be unavailable on some SKUs or when third‑party AV replaces Defender.

## Credits

- Developer: Salahuddin (`https://github.com/salahmed-ctrlz`)
- LinkedIn: Salah Eddine Medkour (`https://www.linkedin.com/in/salah-eddine-medkour/`)
- Project: Powershell Swiss Army Knife (99SAK)

