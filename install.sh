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
INSTALL_DIR="$HOME/MTproxy-Telemt-tg-ui"
OLD_INSTALL_DIR="$HOME/MTproxy-Telmet-tg-ui"  # legacy typo name

# Migrate old folder name (Telmet → Telemt) transparently
if [ -d "$OLD_INSTALL_DIR" ] && [ ! -d "$INSTALL_DIR" ]; then
  mv "$OLD_INSTALL_DIR" "$INSTALL_DIR"
  # Update symlink if it still points to the old path
  if [ -L /usr/local/bin/tg-ui ]; then
    _old_target=$(readlink /usr/local/bin/tg-ui 2>/dev/null || true)
    if [[ "$_old_target" == *"MTproxy-Telmet-tg-ui"* ]]; then
      ln -sf "$INSTALL_DIR/tg-ui.sh" /usr/local/bin/tg-ui 2>/dev/null || true
    fi
  fi
fi

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
  local rc=0
  wait $pid || rc=$?
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

# Detect package manager once
_PKG=""
if   command -v apt     >/dev/null 2>&1; then _PKG="apt"
elif command -v dnf     >/dev/null 2>&1; then _PKG="dnf"
elif command -v yum     >/dev/null 2>&1; then _PKG="yum"
elif command -v zypper  >/dev/null 2>&1; then _PKG="zypper"
elif command -v pacman  >/dev/null 2>&1; then _PKG="pacman"
elif command -v apk     >/dev/null 2>&1; then _PKG="apk"
fi

# Add Docker CE repo for rpm-based distros (yum/dnf)
_add_docker_repo_rpm() {
    local mgr="$1"
    # yum-utils provides yum-config-manager (works for both yum and dnf)
    if ! command -v yum-config-manager >/dev/null 2>&1; then
        run_with_spinner "Installing yum-utils" sudo "$mgr" install -y yum-utils
    fi
    if ! sudo "$mgr" repolist 2>/dev/null | grep -q "docker-ce"; then
        local os_id
        os_id=$(grep -oP '(?<=^ID=).+' /etc/os-release 2>/dev/null | tr -d '"' || echo "centos")
        local repo_url="https://download.docker.com/linux/centos/docker-ce.repo"
        [[ "$os_id" == "fedora" ]] && repo_url="https://download.docker.com/linux/fedora/docker-ce.repo"
        run_with_spinner "Adding Docker CE repo" sudo yum-config-manager --add-repo "$repo_url"
    fi
}

# ── Docker ────────────────────────────────────────────────────
if ! command -v docker >/dev/null 2>&1; then
    _log "Docker not found — installing..."
    case "$_PKG" in
        apt)
            run_with_spinner "Installing Docker" sudo apt install -y docker.io git xxd qrencode
            ;;
        dnf)
            _add_docker_repo_rpm dnf
            # EPEL exists on RHEL/CentOS/Rocky/Alma but NOT on Fedora — skip silently if missing
            sudo dnf install -y epel-release >/dev/null 2>&1 || true
            run_with_spinner "Installing Docker CE" sudo dnf install -y \
                docker-ce docker-ce-cli containerd.io docker-compose-plugin git vim-common qrencode
            run_with_spinner "Enabling Docker" bash -c "sudo systemctl enable --now docker"
            ;;
        yum)
            # CentOS 7 EOL (June 2024): ALL standard mirrors are dead.
            # Must redirect repos to vault.centos.org BEFORE any yum operation —
            # even get.docker.com fails because it calls yum makecache internally.
            run_with_spinner "Fixing CentOS 7 repos → vault.centos.org" bash -c "
                sed -i 's/mirror.centos.org/vault.centos.org/g' /etc/yum.repos.d/CentOS-*.repo
                sed -i 's|^mirrorlist=|#mirrorlist=|g'          /etc/yum.repos.d/CentOS-*.repo
                sed -i 's|^#baseurl=|baseurl=|g'                /etc/yum.repos.d/CentOS-*.repo
                yum clean all -q
            "
            _add_docker_repo_rpm yum
            sudo yum remove -y runc >/dev/null 2>&1 || true
            sudo yum install -y epel-release >/dev/null 2>&1 || true
            run_with_spinner "Installing Docker CE + tools" sudo yum install -y \
                docker-ce docker-ce-cli containerd.io git vim-common qrencode
            run_with_spinner "Enabling Docker" bash -c "sudo systemctl enable docker && sudo systemctl start docker"
            ;;
        zypper)
            run_with_spinner "Installing Docker" sudo zypper install -y docker git vim qrencode
            run_with_spinner "Enabling Docker" bash -c "sudo systemctl enable --now docker"
            ;;
        pacman)
            run_with_spinner "Installing Docker" sudo pacman -S --noconfirm docker git vim qrencode
            run_with_spinner "Enabling Docker" bash -c "sudo systemctl enable --now docker"
            ;;
        apk)
            run_with_spinner "Installing Docker" sudo apk add docker git vim qrencode
            run_with_spinner "Enabling Docker" bash -c "sudo rc-update add docker boot && sudo service docker start"
            ;;
        *)
            _fail "Cannot install Docker automatically. Please install it manually."
            exit 1
            ;;
    esac
else
    _ok "Docker  $(docker --version 2>/dev/null | sed 's/Docker version /v/' | cut -d, -f1)"
fi

# ── Docker Compose ────────────────────────────────────────────
if ! docker-compose version >/dev/null 2>&1 && ! docker compose version >/dev/null 2>&1; then
    _log "docker-compose not found — installing..."
    case "$_PKG" in
        apt)
            run_with_spinner "Installing docker-compose" sudo apt install -y docker-compose
            ;;
        dnf)
            # docker-compose-plugin (installed above) provides 'docker compose'
            # fallback: standalone package or pip
            if ! run_with_spinner "Installing docker-compose" sudo dnf install -y docker-compose-plugin; then
                run_with_spinner "Installing docker-compose via pip" \
                    bash -c "pip3 install docker-compose 2>/dev/null || pip install docker-compose"
            fi
            ;;
        yum)
            # CentOS 7: no standalone package in Docker CE repo, use pip
            if ! run_with_spinner "Installing docker-compose" sudo yum install -y docker-compose; then
                run_with_spinner "Installing docker-compose via pip" \
                    bash -c "pip3 install docker-compose 2>/dev/null || pip install docker-compose"
            fi
            ;;
        zypper)
            run_with_spinner "Installing docker-compose" sudo zypper install -y docker-compose
            ;;
        pacman)
            run_with_spinner "Installing docker-compose" sudo pacman -S --noconfirm docker-compose
            ;;
        apk)
            run_with_spinner "Installing docker-compose" sudo apk add docker-compose
            ;;
        *)
            _fail "Cannot install docker-compose automatically."
            exit 1
            ;;
    esac
else
    _ok "Docker Compose"
fi

# ── git + xxd + qrencode ──────────────────────────────────────
if ! command -v git >/dev/null 2>&1 || ! command -v xxd >/dev/null 2>&1; then
    case "$_PKG" in
        apt)
            run_with_spinner "Installing git + xxd + qrencode" sudo apt install -y git xxd qrencode
            ;;
        dnf)
            sudo dnf install -y epel-release >/dev/null 2>&1 || true
            run_with_spinner "Installing git + xxd + qrencode" sudo dnf install -y git vim-common qrencode
            ;;
        yum)
            sudo yum install -y epel-release >/dev/null 2>&1 || true
            run_with_spinner "Installing git + xxd + qrencode" sudo yum install -y git vim-common qrencode
            ;;
        zypper)
            run_with_spinner "Installing git + xxd + qrencode" sudo zypper install -y git vim qrencode
            ;;
        pacman)
            run_with_spinner "Installing git + xxd + qrencode" sudo pacman -S --noconfirm git vim qrencode
            ;;
        apk)
            run_with_spinner "Installing git + xxd + qrencode" sudo apk add git vim qrencode
            ;;
    esac
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
            case "$_PKG" in
                apt)    sudo apt install -y git ;;
                dnf)    sudo dnf install -y git ;;
                yum)    sudo yum install -y git ;;
                zypper) sudo zypper install -y git ;;
                pacman) sudo pacman -S --noconfirm git ;;
                apk)    sudo apk add git ;;
            esac
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
    # Ensure /usr/local/bin is in PATH for all future shells (fixes CentOS minimal installs)
    if ! echo "$PATH" | grep -q "/usr/local/bin"; then
        echo 'export PATH="/usr/local/bin:$PATH"' | sudo tee /etc/profile.d/local-bin.sh >/dev/null
        export PATH="/usr/local/bin:$PATH"
    fi
    _ok "tg-ui  →  /usr/local/bin/tg-ui"
else
    _fail "tg-ui.sh not found in $PROJECT_DIR"
    exit 1
fi

# ── Autostart (cron → systemd → OpenRC fallback) ─────────────
_setup_autostart_done=false

# 1) Try cron (@reboot) — works on Ubuntu/Debian/CentOS/RHEL out of the box
if ! $_setup_autostart_done && command -v crontab >/dev/null 2>&1; then
    _TMP_CRON=$(mktemp)
    (crontab -l 2>/dev/null | grep -v "tg-ui --auto" || true
     echo "@reboot sleep 15 && /usr/local/bin/tg-ui --auto") > "$_TMP_CRON"
    if crontab "$_TMP_CRON" 2>/dev/null; then
        _ok "Autostart registered  (@reboot cron)"
        _setup_autostart_done=true
    fi
    rm -f "$_TMP_CRON"
fi

# 2) If cron missing — install cronie and retry (Arch/Fedora/openSUSE)
if ! $_setup_autostart_done && ! command -v crontab >/dev/null 2>&1; then
    case "$_PKG" in
        pacman) run_with_spinner "Installing cronie" sudo pacman -S --noconfirm cronie
                sudo systemctl enable --now cronie >/dev/null 2>&1 ;;
        dnf)    run_with_spinner "Installing cronie" sudo dnf install -y cronie
                sudo systemctl enable --now crond >/dev/null 2>&1 ;;
        zypper) run_with_spinner "Installing cron"   sudo zypper install -y cronie
                sudo systemctl enable --now cron >/dev/null 2>&1 ;;
    esac
    if command -v crontab >/dev/null 2>&1; then
        _TMP_CRON=$(mktemp)
        (crontab -l 2>/dev/null | grep -v "tg-ui --auto" || true
         echo "@reboot sleep 15 && /usr/local/bin/tg-ui --auto") > "$_TMP_CRON"
        crontab "$_TMP_CRON" 2>/dev/null && _setup_autostart_done=true
        rm -f "$_TMP_CRON"
        $_setup_autostart_done && _ok "Autostart registered  (@reboot cron)"
    fi
fi

# 3) Fallback: systemd service (all systemd distros)
if ! $_setup_autostart_done && command -v systemctl >/dev/null 2>&1; then
    sudo tee /etc/systemd/system/tg-ui-autostart.service >/dev/null <<'UNIT'
[Unit]
Description=MTProxy Telemt autostart
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 15
ExecStart=/usr/local/bin/tg-ui --auto
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
    sudo systemctl daemon-reload >/dev/null 2>&1
    sudo systemctl enable tg-ui-autostart >/dev/null 2>&1
    _ok "Autostart registered  (systemd)"
    _setup_autostart_done=true
fi

# 4) Fallback: OpenRC local.d (Alpine)
if ! $_setup_autostart_done && command -v rc-update >/dev/null 2>&1; then
    sudo mkdir -p /etc/local.d
    printf '#!/bin/sh\nsleep 15 && /usr/local/bin/tg-ui --auto &\n' \
        | sudo tee /etc/local.d/tg-ui.start >/dev/null
    sudo chmod +x /etc/local.d/tg-ui.start
    sudo rc-update add local default >/dev/null 2>&1 || true
    _ok "Autostart registered  (OpenRC)"
    _setup_autostart_done=true
fi

$_setup_autostart_done || _fail "Could not register autostart — start manually with: tg-ui start"

# ── Phase 4: Startup ──────────────────────────────────────────
echo
printf "  \033[1mLaunching proxy\033[0m\n"

if /usr/local/bin/tg-ui start; then
    # Open proxy port in firewall (firewalld on CentOS/RHEL, ufw on Ubuntu)
    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state 2>/dev/null | grep -q "running"; then
        firewall-cmd --permanent --add-port="${PORT:-8443}/tcp" >/dev/null 2>&1 && \
        firewall-cmd --reload >/dev/null 2>&1 && \
        _ok "Firewall: port ${PORT:-8443}/tcp opened  (firewalld)"
    elif command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "active"; then
        ufw allow "${PORT:-8443}/tcp" >/dev/null 2>&1 && \
        _ok "Firewall: port ${PORT:-8443}/tcp opened  (ufw)"
    fi

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
