#!/bin/bash
# ══════════════════════════════════════════════════════════════
# MTproxy-Telemt-tg-ui - Installer v1.0.0 STABLE
# ══════════════════════════════════════════════════════════════
set -e

# Make sudo optional if not installed
if ! command -v sudo >/dev/null; then
  sudo() { "$@"; }
fi

REPO_URL="https://github.com/lyfreedomitsme/MTproxy-Telemt-tg-ui.git"
INSTALL_DIR="$HOME/MTproxy-Telmet-tg-ui"

# ── Colors ────────────────────────────────────────────────────
RESET='\033[0m'
BOLD='\033[1m'
DIM='\033[2m'
GREEN='\033[32m'
RED='\033[31m'
YELLOW='\033[33m'
CYAN='\033[36m'
NC='\033[0m'

# ── Argument Parsing ─────────────────────────────────────────
UPDATE_MODE=false
for arg in "$@"; do
  if [ "$arg" == "--update" ] || [ "$arg" == "update" ]; then
    UPDATE_MODE=true
  fi
done

# ── Helpers ───────────────────────────────────────────────────
_ok()   { printf "  \033[32m✓\033[0m  \033[2m%s\033[0m\n" "$1"; }
_fail() { printf "  \033[31m✗\033[0m  %s\n" "$1"; }
_log()  { printf "  \033[2m%s\033[0m\n" "$1"; }

# run_with_spinner <label> <cmd...>  — runs cmd in bg, animates spinner
run_with_spinner() {
  local label="$1"; shift
  local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  local i=0
  "$@" &>/tmp/_inst_out &
  local pid=$!
  while kill -0 $pid 2>/dev/null; do
    printf "\r  \033[32m%s\033[0m  \033[2m%s\033[0m " "${frames[$((i % 10))]}" "$label"
    i=$((i+1)); sleep 0.08
  done
  wait $pid; local rc=$?
  if [ $rc -eq 0 ]; then
    printf "\r  \033[32m✓\033[0m  \033[2m%-60s\033[0m\n" "$label"
  else
    printf "\r  \033[31m✗\033[0m  \033[2m%-60s\033[0m\n" "$label"
    cat /tmp/_inst_out
  fi
  rm -f /tmp/_inst_out
  return $rc
}

# ── Header ────────────────────────────────────────────────────
tput civis 2>/dev/null || true
trap 'tput cnorm 2>/dev/null || true' EXIT

echo
printf "  \033[38;2;255;120;0m\033[1mMTProxy-Telemt-tg-ui\033[0m  \033[2m·  Installer\033[0m\n"
printf "  \033[2m──────────────────────────────────────────────────────\033[0m\n"

# ── Phase 1: Dependencies ─────────────────────────────────────
echo
printf "  \033[1mChecking dependencies\033[0m\n"

if ! command -v docker >/dev/null 2>&1; then
    _log "Docker not found — installing..."
    if command -v apt >/dev/null 2>&1; then
        run_with_spinner "Installing Docker" sudo apt install -y docker.io xxd git qrencode
    elif command -v yum >/dev/null 2>&1; then
        run_with_spinner "Installing Docker" sudo yum install -y docker xxd git qrencode
        sudo systemctl start docker && sudo systemctl enable docker
    else
        _fail "Cannot install Docker automatically. Please install it manually."
        exit 1
    fi
else
    _ok "Docker  $(docker --version 2>/dev/null | sed 's/Docker version /v/' | cut -d, -f1)"
fi

if ! docker-compose version >/dev/null 2>&1 && ! docker compose version >/dev/null 2>&1; then
    _log "docker-compose not found — installing..."
    if command -v apt >/dev/null 2>&1; then
        run_with_spinner "Installing docker-compose" sudo apt install -y docker-compose
    elif command -v yum >/dev/null 2>&1; then
        run_with_spinner "Installing docker-compose" sudo yum install -y docker-compose
    else
        _fail "Cannot install docker-compose automatically."
        exit 1
    fi
else
    _ok "Docker Compose"
fi

if ! command -v git >/dev/null 2>&1 || ! command -v xxd >/dev/null 2>&1; then
    if command -v apt >/dev/null 2>&1; then
        run_with_spinner "Installing git + xxd + qrencode" sudo apt install -y git xxd qrencode
    elif command -v yum >/dev/null 2>&1; then
        run_with_spinner "Installing git + xxd + qrencode" sudo yum install -y git xxd qrencode
    fi
else
    _ok "git + xxd"
fi

# ── Detect project directory ───────────────────────────────────
if [[ "${BASH_SOURCE[0]}" == "/dev/fd/"* ]]; then
    if [ -f "tg-ui.sh" ]; then
        PROJECT_DIR=$(pwd)
        # Update mode: pull latest code if this is a git repo
        if [ "$UPDATE_MODE" == "true" ] && [ -d ".git" ]; then
            echo
            printf "  \033[1mPulling latest code\033[0m\n"
            run_with_spinner "git pull" git pull
        fi
    elif [ "$UPDATE_MODE" == "true" ] && [ -d "$INSTALL_DIR/.git" ]; then
        # Update mode from outside project dir: pull instead of wipe (preserve configs)
        echo
        printf "  \033[1mPulling latest code\033[0m\n"
        run_with_spinner "git pull" git -C "$INSTALL_DIR" pull
        cd "$INSTALL_DIR"
        PROJECT_DIR=$(pwd)
    else
        echo
        printf "  \033[1mCloning repository\033[0m\n"
        if ! command -v git >/dev/null 2>&1; then
            if command -v apt >/dev/null 2>&1; then sudo apt update && sudo apt install -y git
            elif command -v yum >/dev/null 2>&1; then sudo yum install -y git; fi
        fi
        rm -rf "$INSTALL_DIR"
        run_with_spinner "Cloning MTProxy-Telemt-tg-ui" git clone "$REPO_URL" "$INSTALL_DIR"
        cd "$INSTALL_DIR"
        PROJECT_DIR=$(pwd)
    fi
else
    SOURCE="${BASH_SOURCE[0]}"
    while [ -h "$SOURCE" ]; do
      DIR="$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )"
      SOURCE="$(readlink "$SOURCE")"
      [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
    done
    PROJECT_DIR="$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )"
fi

# ── Phase 2: Cleanup ──────────────────────────────────────────
echo
printf "  \033[1mCleaning previous installation\033[0m\n"

if [ "$UPDATE_MODE" == "true" ]; then
    _log "Update mode active — preserving existing configs and users"
else
    if [ -f "/usr/local/bin/tg-ui" ] || sudo docker ps -a --format '{{.Names}}' | grep -q "^telemt-proxy$"; then
        _log "Existing installation detected"
        sudo docker stop telemt-proxy >/dev/null 2>&1 || true
        sudo docker rm -f telemt-proxy >/dev/null 2>&1 || true
        _ok "Old container removed"
    fi

    rm -f "$HOME/.telemt-ui-config.env"
    if [ -f "$PROJECT_DIR/tg-ui.sh" ]; then
        rm -f "$PROJECT_DIR/.telemt-users.db" "$PROJECT_DIR/.env"
    fi
    _ok "Old configs cleared"
fi

# ── Phase 3: Configuration ────────────────────────────────────
echo
printf "  \033[1mInstalling management tool\033[0m\n"

TG_UI_SCRIPT="$PROJECT_DIR/tg-ui.sh"
if [ -f "$TG_UI_SCRIPT" ]; then
    chmod +x "$TG_UI_SCRIPT"
    sudo ln -sf "$TG_UI_SCRIPT" /usr/local/bin/tg-ui
    _ok "tg-ui  →  /usr/local/bin/tg-ui"
else
    _fail "tg-ui.sh not found in $PROJECT_DIR"
    exit 1
fi

TMP_CRON=$(mktemp)
(crontab -l 2>/dev/null | grep -v "tg-ui --auto" || true; echo "@reboot sleep 15 && /usr/local/bin/tg-ui --auto") > "$TMP_CRON"
crontab "$TMP_CRON" || true
rm -f "$TMP_CRON"
_ok "Autostart registered  (@reboot)"

# ── Phase 4: Startup ──────────────────────────────────────────
echo
printf "  \033[1mLaunching proxy\033[0m\n"

if /usr/local/bin/tg-ui start; then
    # Fix ownership: install runs as root, but tg-ui should be usable without sudo
    REAL_USER="${SUDO_USER:-$USER}"
    if [ "$REAL_USER" != "root" ]; then
      chown "$REAL_USER":"$REAL_USER" \
        "$PROJECT_DIR/.telemt-users.db" \
        "$PROJECT_DIR/.env" \
        "$HOME/.telemt-ui-config.env" 2>/dev/null || true
    fi
    tput cnorm 2>/dev/null || true
    echo
    printf "  \033[32m✓\033[0m  \033[1mSystem ready — Proxy is online\033[0m\n"
    printf "  \033[2m  manage  :\033[0m  tg-ui\n"
    printf "  \033[2m  qr code :\033[0m  tg-ui qr\n"
    echo
else
    tput cnorm 2>/dev/null || true
    _fail "Proxy startup failed — run  tg-ui start  to retry"
fi
