# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

PinePort (`pineports`, formerly `ports`) is a single-file Python 3 tool for one Linux box: it lists listening services (name, RSS, ports), kills them by port, and serves a PIN-gated web UI on `:6310`. No build step, no package manager, stdlib only (`setproctitle` optional).

## Commands

```bash
./pineports                 # CLI table, sorted by RSS
./pineports kill <port>     # SIGTERM / docker stop whatever owns <port>
./pineports --web           # web UI on 0.0.0.0:6310

# Tests are plain assert scripts (no pytest), run one at a time:
python3 test_easywins.py
python3 test_addon_path.py

# Install / deploy: the systemd user service runs the installed copy, not the repo.
# install.sh is idempotent: copies to ~/.local/bin, restarts the service, keeps PIN.
./install.sh                # also: --reset-pin, --uninstall
```

Test caveats:
- Both tests load the script by **absolute path** `/home/kg/PinePort/pineports` via `SourceFileLoader` (it has no `.py` extension), so they test the repo copy.
- `test_easywins.py` calls the real `gather()` (shells out to `ss`) and **writes to the real `~/.config/pineports-seen.json`**.
- `test_addon_path.py` expects `needle` to be installed in `~/.local/bin`.
- `test_easywins.py` check 6 greps the source for literal strings (`class="badge">new`, `docker:(box,d)=>`, `ThreadingHTTPServer((`). Renaming those breaks the test.

## Architecture (`pineports`)

Everything — data collection, HTTP server, and the HTML/CSS/JS page — lives in one file.

- **Data collection**: `ss_out()` runs `sudo -n /usr/bin/ss -tulpn` and falls back to unprivileged `ss` (fewer pids visible). `gather()` parses that output, groups ports by pid, applies labels from `~/.config/pineports-labels.conf`, reads RSS from `/proc`, and returns one row per pid (no merging by name, so each kill button maps to exactly one process). Each row also carries `cmd` (from `/proc/<pid>/cmdline`, shown on hover) and `links`: TCP ports not bound to loopback, which the page renders as `http://<host>:<port>` links. `sys_stats()`/`cpu_pct()` read `/proc` on every poll; no background threads.
- **Killing** (`kill_port`): first checks whether a Docker container publishes the port (`docker ps` + `inspect`) and `docker stop`s it; otherwise it SIGTERMs the pid, retrying with `sudo -n /usr/bin/kill` on PermissionError. The sudo calls rely on a narrow NOPASSWD sudoers rule that allows only `/usr/bin/ss -tulpn` and `/usr/bin/kill`. Keep the absolute binary paths so they keep matching that rule.
- **New-listener badge** (`badge_ports`): stores per-port first-seen timestamps in `~/.config/pineports-seen.json` behind `_seen_lock`, with atomic writes through a `.tmp` file. A port is badged for `NEW_WINDOW` (24h) unless it's labeled or `>= EPHEMERAL_MIN` (32768).
- **Web server**: `ThreadingHTTPServer` + `Handler`. Every route except `POST /api/login` goes through `check_auth` (cookie `ports_auth`, tokens in in-memory `SESSIONS`, so a restart means re-login). The PIN is compared against the sha256 in `~/.config/pineports-pin`. `try_login` throttles globally: after 5 wrong PINs, all logins are refused for 5 min. A per-request sleep alone does not slow parallel guesses on a threaded server. The cookie is `SameSite=Lax`, and everything the page interpolates into HTML goes through `esc()`. Routes: `/`, `/api/services`, `/api/addon/<name>[?live=1]`, `POST /api/kill`.
- **Page**: `PAGE_TMPL` / `LOGIN_TMPL` are inline HTML strings. `__HOST__` is substituted once at import (`socket.gethostname()`); `__ADDONS__` is substituted per request with the JSON list of found add-ons. Themes use CSS vars, and the chosen theme is stored in localStorage `pp_theme`.

### Add-on system

An add-on is an external CLI that prints JSON. `_find_addons()` runs once at import and resolves each one with `_addon_cmd()`, which tries `shutil.which` first and then falls back to `~/.local/bin`. The fallback is needed because the boot-time systemd user manager has a minimal PATH. On Windows it also resolves Python add-ons on PATH and Needle's standard `%LOCALAPPDATA%\Needle\bin\needle.py` install as `[sys.executable, script]`. Found add-ons go into the `ADDONS` dict as `{cmd, cached args, live args, (cached, live) timeouts}`. The server runs `cmd` + `cached` by default and `cmd` + `live` when `?live=1` is set.

To add one:
1. Register it in `_find_addons()`.
2. Add a JS renderer to `CARD_RENDER` in `PAGE_TMPL`. Without one, the card falls back to a raw JSON dump.

Existing add-ons: `needle` (external repo KGthePM/Needle, AI usage) and `pineports-docker` (in this repo, `docker stats --no-stream`).

## Other files

- `ports-wrapper`: installed as `~/.local/bin/ports`, a muscle-memory alias that execs the installed `pineports`.
- `install.sh`: installer/updater/uninstaller (copies files, sets PIN via hidden prompt, enables the service + `loginctl enable-linger`) and copies itself to `~/.local/bin/pineports-uninstall`, which only uninstalls.
- `systemd/pineports.service`: user unit that runs `%h/.local/bin/pineports --web` (no hardcoded home dir).
- `start-pineports.cmd`, `stop-pineports.cmd`, `restart-pineports.cmd`, `test-pineports.cmd`: double-clickable Windows wrappers around `windows/pineports.ps1`; runtime PID/logs live under `%APPDATA%\pineports`.
- `config/`: example labels file and instructions for generating the PIN hash.
