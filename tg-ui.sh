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
if docker compose version >/dev/null 2>&1; then
  DOCKER_COMPOSE="docker compose"
elif docker-compose version >/dev/null 2>&1; then
  DOCKER_COMPOSE="docker-compose"
else
  echo -e "${RED}❌ Docker Compose is not installed!${NC}"
  exit 1
fi

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
LOG_LEVEL="${LOG_LEVEL:-warn}"
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
LOG_LEVEL="${LOG_LEVEL:-warn}"
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

[general.modes]
classic = false
secure = false
tls = true

[server]
port = ${PORT:-8443}
EOF

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
  cd "$PROJECT_DIR"
  sudo $DOCKER_COMPOSE down >/dev/null 2>&1

  if sudo $DOCKER_COMPOSE up -d >/dev/null 2>&1; then
    local i=0
    while [ $i -lt 40 ]; do
      local status=$(sudo docker inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null)
      if [ "$status" == "running" ]; then
        _spin_ok "Container running"
        break
      fi
      _spin "${_frames[$((i % 10))]}" "Waiting for container..."
      ((i++)); sleep 0.1
    done

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
    if command -v curl >/dev/null 2>&1; then
      SERVER_IP=$(curl -s --connect-timeout 2 ifconfig.me 2>/dev/null || \
                  curl -s --connect-timeout 2 ipinfo.io/ip 2>/dev/null || \
                  curl -s --connect-timeout 2 icanhazip.com 2>/dev/null || \
                  curl -s --connect-timeout 2 api.ipify.org 2>/dev/null)
    fi
    # Fallback to local primary interface IP if external detection fails
    if [ -z "$SERVER_IP" ]; then
      SERVER_IP=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' || \
                  hostname -I | awk '{print $1}')
    fi
  else
    # Verify if stored IP is still present on the machine (optional but safer)
    if [[ ! "$SERVER_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
       # It might be a domain, skip validation
       return
    fi
    # If the stored IP is NOT in the local IPs and we are not in cascade mode
    if ! _is_cascade_active && ! hostname -I | grep -q "$SERVER_IP"; then
       # Silent check for IP change
       local new_ip=$(curl -s --connect-timeout 2 ifconfig.me 2>/dev/null)
       if [ -n "$new_ip" ] && [ "$new_ip" != "$SERVER_IP" ]; then
         SERVER_IP="$new_ip"
         save_config_env
       fi
    fi
  fi
}

function _is_cascade_active() {
  [ -f "/etc/wireguard/wg-telemt.conf" ] && \
  ip link show wg-telemt &>/dev/null && \
  sudo wg show wg-telemt endpoints 2>/dev/null | grep -qv "(none)"
}

function _get_cascade_ip() {
  local ext_ip=$(sudo wg show wg-telemt endpoints 2>/dev/null | awk '{print $2}' | cut -d: -f1 | grep -v "(none)" | head -n 1)
  echo "${ext_ip:-$SERVER_IP}"
}

function show_link() {
  local target_user=$1
  _fetch_ip

  local display_ip="$SERVER_IP"
  local display_port="$PORT"

  if _is_cascade_active; then
    display_ip=$(_get_cascade_ip)
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
    local link="tg://proxy?server=${display_ip}&port=${display_port}&secret=${link_secret}"

    printf "  \033[2m─── %s · %s \033[0m\n" "$name" "$limit_text"
    printf "  ${GREEN}%s${RESET}\n" "$link"
  done < "$USERS_DB"
  echo
}

function show_qr() {
  local target_user=$1

  if ! command -v qrencode >/dev/null 2>&1; then
    printf "  \033[33m⚙\033[0m  Installing qrencode...\n"
    if command -v apt-get >/dev/null 2>&1; then
      sudo apt-get install -y qrencode >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1; then
      sudo yum install -y qrencode >/dev/null 2>&1
    fi
    if ! command -v qrencode >/dev/null 2>&1; then
      printf "  \033[31m✗\033[0m  Failed to install qrencode. Run: sudo apt-get install -y qrencode\n"
      printf "  \033[2mPress Enter to return...\033[0m"; read; return
    fi
  fi

  _fetch_ip

  local display_ip="$SERVER_IP"
  local display_port="$PORT"

  if _is_cascade_active; then
    display_ip=$(_get_cascade_ip)
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

    printf "  \033[2m%s · %s\033[0m\n" "$name" "$limit_text"
    echo

    qr_output=$(qrencode -t UTF8i -m 2 "$link")
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
  printf "  \033[2m(Live feed · Press Enter or Ctrl+C to return)\033[0m\n\n"

  cd "$PROJECT_DIR"
  sudo $DOCKER_COMPOSE logs -f --tail 50 &
  local logs_pid=$!

  _stop_logs() {
    kill "$logs_pid" 2>/dev/null
    pkill -P "$logs_pid" 2>/dev/null
    wait "$logs_pid" 2>/dev/null
  }

  trap '_stop_logs; trap - INT; return 0' INT
  read -r _
  _stop_logs
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
       local raw_url="https://raw.githubusercontent.com/lyfreedomitsme/MTproxy-Telmet-tg-ui/master/tg-ui.sh"
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
    printf "  \033[2m%2d)\033[0m  %s%s\n" "$((i+1))" "$ip" "$marker"
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
    apt-get update && apt-get install -y wireguard-tools iptables iproute2
    if ! command -v wg &> /dev/null; then
       printf "  \033[31mx\033[0m  Failed to install wireguard-tools. Please install manually.\n"
       read -p "  Press Enter to return..."
       return
    fi
  fi

  if [ "$(sysctl -n net.ipv4.ip_forward)" != "1" ]; then
    printf "  \033[2mEnabling IP forwarding...\033[0m\n"
    sysctl -w net.ipv4.ip_forward=1 > /dev/null
    grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
  fi
  
  local WG_DIR="/etc/wireguard"
  local CONF_FILE="$WG_DIR/wg-telemt.conf"
  local MIKROTIK_TXT="$WG_DIR/wg-telemt-mikrotik.txt"
  
  if [ -f "$CONF_FILE" ]; then
    local pbr_status="\033[31m○ offline\033[0m"
    if ip link show wg-telemt &>/dev/null && ip rule show 2>/dev/null | grep -q "wg_table"; then
      pbr_status="\033[32m● running\033[0m"
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
  
  local WG_IP_SERVER="10.99.99.1"
  local WG_IP_MIKROTIK="10.99.99.2"
  local WG_PORT="51830"

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
  cat > "$CONF_FILE" <<EOF
[Interface]
PrivateKey = $SERVER_PRIV
Address = $WG_IP_SERVER/24
ListenPort = $WG_PORT
Table = off
PostUp = grep -q "200 wg_table" /etc/iproute2/rt_tables || echo "200 wg_table" >> /etc/iproute2/rt_tables
PostUp = ip rule del from $WG_IP_SERVER table 200 2>/dev/null; ip rule add from $WG_IP_SERVER table 200 priority 100
PostUp = ip route del default dev wg-telemt table 200 2>/dev/null; ip route add default dev wg-telemt table 200
PostUp = iptables -t mangle -D PREROUTING -i wg-telemt ! -s $WG_IP_MIKROTIK -j CONNMARK --set-mark 200 2>/dev/null; iptables -t mangle -A PREROUTING -i wg-telemt ! -s $WG_IP_MIKROTIK -j CONNMARK --set-mark 200
PostUp = iptables -t mangle -D PREROUTING -m connmark --mark 200 -j MARK --set-mark 200 2>/dev/null; iptables -t mangle -A PREROUTING -m connmark --mark 200 -j MARK --set-mark 200
PostUp = ip rule del fwmark 200 table 200 priority 90 2>/dev/null; ip rule add fwmark 200 table 200 priority 90
PostUp = iptables -t nat -I POSTROUTING 1 -o wg-telemt -m connmark --mark 200 -j SNAT --to-source $WG_IP_SERVER
PostDown = ip rule del from $WG_IP_SERVER table 200 2>/dev/null || true
PostDown = ip route del default dev wg-telemt table 200 2>/dev/null || true
PostDown = iptables -t mangle -D PREROUTING -i wg-telemt ! -s $WG_IP_MIKROTIK -j CONNMARK --set-mark 200 || true
PostDown = iptables -t mangle -D PREROUTING -m connmark --mark 200 -j MARK --set-mark 200 || true
PostDown = ip rule del fwmark 200 table 200 priority 90 2>/dev/null || true
PostDown = iptables -t nat -D POSTROUTING -o wg-telemt -m connmark --mark 200 -j SNAT --to-source $WG_IP_SERVER || true

[Peer]
PublicKey = $MIKROTIK_PUB
AllowedIPs = 0.0.0.0/0
EOF
  chmod 600 "$CONF_FILE"

  cat > "$MIKROTIK_TXT" <<EOF
/interface wireguard add comment="Telemt Cascade" listen-port=13231 name=wg-telemt private-key="$MIKROTIK_PRIV"
/interface wireguard peers add allowed-address=0.0.0.0/0 comment="Telemt Cascade" endpoint-address=$DISPLAY_IP endpoint-port=$WG_PORT interface=wg-telemt public-key="$SERVER_PUB"
/ip address add address=$WG_IP_MIKROTIK/24 comment="Telemt Cascade" interface=wg-telemt
/ip firewall nat add action=accept chain=srcnat comment="Telemt Cascade" protocol=tcp dst-port=$PORT out-interface=wg-telemt place-before=0
/ip firewall nat add action=dst-nat chain=dstnat comment="Telemt Cascade" protocol=tcp dst-port=$MIKROTIK_EXT_PORT in-interface=ether1 to-addresses=$WG_IP_SERVER to-ports=$PORT
EOF
  
  systemctl enable --now wg-quick@wg-telemt &> /dev/null || true
  sleep 1

  if ! ip link show wg-telemt &>/dev/null; then
    printf "  \033[31mx\033[0m  WireGuard interface failed to start.\n"
    printf "     Check: \033[2msystemctl status wg-quick@wg-telemt\033[0m\n"
    read -p "  Press Enter to return..."
    return
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
  printf "  ${CYAN}/ip firewall nat remove [find comment=\"Telemt Cascade\"]${RESET}\n"
  printf "  ${CYAN}/ip address remove [find comment=\"Telemt Cascade\"]${RESET}\n"
  printf "  ${CYAN}/interface wireguard peers remove [find comment=\"Telemt Cascade\"]${RESET}\n"
  printf "  ${CYAN}/interface wireguard remove [find comment=\"Telemt Cascade\"]${RESET}\n"
  printf "  \033[2m──────────────────────────────────────────────────────────────\033[0m\n\n"
  printf "  \033[2mThese commands remove all Telemt Cascade rules by comment tag.\033[0m\n\n"

  read -p "  Press Enter to return..."
}

function sync_mikrotik_commands() {
  local WG_DIR="/etc/wireguard"
  local CONF_FILE="$WG_DIR/wg-telemt.conf"
  local MIKROTIK_TXT="$WG_DIR/wg-telemt-mikrotik.txt"
  local WG_IP_SERVER="10.99.99.1"
  local WG_IP_MIKROTIK="10.99.99.2"
  local WG_PORT="51830"

  [ ! -f "$CONF_FILE" ] && return
  [ ! -f "$MIKROTIK_TXT" ] && return

  _fetch_ip
  local DISPLAY_IP="${SERVER_IP:-YOUR_UBUNTU_IP}"
  local SERVER_PUB=$(grep "PrivateKey" "$CONF_FILE" | awk '{print $3}' | wg pubkey)
  local MIKROTIK_PRIV=$(grep -oP '/interface wireguard add .* private-key="\K[^"]+' "$MIKROTIK_TXT" 2>/dev/null || echo "PLACEHOLDER")

  # Regenerate TXT file with current IP and current proxy port
  sudo tee "$MIKROTIK_TXT" >/dev/null <<EOF
/interface wireguard add comment="Telemt Cascade" listen-port=13231 name=wg-telemt private-key="$MIKROTIK_PRIV"
/interface wireguard peers add allowed-address=0.0.0.0/0 comment="Telemt Cascade" endpoint-address=$DISPLAY_IP endpoint-port=$WG_PORT interface=wg-telemt public-key="$SERVER_PUB"
/ip address add address=$WG_IP_MIKROTIK/24 comment="Telemt Cascade" interface=wg-telemt
/ip firewall nat add action=accept chain=srcnat comment="Telemt Cascade" protocol=tcp dst-port=$PORT out-interface=wg-telemt place-before=0
/ip firewall nat add action=dst-nat chain=dstnat comment="Telemt Cascade" protocol=tcp dst-port=$MIKROTIK_EXT_PORT in-interface=ether1 to-addresses=$WG_IP_SERVER to-ports=$PORT
EOF

  # Ensure transparent IP forwarding rules are active (idempotent - for existing setups)
  if ip link show wg-telemt &>/dev/null; then
    iptables -t mangle -C PREROUTING -i wg-telemt ! -s "$WG_IP_MIKROTIK" -j CONNMARK --set-mark 200 2>/dev/null || \
      iptables -t mangle -A PREROUTING -i wg-telemt ! -s "$WG_IP_MIKROTIK" -j CONNMARK --set-mark 200
    iptables -t mangle -C PREROUTING -m connmark --mark 200 -j MARK --set-mark 200 2>/dev/null || \
      iptables -t mangle -A PREROUTING -m connmark --mark 200 -j MARK --set-mark 200
    ip rule show | grep -q "fwmark 0xc8 lookup 200" || ip rule show | grep -q "fwmark 0xc8 lookup wg_table" || \
      ip rule add fwmark 200 table 200 priority 90 2>/dev/null || true
    iptables -t nat -C POSTROUTING -o wg-telemt -m connmark --mark 200 -j SNAT --to-source "$WG_IP_SERVER" 2>/dev/null || \
      iptables -t nat -I POSTROUTING 1 -o wg-telemt -m connmark --mark 200 -j SNAT --to-source "$WG_IP_SERVER"
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

  if ! sudo docker ps | grep -q "${CONTAINER_NAME}"; then
    start_proxy
    sleep 1
  fi

  while true; do
    clear
    printf "  \033[38;2;255;120;0m\033[1mMTProxy-Telemt-tg-ui\033[0m  \033[2m|  Main Menu\033[0m\n"
    printf "  \033[2m──────────────────────────────────────────────────────\033[0m\n"
    if sudo docker ps | grep -q "${CONTAINER_NAME}"; then
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
        if [[ "$input" =~ ^[0-9]+$ ]]; then
          PORT="$input"
          save_config_env
          start_proxy
        elif [ -n "$input" ]; then
          _fail "Port must be a number (you entered: $input)"
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
  exit 0
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
