# 99SAK — PowerShell Swiss Army Knife

A portable, admin-elevated Windows toolkit for IT professionals, help desk engineers, and network administrators. Zero dependencies. No installation. Works on any Windows 10/11 machine.

---

## Quick Start

1. Double-click `99SAK.bat`
2. Approve the UAC elevation prompt
3. Use the on-screen menu

That is it. No PowerShell execution policy changes required for normal use — the launcher handles it.

**Alternative (direct):**
```powershell
PowerShell -NoProfile -ExecutionPolicy Bypass -File .\99SAK.ps1
```

---

## Navigation

| Input | Action |
|---|---|
| Letter key | Enter a category (A–F, W, L, H) |
| Number | Run a command within a category |
| `B` | Go back to the main menu |
| `/` | Search commands across all categories |
| `Q` | Quit (shows session summary) |
| `Ctrl+B` | Exit immediately from anywhere (Boss Key) |

---

## Categories

### A — Networking (30 tools)

| Group | What it covers |
|---|---|
| Adapters | List, enable, disable, restart network adapters |
| IP & DNS | ipconfig, DHCP release/renew, DNS flush, set DNS (Google/Cloudflare/OpenDNS/custom), DNS latency benchmark |
| Connections | Active TCP connections, listening ports with process names |
| Ports | Common port scan, flag listening ports against bad-port database, TCP/IP reset, Winsock reset |
| Routing | ARP table, routing table, add/remove static routes |
| Diagnostics | Ping, traceroute, LAN device scanner (/24 subnet), DNS/nslookup lookup |
| Wi-Fi | Saved profiles, saved passwords, signal strength |
| Export | Full network info (ipconfig + routes + ARP) to .txt |

### B — System Maintenance (29 tools)

| Group | What it covers |
|---|---|
| Information | System info, disk usage, temp folder sizes, uptime/RAM |
| Cleanup | User temp, system temp, Recycle Bin, Windows Update cache, thumbnail cache, all-at-once cache clear |
| Repair | chkdsk, SFC /scannow, DISM RestoreHealth, memory diagnostic scheduler |
| Services | List running services, start/stop/restart by name |
| Startup & Updates | Registry startup app list, scheduled tasks, Windows Update control |
| Power & Storage | Power plan manager, drive defrag, battery report, energy report |
| System Control | Create restore point, export system info, reboot, shutdown |

### C — Security & Privacy (27 tools)

| Group | What it covers |
|---|---|
| Firewall | Enable/disable all profiles, view active rules, reset to default policy |
| Hosts File | Block/unblock hosts, view current entries |
| Defender | Status, quick scan, full scan, signature update |
| Users & Accounts | List local users, lock workstation, UAC level info, password policy |
| Privacy | Disable DiagTrack telemetry, clear recent files, clear clipboard |
| Monitoring & Audit | Listening ports with process, top processes, unsigned process check, scored security audit report |
| Remote Access | RDP status, enable/disable RDP, change RDP port, BitLocker status, activation status |

### D — Utilities (18 tools)

| Group | What it covers |
|---|---|
| Capture & Media | Screenshot (Desktop), eject CD, mount/dismount ISO |
| Programs & Processes | Installed program list, top processes, kill process, restart Explorer |
| Users | Create local admin, remove user, change password |
| System Tools | Set timezone, event log viewer (with export), full system info export, disable PnP device |
| Registry | Open editor, backup to .reg file, import .reg file |

### E — Misc (9 tools)

SMB shares (list/create/remove), map/unmap network drives, time sync (w32tm), export ARP cache, hibernate toggle, full 99SAK backup to .zip.

### F — Debloat & Cleanup (13 tools)

| Group | What it covers |
|---|---|
| Preinstalled Apps | List all with install status, remove Xbox components, game apps, productivity bloat, Cortana, media apps, OneDrive |
| Services & Telemetry | View and disable telemetry services (DiagTrack, SysMain, WSearch, Xbox services, etc.) |
| Startup & Performance | Startup app viewer and exporter, set Windows to Performance visual mode, restore defaults |
| Registry Tweaks | Disable Bing in Start menu, disable Activity History, disable Edge PDF takeover — each individually or all at once |

> All debloat operations auto-create a System Restore Point before making any changes.

### W — Safety Workflows

Guided multi-step operations with automatic restore points, step-by-step progress output, and exportable reports.

| Workflow | Description | Risk |
|---|---|---|
| W1 — Health Check | Full read-only system diagnosis | None |
| W2 — System Repair | SFC + DISM + verify, with reboot advisory | Low |
| W3 — Network Reset | Winsock, TCP/IP, DNS flush, connectivity test | Moderate |
| W4 — Malware Triage | Ports, hosts, unsigned processes, Defender scan | Low |
| W5 — Safety Backup | Registry, network config, firewall rules, hosts, logs | None |

> Workflows are in active development and will be available in v2.1.

### L — Logs & Reports

View today's or yesterday's log in-tool, search by keyword, export any date's log to a .txt file on your Desktop, or trigger log archival for entries older than 30 days.

---

## File Structure

```
99SAK\
├── 99SAK.bat               Launch here — double-click, auto-elevates to Administrator
├── 99SAK.ps1               Main script, all menus and commands
├── modules\
│   ├── UI.psm1             Console rendering, input handling, status output
│   ├── Logging.psm1        Log engine, log viewer, session summary
│   ├── Safety.psm1         Admin elevation, restore points, pre-flight checks
│   └── Workflows.psm1      Guided multi-step workflows (v2.1)
├── data\
│   ├── bad_ports.json      39 known risky ports with risk descriptions
│   └── debloat_list.json   Curated bloatware apps, telemetry services, registry tweaks
├── Logs\
│   ├── yyyy-MM-dd.log      Daily log (auto-created on first run)
│   └── Archive\            Logs older than 30 days are moved here automatically
└── README.md
```

---

## Logging

Every command run is logged to `Logs\yyyy-MM-dd.log` with:
- Timestamp
- Log level (`INFO`, `ACTION`, `WARN`, `ERROR`, `WORKFLOW`)
- Session ID (unique per launch, printed in the main menu footer)
- Username and hostname

Log levels are color-coded in the in-tool viewer. Logs can be exported to `.txt` at any time from the `L` menu.

**Session summary** is shown when you press `Q` to quit: total actions, errors, duration, and path to the log file.

---

## Safety Features

- **Restore point before risky actions**: DNS changes, TCP/IP reset, Winsock reset, debloat operations, registry tweaks, and more — all auto-create a System Restore Point first.
- **Confirmation prompts**: any operation that modifies system state requires typing `YES` to proceed.
- **Boss Key**: `Ctrl+B` exits the tool immediately from any prompt.
- **Pre-flight checks**: each workflow verifies admin status, disk space, and PowerShell version before proceeding.

---

## Compatibility

| Requirement | Minimum |
|---|---|
| Windows | Windows 10 (build 1809+) or Windows 11 |
| PowerShell | 5.1 (built into Windows) or PowerShell 7+ |
| Privileges | Administrator (auto-requested by launcher) |
| Dependencies | None — fully native |

The launcher uses `fltMC.exe` for elevation detection, which works reliably on both local accounts and domain-joined machines where `NET SESSION` may be restricted.

---

## Troubleshooting

**"Script is not digitally signed"**
Use the `.bat` launcher — it passes `-ExecutionPolicy Bypass` for that session only. Alternatively:
```powershell
Unblock-File .\99SAK.ps1
```

**"Access denied" or command fails**
Make sure you launched via `99SAK.bat`, not by right-clicking the `.ps1` directly. Some commands silently need elevation.

**Defender / BitLocker commands not available**
These require Windows editions that include those features (Pro, Enterprise). Home editions may not have BitLocker. Third-party AV may replace Defender cmdlets.

**Module not found warning at startup**
All module files must remain in the `modules\` subfolder alongside `99SAK.ps1`. The tool logs which module could not be loaded and continues with reduced functionality.

---

## Credits

- Developer: Salahuddin — [github.com/salahmed-ctrlz](https://github.com/salahmed-ctrlz)
- LinkedIn: [Salah Eddine Medkour](https://www.linkedin.com/in/salah-eddine-medkour/)

---

## Changelog

### v2.0
- Modular architecture: UI, Logging, Safety, Workflows modules
- Upgraded launcher with `fltMC.exe` elevation (reliable on all Windows SKUs and domain machines)
- 6 categories: added Debloat & Cleanup (F) with 13 tools
- Total tools: 126 across all categories
- Improved logging: session IDs, log levels, log viewer, keyword search, export to .txt
- Session summary on quit: duration, action count, error count, log path
- In-tool search (`/`) across all commands
- Boss Key (`Ctrl+B`) on every prompt
- Section dividers and grouped navigation within each category
- New networking tools: DNS benchmark, LAN scanner, bad-port checker, Wi-Fi signal
- New system tools: combined cache cleaner, power plan manager, startup app exporter
- New security tools: scored security audit, unsigned process checker, full firewall reset
- Bad ports database expanded from 14 to 39 entries
- Debloat list: 26 apps, 9 services, 4 registry tweaks

### v1.x
- Original 99-command single-file script (5 categories, basic logging, Boss Key)
