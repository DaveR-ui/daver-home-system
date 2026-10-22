#!/usr/bin/env bash
#
# Install, upgrade, remove or inspect the Home Keys Plasma applet, and store
# its Home Assistant long-lived token in KWallet.
#
#   ./install.sh [install|upgrade|remove|status] [options]
#   ./install.sh token [--wallet NAME] [--folder NAME] [--key NAME]
#
# The token is read from stdin without echo and piped to kwallet-query's -w
# mode: it never appears on a command line, in a file, or in this script's
# output.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLASMOID_ID="io.github.daver-ui.homekeys"
PLASMOID_SRC="$SCRIPT_DIR/$PLASMOID_ID"
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}"
PLASMOID_DEST="$DATA_DIR/plasma/plasmoids/$PLASMOID_ID"

# Defaults mirror contents/config/main.xml.
WALLET="kdewallet"
FOLDER="DaverHomeSystem"
KEY="ha-token"

say() { printf '%s\n' "$*"; }
die() { printf 'homekeys: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage:
  ./install.sh [install]              Install the plasmoid (default).
  ./install.sh upgrade                Upgrade an installed plasmoid.
  ./install.sh remove                 Remove the plasmoid.
  ./install.sh status                 Report whether it is installed.
  ./install.sh token [options]        Store the HA token in KWallet (stdin, no echo).

Options for "token":
  --wallet NAME    KWallet wallet name   (default: kdewallet)
  --folder NAME    KWallet folder name   (default: DaverHomeSystem)
  --key NAME       KWallet entry key     (default: ha-token)
EOF
}

have_kpackagetool() {
    command -v kpackagetool6 >/dev/null 2>&1
}

# True when the applet is already present, by the same test `status` uses.
plasmoid_is_installed() {
    if have_kpackagetool; then
        kpackagetool6 --type Plasma/Applet --list 2>/dev/null | grep -qF "$PLASMOID_ID"
        return
    fi
    [ -d "$PLASMOID_DEST" ]
}

next_steps() {
    say ""
    say "Next steps:"
    say "  1. Add the widget: right-click the panel or desktop -> Add Widgets... -> Home Keys."
    say "  2. If it does not appear, restart plasmashell: kquitapp6 plasmashell && kstart plasmashell"
    say "  3. If the widget says the token is missing, run: $SCRIPT_DIR/install.sh token"
}

do_install() {
    [ -d "$PLASMOID_SRC" ] || die "plasmoid source not found: $PLASMOID_SRC"

    if have_kpackagetool; then
        if plasmoid_is_installed; then
            say "Plasmoid already installed; upgrading instead: $PLASMOID_ID"
            kpackagetool6 --type Plasma/Applet --upgrade "$PLASMOID_SRC"
            say "Upgraded plasmoid: $PLASMOID_ID"
        else
            kpackagetool6 --type Plasma/Applet --install "$PLASMOID_SRC"
            say "Installed plasmoid: $PLASMOID_ID"
        fi
    else
        if [ -d "$PLASMOID_DEST" ]; then
            say "Copied plasmoid already present; replacing it: $PLASMOID_DEST"
        else
            say "kpackagetool6 not found; copying the package instead."
        fi
        mkdir -p -- "$(dirname -- "$PLASMOID_DEST")"
        rm -rf -- "$PLASMOID_DEST"
        mkdir -p -- "$PLASMOID_DEST"
        cp -r -- "$PLASMOID_SRC/." "$PLASMOID_DEST/"
        say "Copied plasmoid to: $PLASMOID_DEST"
    fi
    next_steps
}

do_upgrade() {
    [ -d "$PLASMOID_SRC" ] || die "plasmoid source not found: $PLASMOID_SRC"

    if have_kpackagetool; then
        if kpackagetool6 --type Plasma/Applet --upgrade "$PLASMOID_SRC"; then
            say "Upgraded plasmoid: $PLASMOID_ID"
        else
            die "upgrade failed; is the applet installed? Run: $SCRIPT_DIR/install.sh install"
        fi
    else
        say "kpackagetool6 not found; copying the package instead."
        rm -rf -- "$PLASMOID_DEST"
        mkdir -p -- "$PLASMOID_DEST"
        cp -r -- "$PLASMOID_SRC/." "$PLASMOID_DEST/"
        say "Copied plasmoid to: $PLASMOID_DEST"
    fi
    next_steps
}

do_remove() {
    if have_kpackagetool; then
        if kpackagetool6 --type Plasma/Applet --remove "$PLASMOID_ID"; then
            say "Removed plasmoid: $PLASMOID_ID"
        else
            say "Plasmoid is not installed (nothing to remove)."
        fi
    else
        if [ -d "$PLASMOID_DEST" ]; then
            rm -rf -- "$PLASMOID_DEST"
            say "Removed copied plasmoid: $PLASMOID_DEST"
        else
            say "Plasmoid is not installed (nothing to remove)."
        fi
    fi
}

do_status() {
    if have_kpackagetool; then
        if kpackagetool6 --type Plasma/Applet --list 2>/dev/null | grep -qF "$PLASMOID_ID"; then
            say "Installed: $PLASMOID_ID"
            return 0
        fi
        say "Not installed: $PLASMOID_ID"
        return 1
    fi

    if [ -d "$PLASMOID_DEST" ]; then
        say "Installed (copied): $PLASMOID_ID"
        return 0
    fi
    say "Not installed: $PLASMOID_ID"
    return 1
}

do_token() {
    command -v kwallet-query >/dev/null 2>&1 \
        || die "kwallet-query not found; install the KWallet command-line tools."

    say "Reading the Home Assistant long-lived token from stdin (input is not echoed)."
    printf 'Token: ' >&2

    local token
    IFS= read -r -s token || true
    printf '\n' >&2

    [ -n "$token" ] || die "empty token; nothing was stored."

    # The secret travels on stdin. Only the wallet, folder and entry key -- all
    # non-secret -- are on the command line.
    printf '%s' "$token" | kwallet-query --folder "$FOLDER" -w "$KEY" "$WALLET" >/dev/null
    unset token

    say "Stored the token in KWallet ($WALLET/$FOLDER/$KEY)."
    say "The widget reads it at startup and again whenever Retry is pressed after Home Assistant rejected the token."
}

command_name=""
while [ $# -gt 0 ]; do
    case "$1" in
        install|upgrade|remove|status|token)
            [ -z "$command_name" ] || die "only one subcommand may be given"
            command_name="$1"
            shift
            ;;
        --wallet)
            [ $# -ge 2 ] || die "--wallet needs a value"
            WALLET="$2"
            shift 2
            ;;
        --folder)
            [ $# -ge 2 ] || die "--folder needs a value"
            FOLDER="$2"
            shift 2
            ;;
        --key)
            [ $# -ge 2 ] || die "--key needs a value"
            KEY="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown argument: $1 (try --help)"
            ;;
    esac
done

command_name="${command_name:-install}"

case "$command_name" in
    install) do_install ;;
    upgrade) do_upgrade ;;
    remove) do_remove ;;
    status) do_status ;;
    token) do_token ;;
    *) die "unknown subcommand: $command_name" ;;
esac
