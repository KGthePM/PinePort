# PinePort

Listener overview for the Linux box it runs on — what's running, on which ports, how much RAM it's eating — plus one-keystroke kills. Née `ports`, renamed `pineports`.

![PinePort web UI](docs/screenshot.png)

## What it does

- `pineports` — CLI table: name, RSS, ports, sorted by memory (one row per pid)
- `pineports kill <port>` — SIGTERM. Docker-published ports stop the container; root-owned pids use passwordless `sudo kill` (sudoers rule `/etc/sudoers.d/ports`: only `/usr/bin/ss -tulpn` and `/usr/bin/kill`, NOPASSWD)
- `pineports --web` — web UI on `:6310` (systemd user service `pineports`, enabled)
  - Reachable LAN-wide and via Tailscale at `http://<hostname>:6310`; the page and login screen show the machine's hostname
  - Ports reachable off-box (TCP, not loopback-bound) are clickable links; hover a service name for its pid + command line
  - Kill buttons hidden for system services (cupsd, avahi, tailscaled, AdGuardHome, systemd)
  - Stats bar: CPU/RAM/disk % with meters, load, uptime — read from `/proc` per poll, no daemons
  - Theme picker: midnight/forest/paper/plum (CSS vars, saved in localStorage `pp_theme`)
  - Add-on system: `_find_addons()` probes PATH at startup (`shutil.which`); found tool → card + `/api/addon/<name>` route, absent → quietly skipped. Contract: CLI prints JSON, supports `--cached` (fast, no network) and bare invocation (live, own cooldowns). Registry in `ADDONS` dict; renderers in `CARD_RENDER` (generic JSON dump fallback). First add-on: [Needle](https://github.com/KGthePM/Needle) (AI usage gauge). Second: `pineports-docker` (real container CPU/RAM via `docker stats --no-stream`).
  - New-listener badge: ports first seen < 24h ago get a `new` badge — labeled ports and ephemeral ports (≥ 32768, VS Code/Firefox) are exempt. History in `~/.config/pineports-seen.json`.

## Install

```bash
git clone https://github.com/KGthePM/PinePort.git && cd PinePort && ./install.sh
```

The installer copies `pineports`, `pineports-docker` and the `ports` alias to `~/.local/bin`, asks for a dashboard PIN (stored as a sha256 hash, `chmod 600`), and enables the `pineports` systemd user service with linger, so the dashboard starts at boot and keeps running while you're logged out.

```bash
./install.sh               # re-run any time to update; keeps your PIN and labels
./install.sh --reset-pin   # choose a new PIN
./install.sh --uninstall   # remove it (asks before deleting config or turning off linger)
pineports-uninstall        # same, from anywhere (no repo clone needed)
```

Optional: `pip install --user setproctitle` (nicer process name).

Optional sudoers rule for killing root-owned pids (deliberately narrow):

```
kg ALL=(root) NOPASSWD: /usr/bin/ss -tulpn, /usr/bin/kill
```

## Notes

- Threaded server (`ThreadingHTTPServer`) — a slow live add-on call (~seconds) no longer blocks the 5s table poll.
- Sessions in-memory (restart = re-login), 30-day `SameSite=Lax` cookie, 1s delay on wrong PIN, global 5-minute lockout after 5 wrong PINs. All endpoints gated, incl. `/api/services`.
- Friendly port labels live in `~/.config/pineports-labels.conf` (`<port>: <label>`).
- Docker services show tiny RSS (only the ipv4/ipv6 proxy is visible) — `docker stats --no-stream` for real usage.
- `code`/`firefox-bin` entries = VS Code/Firefox on random high ports. Normal.
