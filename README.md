# PinePort

Listener overview for GomieAI2 — what's running, on which ports, how much RAM it's eating — plus one-keystroke kills. Née `ports`, renamed `pineports`.

## What it does

- `pineports` — CLI table: name, RSS, ports, sorted by memory
- `pineports kill <port>` — SIGTERM. Docker-published ports stop the container; root-owned pids use passwordless `sudo kill` (sudoers rule `/etc/sudoers.d/ports`: only `/usr/bin/ss -tulpn` and `/usr/bin/kill`, NOPASSWD)
- `pineports --web` — web UI on `:6310` (systemd user service `pineports`, enabled)
  - Reachable LAN-wide and via Tailscale at http://gomieai2:6310
  - Kill buttons hidden for system services (cupsd, avahi, tailscaled, AdGuardHome, systemd)
  - Stats bar: CPU/RAM/disk % with meters, load, uptime — read from `/proc` per poll, no daemons
  - Theme picker: midnight/forest/paper/plum (CSS vars, saved in localStorage `pp_theme`)
  - Add-on system: `_find_addons()` probes PATH at startup (`shutil.which`); found tool → card + `/api/addon/<name>` route, absent → quietly skipped. Contract: CLI prints JSON, supports `--cached` (fast, no network) and bare invocation (live, own cooldowns). Registry in `ADDONS` dict; renderers in `CARD_RENDER` (generic JSON dump fallback). First add-on: [Needle](https://github.com/KGthePM/Needle) (AI usage gauge). Second: `pineports-docker` (real container CPU/RAM via `docker stats --no-stream`).
  - New-listener badge: ports first seen < 24h ago get a `new` badge — labeled ports and ephemeral ports (≥ 32768, VS Code/Firefox) are exempt. History in `~/.config/pineports-seen.json`.

## Install

```bash
cp pineports ~/.local/bin/pineports
cp ports-wrapper ~/.local/bin/ports          # muscle-memory alias
mkdir -p ~/.config/systemd/user
cp systemd/pineports.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now pineports
cp config/pineports-labels.conf ~/.config/

# PIN auth (sha256 hash, no trailing newline, chmod 600)
printf '%s' 'YOURPIN' | sha256sum | cut -d' ' -f1 > ~/.config/pineports-pin
chmod 600 ~/.config/pineports-pin

# deps
pip install --user setproctitle
```

Optional sudoers rule for killing root-owned pids (deliberately narrow):

```
kg ALL=(root) NOPASSWD: /usr/bin/ss -tulpn, /usr/bin/kill
```

## Notes

- Single-threaded server — a live add-on call (~seconds) briefly blocks the 5s table poll. Fine for personal use.
- Sessions in-memory (restart = re-login), 30-day cookie, 1s delay on wrong PIN. All endpoints gated, incl. `/api/services`.
- Friendly port labels live in `~/.config/pineports-labels.conf` (`<port>: <label>`).
- Docker services show tiny RSS (only the ipv4/ipv6 proxy is visible) — `docker stats --no-stream` for real usage.
- `code`/`firefox-bin` entries = VS Code/Firefox on random high ports. Normal.
