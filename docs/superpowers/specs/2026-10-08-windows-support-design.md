# PinePort Windows Support — Design

Date: 2026-10-08
Status: Approved in chat (Kyle), 2026-10-08. Real-Windows validation delegated to Dave post-push.

## Goal

PinePort currently runs only on Linux. Windows users should get the same
core experience: a table of listening services (name, RAM, ports), a
PIN-gated web UI on :6310 with the stats bar, and the ability to kill
what's listening — including Docker Desktop-published ports.

## Decisions (made in chat)

- **Full parity**: list + kill + web UI on Windows.
- **Single file**: one `pineports` script; platform layer at the top,
  everything else (server, page, auth, badges, themes, add-ons) shared.
- **psutil** for Windows PID/name/RSS/CPU/RAM/disk (one pip dependency,
  documented). PowerShell `Get-NetTCPConnection` for the listener list.
- **Docker kill included** on Windows (`docker` via PATH, Docker Desktop).
- **No service**: README documents `python pineports.py --web` + optional
  Startup-folder shortcut. `install.sh` and systemd stay Linux-only.
- **Kill escalation on Windows**: psutil `terminate()` then `kill()`;
  access-denied (other users' processes) returns an honest error telling
  the user to run from an elevated console.
- **Tests**: `test_windows.py` (real Windows only, skips on Linux) +
  `test_crossplatform.py` (mocked PowerShell/psutil, runs on Linux CI/dev
  boxes). Existing tests untouched.

## Config paths

| File | Linux | Windows |
|---|---|---|
| labels | `~/.config/pineports-labels.conf` | `%APPDATA%\pineports\pineports-labels.conf` |
| pin | `~/.config/pineports-pin` | `%APPDATA%\pineports\pineports-pin` |
| seen | `~/.config/pineports-seen.json` | `%APPDATA%\pineports\pineports-seen.json` |

Same formats. `CONFIG_DIR` helper computes the right base once.

## Architecture

`IS_WIN = sys.platform == "win32"` gates two implementation blocks that
define the SAME function names; downstream code is untouched:

- `ss_out()` — Linux: sudo/unprivileged `ss -tulpn` text.
  Windows: PowerShell `Get-NetTCPConnection -State Listen` → JSON.
- `mem_mb(pid)` / `cmdline(pid)` — Linux: `/proc`.
  Windows: psutil (graceful fallback to pid-only if psutil missing).
- `gather()` — Linux: parse `ss` text (unchanged body).
  Windows: build rows from Get-NetTCPConnection + psutil; same output
  schema (`name, pid, rss, cmd, ports, links, kind, new`).
- `cpu_pct()` / `sys_stats()` — Linux: `/proc` + `statvfs` (unchanged).
  Windows: psutil cpu/vmem/disk/boot_time; `load1` reported as 0.
- `docker_container_for_port()` / `kill_port()` — Linux: unchanged.
  Windows: `docker` via PATH; process kill via psutil.

Unchanged on both platforms: auth/PIN/throttle, badge logic, add-on
system (the `~/.local/bin` add-on fallback simply never matches on
Windows), web server, page, themes, CLI arg handling. `setproctitle`
import is already guarded (Linux-only package).

`EPHEMERAL_MIN`/`NEW_WINDOW` badge rules apply unchanged.

## Error handling

- psutil absent on Windows: services list still renders (ports + pid,
  no name/RSS); README says `pip install psutil` for full data.
- PowerShell missing/failing (Win10+ has it built in): empty service
  list, web UI still serves.
- Kill AccessDenied: message states the process belongs to another
  user/admin and to run from an elevated prompt. No silent failures.

## Testing

- `test_crossplatform.py` (runs HERE on Linux): feeds mock
  Get-NetTCPConnection JSON + fake psutil objects into the Windows code
  paths; asserts gather output schema, loopback/links filtering, badge
  integration, kill escalation messages, sys_stats shape.
- `test_windows.py`: real-Windows smoke (skips elsewhere).
- Existing `test_easywins.py` + `test_addon_path.py` must still pass.
- Known limit: no Windows box in this environment — Dave smoke-tests on
  real Windows after push (checklist included in README).

## Out of scope

- Windows service/NSSM, auto-update, macOS, Docker stats add-on parity
  (`pineports-docker` is found via PATH; it works on Windows if Docker
  CLI is present, else the card is skipped — no extra work).
