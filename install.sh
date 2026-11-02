#!/bin/sh
# Installer for elektro-l3-scripts (POSIX sh; safe to pipe into sh).
#
#   curl -fsSL https://raw.githubusercontent.com/ch3p4ll3/elektro-l3-scripts/main/install.sh | sh
#   curl -fsSL .../install.sh | sh -s -- --home /data/elektro_l3 --enable
#   curl -fsSL .../install.sh | sh -s -- --uninstall
#
# Run it as your normal user: sudo is used only for the system-wide steps.

set -eu

REPO_URL="${L3_REPO_URL:-https://github.com/ch3p4ll3/elektro-l3-scripts.git}"
BRANCH="${L3_BRANCH:-}"
BIN_DIR="${L3_BIN_DIR:-/usr/local/bin}"
UNIT_DIR="${L3_UNIT_DIR:-/etc/systemd/system}"
CONF_FILE="${L3_CONF:-/etc/elektro-l3.conf}"
HOME_ARG="${L3_HOME:-}"

ACTION=install
ENABLE=0
SYSTEMD=1
PURGE=0

# ---------------------------------------------------------------- helpers
info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

usage() {
    cat <<'EOF'
Usage: install.sh [options]

  --home DIR      elektro_l3 data folder used by every script
                  (default: ~/Desktop/elektro_l3). Layout inside it:
                  lrit/{products,images,timelapses}, hrit/products
  --enable        enable and start the l3-lrit / l3-hrit systemd timers
  --no-systemd    install scripts only, skip systemd units
  --uninstall     remove everything this installer put in place
  --purge         with --uninstall: also delete the cloned sources
  -h, --help      show this help

Environment: L3_HOME (same as --home), L3_REPO_URL, L3_BRANCH, L3_SRC_DIR,
             L3_BIN_DIR, L3_UNIT_DIR, L3_CONF (default /etc/elektro-l3.conf)

Installed commands (in the bin dir): l3-lrit.sh, l3-hrit.sh,
l3-generate-images, l3-generate-timelapse. All of them accept -d DIR to
override the data folder for a single run.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --home)       [ $# -ge 2 ] || die "--home needs a directory"; HOME_ARG="$2"; shift ;;
        --home=*)     HOME_ARG="${1#--home=}" ;;
        --enable)     ENABLE=1 ;;
        --no-systemd) SYSTEMD=0 ;;
        --uninstall)  ACTION=uninstall ;;
        --purge)      PURGE=1 ;;
        -h|--help)    usage; exit 0 ;;
        *) die "unknown option: $1 (try --help)" ;;
    esac
    shift
done

# ------------------------------------------------- who are we installing for
if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
    TARGET_USER="$SUDO_USER"
else
    TARGET_USER="$(id -un)"
fi

if have getent; then
    TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
else
    TARGET_HOME="$(eval echo "~$TARGET_USER")"
fi
[ -n "$TARGET_HOME" ] && [ -d "$TARGET_HOME" ] || die "cannot determine home of $TARGET_USER"

# elektro_l3 data folder: expand a leading ~, require an absolute path
if [ -z "$HOME_ARG" ]; then
    L3_HOME_DIR="$TARGET_HOME/Desktop/elektro_l3"
else
    case "$HOME_ARG" in
        "~")   HOME_ARG="$TARGET_HOME" ;;
        "~/"*) HOME_ARG="$TARGET_HOME/${HOME_ARG#"~/"}" ;;
    esac
    case "$HOME_ARG" in
        /*) ;;
        *) die "--home must be an absolute path (got: $HOME_ARG)" ;;
    esac
    L3_HOME_DIR="${HOME_ARG%/}"
fi
case "$L3_HOME_DIR" in
    *[!A-Za-z0-9_./@%+=:,-]*) die "--home contains unsupported characters (letters, digits and _ . / @ % + = : , - only): $L3_HOME_DIR" ;;
esac
[ -n "$L3_HOME_DIR" ] || die "--home cannot be /"

SRC_DIR="${L3_SRC_DIR:-$TARGET_HOME/.local/share/elektro-l3-scripts}"
MANIFEST="$SRC_DIR.manifest"

# ---------------------------------------------------------------- privileges
if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
elif have sudo; then
    SUDO="sudo"
else
    SUDO=""
    warn "not root and sudo not found: system-wide steps may fail"
fi

# Run a command as the target user (needed only when invoked via sudo/root),
# so files created in the user's home are owned by them.
as_target() {
    if [ "$(id -u)" -eq 0 ] && [ "$TARGET_USER" != root ]; then
        if have runuser; then runuser -u "$TARGET_USER" -- "$@"
        elif have sudo;  then sudo -u "$TARGET_USER" "$@"
        else die "need runuser or sudo to act as $TARGET_USER"
        fi
    else
        "$@"
    fi
}

pkg_install() {
    if   have dnf;     then $SUDO dnf install -y "$@"
    elif have apt-get; then $SUDO apt-get update -qq && $SUDO apt-get install -y "$@"
    elif have pacman;  then $SUDO pacman -S --noconfirm --needed "$@"
    elif have zypper;  then $SUDO zypper --non-interactive install "$@"
    else die "no supported package manager found; please install: $*"
    fi
}

# install_file MODE SRC DST - copy a file, pointing User= at the target user
install_file() {
    _tmp="$(mktemp)"
    sed -e "s#^User=.*#User=$TARGET_USER#" "$2" > "$_tmp"
    $SUDO install -D -m "$1" "$_tmp" "$3"
    rm -f "$_tmp"
    echo "$3" >> "$MANIFEST.new"
}

# ---------------------------------------------------------------- uninstall
do_uninstall() {
    [ -f "$MANIFEST" ] || die "no manifest at $MANIFEST: nothing to uninstall"
    info "Removing installed files"
    if have systemctl && [ "$SYSTEMD" -eq 1 ]; then
        while IFS= read -r f; do
            case "$f" in
                "$UNIT_DIR"/*.timer) $SUDO systemctl disable --now "$(basename "$f")" 2>/dev/null || true ;;
            esac
        done < "$MANIFEST"
    fi
    while IFS= read -r f; do
        if [ -n "$f" ]; then
            $SUDO rm -f "$f"
            echo "  removed $f"
        fi
    done < "$MANIFEST"
    if have systemctl; then $SUDO systemctl daemon-reload || true; fi
    rm -f "$MANIFEST"
    if [ "$PURGE" -eq 1 ]; then
        rm -rf "$SRC_DIR"
        info "Deleted $SRC_DIR"
    fi
    info "Done. Your data folder was left untouched."
}

# ------------------------------------------------------------------- install
do_install() {
    # 1. prerequisites
    if ! have git; then
        info "Installing git"
        pkg_install git
    fi
    have satdump || warn "satdump not found in PATH (needed by every script); see the README"
    have ffmpeg  || warn "ffmpeg not found (only needed by l3-generate-timelapse)"

    # 2. fetch the sources (as the target user)
    as_target mkdir -p "$(dirname "$SRC_DIR")"
    if [ -d "$SRC_DIR/.git" ]; then
        info "Updating $SRC_DIR"
        as_target git -C "$SRC_DIR" fetch --quiet --tags origin
        if [ -n "$BRANCH" ]; then as_target git -C "$SRC_DIR" checkout --quiet "$BRANCH"; fi
        as_target git -C "$SRC_DIR" pull --quiet --ff-only || warn "could not fast-forward; using local copy"
    else
        info "Cloning $REPO_URL"
        if [ -n "$BRANCH" ]; then
            as_target git clone --quiet --depth 1 --branch "$BRANCH" "$REPO_URL" "$SRC_DIR"
        else
            as_target git clone --quiet --depth 1 "$REPO_URL" "$SRC_DIR"
        fi
    fi

    : > "$MANIFEST.new"

    # 3. config file read by all scripts
    info "Writing $CONF_FILE (L3_HOME=$L3_HOME_DIR)"
    _tmp="$(mktemp)"
    printf '# elektro-l3-scripts: data folder shared by all scripts\nL3_HOME=%s\n' "$L3_HOME_DIR" > "$_tmp"
    $SUDO install -D -m 0644 "$_tmp" "$CONF_FILE"
    rm -f "$_tmp"
    echo "$CONF_FILE" >> "$MANIFEST.new"

    # 4. scripts
    info "Installing scripts to $BIN_DIR"
    for f in l3-lrit.sh l3-hrit.sh; do
        [ -f "$SRC_DIR/receive/$f" ] || die "missing $SRC_DIR/receive/$f"
        install_file 0755 "$SRC_DIR/receive/$f" "$BIN_DIR/$f"
        echo "  $f"
    done
    for pair in generate_images.sh:l3-generate-images generate_timelapse.sh:l3-generate-timelapse; do
        src="${pair%%:*}"; dst="${pair#*:}"
        [ -f "$SRC_DIR/postprocess/$src" ] || die "missing $SRC_DIR/postprocess/$src"
        install_file 0755 "$SRC_DIR/postprocess/$src" "$BIN_DIR/$dst"
        echo "  $dst"
    done

    # 5. systemd units
    if [ "$SYSTEMD" -eq 1 ] && have systemctl; then
        info "Installing systemd units to $UNIT_DIR (User=$TARGET_USER)"
        timers=""
        for f in "$SRC_DIR"/receive/systemd/*.service "$SRC_DIR"/receive/systemd/*.timer; do
            [ -f "$f" ] || continue
            install_file 0644 "$f" "$UNIT_DIR/$(basename "$f")"
            echo "  $(basename "$f")"
            case "$f" in *.timer) timers="$timers $(basename "$f")" ;; esac
        done
        $SUDO systemctl daemon-reload
        if [ "$ENABLE" -eq 1 ] && [ -n "$timers" ]; then
            # shellcheck disable=SC2086
            $SUDO systemctl enable --now $timers
        fi
    elif [ "$SYSTEMD" -eq 1 ]; then
        warn "systemctl not found: skipping units"
    fi

    # 6. data folders, created as the target user
    as_target mkdir -p "$L3_HOME_DIR/lrit/products" "$L3_HOME_DIR/hrit/products"

    # 7. remember what we installed (for --uninstall)
    sort -u "$MANIFEST.new" > "$MANIFEST"
    rm -f "$MANIFEST.new"
    if [ "$(id -u)" -eq 0 ] && [ "$TARGET_USER" != root ]; then chown "$TARGET_USER" "$MANIFEST"; fi

    info "Installed."
    cat <<EOF

  Data folder : $L3_HOME_DIR   (change later by editing $CONF_FILE)
  Sources     : $SRC_DIR
  Commands    : $BIN_DIR/{l3-lrit.sh,l3-hrit.sh,l3-generate-images,l3-generate-timelapse}

  Update      : re-run the same install command
  Remove      : curl -fsSL <url>/install.sh | sh -s -- --uninstall
EOF
    if [ "$ENABLE" -eq 0 ] && [ "$SYSTEMD" -eq 1 ]; then
        echo "  Schedule    : re-run with --enable (or: sudo systemctl enable --now l3-lrit.timer l3-hrit.timer)"
    fi
}

case "$ACTION" in
    install)   do_install ;;
    uninstall) do_uninstall ;;
esac
