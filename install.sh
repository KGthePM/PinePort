#!/usr/bin/env bash
# PinePort installer. Safe to re-run: a second run updates the installed copy
# and restarts the service, keeping your PIN and labels.
#
#   ./install.sh              install or update
#   ./install.sh --reset-pin  install/update and choose a new PIN
#   ./install.sh --uninstall  remove everything this script installed
#   pineports-uninstall       same, from anywhere (installed copy of this script)
set -euo pipefail

BIN="$HOME/.local/bin"
CONF="$HOME/.config"
UNIT_DIR="$CONF/systemd/user"
PIN_FILE="$CONF/pineports-pin"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

say()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

# prompts read from the terminal directly so they still work if stdin is piped
ask_yn() {  # ask_yn "question" -> 0 on yes (default no)
    local a
    read -r -p "$1 [y/N] " a </dev/tty || return 1
    [[ $a == [yY]* ]]
}

# ports-wrapper is ours if it execs pineports; never clobber some other `ports`
is_our_wrapper() { [[ ! -e $1 ]] || grep -q pineports "$1" 2>/dev/null; }

set_pin() {
    local p1 p2
    while :; do
        read -r -s -p "Choose a PIN for the web dashboard: " p1 </dev/tty; echo
        [[ -n $p1 ]] || { warn "PIN can't be empty"; continue; }
        read -r -s -p "Repeat PIN: " p2 </dev/tty; echo
        [[ $p1 == "$p2" ]] && break
        warn "PINs didn't match, try again"
    done
    # sha256 of the PIN with no trailing newline, readable only by you
    (umask 077; printf '%s' "$p1" | sha256sum | cut -d' ' -f1 > "$PIN_FILE")
    chmod 600 "$PIN_FILE"
    say "PIN saved (hashed) to $PIN_FILE"
}

uninstall() {
    say "Stopping and removing the pineports service"
    systemctl --user disable --now pineports 2>/dev/null || true
    rm -f "$UNIT_DIR/pineports.service"
    systemctl --user daemon-reload

    rm -f "$BIN/pineports" "$BIN/pineports-docker" "$BIN/pineports-uninstall"
    say "Removed pineports, pineports-docker and pineports-uninstall from $BIN"
    if is_our_wrapper "$BIN/ports"; then rm -f "$BIN/ports"
    else warn "Left $BIN/ports alone (not PinePort's wrapper)"; fi

    if ask_yn "Also delete your PIN, labels and port history in $CONF?"; then
        rm -f "$PIN_FILE" "$CONF/pineports-labels.conf" \
              "$CONF/pineports-seen.json" "$CONF/pineports-seen.json.tmp"
        say "Config deleted"
    else
        say "Kept config in $CONF/pineports-*"
    fi

    if [[ $(loginctl show-user "$USER" -p Linger --value 2>/dev/null) == yes ]] &&
       ask_yn "Turn off linger? (only if nothing else of yours needs to run while logged out)"; then
        loginctl disable-linger "$USER" && say "Linger off"
    fi
    say "PinePort uninstalled"
}

do_install() {
    local reset_pin=$1
    command -v python3   >/dev/null || die "python3 is required"
    command -v systemctl >/dev/null || die "systemd is required for the web dashboard"
    for f in pineports pineports-docker ports-wrapper systemd/pineports.service; do
        [[ -f $SRC/$f ]] || die "missing $f — run this from a PinePort checkout"
    done

    mkdir -p "$BIN" "$UNIT_DIR"

    say "Installing to $BIN"
    install -m 755 "$SRC/pineports" "$SRC/pineports-docker" "$BIN/"
    install -m 755 "$SRC/install.sh" "$BIN/pineports-uninstall"
    if is_our_wrapper "$BIN/ports"; then install -m 755 "$SRC/ports-wrapper" "$BIN/ports"
    else warn "$BIN/ports already exists and isn't PinePort's — skipped the 'ports' alias"; fi

    # labels are yours to edit: seed the example once, never overwrite
    [[ -f $CONF/pineports-labels.conf ]] || cp "$SRC/config/pineports-labels.conf" "$CONF/"

    if [[ ! -s $PIN_FILE || $reset_pin == 1 ]]; then set_pin
    else say "Keeping existing PIN (use --reset-pin to change it)"; fi

    say "Starting the web dashboard service"
    install -m 644 "$SRC/systemd/pineports.service" "$UNIT_DIR/"
    systemctl --user daemon-reload
    systemctl --user enable pineports >/dev/null 2>&1
    systemctl --user restart pineports   # restart, not start, so updates take effect

    # linger: start the service at boot and keep it up while you're logged out
    if [[ $(loginctl show-user "$USER" -p Linger --value 2>/dev/null) != yes ]]; then
        if loginctl enable-linger "$USER" 2>/dev/null; then
            say "Enabled linger: the dashboard now runs at boot, even when you're logged out"
        else
            warn "Couldn't enable linger; the dashboard will only run while you're logged in."
            warn "To fix: sudo loginctl enable-linger $USER"
        fi
    fi

    sleep 1
    systemctl --user is-active --quiet pineports ||
        die "service failed to start — see: journalctl --user -u pineports -n 30"

    case ":$PATH:" in *":$BIN:"*) ;; *)
        warn "$BIN is not on your PATH. Add this to ~/.bashrc (or your shell's rc):"
        warn "  export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
    esac

    if ! sudo -n /usr/bin/ss -tulpn >/dev/null 2>&1; then
        echo
        echo "Optional: to see and kill root-owned services, add this sudoers rule"
        echo "(sudo visudo -f /etc/sudoers.d/pineports):"
        echo "  $USER ALL=(root) NOPASSWD: /usr/bin/ss -tulpn, /usr/bin/kill"
    fi

    echo
    say "Done. Dashboard: http://$(hostname):6310"
    local ip; ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    if [[ -n $ip ]]; then say "      or:        http://$ip:6310"; fi
    say "CLI: pineports   |   kill: pineports kill <port>"
}

# the copy in ~/.local/bin only uninstalls; installing needs the repo files
if [[ $(basename "$0") == pineports-uninstall ]]; then
    case "${1:-}" in
        ""|--uninstall) uninstall; exit ;;
        -h|--help)      echo "pineports-uninstall: remove PinePort"; exit ;;
        *)              die "pineports-uninstall only uninstalls; run ./install.sh from a PinePort checkout to install" ;;
    esac
fi

case "${1:-}" in
    "")          do_install 0 ;;
    --reset-pin) do_install 1 ;;
    --uninstall) uninstall ;;
    -h|--help)   sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//' ;;
    *)           die "unknown option: $1 (try --help)" ;;
esac
