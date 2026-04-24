#!/bin/bash
# ══════════════════════════════════════════════════════════════
# MTProto Proxy Manager (tg-ui) - v1.0.0 STABLE
# ══════════════════════════════════════════════════════════════

RESET='\033[0m'
BOLD='\033[1m'
DIM='\033[2m'
GREEN='\033[32m'
RED='\033[31m'
YELLOW='\033[33m'
CYAN='\033[36m'
BLUE='\033[38;2;0;120;255m'
ORANGE='\033[38;2;255;120;0m'
NC='\033[0m'

# UI helpers
_ok()   { printf "  \033[32m✓\033[0m  \033[2m%s\033[0m\n" "$1"; }
_fail() { printf "  \033[31m✗\033[0m  %s\n" "$1"; }
_log()  { printf "  \033[2m%s\033[0m\n" "$1"; }
_spin() { printf "\r  \033[32m%s\033[0m  \033[2m%s\033[0m" "$1" "$2"; }
_spin_ok() { printf "\r  \033[32m✓\033[0m  \033[2m%-55s\033[0m\n" "$1"; }

# Legacy aliases
ok()   { _ok "$1"; }
fail() { _fail "$1"; }
info() { _log "$1"; }

# Package manager helpers (used for on-demand installs inside tg-ui)
_detect_pkg() {
  if   command -v apt-get >/dev/null 2>&1; then echo "apt"
  elif command -v dnf     >/dev/null 2>&1; then echo "dnf"
  elif command -v yum     >/dev/null 2>&1; then echo "yum"
  elif command -v zypper  >/dev/null 2>&1; then echo "zypper"
  elif command -v pacman  >/dev/null 2>&1; then echo "pacman"
  elif command -v apk     >/dev/null 2>&1; then echo "apk"
  fi
}

_pkg_install() {
  local _pm; _pm=$(_detect_pkg)
  case "$_pm" in
    apt)    sudo apt-get install -y "$@" >/dev/null 2>&1 ;;
    dnf)    sudo dnf install -y "$@" >/dev/null 2>&1 ;;
    yum)    sudo yum install -y "$@" >/dev/null 2>&1 ;;
    zypper) sudo zypper install -y "$@" >/dev/null 2>&1 ;;
    pacman) sudo pacman -S --noconfirm "$@" >/dev/null 2>&1 ;;
    apk)    sudo apk add "$@" >/dev/null 2>&1 ;;
  esac
}

# Resolve the real user's home directory (even if running via sudo)
REAL_HOME="$HOME"
if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
  REAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6 2>/dev/null || eval echo "~$SUDO_USER")
fi

CONFIG_FILE="$REAL_HOME/.telemt-ui-config.env"
CONTAINER_NAME="telemt-proxy"
IMAGE_NAME="telemt-custom"

# Resolve absolute path to the project directory, even if executed via symlink
SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do
  DIR="$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )"
  SOURCE="$(readlink "$SOURCE")"
  [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
PROJECT_DIR="$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )"

CONFIG_TOML="$PROJECT_DIR/config.toml"
USERS_DB="$PROJECT_DIR/.telemt-users.db"

# Make sudo optional if not installed
if ! command -v sudo >/dev/null; then
  sudo() { "$@"; }
fi

# Detect Docker Compose command (legacy binary vs modern plugin)
# Also detect if it's v1 (docker-compose) or v2 (docker compose plugin)
DOCKER_COMPOSE_V1=false
if docker compose version >/dev/null 2>&1; then
  DOCKER_COMPOSE="docker compose"
elif docker-compose version >/dev/null 2>&1; then
  DOCKER_COMPOSE="docker-compose"
  DOCKER_COMPOSE_V1=true
else
  echo -e "${RED}❌ Docker Compose is not installed!${NC}"
  exit 1
fi

function _write_compose_file() {
  if [ "$DOCKER_COMPOSE_V1" = true ]; then
    # v1: version 2.2, no tmpfs mount options
    cat > "$PROJECT_DIR/docker-compose.yml" <<'EOF'
version: "2.2"
services:
  telemt:
    image: ghcr.io/telemt/telemt:latest
    container_name: telemt-proxy
    restart: unless-stopped
    network_mode: "host"
    working_dir: /run/telemt
    read_only: true
    cap_drop:
      - ALL
    cap_add:
      - NET_BIND_SERVICE
      - NET_ADMIN
    security_opt:
      - no-new-privileges:true
    user: "65534:65534"
    ulimits:
      nofile:
        soft: 65536
        hard: 262144
    tmpfs:
      - /run/telemt
      - /etc/telemt
    volumes:
      - /dev/shm/telemt-tgui-config.toml:/run/telemt/config.toml:ro
EOF
  else
    # v2: no version field needed, full tmpfs options supported
    cat > "$PROJECT_DIR/docker-compose.yml" <<'EOF'
services:
  telemt:
    image: ghcr.io/telemt/telemt:latest
    pull_policy: always
    container_name: telemt-proxy
    restart: unless-stopped
    network_mode: "host"
    working_dir: /run/telemt
    read_only: true
    cap_drop:
      - ALL
    cap_add:
      - NET_BIND_SERVICE
      - NET_ADMIN
    security_opt:
      - no-new-privileges:true
    user: "65534:65534"
    ulimits:
      nofile:
        soft: 65536
        hard: 262144
    tmpfs:
      - /run/telemt:rw,size=128m,mode=1777
      - /etc/telemt:rw,size=16m,mode=1777
    volumes:
      - /dev/shm/telemt-tgui-config.toml:/run/telemt/config.toml:ro
EOF
  fi
}

# Default values for all settings
FAKE_DOMAIN="ya.ru"
PORT="8443"
INTERNAL_PORT="443"
USER_MAX_IPS="0"
SECRET=""
SERVER_IP=""
MASK_ENABLED="true"
LOG_LEVEL="normal"
MASK_PORT="443"
PROXY_PROTOCOL="false"
PROXY_PROTOCOL_CIDRS=""
MIKROTIK_EXT_PORT="${MIKROTIK_EXT_PORT:-443}"

# Load persistent variables if they exist
if [ -f "$CONFIG_FILE" ]; then
  source "$CONFIG_FILE"
fi

function save_config_env() {
  # When running via "sudo bash install.sh", $HOME=/root but config must go to
  # the real user's home so 'tg-ui' (as non-root) can find and load it.
  local target_config="$CONFIG_FILE"

  cat << EOF | sudo tee "$target_config" > /dev/null
FAKE_DOMAIN="${FAKE_DOMAIN}"
PORT="${PORT}"
USER_MAX_IPS="${USER_MAX_IPS:-0}"
SECRET="${SECRET}"
SERVER_IP="${SERVER_IP}"
MASK_ENABLED="${MASK_ENABLED:-true}"
LOG_LEVEL="${LOG_LEVEL:-normal}"
MASK_PORT="${MASK_PORT:-443}"
PROXY_PROTOCOL="${PROXY_PROTOCOL:-false}"
PROXY_PROTOCOL_CIDRS="${PROXY_PROTOCOL_CIDRS:-}"
MIKROTIK_EXT_PORT="${MIKROTIK_EXT_PORT:-443}"
AD_TAG="${AD_TAG:-00000000000000000000000000000000}"
EOF

  # Update local .env for docker-compose with sudo
  cat << EOF | sudo tee "$PROJECT_DIR/.env" > /dev/null
CONTAINER_NAME="${CONTAINER_NAME}"
PORT="${PORT}"
INTERNAL_PORT="${INTERNAL_PORT:-443}"
USER_MAX_IPS="${USER_MAX_IPS:-0}"
FAKE_DOMAIN="${FAKE_DOMAIN}"
MASK_ENABLED="${MASK_ENABLED:-true}"
LOG_LEVEL="${LOG_LEVEL:-normal}"
MASK_PORT="${MASK_PORT:-443}"
PROXY_PROTOCOL="${PROXY_PROTOCOL:-false}"
PROXY_PROTOCOL_CIDRS="${PROXY_PROTOCOL_CIDRS:-}"
MIKROTIK_EXT_PORT="${MIKROTIK_EXT_PORT:-443}"
AD_TAG="${AD_TAG:-00000000000000000000000000000000}"
EOF

  # Ensure config is readable by everyone to allow 'tg-ui qr' to work as non-root
  sudo chmod 644 "$target_config" "$PROJECT_DIR/.env"
}

function migrate_to_multi_user() {
  [ -f "$USERS_DB" ] && return

  touch "$USERS_DB"
  local default_links_created=false

  if ! grep -q "^admin:" "$USERS_DB"; then
    local admin_sec="$SECRET"
    if [ -z "$admin_sec" ]; then
      if command -v openssl >/dev/null 2>&1; then admin_sec=$(openssl rand -hex 16); else admin_sec=$(head -c 16 /dev/urandom | xxd -p | tr -d '\n'); fi
      SECRET="$admin_sec"
      save_config_env
    fi
    echo "admin:${admin_sec}:0" >> "$USERS_DB"
    default_links_created=true
  fi

  if ! grep -q "^public:" "$USERS_DB"; then
    local public_sec
    if command -v openssl >/dev/null 2>&1; then public_sec=$(openssl rand -hex 16); else public_sec=$(head -c 16 /dev/urandom | xxd -p | tr -d '\n'); fi
    echo "public:${public_sec}:0" >> "$USERS_DB"
    default_links_created=true
  fi

  if [ "$default_links_created" = true ]; then
    _ok "Default links created (unlimited)"
    # Ensure USERS_DB is owned by the real user if created as root
    local real_user="${SUDO_USER:-$USER}"
    if [ "$(id -u)" -eq 0 ] && [ "$real_user" != "root" ]; then
      chown "$real_user":"$real_user" "$USERS_DB" 2>/dev/null || true
    fi
    chmod 600 "$USERS_DB"
  fi
}

function get_config_toml_content() {
  local has_per_user_limits=false
  while IFS=: read -r name secret limit; do
    [ -z "$name" ] && continue
    [ "${limit:-0}" -gt 0 ] && has_per_user_limits=true
  done < "$USERS_DB"

  cat << EOF
[general]
ad_tag = "${AD_TAG:-00000000000000000000000000000000}"
use_middle_proxy = true
log_level = "${LOG_LEVEL:-normal}"
rst_on_close = "always"

[general.modes]
classic = false
secure = false
tls = true

[server]
port = ${PORT:-8443}

[timeouts]
client_keepalive = 10
client_handshake = 120
relay_client_idle_soft_secs = 30
relay_client_idle_hard_secs = 45

EOF

  # Add listener configuration based on IP type
  if _is_ipv6 "$SERVER_IP"; then
    # IPv6 listener
    cat <<EOF
[[server.listeners]]
ip = "[::]"
port = ${PORT:-8443}
announce_ip = "$SERVER_IP"

EOF
  else
    # IPv4 listener
    cat <<EOF
[[server.listeners]]
ip = "0.0.0.0"
port = ${PORT:-8443}

EOF
  fi

  if [ "$PROXY_PROTOCOL" == "true" ]; then
    echo "proxy_protocol = true"
    if [ -n "$PROXY_PROTOCOL_CIDRS" ]; then
      IFS=',' read -ra ADDR <<< "$PROXY_PROTOCOL_CIDRS"
      cidrs_arr=""
      for i in "${ADDR[@]}"; do
        i="$(echo "$i" | tr -d '[:space:]')"
        [ -n "$i" ] && cidrs_arr="$cidrs_arr\"$i\", "
      done
      cidrs_arr="[${cidrs_arr%, }]"
      echo "proxy_protocol_trusted_cidrs = $cidrs_arr"
    fi
  fi

  cat <<EOF

[server.api]
enabled = true
listen = "127.0.0.1:9091"

[censorship]
tls_domain = "${FAKE_DOMAIN}"
mask = ${MASK_ENABLED:-true}
mask_port = ${MASK_PORT:-443}
fake_cert_len = 2048

[access]
user_max_unique_ips_global_each = ${USER_MAX_IPS:-0}
user_max_unique_ips_mode = "active_window"

[access.users]
EOF

  while IFS=: read -r name secret limit; do
    [ -z "$name" ] && continue
    echo "$name = \"$secret\""
  done < "$USERS_DB"

  # Only write per-user IP limit section when at least one user has a positive limit
  if [ "$has_per_user_limits" = true ]; then
    echo ""
    echo "[access.user_max_unique_ips]"
    while IFS=: read -r name secret limit; do
      [ -z "$name" ] && continue
      [ "${limit:-0}" -gt 0 ] && echo "$name = $limit"
    done < "$USERS_DB"
  fi
}

function generate_secret() {
  if command -v openssl >/dev/null 2>&1; then
    SECRET=$(openssl rand -hex 16)
  else
    SECRET=$(head -c 16 /dev/urandom | xxd -p | tr -d '\n')
  fi
}

function check_port_free() {
  local port=$1
  if command -v ss >/dev/null 2>&1; then
    ! sudo ss -tunlp | grep -q ":$port "
  elif command -v netstat >/dev/null 2>&1; then
    ! sudo netstat -tunlp | grep -q ":$port "
  elif command -v lsof >/dev/null 2>&1; then
    ! sudo lsof -i :$port >/dev/null 2>&1
  else
    return 0
  fi
}

function find_best_port() {
  # FIX: Added 9443 immediately after 8443 as next fallback
  local preferred_ports=(8443 9443 443 2053 2083 2087 2096 8888)

  if check_port_free "$PORT"; then
    return
  fi

  info "Port $PORT is occupied — scanning for available port..."

  for p in "${preferred_ports[@]}"; do
    if [ "$p" == "$PORT" ]; then continue; fi
    if check_port_free "$p"; then
      ok "Using free port: $p"
      PORT="$p"
      return
    fi
  done

  # Final fallback: scan from 10000+
  local p=10000
  while ! check_port_free "$p"; do ((p++)); done
  PORT="$p"
}

function start_proxy() {
  local _frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  local _fi=0

  echo
  printf "  \033[1mStarting proxy\033[0m\n"

  save_config_env
  _ok "Config saved"

  if sudo docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    sudo docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1
    _ok "Old container removed"
  fi

  if [ -z "$SECRET" ]; then generate_secret; fi
  find_best_port
  _ok "Port $PORT ready"

  local ram_config="/dev/shm/telemt-tgui-config.toml"
  printf "  \033[2mGenerating config...\033[0m\n"

  # Remove if Docker incorrectly created this path as a directory
  if [ -d "$ram_config" ]; then
    sudo rm -rf "$ram_config"
  fi

  get_config_toml_content | sudo tee "$ram_config" > /dev/null
  sudo chmod 644 "$ram_config"
  _ok "Config written"

  save_config_env
  sync_mikrotik_commands  # Auto-refresh Mikrotik commands if port/IP changed

  # Apply aggressive TCP keepalive to detect dead connections FAST (fixes "infinite loading")
  # Dead connection detected in: 10 + (5 × 3) = 25 seconds
  local _want_ka_time=10
  if [ "$(sysctl -n net.ipv4.tcp_keepalive_time 2>/dev/null)" != "$_want_ka_time" ]; then
    sudo sysctl -w net.ipv4.tcp_keepalive_time=$_want_ka_time >/dev/null 2>&1
    sudo sysctl -w net.ipv4.tcp_keepalive_intvl=5 >/dev/null 2>&1
    sudo sysctl -w net.ipv4.tcp_keepalive_probes=3 >/dev/null 2>&1
    # Persist in sysctl.conf (replace old values if present)
    sudo sed -i '/net.ipv4.tcp_keepalive_/d' /etc/sysctl.conf 2>/dev/null
    echo "net.ipv4.tcp_keepalive_time=$_want_ka_time" | sudo tee -a /etc/sysctl.conf >/dev/null
    echo "net.ipv4.tcp_keepalive_intvl=5" | sudo tee -a /etc/sysctl.conf >/dev/null
    echo "net.ipv4.tcp_keepalive_probes=3" | sudo tee -a /etc/sysctl.conf >/dev/null
  fi

  cd "$PROJECT_DIR"
  _write_compose_file
  sudo $DOCKER_COMPOSE down >/dev/null 2>&1

  printf "  \033[2mPulling latest image...\033[0m\n"
  sudo docker pull ghcr.io/telemt/telemt:latest >/dev/null 2>&1 && _ok "Image up to date" || true

  if sudo $DOCKER_COMPOSE up -d >/dev/null 2>&1; then
    local i=0
    local status=""
    while [ $i -lt 300 ]; do
      status=$(sudo docker inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null)
      if [ "$status" == "running" ]; then
        _spin_ok "Container running"
        break
      fi
      # If container exited with error — no point waiting further
      if [ "$status" == "exited" ] || [ "$status" == "dead" ]; then
        break
      fi
      _spin "${_frames[$((i % 10))]}" "Waiting for container..."
      ((i++)); sleep 0.1
    done

    if [ "$status" != "running" ]; then
      local exit_code=$(sudo docker inspect -f '{{.State.ExitCode}}' "$CONTAINER_NAME" 2>/dev/null)
      local error_msg=$(sudo docker inspect -f '{{.State.Error}}' "$CONTAINER_NAME" 2>/dev/null)
      _fail "Error starting container (status: ${status:-unknown}, exit: ${exit_code:-?})"
      [ -n "$error_msg" ] && printf "     Error: %s\n" "$error_msg"
      sudo docker logs "$CONTAINER_NAME" 2>&1 | tail -8 | while IFS= read -r line; do
        printf "     \033[2m%s\033[0m\n" "$line"
      done
      return 1
    fi

    if [ -z "$SERVER_IP" ]; then
      if command -v curl >/dev/null 2>&1; then
        SERVER_IP=$(curl -s --connect-timeout 3 ifconfig.me 2>/dev/null ||
                    curl -s --connect-timeout 3 ipinfo.io/ip 2>/dev/null ||
                    curl -s --connect-timeout 3 icanhazip.com 2>/dev/null ||
                    curl -s --connect-timeout 3 api.ipify.org 2>/dev/null)
      fi
      # Fallback: local IP
      if [ -z "$SERVER_IP" ]; then
        SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
      fi
    fi

    save_config_env
    show_link
  else
    _fail "Error starting container"
    return 1
  fi
}

function _fetch_ip() {
  if [ -z "$SERVER_IP" ] || [ "$SERVER_IP" == "YOUR_UBUNTU_IP" ]; then
    # Priority: IPv4 first, then fallback to IPv6
    if command -v curl >/dev/null 2>&1; then
      SERVER_IP=$(curl -s --connect-timeout 2 ifconfig.me 2>/dev/null || \
                  curl -s --connect-timeout 2 ipinfo.io/ip 2>/dev/null || \
                  curl -s --connect-timeout 2 icanhazip.com 2>/dev/null || \
                  curl -s --connect-timeout 2 api.ipify.org 2>/dev/null)
    fi

    # Fallback to local primary IPv4 interface
    if [ -z "$SERVER_IP" ]; then
      SERVER_IP=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' || \
                  hostname -I | awk '{print $1}')
    fi

    # Final fallback: IPv6 if no IPv4 found
    if [ -z "$SERVER_IP" ]; then
      SERVER_IP=$(ip -6 addr show | grep "scope global" | head -1 | awk '{print $2}' | cut -d/ -f1)
    fi
  else
    # Validate: IPv4 or IPv6
    if [[ "$SERVER_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
       return  # Valid IPv4
    fi
    if [[ "$SERVER_IP" =~ : ]]; then
       return  # Valid IPv6
    fi
    # It might be a domain, skip validation
    return
  fi
}

function _is_cascade_active() {
  [ -f "/etc/wireguard/wg-telemt.conf" ] && \
  ip link show wg-telemt &>/dev/null && \
  sudo wg show wg-telemt endpoints 2>/dev/null | grep -qv "(none)"
}

function _is_ipv6() {
  local ip="$1"
  [[ "$ip" =~ : ]]
}

function _get_cascade_ip() {
  local endpoint=$(sudo wg show wg-telemt endpoints 2>/dev/null | awk '{print $2}' | grep -v "(none)" | head -n 1)

  if [ -z "$endpoint" ]; then
    echo "$SERVER_IP"
    return
  fi

  # Parse endpoint - remove port for both IPv4 and IPv6
  local ext_ip
  if [[ "$endpoint" =~ ^\[.*\]:[0-9]+$ ]]; then
    # IPv6 with brackets: [addr]:port
    ext_ip="${endpoint%:*}"  # Remove port
    ext_ip="${ext_ip#\[}"    # Remove leading [
    ext_ip="${ext_ip%\]}"    # Remove trailing ]
  elif [[ "$endpoint" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+$ ]]; then
    # IPv4: addr:port
    ext_ip="${endpoint%:*}"
  else
    # Assume it's already just an address without port
    ext_ip="$endpoint"
  fi

  echo "${ext_ip:-$SERVER_IP}"
}

function show_link() {
  local target_user=$1
  _fetch_ip

  local display_ip="$SERVER_IP"
  local display_port="$PORT"

  # Format IPv6 with brackets for proper URL formatting
  if [[ "$display_ip" =~ : ]]; then
    display_ip="[$display_ip]"
  fi

  if _is_cascade_active; then
    display_ip=$(_get_cascade_ip)
    # Format cascade IPv6 with brackets
    if [[ "$display_ip" =~ : ]]; then
      display_ip="[$display_ip]"
    fi
    display_port="$MIKROTIK_EXT_PORT"
    _ok "Cascade active: Generating links for Mikrotik ($display_ip:$display_port)"
  fi

  local domain_hex=$(echo -n "$FAKE_DOMAIN" | xxd -ps -c 256 | tr -d '\n')

  echo
  printf "  \033[1mProxy connections\033[0m\n"
  printf "  \033[2m%-12s\033[0m  %s\n" "ip" "${display_ip:-unknown}"
  printf "  \033[2m%-12s\033[0m  %s\n" "port" "$display_port"
  printf "  \033[2m%-12s\033[0m  %s\n" "fake-tls" "$FAKE_DOMAIN"

  while IFS=: read -r name secret limit; do
    [ -z "$name" ] && continue
    if [ -n "$target_user" ] && [ "$target_user" != "$name" ]; then continue; fi

    local limit_text
    if [ "${limit:-0}" -eq "0" ]; then limit_text="unlimited"; else limit_text="${limit} IP"; fi

    local link_secret
    if [ "$MASK_ENABLED" == "true" ]; then
      link_secret="ee${secret}${domain_hex}"
    else
      link_secret="$secret"
    fi
    local tg_link="tg://proxy?server=${display_ip}&port=${display_port}&secret=${link_secret}"
    local web_link="https://t.me/proxy?server=${display_ip}&port=${display_port}&secret=${link_secret}"

    printf "  \033[2m─── %s · %s \033[0m\n" "$name" "$limit_text"
    printf "  ${GREEN}%s${RESET}\n" "$web_link"
    printf "  \033[2m↑ share:\033[0m %s\n" "$tg_link"
  done < "$USERS_DB"
  echo
}

function show_qr() {
  local target_user=$1

  if ! command -v qrencode >/dev/null 2>&1; then
    printf "  \033[33m⚙\033[0m  Installing qrencode...\n"
    _pkg_install qrencode
    if ! command -v qrencode >/dev/null 2>&1; then
      printf "  \033[31m✗\033[0m  Failed to install qrencode. Run: sudo apt-get install -y qrencode\n"
      printf "  \033[2mPress Enter to return...\033[0m"; read; return
    fi
  fi

  _fetch_ip

  local display_ip="$SERVER_IP"
  local display_port="$PORT"

  # Format IPv6 with brackets
  if [[ "$display_ip" =~ : ]]; then
    display_ip="[$display_ip]"
  fi

  if _is_cascade_active; then
    display_ip=$(_get_cascade_ip)
    # Format cascade IPv6 with brackets
    if [[ "$display_ip" =~ : ]]; then
      display_ip="[$display_ip]"
    fi
    display_port="$MIKROTIK_EXT_PORT"
  fi

  local domain_hex=$(echo -n "$FAKE_DOMAIN" | xxd -ps -c 256 | tr -d '\n')
  local current=1

  clear
  echo
  printf "  \033[38;2;255;120;0m\033[1mMTProxy QR codes\033[0m\n"
  if _is_cascade_active; then
    printf "  \033[32m●\033[0m \033[2mMikrotik Cascade Active ($display_ip:$display_port)\033[0m\n"
  fi
  printf "  \033[2m──────────────────────────────────────────────────────\033[0m\n"

  while IFS=: read -r name secret limit; do
    [ -z "$name" ] && continue
    if [ -n "$target_user" ] && [ "$target_user" != "$name" ]; then continue; fi

    local limit_text
    if [ "${limit:-0}" -eq "0" ]; then limit_text="unlimited"; else limit_text="${limit} IP"; fi

    local link_secret
    if [ "$MASK_ENABLED" == "true" ]; then
      link_secret="ee${secret}${domain_hex}"
    else
      link_secret="$secret"
    fi
    local link="tg://proxy?server=${display_ip}&port=${display_port}&secret=${link_secret}"
    local qr_link="tg://proxy?server=${display_ip}&port=${display_port}&secret=${link_secret}"

    printf "  \033[2m%s · %s\033[0m\n" "$name" "$limit_text"
    echo

    qr_output=$(qrencode -t UTF8i -m 2 "$qr_link")
    first_line=$(head -n 1 <<< "$qr_output")
    qr_width=${#first_line}
    padding=$(( (60 - qr_width) / 2 ))
    [ $padding -lt 0 ] && padding=0
    pad_str=$(printf "%*s" $padding "")
    echo "$qr_output" | sed "s/^/$pad_str/"

    printf "  \033[2m──────────────────────────────────────────────────────\033[0m\n"
    ((current++))
  done < "$USERS_DB"

  printf "  \033[2mPress Enter to return...\033[0m"
  read
}

function manage_users() {
  while true; do
    clear
    printf "  \033[38;2;255;120;0m\033[1mMTProxy-Telemt-tg-ui\033[0m  \033[2m|  Links & Users\033[0m\n"
    printf "  \033[2m──────────────────────────────────────────────────────\033[0m\n"
    printf "  \033[2m%-3s  %-14s  %-10s  %s\033[0m\n" "#" "name" "ip limit" "secret"
    printf "  \033[2m──────────────────────────────────────────────────────\033[0m\n"

    local names=()
    local count=1
    while IFS=: read -r name secret limit; do
      [ -z "$name" ] && continue
      names+=("$name")
      printf "  \033[33m%-3s\033[0m  \033[2m%-14s  %-10s  %s...\033[0m\n" "$count)" "$name" "$limit" "$(echo "$secret" | cut -c1-8)"
      ((count++))
    done < "$USERS_DB"

    printf "  \033[2m──────────────────────────────────────────────────────\033[0m\n"
    printf "  \033[2m1)\033[0m  Add new link\n"
    printf "  \033[2m2)\033[0m  Delete link\n"
    printf "  \033[2m3)\033[0m  Change IP limit\n"
    printf "  \033[2m4)\033[0m  Show all connections\n"
    printf "  \033[2m5)\033[0m  Show QR codes\n"
    printf "  \033[2m0)\033[0m  Back\n"
    printf "  \033[2m──────────────────────────────────────────────────────\033[0m\n"
    printf "  select: "
    read user_choice

    case $user_choice in
      1)
        printf "  name for new link: "
        read new_name
        if [ -n "$new_name" ]; then
          if [[ ! "$new_name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
            _fail "Name can only contain letters, numbers, dash and underscore"
            sleep 2
            continue
          fi
          if grep -q "^$new_name:" "$USERS_DB" 2>/dev/null; then
            _fail "A user with this name already exists"
            sleep 2
            continue
          fi
          local new_secret
          if command -v openssl >/dev/null 2>&1; then new_secret=$(openssl rand -hex 16); else new_secret=$(head -c 16 /dev/urandom | xxd -p | tr -d '\n'); fi
          echo "$new_name:$new_secret:0" >> "$USERS_DB"
          start_proxy
        fi
        ;;
      2)
        printf "  # to delete: "
        read del_idx
        if [[ "$del_idx" =~ ^[0-9]+$ ]]; then
          real_idx=$((del_idx-1))
          if [ $real_idx -ge 0 ] && [ $real_idx -lt ${#names[@]} ]; then
            del_name="${names[$real_idx]}"
            sed -i "/^$del_name:/d" "$USERS_DB"
            start_proxy
          fi
        fi
        ;;
      3)
        printf "  # to update: "
        read up_idx
        if [[ "$up_idx" =~ ^[0-9]+$ ]]; then
          real_idx=$((up_idx-1))
          if [ $real_idx -ge 0 ] && [ $real_idx -lt ${#names[@]} ]; then
            up_name="${names[$real_idx]}"
            printf "  new IP limit for %s \033[2m(0 = unlimited)\033[0m: " "$up_name"
            read up_limit
            if [[ "$up_limit" =~ ^[0-9]+$ ]]; then
              local old_line=$(grep "^$up_name:" "$USERS_DB")
              local old_secret=$(echo "$old_line" | cut -d: -f2)
              sed -i "s/^$up_name:.*/$up_name:$old_secret:$up_limit/" "$USERS_DB"
              start_proxy
            fi
          fi
        fi
        ;;
      4) show_link; printf "  \033[2mPress Enter to return...\033[0m"; read ;;
      5) show_qr ;;
      0) break ;;
    esac
  done
}

function update_from_upstream() {
  echo
  printf "  \033[1mUpdating proxy image\033[0m\n"
  cd "$PROJECT_DIR"
  if sudo $DOCKER_COMPOSE pull; then
    _ok "Image updated"
    start_proxy
  else
    _fail "Error downloading updates"
  fi
}

function view_logs() {
  clear
  printf "  \033[38;2;255;120;0m\033[1mMTProxy-Telemt-tg-ui\033[0m  \033[2m|  Logs\033[0m\n"
  printf "  \033[2m──────────────────────────────────────────────────────\033[0m\n"
  printf "  \033[2m(Press Ctrl+C to return)\033[0m\n\n"

  cd "$PROJECT_DIR"
  trap 'return 0' INT
  sudo $DOCKER_COMPOSE logs -f --tail 50
  trap - INT
}

function update_panel() {
  echo
  printf "  \033[1mUpdating management panel\033[0m\n"
  cd "$PROJECT_DIR"
  if [ -d ".git" ]; then
    if git pull; then
      _ok "Panel updated from Git"
      sleep 1
      exec tg-ui
    else
      _fail "Git pull failed"
    fi
  else
    # Non-git update (fallback to curl)
    if command -v curl >/dev/null 2>&1; then
       local raw_url="https://raw.githubusercontent.com/lyfreedomitsme/MTproxy-Telemt-tg-ui/master/tg-ui.sh"
       if curl -sL "$raw_url" -o /tmp/tg-ui-update.sh; then
          chmod +x /tmp/tg-ui-update.sh
          # Replace binary in /usr/local/bin
          sudo mv /tmp/tg-ui-update.sh /usr/local/bin/tg-ui
          # Also replace the local file if we are running the local one
          if [[ "${BASH_SOURCE[0]}" == "$PROJECT_DIR/tg-ui.sh" ]]; then
            cp /usr/local/bin/tg-ui "$PROJECT_DIR/tg-ui.sh" 2>/dev/null || true
          fi
          _ok "Panel updated via Direct Download"
          sleep 1
          # If we are in the terminal (not piped), restart
          if [ -t 0 ]; then
            exec tg-ui
          fi
       else
          _fail "Download failed"
       fi
    else
       _fail "curl not found, cannot update without Git"
    fi
  fi
}

function rotate_secrets() {
  echo
  printf "  \033[33m!\033[0m  This will re-generate ALL secrets for ALL users\n"
  printf "  \033[2mExisting users will need new links to connect\033[0m\n"
  printf "  are you sure? \033[2m(y/n)\033[0m: "
  read confirm
  if [ "$confirm" == "y" ]; then
    local tmp_db=$(mktemp)
    while IFS=: read -r name secret limit; do
      [ -z "$name" ] && continue
      local new_secret
      if command -v openssl >/dev/null 2>&1; then new_secret=$(openssl rand -hex 16); else new_secret=$(head -c 16 /dev/urandom | xxd -p | tr -d '\n'); fi
      echo "$name:$new_secret:$limit" >> "$tmp_db"
    done < "$USERS_DB"
    mv "$tmp_db" "$USERS_DB"
    _ok "All secrets rotated"
    start_proxy
  fi
}

function change_fake_tls() {
  printf "  new Fake TLS domain: "
  read input
  if [ -n "$input" ]; then
    FAKE_DOMAIN="$input"
    save_config_env
    start_proxy
  fi
}

function select_sni_domain() {
  local domains=("google.com" "apple.com" "wikipedia.org" "cloudflare.com" "bing.com" "microsoft.com" "itunes.apple.com" "updates.cdn-apple.com" "ia.ru" "ok.ru")

  clear
  printf "  \033[38;2;255;120;0m\033[1mMTProxy-Telemt-tg-ui\033[0m  \033[2m|  SNI Domain\033[0m\n"
  printf "  \033[33m!\033[0m  \033[2mChanging SNI will update ALL links — users will need new links\033[0m\n"
  printf "  \033[2m──────────────────────────────────────────────────────\033[0m\n"
  for i in "${!domains[@]}"; do
    printf "  \033[2m%2d)\033[0m  %s\n" "$((i+1))" "${domains[$i]}"
  done
  printf "  \033[2m %d)\033[0m  Custom domain  \033[2m(current: %s)\033[0m\n" 0 "$FAKE_DOMAIN"
  printf "  \033[2m──────────────────────────────────────────────────────\033[0m\n"
  printf "  select: "
  read sd_choice

  if [[ "$sd_choice" =~ ^[0-9]+$ ]] && [ "$sd_choice" -gt 0 ] && [ "$sd_choice" -le "${#domains[@]}" ]; then
    FAKE_DOMAIN="${domains[$((sd_choice-1))]}"
    save_config_env
    start_proxy
  elif [ "$sd_choice" == "0" ]; then
    printf "  custom domain: "
    read custom
    if [ -n "$custom" ]; then
      FAKE_DOMAIN="$custom"
      save_config_env
      start_proxy
    fi
  fi
}

function select_log_level() {
  clear
  printf "  \033[38;2;255;120;0m\033[1mMTProxy-Telemt-tg-ui\033[0m  \033[2m|  Log Level\033[0m\n"
  printf "  \033[2m──────────────────────────────────────────────────────\033[0m\n"
  printf "  \033[2m1)\033[0m  silent   \033[2m- no logs (max privacy)\033[0m\n"
  printf "  \033[2m2)\033[0m  normal   \033[2m- standard logs (recommended)\033[0m\n"
  printf "  \033[2m3)\033[0m  verbose  \033[2m- detailed connection data\033[0m\n"
  printf "  \033[2m4)\033[0m  inspect  \033[2m- full technical output\033[0m\n"
  printf "  \033[2m0)\033[0m  cancel\n"
  printf "  \033[2m──────────────────────────────────────────────────────\033[0m\n"
  printf "  select: "
  read ll_choice

  case $ll_choice in
    1) LOG_LEVEL="silent" ;;
    2) LOG_LEVEL="normal" ;;
    3) LOG_LEVEL="verbose" ;;
    4) LOG_LEVEL="debug" ;;
    0) return ;;
    *) _fail "Invalid choice"; sleep 1; return ;;
  esac
  save_config_env
  start_proxy
}

function select_server_ip() {
  clear
  printf "  \033[38;2;255;120;0m\033[1mMTProxy-Telemt-tg-ui\033[0m  \033[2m|  Server IP\033[0m\n"
  printf "  \033[33m!\033[0m  \033[2mChoosing a specific IP will update all links and QR codes\033[0m\n"
  printf "  \033[2m──────────────────────────────────────────────────────\033[0m\n"

  # Fetch all local IPv4 addresses (excluding loopback)
  local ips=($(hostname -I))
  local current_found=false

  for i in "${!ips[@]}"; do
    local ip="${ips[$i]}"
    local marker=""
    if [ "$ip" == "$SERVER_IP" ]; then
      marker=" \033[32m(current)\033[0m"
      current_found=true
    fi
    printf "  \033[2m%2d)\033[0m  %s%b\n" "$((i+1))" "$ip" "$marker"
  done

  printf "  \033[2m 0)\033[0m  Automatic detection\n"
  printf "  \033[2m──────────────────────────────────────────────────────\033[0m\n"
  printf "  select: "
  read ip_choice

  if [[ "$ip_choice" =~ ^[0-9]+$ ]] && [ "$ip_choice" -gt 0 ] && [ "$ip_choice" -le "${#ips[@]}" ]; then
    SERVER_IP="${ips[$((ip_choice-1))]}"
    save_config_env
    _ok "Server IP updated to: $SERVER_IP"
    sleep 2
  elif [ "$ip_choice" == "0" ]; then
    SERVER_IP=""
    _fetch_ip
    save_config_env
    _ok "Server IP reset to automatic detection ($SERVER_IP)"
    sleep 2
  fi
}

function advanced_security_menu() {
  while true; do
    clear
    printf "  \033[38;2;255;120;0m\033[1mMTProxy-Telemt-tg-ui\033[0m  \033[2m|  Security\033[0m\n"
    printf "  \033[2m──────────────────────────────────────────────────────\033[0m\n"

    local mask_status
    if [ "$MASK_ENABLED" == "true" ]; then
      mask_status="\033[32mon\033[0m"
    else
      mask_status="\033[31moff\033[0m"
    fi

    local proxy_status
    if [ "$PROXY_PROTOCOL" == "true" ]; then
      proxy_status="\033[32mon\033[0m"
    else
      proxy_status="\033[31moff\033[0m"
    fi

    printf "  \033[2m1)\033[0m  Active masking   %b\n" "$mask_status"
    printf "  \033[2m2)\033[0m  SNI domain       \033[2m%s\033[0m\n" "$FAKE_DOMAIN"
    printf "  \033[2m3)\033[0m  Log level        \033[2m%s\033[0m\n" "${LOG_LEVEL^^}"
    printf "  \033[2m4)\033[0m  PROXY Protocol   %b\n" "$proxy_status"
    printf "  \033[2m5)\033[0m  Rotate all secrets\n"
    printf "  \033[2m6)\033[0m  Mikrotik Cascade (Wireguard)\n"
    printf "  \033[2m7)\033[0m  Remove Cascade Tunnel\n"
    printf "  \033[2m8)\033[0m  Change Server IP  \033[2m(%s)\033[0m\n" "${SERVER_IP:-auto}"
    printf "  \033[2m9)\033[0m  Promoted Channel (Ad Tag)\n"
    printf "  \033[2m0)\033[0m  Back\n"
    printf "  \033[2m──────────────────────────────────────────────────────\033[0m\n"
    printf "  select: "
    read as_choice

    case $as_choice in
      1)
        if [ "$MASK_ENABLED" == "true" ]; then MASK_ENABLED="false"; else MASK_ENABLED="true"; fi
        save_config_env; start_proxy ;;
      2) select_sni_domain ;;
      3) select_log_level ;;
      4) toggle_proxy_protocol ;;
      5) rotate_secrets ;;
      6) setup_mikrotik_cascade ;;
      7) remove_mikrotik_cascade ;;
      8) select_server_ip ;;
      9)
        printf "  Enter Ad Tag (hex) \033[2m[current: %s]\033[0m: " "${AD_TAG}"
        read adtag_input
        if [ -n "$adtag_input" ]; then
          AD_TAG="$adtag_input"
          save_config_env
          start_proxy
        fi
        ;;
      0) break ;;
    esac
  done
}

function _install_cascade_watchdog() {
  local WATCHDOG="/usr/local/bin/telemt-wg-watchdog"
  local CRON="/etc/cron.d/telemt-wg-watchdog"

  cat > "$WATCHDOG" <<'WATCHDOG_EOF'
#!/bin/bash
# Detects stale WireGuard tunnel states and auto-recovers wg-telemt
# Checks: handshake age, rx bytes growth, and ping connectivity
WG_IFACE="wg-telemt"
STATE_FILE="/run/telemt-wg-watchdog.state"
STALE_SECS=120
PEER_IP="10.99.99.2"

# Detect IPv6 cascade and adjust peer IP
if grep -q "fd00::" /etc/wireguard/wg-telemt.conf 2>/dev/null; then
  PEER_IP="fd00::2"
fi

ip link show "$WG_IFACE" &>/dev/null || exit 0

HS_RAW=$(wg show "$WG_IFACE" latest-handshakes 2>/dev/null | awk '{print $2}')
[ -z "$HS_RAW" ] && exit 0
HS_AGE=$(( $(date +%s) - HS_RAW ))

_restart_tunnel() {
  logger -t telemt-wg-watchdog "$1"
  conntrack -D -i "$WG_IFACE" 2>/dev/null || true
  wg-quick down "$WG_IFACE" 2>/dev/null
  sleep 2
  wg-quick up "$WG_IFACE" 2>/dev/null
  rm -f "$STATE_FILE"
}

# Handshake stale > 3 min despite keepalive=25s → WireGuard broken
if [ "$HS_AGE" -gt 180 ]; then
  _restart_tunnel "Stale handshake (${HS_AGE}s) — restarting $WG_IFACE"
  exit 0
fi

# Ping test: if handshake is fresh but no ICMP reply → tunnel data path broken
if ! ping -c 2 -W 3 -I "$WG_IFACE" "$PEER_IP" &>/dev/null; then
  # Double-check with a second attempt after a brief pause
  sleep 2
  if ! ping -c 2 -W 3 -I "$WG_IFACE" "$PEER_IP" &>/dev/null; then
    _restart_tunnel "Ping to $PEER_IP via $WG_IFACE failed (handshake ${HS_AGE}s ago) — restarting"
    exit 0
  fi
fi

# Handshake fresh but rx bytes not growing → stale conntrack entries
RX_NOW=$(cat /sys/class/net/$WG_IFACE/statistics/rx_bytes 2>/dev/null || echo "0")
TS_NOW=$(date +%s)

if [ -f "$STATE_FILE" ]; then
  RX_LAST=$(awk '/^rx/{print $2}' "$STATE_FILE" 2>/dev/null || echo "0")
  TS_LAST=$(awk '/^ts/{print $2}' "$STATE_FILE" 2>/dev/null || echo "$TS_NOW")
  ELAPSED=$(( TS_NOW - TS_LAST ))
  if [ "$ELAPSED" -ge "$STALE_SECS" ] && [ "$RX_LAST" -gt 0 ] && [ "$RX_NOW" -le "$RX_LAST" ]; then
    _restart_tunnel "Stale conntrack (${ELAPSED}s no new bytes, handshake ${HS_AGE}s ago) — restarting $WG_IFACE"
    exit 0
  fi
fi

printf "rx %s\nts %s\n" "$RX_NOW" "$TS_NOW" > "$STATE_FILE"
WATCHDOG_EOF

  chmod +x "$WATCHDOG"
  printf "*/2 * * * * root %s\n" "$WATCHDOG" > "$CRON"
  chmod 644 "$CRON"
  printf "  \033[32m✔\033[0m  Watchdog installed (checks every 2 min)\n"
}

function setup_mikrotik_cascade() {
  clear
  printf "  \033[38;2;255;120;0m\033[1mMTProxy-Telemt-tg-ui\033[0m  \033[2m|  Mikrotik Cascade Setup\033[0m\n"
  printf "  \033[2m──────────────────────────────────────────────────────\033[0m\n"

  _fetch_ip
  local DISPLAY_IP="${SERVER_IP:-YOUR_UBUNTU_IP}"
  
  if [ "$EUID" -ne 0 ]; then
    printf "  \033[31mx\033[0m  Error: You must run this script with \033[1msudo\033[0m to configure Wireguard.\n"
    printf "     Please exit and run: \033[32msudo ./tg-ui.sh\033[0m\n"
    read -p "  Press Enter to return..."
    return
  fi
  
  if ! command -v wg &> /dev/null; then
    printf "  \033[33m!\033[0m  Wireguard tools not installed. Installing...\n"
    local pkgs="wireguard-tools iptables iproute2"
    # ip6tables is a separate apt package; on rpm/arch/apk it's bundled with iptables
    if _is_ipv6 "$DISPLAY_IP" && [ "$(_detect_pkg)" = "apt" ]; then
      pkgs="$pkgs ip6tables"
    fi
    [ "$(_detect_pkg)" = "apt" ] && sudo apt-get update -qq >/dev/null 2>&1
    _pkg_install $pkgs
    if ! command -v wg &> /dev/null; then
       printf "  \033[31mx\033[0m  Failed to install wireguard-tools. Please install manually.\n"
       read -p "  Press Enter to return..."
       return
    fi
  elif _is_ipv6 "$DISPLAY_IP" && ! command -v ip6tables &> /dev/null; then
    printf "  \033[33m!\033[0m  Installing ip6tables for IPv6 support...\n"
    _pkg_install ip6tables
  fi

  if [ "$(sysctl -n net.ipv4.ip_forward)" != "1" ]; then
    printf "  \033[2mEnabling IP forwarding...\033[0m\n"
    sysctl -w net.ipv4.ip_forward=1 > /dev/null
    grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
  fi

  # Enable IPv6 forwarding if IPv6 is used
  if _is_ipv6 "$DISPLAY_IP"; then
    if [ "$(sysctl -n net.ipv6.conf.all.forwarding)" != "1" ]; then
      printf "  \033[2mEnabling IPv6 forwarding...\033[0m\n"
      sysctl -w net.ipv6.conf.all.forwarding=1 > /dev/null
      grep -q "^net.ipv6.conf.all.forwarding=1" /etc/sysctl.conf || echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.conf
    fi
  fi
  
  local WG_DIR="/etc/wireguard"
  local CONF_FILE="$WG_DIR/wg-telemt.conf"
  local MIKROTIK_TXT="$WG_DIR/wg-telemt-mikrotik.txt"
  
  if [ -f "$CONF_FILE" ]; then
    local pbr_status="\033[31m○ offline\033[0m"
    if ip link show wg-telemt &>/dev/null && ip rule show 2>/dev/null | grep -q "wg_table"; then
      pbr_status="\033[32m● running\033[0m"
    fi

    # Patch existing config if missing docker restart command
    local config_updated=false
    if ! grep -q "docker restart.*telemt-proxy" "$CONF_FILE" 2>/dev/null; then
      printf "  \033[2mPatching config to auto-restart Docker container on WireGuard events...\033[0m\n"
      sed -i '/^PostUp = iptables -t nat -I POSTROUTING 1 -o wg-telemt -m connmark --mark 200 -j SNAT --to-source/a PostUp = docker restart telemt-proxy 2>\/dev\/null || true' "$CONF_FILE"
      config_updated=true
      printf "  \033[32m✔\033[0m  WireGuard config patched\n"
    fi

    # Patch existing config if missing PersistentKeepalive (keeps tunnel alive, fixes idle reconnect)
    if ! grep -q "PersistentKeepalive" "$CONF_FILE" 2>/dev/null; then
      printf "  \033[2mPatching config to add PersistentKeepalive (fixes idle reconnect bug)...\033[0m\n"
      sed -i '/^\[Peer\]/a PersistentKeepalive = 25' "$CONF_FILE"
      config_updated=true
      printf "  \033[32m✔\033[0m  PersistentKeepalive = 25 added\n"
    fi

    # Patch existing config: flush stale conntrack entries on PostUp (fixes "tunnel up but no traffic" bug)
    if ! grep -q "conntrack -D -i wg-telemt" "$CONF_FILE" 2>/dev/null; then
      printf "  \033[2mPatching config to flush stale conntrack on tunnel restart...\033[0m\n"
      sed -i '/^PostUp = .*docker restart/i PostUp = conntrack -D -i wg-telemt 2>\/dev\/null || true' "$CONF_FILE"
      config_updated=true
      printf "  \033[32m✔\033[0m  Conntrack flush on restart added\n"
    fi

    # Patch existing config: add MTU = 1420 to prevent packet fragmentation through tunnel
    if ! grep -q "^MTU" "$CONF_FILE" 2>/dev/null; then
      printf "  \033[2mPatching config to set MTU = 1420 (fixes packet fragmentation)...\033[0m\n"
      sed -i '/^ListenPort/a MTU = 1420' "$CONF_FILE"
      config_updated=true
      printf "  \033[32m✔\033[0m  MTU = 1420 added\n"
    fi

    # Patch existing config: add TCP MSS clamping to prevent oversized segments
    if ! grep -q "clamp-mss-to-pmtu" "$CONF_FILE" 2>/dev/null; then
      printf "  \033[2mPatching config to add TCP MSS clamping (fixes connection stalls)...\033[0m\n"
      if grep -q "ip6tables" "$CONF_FILE" 2>/dev/null; then
        sed -i '/^PostUp = conntrack -D/i PostUp = ip6tables -t mangle -A FORWARD -o wg-telemt -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu' "$CONF_FILE"
        # Add PostDown cleanup before last PostDown line
        echo 'PostDown = ip6tables -t mangle -D FORWARD -o wg-telemt -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu || true' >> "$CONF_FILE.mss_patch"
        # Insert the PostDown line before the [Peer] section
        sed -i '/^\[Peer\]/i PostDown = ip6tables -t mangle -D FORWARD -o wg-telemt -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu || true' "$CONF_FILE"
      else
        sed -i '/^PostUp = conntrack -D/i PostUp = iptables -t mangle -A FORWARD -o wg-telemt -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu' "$CONF_FILE"
        sed -i '/^\[Peer\]/i PostDown = iptables -t mangle -D FORWARD -o wg-telemt -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu || true' "$CONF_FILE"
      fi
      rm -f "$CONF_FILE.mss_patch"
      config_updated=true
      printf "  \033[32m✔\033[0m  TCP MSS clamping added\n"
    fi

    # Install watchdog if not present
    _install_cascade_watchdog

    # Ensure systemd service is enabled for auto-start on reboot
    if ! systemctl is-enabled wg-quick@wg-telemt &>/dev/null; then
      printf "  \033[2mEnabling WireGuard auto-start on system reboot...\033[0m\n"
      systemctl enable wg-quick@wg-telemt >/dev/null 2>&1
      printf "  \033[32m✔\033[0m  WireGuard will auto-start on reboot\n"
      config_updated=true
    fi

    # Reload WireGuard if config was updated
    if [ "$config_updated" = true ] && ip link show wg-telemt &>/dev/null; then
      printf "  \033[2mReloading WireGuard to apply updates...\033[0m\n"
      wg-quick down wg-telemt >/dev/null 2>&1
      sleep 1
      wg-quick up wg-telemt >/dev/null 2>&1
      printf "  \033[32m✔\033[0m  WireGuard reloaded\n"
    fi

    printf "  \033[2mstatus\033[0m  %b\n" "$pbr_status"
    printf "  \033[31mx\033[0m  Cascade tunnel (wg-telemt) already exists!\n"
    printf "     Config path: \033[2m%s\033[0m\n" "$CONF_FILE"
    if [ -f "$MIKROTIK_TXT" ]; then
      sync_mikrotik_commands
      printf "\n  ${BOLD}Mikrotik Commands:${RESET}\n"
      printf "  \033[2m──────────────────────────────────────────────────────────────\033[0m\n"
      while IFS= read -r line; do
        line="${line//YOUR_UBUNTU_IP/$DISPLAY_IP}"
        printf "  ${CYAN}%s${RESET}\n" "$line"
      done < "$MIKROTIK_TXT"
      printf "  \033[2m──────────────────────────────────────────────────────────────\033[0m\n"
    fi
    printf "\n"
    read -p "  Press Enter to return..."
    return
  fi
  
  printf "  \033[2mGenerating secure tunnel keys...\033[0m\n"
  local SERVER_PRIV=$(wg genkey)
  local SERVER_PUB=$(echo "$SERVER_PRIV" | wg pubkey)
  local MIKROTIK_PRIV=$(wg genkey)
  local MIKROTIK_PUB=$(echo "$MIKROTIK_PRIV" | wg pubkey)

  local WG_PORT="51830"

  # Determine IP type and set appropriate WireGuard addresses
  local WG_IP_SERVER
  local WG_IP_MIKROTIK
  local WG_ALLOWED_IPS
  local USE_IPV6=false

  if _is_ipv6 "$DISPLAY_IP"; then
    printf "  \033[32m●\033[0m  IPv6 detected: $DISPLAY_IP\n"
    printf "\n  \033[31m!\033[0m  IPv6 cascade requires Mikrotik with IPv6 support!\n"
    printf "  \033[33m!\033[0m  Does your Mikrotik support IPv6? (y/n): "
    read mk_ipv6_support

    if [[ "$mk_ipv6_support" =~ ^[Yy]$ ]]; then
      USE_IPV6=true
      WG_IP_SERVER="fd00::1"
      WG_IP_MIKROTIK="fd00::2"
      WG_ALLOWED_IPS="::/0"
      printf "  \033[32m✓\033[0m  IPv6 cascade mode enabled\n"
    else
      printf "  \033[31mx\033[0m  ERROR: Cannot create cascade without IPv6 on Mikrotik!\n"
      printf "     Your Ubuntu has IPv6 ($DISPLAY_IP), but Mikrotik doesn't.\n"
      printf "     WireGuard endpoint must match the public IP type.\n"
      printf "\n     Solutions:\n"
      printf "     1. Enable IPv6 on your Mikrotik\n"
      printf "     2. Or use a different Ubuntu server with IPv4\n\n"
      read -p "  Press Enter to return..."
      return
    fi
  else
    printf "  \033[32m●\033[0m  IPv4 detected\n"
    WG_IP_SERVER="10.99.99.1"
    WG_IP_MIKROTIK="10.99.99.2"
    WG_ALLOWED_IPS="0.0.0.0/0"
  fi

  printf "  \033[2mConfiguring external access...\033[0m\n"
  printf "  Which port to use on Mikrotik for users? \033[2m[default: 443]\033[0m: "
  read ext_port_input
  if [[ "$ext_port_input" =~ ^[0-9]+$ ]]; then
    MIKROTIK_EXT_PORT="$ext_port_input"
  else
    MIKROTIK_EXT_PORT="443"
  fi
  save_config_env

  mkdir -p "$WG_DIR"

  # Generate WireGuard config based on USE_IPV6 choice
  if [ "$USE_IPV6" = true ]; then
    # IPv6 version - simplified for better compatibility
    cat > "$CONF_FILE" <<'EOF'
[Interface]
EOF
    cat >> "$CONF_FILE" <<EOF
PrivateKey = $SERVER_PRIV
Address = $WG_IP_SERVER/64
ListenPort = $WG_PORT
MTU = 1420
Table = off
PostUp = ip6tables -t mangle -A PREROUTING -i wg-telemt ! -s $WG_IP_MIKROTIK -j CONNMARK --set-mark 200
PostUp = ip6tables -t mangle -A PREROUTING -m connmark --mark 200 -j MARK --set-mark 200
PostUp = ip -6 rule add fwmark 200 table 200 priority 90 2>/dev/null || true
PostUp = ip6tables -t nat -I POSTROUTING 1 -o wg-telemt -m connmark --mark 200 -j SNAT --to-source $WG_IP_SERVER
PostUp = ip6tables -t mangle -A FORWARD -o wg-telemt -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
PostUp = conntrack -D -i wg-telemt 2>/dev/null || true
PostUp = (sleep 0.5; docker restart ${CONTAINER_NAME}) > /dev/null 2>&1 &
PostDown = ip6tables -t mangle -D PREROUTING -i wg-telemt ! -s $WG_IP_MIKROTIK -j CONNMARK --set-mark 200 || true
PostDown = ip6tables -t mangle -D PREROUTING -m connmark --mark 200 -j MARK --set-mark 200 || true
PostDown = ip -6 rule del fwmark 200 table 200 priority 90 2>/dev/null || true
PostDown = ip6tables -t nat -D POSTROUTING -o wg-telemt -m connmark --mark 200 -j SNAT --to-source $WG_IP_SERVER || true
PostDown = ip6tables -t mangle -D FORWARD -o wg-telemt -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu || true

[Peer]
PublicKey = $MIKROTIK_PUB
AllowedIPs = $WG_ALLOWED_IPS
PersistentKeepalive = 25
EOF
  else
    # IPv4 version with iptables
    cat > "$CONF_FILE" <<'EOF'
[Interface]
EOF
    cat >> "$CONF_FILE" <<EOF
PrivateKey = $SERVER_PRIV
Address = $WG_IP_SERVER/24
ListenPort = $WG_PORT
MTU = 1420
Table = off
PostUp = iptables -t mangle -A PREROUTING -i wg-telemt ! -s $WG_IP_MIKROTIK -j CONNMARK --set-mark 200
PostUp = iptables -t mangle -A PREROUTING -m connmark --mark 200 -j MARK --set-mark 200
PostUp = ip rule add fwmark 200 table 200 priority 90 2>/dev/null || true
PostUp = iptables -t nat -I POSTROUTING 1 -o wg-telemt -m connmark --mark 200 -j SNAT --to-source $WG_IP_SERVER
PostUp = iptables -t mangle -A FORWARD -o wg-telemt -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
PostUp = conntrack -D -i wg-telemt 2>/dev/null || true
PostUp = (sleep 0.5; docker restart ${CONTAINER_NAME}) > /dev/null 2>&1 &
PostDown = iptables -t mangle -D PREROUTING -i wg-telemt ! -s $WG_IP_MIKROTIK -j CONNMARK --set-mark 200 || true
PostDown = iptables -t mangle -D PREROUTING -m connmark --mark 200 -j MARK --set-mark 200 || true
PostDown = ip rule del fwmark 200 table 200 priority 90 2>/dev/null || true
PostDown = iptables -t nat -D POSTROUTING -o wg-telemt -m connmark --mark 200 -j SNAT --to-source $WG_IP_SERVER || true
PostDown = iptables -t mangle -D FORWARD -o wg-telemt -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu || true

[Peer]
PublicKey = $MIKROTIK_PUB
AllowedIPs = $WG_ALLOWED_IPS
PersistentKeepalive = 25
EOF
  fi
  chmod 600 "$CONF_FILE"

  # Generate Mikrotik config based on USE_IPV6 choice
  if [ "$USE_IPV6" = true ]; then
    # IPv6 version
    cat > "$MIKROTIK_TXT" <<EOF
/interface wireguard add comment="Telemt Cascade IPv6" listen-port=13231 name=wg-telemt private-key="$MIKROTIK_PRIV"
/interface wireguard peers add allowed-address=::/0 comment="Telemt Cascade IPv6" endpoint-address=$DISPLAY_IP endpoint-port=$WG_PORT interface=wg-telemt public-key="$SERVER_PUB"
/ip address add address=$WG_IP_MIKROTIK/64 comment="Telemt Cascade IPv6" interface=wg-telemt
/ip firewall nat add action=accept chain=srcnat comment="Telemt Cascade IPv6" protocol=tcp dst-port=$PORT out-interface=wg-telemt place-before=0
/ip firewall nat add action=dst-nat chain=dstnat comment="Telemt Cascade IPv6" protocol=tcp dst-port=$MIKROTIK_EXT_PORT in-interface=ether1 to-addresses=$WG_IP_SERVER to-ports=$PORT
EOF
  else
    # IPv4 version
    cat > "$MIKROTIK_TXT" <<EOF
/interface wireguard add comment="Telemt Cascade" listen-port=13231 name=wg-telemt private-key="$MIKROTIK_PRIV"
/interface wireguard peers add allowed-address=0.0.0.0/0 comment="Telemt Cascade" endpoint-address=$DISPLAY_IP endpoint-port=$WG_PORT interface=wg-telemt public-key="$SERVER_PUB"
/ip address add address=$WG_IP_MIKROTIK/24 comment="Telemt Cascade" interface=wg-telemt
/ip firewall nat add action=accept chain=srcnat comment="Telemt Cascade" protocol=tcp dst-port=$PORT out-interface=wg-telemt place-before=0
/ip firewall nat add action=dst-nat chain=dstnat comment="Telemt Cascade" protocol=tcp dst-port=$MIKROTIK_EXT_PORT in-interface=ether1 to-addresses=$WG_IP_SERVER to-ports=$PORT
EOF
  fi
  
  systemctl enable --now wg-quick@wg-telemt &> /dev/null || true
  _install_cascade_watchdog
  sleep 1

  if ! ip link show wg-telemt &>/dev/null; then
    printf "  \033[31mx\033[0m  WireGuard interface failed to start.\n"
    printf "     Check: \033[2msystemctl status wg-quick@wg-telemt\033[0m\n"
    read -p "  Press Enter to return..."
    return
  fi

  # Wait for container to restart and initialize with tunnel
  printf "  \033[2mWaiting for container to initialize with tunnel...\033[0m\n"
  sleep 3

  local container_ready=false
  for ((i=0; i<20; i++)); do
    if sudo docker inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null | grep -q "running"; then
      container_ready=true
      break
    fi
    sleep 0.5
  done

  if [ "$container_ready" = true ]; then
    printf "  \033[32m✔\033[0m  Container restarted with tunnel\n"
  else
    printf "  \033[33m!\033[0m  Warning: Container may not have restarted. Check: \033[2msudo docker logs $CONTAINER_NAME\033[0m\n"
  fi

  # Open WireGuard UDP port in firewall
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "active"; then
    ufw allow "$WG_PORT/udp" comment "Telemt WireGuard" >/dev/null 2>&1 && \
      printf "  \033[32m✔\033[0m  UFW: opened port %s/udp\n" "$WG_PORT"
  fi
  iptables -C INPUT -p udp --dport "$WG_PORT" -j ACCEPT 2>/dev/null || \
    iptables -I INPUT -p udp --dport "$WG_PORT" -j ACCEPT

  printf "  \033[32m✔\033[0m  Ubuntu WG Tunnel (wg-telemt) started successfully!\n\n"
  
  printf "  ${ORANGE}${BOLD}Now, open your Mikrotik Terminal and paste these exact commands:${RESET}\n"
  printf "  \033[2m──────────────────────────────────────────────────────────────\033[0m\n"
  
  while IFS= read -r line; do
    printf "  ${CYAN}%s${RESET}\n" "$line"
  done < "$MIKROTIK_TXT"

  printf "  \033[2m──────────────────────────────────────────────────────────────\033[0m\n\n"
  printf "  ${ORANGE}!${RESET}  Note: If the detected IP ${ORANGE}%s${RESET} is incorrect, replace it manually.\n" "$DISPLAY_IP"
  printf "  ${ORANGE}!${RESET}  Note: Replace ${ORANGE}ether1${RESET} with your Mikrotik's actual Internet interface name (if different).\n\n"
  printf "  \033[2mClean text copy saved to: \033[2m%s\033[0m\n\n" "$MIKROTIK_TXT"

  read -p "  Press Enter after you have saved these commands..."
}

function remove_mikrotik_cascade() {
  clear
  printf "  \033[38;2;255;120;0m\033[1mMTProxy-Telemt-tg-ui\033[0m  \033[2m|  Remove Cascade\033[0m\n"
  printf "  \033[2m──────────────────────────────────────────────────────\033[0m\n"

  if [ "$EUID" -ne 0 ]; then
    printf "  \033[31mx\033[0m  Error: You must run this script with \033[1msudo\033[0m to remove Wireguard configurations.\n"
    printf "     Please exit and run: \033[32msudo ./tg-ui.sh\033[0m\n"
    read -p "  Press Enter to return..."
    return
  fi

  local WG_DIR="/etc/wireguard"
  local CONF_FILE="$WG_DIR/wg-telemt.conf"
  local MIKROTIK_TXT="$WG_DIR/wg-telemt-mikrotik.txt"

  if [ ! -f "$CONF_FILE" ]; then
    printf "  \033[33m!\033[0m  No cascade tunnel (wg-telemt) found.\n\n"
    read -p "  Press Enter to return..."
    return
  fi

  local WG_PORT="51830"

  # Detect cascade type before removal
  local CASCADE_COMMENT="Telemt Cascade"
  if grep -q "IPv6" "$MIKROTIK_TXT" 2>/dev/null; then
    CASCADE_COMMENT="Telemt Cascade IPv6"
  fi

  printf "  \033[33m!\033[0m  This will remove the Wireguard tunnel and all related configs.\n"
  printf "  Are you sure? \033[2m(y/n)\033[0m: "
  read confirm
  if [ "$confirm" != "y" ]; then return; fi

  printf "  \033[2mStopping Wireguard interface...\033[0m\n"
  systemctl disable --now wg-quick@wg-telemt &>/dev/null || true
  ip link delete wg-telemt &>/dev/null || true

  # Close WireGuard UDP port in firewall
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "active"; then
    ufw delete allow "$WG_PORT/udp" >/dev/null 2>&1 || true
  fi
  iptables -D INPUT -p udp --dport "$WG_PORT" -j ACCEPT 2>/dev/null || true

  rm -f "$CONF_FILE" "$MIKROTIK_TXT"
  _ok "Cascade tunnel removed successfully"

  printf "\n  ${ORANGE}${BOLD}Now clean up your Mikrotik — paste these commands in Mikrotik Terminal:${RESET}\n"
  printf "  \033[2m──────────────────────────────────────────────────────────────\033[0m\n"
  printf "  ${CYAN}/ip firewall nat remove [find comment=\"%s\"]${RESET}\n" "$CASCADE_COMMENT"
  printf "  ${CYAN}/ip address remove [find comment=\"%s\"]${RESET}\n" "$CASCADE_COMMENT"
  printf "  ${CYAN}/interface wireguard peers remove [find comment=\"%s\"]${RESET}\n" "$CASCADE_COMMENT"
  printf "  ${CYAN}/interface wireguard remove [find comment=\"%s\"]${RESET}\n" "$CASCADE_COMMENT"
  printf "  \033[2m──────────────────────────────────────────────────────────────\033[0m\n\n"
  printf "  \033[2mThese commands remove all Telemt Cascade rules by comment tag.\033[0m\n\n"

  read -p "  Press Enter to return..."
}

function sync_mikrotik_commands() {
  local WG_DIR="/etc/wireguard"
  local CONF_FILE="$WG_DIR/wg-telemt.conf"
  local MIKROTIK_TXT="$WG_DIR/wg-telemt-mikrotik.txt"
  local WG_PORT="51830"

  [ ! -f "$CONF_FILE" ] && return
  [ ! -f "$MIKROTIK_TXT" ] && return

  _fetch_ip
  local DISPLAY_IP="${SERVER_IP:-YOUR_UBUNTU_IP}"
  local SERVER_PUB=$(grep "PrivateKey" "$CONF_FILE" | awk '{print $3}' | wg pubkey)
  local MIKROTIK_PRIV=$(grep -oP '/interface wireguard add .* private-key="\K[^"]+' "$MIKROTIK_TXT" 2>/dev/null || echo "PLACEHOLDER")

  # Determine current cascade type from existing config
  local USE_IPV6=false
  if grep -q "IPv6" "$MIKROTIK_TXT" 2>/dev/null; then
    USE_IPV6=true
  fi

  # Determine IP type and set appropriate WireGuard addresses
  local WG_IP_SERVER
  local WG_IP_MIKROTIK
  local WG_ALLOWED_IPS
  local WG_MASK

  if [ "$USE_IPV6" = true ]; then
    WG_IP_SERVER="fd00::1"
    WG_IP_MIKROTIK="fd00::2"
    WG_ALLOWED_IPS="::/0"
    WG_MASK="64"
  else
    WG_IP_SERVER="10.99.99.1"
    WG_IP_MIKROTIK="10.99.99.2"
    WG_ALLOWED_IPS="0.0.0.0/0"
    WG_MASK="24"
  fi

  # Regenerate TXT file with current IP and current proxy port based on cascade type
  if [ "$USE_IPV6" = true ]; then
    sudo tee "$MIKROTIK_TXT" >/dev/null <<EOF
/interface wireguard add comment="Telemt Cascade IPv6" listen-port=13231 name=wg-telemt private-key="$MIKROTIK_PRIV"
/interface wireguard peers add allowed-address=::/0 comment="Telemt Cascade IPv6" endpoint-address=$DISPLAY_IP endpoint-port=$WG_PORT interface=wg-telemt public-key="$SERVER_PUB"
/ip address add address=$WG_IP_MIKROTIK/$WG_MASK comment="Telemt Cascade IPv6" interface=wg-telemt
/ip firewall nat add action=accept chain=srcnat comment="Telemt Cascade IPv6" protocol=tcp dst-port=$PORT out-interface=wg-telemt place-before=0
/ip firewall nat add action=dst-nat chain=dstnat comment="Telemt Cascade IPv6" protocol=tcp dst-port=$MIKROTIK_EXT_PORT in-interface=ether1 to-addresses=$WG_IP_SERVER to-ports=$PORT
EOF
  else
    sudo tee "$MIKROTIK_TXT" >/dev/null <<EOF
/interface wireguard add comment="Telemt Cascade" listen-port=13231 name=wg-telemt private-key="$MIKROTIK_PRIV"
/interface wireguard peers add allowed-address=0.0.0.0/0 comment="Telemt Cascade" endpoint-address=$DISPLAY_IP endpoint-port=$WG_PORT interface=wg-telemt public-key="$SERVER_PUB"
/ip address add address=$WG_IP_MIKROTIK/$WG_MASK comment="Telemt Cascade" interface=wg-telemt
/ip firewall nat add action=accept chain=srcnat comment="Telemt Cascade" protocol=tcp dst-port=$PORT out-interface=wg-telemt place-before=0
/ip firewall nat add action=dst-nat chain=dstnat comment="Telemt Cascade" protocol=tcp dst-port=$MIKROTIK_EXT_PORT in-interface=ether1 to-addresses=$WG_IP_SERVER to-ports=$PORT
EOF
  fi

  # Ensure transparent IP forwarding rules are active (idempotent - for existing setups)
  if ip link show wg-telemt &>/dev/null; then
    local ipt_cmd="iptables"
    if [ "$USE_IPV6" = true ]; then
      ipt_cmd="ip6tables"
    fi

    sudo $ipt_cmd -t mangle -C PREROUTING -i wg-telemt ! -s "$WG_IP_MIKROTIK" -j CONNMARK --set-mark 200 2>/dev/null || \
      sudo $ipt_cmd -t mangle -A PREROUTING -i wg-telemt ! -s "$WG_IP_MIKROTIK" -j CONNMARK --set-mark 200
    sudo $ipt_cmd -t mangle -C PREROUTING -m connmark --mark 200 -j MARK --set-mark 200 2>/dev/null || \
      sudo $ipt_cmd -t mangle -A PREROUTING -m connmark --mark 200 -j MARK --set-mark 200
    sudo ip rule show | grep -q "fwmark 0xc8 lookup 200" || sudo ip rule show | grep -q "fwmark 0xc8 lookup wg_table" || \
      sudo ip rule add fwmark 200 table 200 priority 90 2>/dev/null || true
    sudo $ipt_cmd -t nat -C POSTROUTING -o wg-telemt -m connmark --mark 200 -j SNAT --to-source "$WG_IP_SERVER" 2>/dev/null || \
      sudo $ipt_cmd -t nat -I POSTROUTING 1 -o wg-telemt -m connmark --mark 200 -j SNAT --to-source "$WG_IP_SERVER"
    # Ensure TCP MSS clamping is active (prevents oversized segments through tunnel)
    sudo $ipt_cmd -t mangle -C FORWARD -o wg-telemt -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
      sudo $ipt_cmd -t mangle -A FORWARD -o wg-telemt -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
  fi
}

function toggle_proxy_protocol() {
  clear
  printf "  \033[38;2;255;120;0m\033[1mMTProxy-Telemt-tg-ui\033[0m  \033[2m|  PROXY Protocol\033[0m\n"
  printf "  \033[2m──────────────────────────────────────────────────────\033[0m\n"
  
  if [ "$PROXY_PROTOCOL" == "true" ]; then
    PROXY_PROTOCOL="false"
    PROXY_PROTOCOL_CIDRS=""
    save_config_env
    start_proxy
    _ok "PROXY Protocol disabled"
  else
    printf "  Enable HAProxy PROXY Protocol support? \033[2m(y/n)\033[0m: "
    read ans
    if [[ "$ans" =~ ^[Yy]$ ]]; then
      PROXY_PROTOCOL="true"
      printf "  \n"
      printf "  \033[2mEnter your frontend server IPs separated by comma\033[0m\n"
      printf "  \033[2m(Example: 10.0.0.0/8, 192.168.1.100/32)\033[0m\n"
      printf "  trusted IPs (leave empty to trust ANY source): "
      read cidrs
      PROXY_PROTOCOL_CIDRS="$cidrs"
      save_config_env
      start_proxy
      _ok "PROXY Protocol enabled"
    fi
  fi
  sleep 2
}

function show_menu() {
  # Defensive check: if Docker created a directory here by mistake (happens if file didn't exist during mount)
  local ram_config="/dev/shm/telemt-tgui-config.toml"
  if [ -d "$ram_config" ]; then
    sudo rm -rf "$ram_config"
  fi

  # Auto-fix permissions if running as root or via sudo
  local real_user="${SUDO_USER:-$USER}"
  if [ "$(id -u)" -eq 0 ] && [ "$real_user" != "root" ]; then
    chown "$real_user":"$real_user" "$USERS_DB" "$PROJECT_DIR/.env" "$CONFIG_FILE" 2>/dev/null || true
    chmod 600 "$USERS_DB"
    chmod 644 "$PROJECT_DIR/.env" "$CONFIG_FILE"
  fi

  if ! sudo docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    start_proxy
    sleep 1
  fi

  while true; do
    clear
    printf "  \033[38;2;255;120;0m\033[1mMTProxy-Telemt-tg-ui\033[0m  \033[2m|  Main Menu\033[0m\n"
    printf "  \033[2m──────────────────────────────────────────────────────\033[0m\n"
    if sudo docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
      printf "  status:  \033[32m● running\033[0m\n"
    else
      printf "  status:  \033[31m○ stopped\033[0m\n"
    fi
    if _is_cascade_active; then
      local _cascade_ip=$(_get_cascade_ip)
      printf "  ip:      \033[2m%s\033[0m  \033[32m(cascade: %s:%s)\033[0m\n" "${SERVER_IP:-detecting...}" "$_cascade_ip" "$MIKROTIK_EXT_PORT"
    else
      printf "  ip:      \033[2m%s\033[0m\n" "${SERVER_IP:-detecting...}"
    fi
    printf "  port:    \033[2m%s\033[0m\n" "$PORT"
    printf "  sni:     \033[2m%s\033[0m\n" "$FAKE_DOMAIN"
    printf "  \033[2m──────────────────────────────────────────────────────\033[0m\n"
    printf "  \033[2m1)\033[0m  Restart proxy\n"
    printf "  \033[2m2)\033[0m  Change Fake TLS  \033[2m(%s)\033[0m\n" "$FAKE_DOMAIN"
    printf "  \033[2m3)\033[0m  Change port  \033[2m(%s)\033[0m\n" "$PORT"
    printf "  \033[2m4)\033[0m  Manage links & users\n"
    printf "  \033[2m5)\033[0m  Advanced security settings\n"
    printf "  \033[2m6)\033[0m  Update proxy image\n"
    printf "  \033[2m7)\033[0m  Stop proxy\n"
    printf "  \033[2m8)\033[0m  View logs\n"
    printf "  \033[2m9)\033[0m  Update panel\n"
    printf "  \033[2m0)\033[0m  Exit\n"
    printf "  \033[2m──────────────────────────────────────────────────────\033[0m\n"
    printf "  select: "
    read choice

    case $choice in
      1) start_proxy ;;
      2) change_fake_tls ;;
      3)
        printf "  Enter new port \033[2m[current: %s]\033[0m: " "$PORT"
        read input
        if [[ "$input" =~ ^[0-9]+$ ]] && [ "$input" -ge 1 ] && [ "$input" -le 65535 ]; then
          PORT="$input"
          save_config_env
          start_proxy
        elif [ -n "$input" ]; then
          _fail "Port must be a number between 1 and 65535 (you entered: $input)"
          sleep 2
        fi
        ;;
      4) manage_users ;;
      5) advanced_security_menu ;;
      6) update_from_upstream; printf "  \033[2mPress Enter to return...\033[0m"; read ;;
      7)
        cd "$PROJECT_DIR"
        sudo $DOCKER_COMPOSE down
        _ok "Service stopped"
        sleep 1
        ;;
      8) view_logs ;;
      9) update_panel ;;
      0) printf "\n  \033[2mBye!\033[0m\n\n"; exit 0 ;;
      *) _fail "Invalid command"; sleep 1 ;;
    esac
  done
}

if [ "$1" == "--auto" ]; then
  sleep 5
  migrate_to_multi_user
  start_proxy > /dev/null 2>&1
  exit 0
elif [ "$1" == "start" ]; then
  migrate_to_multi_user
  start_proxy
  exit $?
elif [ "$1" == "stop" ]; then
  cd "$PROJECT_DIR"
  sudo $DOCKER_COMPOSE down
  _ok "Service stopped"
  exit 0
elif [ "$1" == "update" ]; then
  update_panel
  exit 0
elif [ "$1" == "link" ]; then
  migrate_to_multi_user
  show_link
  exit 0
elif [ "$1" == "qr" ]; then
  migrate_to_multi_user
  show_qr
  exit 0
elif [ "$1" == "logs" ]; then
  view_logs
  exit 0
elif [ "$1" == "help" ] || [ -n "$1" ]; then
  echo
  printf "  \033[38;2;255;120;0m\033[1mMTProxy Management Commands\033[0m\n"
  printf "  \033[2m──────────────────────────────────────────────────────\033[0m\n"
  printf "  \033[33m%-18s\033[0m  \033[2m%s\033[0m\n" "tg-ui"       "Open interactive menu"
  printf "  \033[33m%-18s\033[0m  \033[2m%s\033[0m\n" "tg-ui start" "Start / restart proxy"
  printf "  \033[33m%-18s\033[0m  \033[2m%s\033[0m\n" "tg-ui stop"  "Stop proxy service"
  printf "  \033[33m%-18s\033[0m  \033[2m%s\033[0m\n" "tg-ui logs"  "View proxy logs"
  printf "  \033[33m%-18s\033[0m  \033[2m%s\033[0m\n" "tg-ui link"  "Show all connection links"
  printf "  \033[33m%-18s\033[0m  \033[2m%s\033[0m\n" "tg-ui qr"    "Generate QR codes for links"
  printf "  \033[33m%-18s\033[0m  \033[2m%s\033[0m\n" "tg-ui update" "Update management tool"
  printf "  \033[33m%-18s\033[0m  \033[2m%s\033[0m\n" "tg-ui help"   "Show this help message"
  printf "  \033[2m──────────────────────────────────────────────────────\033[0m\n"
  echo
  exit 0
fi

if [ "${BASH_SOURCE[0]}" == "${0}" ]; then
  migrate_to_multi_user
  show_menu
fi
