#!/bin/bash
# Checking Root Access
if [[ $EUID -ne 0 ]]; then
    echo -e "\033[31m[ERROR]\033[0m Please run this script as \033[1mroot\033[0m."
    exit 1
fi

INSTALL_LOG="/tmp/mirza_install.log"

print_header() {
    echo ""
    echo -e "\033[1;34m╭────────────────────────────────────────────────╮\033[0m"
    printf  "\033[1;34m│\033[0m \033[1;36m%-46s\033[0m \033[1;34m│\033[0m\n" "$1"
    echo -e "\033[1;34m╰────────────────────────────────────────────────╯\033[0m"
}

run_step() {
    local msg="$1"
    local cmd="$2"
    : > "$INSTALL_LOG"
    bash -c "$cmd" >> "$INSTALL_LOG" 2>&1 &
    local pid=$!
    local frames=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
    local n=${#frames[@]}
    local i=0
    tput civis 2>/dev/null
    while kill -0 "$pid" 2>/dev/null; do
        printf "\r\033[K \033[1;33m%s\033[0m  %s" "${frames[$i]}" "$msg"
        i=$(( (i + 1) % n ))
        sleep 0.1
    done
    wait "$pid"
    local rc=$?
    tput cnorm 2>/dev/null
    if [ "$rc" -eq 0 ]; then
        printf "\r\033[K \033[1;32m✔\033[0m  %s\n" "$msg"
    else
        printf "\r\033[K \033[1;31m✘\033[0m  %s\n" "$msg"
    fi
    return "$rc"
}

show_step_error() {
    echo -e "\033[1;31m──────────────── Error details ─────────────────\033[0m"
    tail -n 20 "$INSTALL_LOG" 2>/dev/null
    echo -e "\033[1;31m─────────────────────────────────────────────────\033[0m"
}

# ── Menu UI helpers ──────────────────────────────────────────
C_BORDER=$'\033[1;36m'; C_TITLE=$'\033[1;37m'; C_DIM=$'\033[0;37m'
C_KEY=$'\033[1;33m';    C_TXT=$'\033[0;37m';   C_OK=$'\033[1;32m'
C_BAD=$'\033[1;31m';    C_WARN=$'\033[1;33m';  C_PROMPT=$'\033[1;36m'
CR=$'\033[0m'
UI_W=52   # width of horizontal rules (no right border = never misaligns)

_repeat() { local ch="$1" n="$2" out="" i; for ((i=0;i<n;i++)); do out+="$ch"; done; printf '%s' "$out"; }
# Horizontal rules (left-aligned, no right edge to drift)
_rule()   { printf "  ${C_BORDER}%s${CR}\n" "$(_repeat "─" "$UI_W")"; }
_drule()  { printf "  ${C_BORDER}%s${CR}\n" "$(_repeat "━" "$UI_W")"; }
# Banner: rules + left-aligned title (no full box)
banner()  {
    echo
    _drule
    printf "  ${C_OK}▌${CR} ${C_TITLE}MIRZA${CR}  ${C_DIM}— VPN Subscription Management${CR}\n"
    _drule
}
# Menu item row: [n] label  (left-aligned, no right border)
_mi()     { printf "    ${C_KEY}[%s]${CR}  ${C_TXT}%b${CR}\n" "$1" "$2"; }

# ── DNS auto-fix (used early, before any download) ───────────
RESOLV="/etc/resolv.conf"
DNS_SERVERS=("1.1.1.1" "8.8.8.8" "9.9.9.9")

dns_works() {
    getent hosts github.com       >/dev/null 2>&1 && return 0
    getent hosts api.telegram.org >/dev/null 2>&1 && return 0
    return 1
}

ensure_dns() {
    dns_works && return 0
    echo -e "  ${C_WARN}!${CR} ${C_WARN}DNS resolution failed - configuring public DNS...${CR}"
    if [ -L "$RESOLV" ]; then
        rm -f "$RESOLV" 2>/dev/null
    elif [ -f "$RESOLV" ] && [ ! -f "${RESOLV}.mirza.bak" ]; then
        cp -a "$RESOLV" "${RESOLV}.mirza.bak" 2>/dev/null
    fi
    { local d; for d in "${DNS_SERVERS[@]}"; do echo "nameserver $d"; done; } > "$RESOLV" 2>/dev/null
    if command -v resolvectl >/dev/null 2>&1; then
        local ifc; ifc=$(ip route show default 2>/dev/null | awk '/default/{print $5; exit}')
        [ -n "$ifc" ] && resolvectl dns "$ifc" "${DNS_SERVERS[@]}" 2>/dev/null || true
    fi
    sleep 1
    dns_works && { echo -e "  ${C_OK}●${CR} ${C_OK}DNS is now working.${CR}"; return 0; }
    echo -e "  ${C_BAD}●${CR} ${C_BAD}DNS still failing after applying public resolvers.${CR}"
    return 1
}

# Ensure /usr/local/bin/mirza points at the master script
_link_mirza() {
    local master="$1" link="$2"
    chmod +x "$master" 2>/dev/null
    if [ ! -e "$link" ] || [ "$(readlink -f "$link" 2>/dev/null)" != "$(readlink -f "$master" 2>/dev/null)" ]; then
        ln -sf "$master" "$link"
    fi
    chmod +x "$link" 2>/dev/null
}

# Self-update: every run, fetch the latest script from GitHub, validate it,
# install it to /root/install.sh, link it into /usr/local/bin, and re-exec.
function self_update_script() {
    local MASTER_PATH="/root/install.sh"
    local BIN_LINK="/usr/local/bin/mirza"
    local URL="https://raw.githubusercontent.com/mahdiMGF2/mirza_pro/main/install.sh"
    local TEMP_FILE="/tmp/mirza_pro_update.sh"

    # Make sure DNS works before reaching GitHub
    ensure_dns >/dev/null 2>&1

    echo -e "\e[33mChecking for the latest script version...\033[0m"
    rm -f "$TEMP_FILE"
    curl -fsSL --max-time 15 -o "$TEMP_FILE" "$URL" 2>/dev/null \
        || wget -q -O "$TEMP_FILE" "$URL" 2>/dev/null

    # Validate the download is a complete, valid bash script (not a 404/HTML/partial)
    local valid=0
    if [ -s "$TEMP_FILE" ] \
       && head -n1 "$TEMP_FILE" | grep -q '^#!/bin/bash' \
       && grep -q 'process_arguments' "$TEMP_FILE" \
       && bash -n "$TEMP_FILE" 2>/dev/null; then
        valid=1
    fi

    if [ "$valid" -ne 1 ]; then
        echo -e "\e[91mWarning: could not fetch a valid update (offline / bad download). Using current version.\033[0m"
        rm -f "$TEMP_FILE"
        if [ ! -f "$MASTER_PATH" ]; then
            echo -e "\e[91mCritical: cannot install the script for the first time without internet.\033[0m"
            exit 1
        fi
        _link_mirza "$MASTER_PATH" "$BIN_LINK"
        return 0
    fi

    local LOCAL_HASH REMOTE_HASH
    if [ -f "$MASTER_PATH" ]; then
        LOCAL_HASH=$(md5sum "$MASTER_PATH" | awk '{print $1}')
    else
        LOCAL_HASH="not_installed"
    fi
    REMOTE_HASH=$(md5sum "$TEMP_FILE" | awk '{print $1}')

    if [ "$LOCAL_HASH" != "$REMOTE_HASH" ]; then
        if [ "$LOCAL_HASH" = "not_installed" ]; then
            echo -e "\e[32mInstalling script to the system...\033[0m"
        else
            echo -e "\e[32mNew version found - updating...\033[0m"
        fi
        install -m 0755 "$TEMP_FILE" "$MASTER_PATH" 2>/dev/null || { mv "$TEMP_FILE" "$MASTER_PATH"; chmod +x "$MASTER_PATH"; }
        rm -f "$TEMP_FILE"
        _link_mirza "$MASTER_PATH" "$BIN_LINK"
        echo -e "\e[32mUpdated. Restarting with the latest version...\033[0m"
        sleep 1
        exec bash "$MASTER_PATH" "$@"
    fi

    # Already up to date - just make sure it is linked under /usr/local/bin
    rm -f "$TEMP_FILE"
    _link_mirza "$MASTER_PATH" "$BIN_LINK"
    echo -e "\e[32mScript is up to date.\033[0m"
}
self_update_script "$@"

# ── Repo / paths ─────────────────────────────────────────────
BOT_DIR_DEFAULT="/var/www/html/mirzaprobotconfig"
CONFIG_FILE_DEFAULT="$BOT_DIR_DEFAULT/config.php"
GIT_REPO="mahdiMGF2/mirzabot"
LATEST_CACHE="/tmp/.mirza_latest_version"
IP_CACHE="/tmp/.mirza_server_ip"

# Colored status dot
_dot() {
    case "$1" in
        ok)   printf "${C_OK}●${CR}"  ;;
        bad)  printf "${C_BAD}●${CR}" ;;
        warn) printf "${C_WARN}●${CR}";;
        *)    printf "${C_DIM}●${CR}" ;;
    esac
}

# Dashboard section header + key/value row helpers
_sec() { printf "\n  ${C_KEY}▌${CR} ${C_TITLE}%s${CR}\n" "$1"; _rule; }
_kv()  { printf "    ${C_DIM}%-11s${CR}${C_BORDER}:${CR} %b${CR}\n" "$1" "$2"; }

# Read the installed version from the source 'version' file
get_installed_version() {
    if [ -f "$BOT_DIR_DEFAULT/version" ]; then
        tr -d ' \t\r\n' < "$BOT_DIR_DEFAULT/version"
    else
        echo ""
    fi
}

# Get latest version (newest git tag) from GitHub, cached for 1 hour
get_latest_version() {
    if [ -f "$LATEST_CACHE" ] && [ $(( $(date +%s) - $(stat -c %Y "$LATEST_CACHE" 2>/dev/null || echo 0) )) -lt 3600 ]; then
        cat "$LATEST_CACHE"
        return
    fi
    local tags v
    tags=$(curl -fsSL --max-time 6 "https://api.github.com/repos/${GIT_REPO}/tags" 2>/dev/null)
    if [ -n "$tags" ]; then
        if command -v jq >/dev/null 2>&1; then
            v=$(echo "$tags" | jq -r '.[].name' 2>/dev/null | sort -V | tail -1)
        else
            v=$(echo "$tags" | grep -oE '"name"[[:space:]]*:[[:space:]]*"[^"]+"' | sed -E 's/.*"([^"]+)".*/\1/' | sort -V | tail -1)
        fi
    fi
    if [ -n "$v" ]; then
        echo "$v" > "$LATEST_CACHE"
        echo "$v"
    fi
}

# Print all release tags, newest first (one per line)
list_tags_desc() {
    local tags
    tags=$(curl -fsSL --max-time 8 "https://api.github.com/repos/${GIT_REPO}/tags" 2>/dev/null)
    [ -z "$tags" ] && return 1
    if command -v jq >/dev/null 2>&1; then
        echo "$tags" | jq -r '.[].name' 2>/dev/null | sort -Vr
    else
        echo "$tags" | grep -oE '"name"[[:space:]]*:[[:space:]]*"[^"]+"' | sed -E 's/.*"([^"]+)".*/\1/' | sort -Vr
    fi
}

# Choose which source to download.
# Sets globals: SRC_ZIP_URL, SRC_LABEL
# Honors flags ARG_CHANNEL (beta|release|auto) and ARG_VERSION (tag) for non-interactive use.
# Returns: 0 = chosen, 1 = error, 2 = back to menu
choose_source() {
    SRC_ZIP_URL=""; SRC_LABEL=""
    local beta="https://github.com/${GIT_REPO}/archive/refs/heads/main.zip"
    local tagbase="https://github.com/${GIT_REPO}/archive/refs/tags"

    # ── Non-interactive (flags) ──────────────────────────────
    if [ -n "$ARG_VERSION" ]; then
        # Verify the requested tag actually exists (when the list is reachable)
        local _avail; _avail=$(list_tags_desc)
        if [ -n "$_avail" ] && ! echo "$_avail" | grep -qx "$ARG_VERSION"; then
            echo -e "    ${C_BAD}●${CR} ${C_BAD}Version '${ARG_VERSION}' not found.${CR}"
            echo -e "    ${C_DIM}Available:${CR} $(echo "$_avail" | tr '\n' ' ')"
            return 1
        fi
        SRC_ZIP_URL="${tagbase}/${ARG_VERSION}.zip"; SRC_LABEL="Release ${ARG_VERSION}"; return 0
    fi
    if [ -n "$ARG_CHANNEL" ]; then
        case "$ARG_CHANNEL" in
            beta|main)      SRC_ZIP_URL="$beta"; SRC_LABEL="Beta (main)"; return 0 ;;
            release|auto|latest|stable)
                local l; l=$(get_latest_version)
                if [ -n "$l" ]; then SRC_ZIP_URL="${tagbase}/${l}.zip"; SRC_LABEL="Release ${l}";
                else SRC_ZIP_URL="$beta"; SRC_LABEL="Beta (main)"; fi
                return 0 ;;
            *) echo -e "    ${C_BAD}Unknown channel: ${ARG_CHANNEL}${CR}"; return 1 ;;
        esac
    fi

    # ── Interactive ──────────────────────────────────────────
    _sec "Select version"
    _mi "1" "Automatic  ${C_DIM}(latest stable release)${CR}"
    _mi "2" "Choose a specific release version"
    _mi "3" "Beta       ${C_DIM}(latest main branch - may be unstable)${CR}"
    _mi "0" "Back to menu"
    echo ""
    printf "  ${C_PROMPT}❯${CR} Select ${C_DIM}[0-3]${CR}: "
    local S; read -r S
    case "$S" in
        0) return 2 ;;
        1)
            local l; l=$(get_latest_version)
            if [ -n "$l" ]; then SRC_ZIP_URL="${tagbase}/${l}.zip"; SRC_LABEL="Release ${l}";
            else
                echo -e "    ${C_WARN}Could not detect latest release; falling back to Beta.${CR}"
                SRC_ZIP_URL="$beta"; SRC_LABEL="Beta (main)"
            fi
            return 0 ;;
        2)
            echo ""
            echo -e "  ${C_DIM}Fetching available versions...${CR}"
            local TAGS=(); mapfile -t TAGS < <(list_tags_desc)
            if [ "${#TAGS[@]}" -eq 0 ]; then
                echo -e "    ${C_BAD}●${CR} ${C_BAD}Could not fetch release list (offline or rate-limited).${CR}"
                return 1
            fi
            _sec "Available versions"
            local i=1 t
            for t in "${TAGS[@]}"; do
                if [ "$i" -eq 1 ]; then _mi "$i" "${t}  ${C_OK}(latest)${CR}"; else _mi "$i" "$t"; fi
                i=$((i+1))
            done
            _mi "0" "Back to menu"
            echo ""
            printf "  ${C_PROMPT}❯${CR} Select version ${C_DIM}[default: 1]${CR}: "
            local V; read -r V; [ -z "$V" ] && V=1
            [ "$V" = "0" ] && return 2
            if ! [[ "$V" =~ ^[0-9]+$ ]] || [ "$V" -lt 1 ] || [ "$V" -gt "${#TAGS[@]}" ]; then
                echo -e "    ${C_BAD}Invalid selection.${CR}"; return 1
            fi
            local c="${TAGS[$((V-1))]}"
            SRC_ZIP_URL="${tagbase}/${c}.zip"; SRC_LABEL="Release ${c}"
            return 0 ;;
        3) SRC_ZIP_URL="$beta"; SRC_LABEL="Beta (main)"; return 0 ;;
        *) echo -e "    ${C_BAD}Invalid selection.${CR}"; return 1 ;;
    esac
}

# Get public server IP, cached for 1 hour (falls back to local IP)
get_server_ip() {
    if [ -f "$IP_CACHE" ] && [ $(( $(date +%s) - $(stat -c %Y "$IP_CACHE" 2>/dev/null || echo 0) )) -lt 3600 ]; then
        cat "$IP_CACHE"
        return
    fi
    local ip
    ip=$(curl -fsSL --max-time 4 ifconfig.me 2>/dev/null)
    [ -z "$ip" ] && ip=$(curl -fsSL --max-time 4 https://api.ipify.org 2>/dev/null)
    [ -z "$ip" ] && ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    [ -z "$ip" ] && ip="n/a"
    echo "$ip" > "$IP_CACHE"
    echo "$ip"
}

# ── Dashboard sections ───────────────────────────────────────
version_section() {
    local inst latest
    inst=$(get_installed_version)
    latest=$(get_latest_version)
    _sec "Version"
    if [ -n "$inst" ]; then
        _kv "Installed" "$(_dot ok) ${C_OK}${inst}${CR}"
    else
        _kv "Installed" "$(_dot bad) ${C_BAD}not installed${CR}"
    fi
    if [ -n "$latest" ]; then
        if [ -n "$inst" ] && [ "$inst" = "$latest" ]; then
            _kv "Latest" "$(_dot ok) ${C_OK}${latest}${CR} ${C_DIM}(up to date)${CR}"
        elif [ -n "$inst" ]; then
            _kv "Latest" "$(_dot warn) ${C_WARN}${latest}${CR} ${C_WARN}(update available!)${CR}"
        else
            _kv "Latest" "$(_dot warn) ${C_DIM}${latest}${CR}"
        fi
    else
        _kv "Latest" "$(_dot warn) ${C_DIM}unknown (offline)${CR}"
    fi
    _kv "Channel" "${C_DIM}t.me/mirzapanel${CR}"
    _kv "Group" "${C_DIM}t.me/mirzapanelgroup${CR}"
}

bot_section() {
    SSL_DOMAIN=""
    _sec "Bot Status"
    if [ ! -f "$CONFIG_FILE_DEFAULT" ]; then
        _kv "State" "$(_dot bad) ${C_BAD}not installed${CR}"
        return
    fi
    _kv "State" "$(_dot ok) ${C_OK}installed${CR}"
    SSL_DOMAIN=$(grep '^\$domainhosts' "$CONFIG_FILE_DEFAULT" | cut -d"'" -f2 | cut -d'/' -f1)
    if [ -n "$SSL_DOMAIN" ] && [ -f "/etc/letsencrypt/live/$SSL_DOMAIN/cert.pem" ]; then
        local expiry days
        expiry=$(openssl x509 -enddate -noout -in "/etc/letsencrypt/live/$SSL_DOMAIN/cert.pem" 2>/dev/null | cut -d= -f2)
        days=$(( ( $(date -d "$expiry" +%s 2>/dev/null || echo 0) - $(date +%s) ) / 86400 ))
        if [ "$days" -gt 14 ]; then
            _kv "SSL" "$(_dot ok) ${C_OK}valid${CR} ${C_DIM}(${days} days left)${CR}"
        elif [ "$days" -gt 0 ]; then
            _kv "SSL" "$(_dot warn) ${C_WARN}valid${CR} ${C_DIM}(${days} days left - renew soon)${CR}"
        else
            _kv "SSL" "$(_dot bad) ${C_BAD}expired${CR}"
        fi
    else
        _kv "SSL" "$(_dot warn) ${C_WARN}certificate not found${CR}"
    fi
    if [ -n "$SSL_DOMAIN" ]; then
        _kv "Domain" "${C_DIM}https://${SSL_DOMAIN}${CR}"
        _kv "phpMyAdmin" "${C_DIM}https://${SSL_DOMAIN}/phpmyadmin${CR}"
    fi
}

# Read the Telegram webhook using the bot token from config.php.
# Prints webhook URL / pending count, and surfaces any error message.
webhook_section() {
    _sec "Webhook"
    if [ ! -f "$CONFIG_FILE_DEFAULT" ]; then
        _kv "Status" "$(_dot warn) ${C_DIM}n/a (bot not installed)${CR}"
        return
    fi
    local token info ok url pending err errdate apierr when
    token=$(grep '^\$APIKEY' "$CONFIG_FILE_DEFAULT" | cut -d"'" -f2)
    if [ -z "$token" ]; then
        _kv "Status" "$(_dot bad) ${C_BAD}token not found in config.php${CR}"
        return
    fi
    info=$(curl -fsSL --max-time 8 "https://api.telegram.org/bot${token}/getWebhookInfo" 2>/dev/null)
    if [ -z "$info" ]; then
        _kv "Status" "$(_dot bad) ${C_BAD}cannot reach Telegram API${CR}"
        printf "    ${C_BAD}Error:${CR} request to api.telegram.org failed (network/timeout).\n"
        return
    fi
    if command -v jq >/dev/null 2>&1; then
        ok=$(echo "$info"     | jq -r '.ok')
        url=$(echo "$info"    | jq -r '.result.url // empty')
        pending=$(echo "$info"| jq -r '.result.pending_update_count // 0')
        err=$(echo "$info"    | jq -r '.result.last_error_message // empty')
        errdate=$(echo "$info"| jq -r '.result.last_error_date // empty')
        apierr=$(echo "$info" | jq -r '.description // empty')
    else
        ok=$(echo "$info"     | grep -oE '"ok":[[:space:]]*(true|false)' | grep -oE '(true|false)')
        url=$(echo "$info"    | grep -oE '"url":[[:space:]]*"[^"]*"' | sed -E 's/.*"url":[[:space:]]*"([^"]*)".*/\1/')
        pending=$(echo "$info"| grep -oE '"pending_update_count":[[:space:]]*[0-9]+' | grep -oE '[0-9]+$')
        err=$(echo "$info"    | grep -oE '"last_error_message":[[:space:]]*"[^"]*"' | sed -E 's/.*"last_error_message":[[:space:]]*"([^"]*)".*/\1/')
        errdate=$(echo "$info"| grep -oE '"last_error_date":[[:space:]]*[0-9]+' | grep -oE '[0-9]+$')
        apierr=$(echo "$info" | grep -oE '"description":[[:space:]]*"[^"]*"' | sed -E 's/.*"description":[[:space:]]*"([^"]*)".*/\1/')
        [ -z "$pending" ] && pending=0
    fi
    # Telegram-level API failure (e.g. invalid/revoked token)
    if [ "$ok" != "true" ]; then
        _kv "Status" "$(_dot bad) ${C_BAD}API error${CR}"
        [ -n "$apierr" ] && printf "    ${C_BAD}Error:${CR} %s\n" "$apierr"
        return
    fi
    # Webhook URL
    if [ -n "$url" ]; then
        _kv "URL" "$(_dot ok) ${C_OK}set${CR} ${C_DIM}(${url})${CR}"
    else
        _kv "URL" "$(_dot bad) ${C_BAD}not set${CR}"
    fi
    _kv "Pending" "${C_DIM}${pending} update(s)${CR}"
    # Last delivery error reported by Telegram
    if [ -n "$err" ]; then
        when=""
        [ -n "$errdate" ] && when=$(date -d "@$errdate" '+%Y-%m-%d %H:%M' 2>/dev/null)
        _kv "Last error" "$(_dot bad) ${C_BAD}${err}${CR}"
        [ -n "$when" ] && _kv "Error time" "${C_DIM}${when}${CR}"
    else
        _kv "Last error" "$(_dot ok) ${C_OK}none${CR}"
    fi
}

system_section() {
    local php_v apache_s mysql_s ip os
    php_v=$(php -r 'echo PHP_VERSION;' 2>/dev/null); [ -z "$php_v" ] && php_v="n/a"
    apache_s=$(systemctl is-active apache2 2>/dev/null || echo "inactive")
    mysql_s=$(systemctl is-active mysql 2>/dev/null || echo "inactive")
    ip=$(get_server_ip)
    if [ -f /etc/os-release ]; then os=$(. /etc/os-release; echo "$PRETTY_NAME"); else os="Unknown"; fi
    _svc_row() { if [ "$2" = "active" ]; then _kv "$1" "$(_dot ok) ${C_OK}active${CR}"; else _kv "$1" "$(_dot bad) ${C_BAD}$2${CR}"; fi; }
    _sec "System"
    _kv "OS" "${C_DIM}${os}${CR}"
    _kv "PHP" "${C_DIM}${php_v}${CR}"
    _svc_row "Apache" "$apache_s"
    _svc_row "MySQL" "$mysql_s"
    _kv "Server IP" "${C_DIM}${ip}${CR}"
}

resources_section() {
    local mem_t mem_u mem_p disk load cores up
    mem_t=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}')
    mem_u=$(free -m 2>/dev/null | awk '/^Mem:/{print $3}')
    if [ -n "$mem_t" ] && [ "$mem_t" -gt 0 ] 2>/dev/null; then mem_p=$(( mem_u * 100 / mem_t )); else mem_p=0; fi
    disk=$(df -h / 2>/dev/null | awk 'NR==2{print $3" / "$2"  ("$5")"}')
    load=$(awk '{print $1", "$2", "$3}' /proc/loadavg 2>/dev/null)
    cores=$(nproc 2>/dev/null)
    up=$(uptime -p 2>/dev/null | sed 's/^up //')
    [ -z "$up" ] && up="n/a"
    _sec "Resources"
    _kv "RAM" "${C_DIM}${mem_u}MB / ${mem_t}MB  (${mem_p}%)${CR}"
    _kv "Disk" "${C_DIM}${disk}${CR}"
    _kv "CPU load" "${C_DIM}${load}  (${cores} cores)${CR}"
    _kv "Uptime" "${C_DIM}${up}${CR}"
}

function show_logo() {
    clear
    banner
    version_section
    bot_section
    webhook_section
    system_section
    resources_section
}

function show_menu() {
    show_logo
    _sec "Menu"
    _mi "1" "Install Mirza"
    _mi "2" "Update Mirza"
    _mi "3" "Remove Mirza"
    _mi "4" "Migrate: Free -> Pro (Beta)"
    _mi "5" "Help & Parameters"
    _mi "6" "Exit"
    _rule
    echo ""
    printf  "  ${C_PROMPT}❯${CR} Select an option ${C_DIM}[1-6]${CR}: "
    read -r option
    case $option in
        1) install_bot ;;
        2) update_bot ;;
        3) remove_bot ;;
        4) migrate_to_pro ;;
        5) show_help_screen ;;
        6) echo -e "\n${C_OK}Exiting...${CR}"; exit 0 ;;
        *) echo -e "\n${C_BAD}Invalid option. Please try again.${CR}"; sleep 1; show_menu ;;
    esac
}

# Clean, styled guide of all commands and parameters
function show_help_screen() {
    clear
    banner

    _sec "Commands"
    _kv "install" "${C_DIM}Install Mirza${CR}"
    _kv "update" "${C_DIM}Update Mirza (choose channel / version)${CR}"
    _kv "remove" "${C_DIM}Remove Mirza and its services${CR}"
    _kv "migrate" "${C_DIM}Migrate Free -> Pro${CR}"
    _kv "menu" "${C_DIM}Open this interactive panel (default)${CR}"

    _sec "Install parameters"
    _kv "--name" "${C_DIM}Bot username${CR}"
    _kv "--token" "${C_DIM}Telegram bot token${CR}"
    _kv "--admin" "${C_DIM}Admin chat id${CR}"
    _kv "--domain" "${C_DIM}Domain name (e.g. bot.example.com)${CR}"
    _kv "--db-user" "${C_DIM}Database username${CR}"
    _kv "--db-pass" "${C_DIM}Database password${CR}"

    _sec "Source parameters"
    _kv "--version" "${C_DIM}Specific release tag (e.g. 0.1.7)${CR}"
    _kv "--channel" "${C_DIM}beta | release | auto${CR}"
    _kv "-h, --help" "${C_DIM}Show CLI help and exit${CR}"

    _sec "Examples"
    printf "    ${C_KEY}mirza install --channel auto${CR}\n"
    printf "    ${C_KEY}mirza install --name myvpnbot --token 123:ABC \\\\${CR}\n"
    printf "    ${C_DIM}            --admin 111 --domain bot.example.com --version 0.1.7${CR}\n"
    printf "    ${C_KEY}mirza update --version 0.1.6${CR}\n"
    printf "    ${C_KEY}mirza update --channel release${CR}\n"
    printf "    ${C_KEY}mirza remove${CR}\n"

    echo ""
    _rule
    echo ""
    printf "  ${C_PROMPT}❯${CR} Press Enter to return to the menu... "
    read -r _
    show_menu
}
function check_marzban_installed() {
    if [ -f "/opt/marzban/docker-compose.yml" ]; then
        return 0
    else
        return 1
    fi
}
function detect_database_type() {
    COMPOSE_FILE="/opt/marzban/docker-compose.yml"
    if [ ! -f "$COMPOSE_FILE" ]; then
        echo "unknown"
        return 1
    fi
    if grep -q "^[[:space:]]*mysql:" "$COMPOSE_FILE"; then
        echo "mysql"
        return 0
    elif grep -q "^[[:space:]]*mariadb:" "$COMPOSE_FILE"; then
        echo "mariadb"
        return 1
    else
        echo "sqlite"
        return 1
    fi
}
function find_free_port() {
    for port in {3300..3330}; do
        if ! ss -tuln | grep -q ":$port "; then
            echo "$port"
            return 0
        fi
    done
    echo -e "\033[31m[ERROR] No free port found between 3300 and 3330.\033[0m"
    exit 1
}
function fix_update_issues() {
    echo -e "\e[33mTrying to fix update issues by changing mirrors...\033[0m"
    # Broken apt mirrors are often a DNS problem - fix DNS first
    ensure_dns
    cp /etc/apt/sources.list /etc/apt/sources.list.backup
    if [ -f /etc/os-release ]; then
        . /etc/apt/sources.list
        VERSION_ID=$(cat /etc/os-release | grep VERSION_ID | cut -d '"' -f2)
        UBUNTU_CODENAME=$(cat /etc/os-release | grep UBUNTU_CODENAME | cut -d '=' -f2)
    else
        echo -e "\e[91mCould not detect Ubuntu version.\033[0m"
        return 1
    fi
    MIRRORS=(
        "archive.ubuntu.com"
        "us.archive.ubuntu.com"
        "fr.archive.ubuntu.com"
        "de.archive.ubuntu.com"
        "mirrors.digitalocean.com"
        "mirrors.linode.com"
    )
    for mirror in "${MIRRORS[@]}"; do
        echo -e "\e[33mTrying mirror: $mirror\033[0m"
        cat > /etc/apt/sources.list << EOF
deb http://$mirror/ubuntu/ $UBUNTU_CODENAME main restricted universe multiverse
deb http://$mirror/ubuntu/ $UBUNTU_CODENAME-updates main restricted universe multiverse
deb http://$mirror/ubuntu/ $UBUNTU_CODENAME-security main restricted universe multiverse
EOF
        if apt-get update 2>/dev/null; then
            echo -e "\e[32mSuccessfully updated using mirror: $mirror\033[0m"
            return 0
        fi
    done
    mv /etc/apt/sources.list.backup /etc/apt/sources.list
    echo -e "\e[91mAll mirrors failed. Restored original sources.list\033[0m"
    return 1
}

# ─────────────────────────────────────────────────────────────
#  Validation and pre-flight checks
#  (DNS helpers dns_works/ensure_dns are defined near the top)
# ─────────────────────────────────────────────────────────────

# Can we actually reach the internet?
net_works() {
    curl -fsSL --max-time 8 -o /dev/null "https://github.com" 2>/dev/null && return 0
    curl -fsSL --max-time 8 -o /dev/null "https://api.telegram.org" 2>/dev/null && return 0
    return 1
}

# Ensure DNS + connectivity, fixing DNS automatically if needed.
ensure_connectivity() {
    ensure_dns
    net_works && return 0
    echo -e "  ${C_WARN}!${CR} ${C_WARN}No connectivity - resetting DNS and retrying...${CR}"
    ensure_dns
    net_works && return 0
    return 1
}

# ── Input validators ─────────────────────────────────────────
validate_domain() { [[ "$1" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; }

# 0 = points here, 1 = points elsewhere, 2 = could not resolve
domain_points_here() {
    local dom="$1" myip resolved
    myip=$(get_server_ip)
    resolved=$(getent ahostsv4 "$dom" 2>/dev/null | awk '{print $1; exit}')
    [ -z "$resolved" ] && resolved=$(getent hosts "$dom" 2>/dev/null | awk '{print $1; exit}')
    [ -z "$resolved" ] && return 2
    [ "$resolved" = "$myip" ] && return 0
    return 1
}

# 0 = valid+live, 1 = bad format, 2 = format ok but token rejected/unreachable
validate_token() {
    [[ "$1" =~ ^[0-9]{8,10}:[a-zA-Z0-9_-]{35}$ ]] || return 1
    local r; r=$(curl -fsSL --max-time 8 "https://api.telegram.org/bot$1/getMe" 2>/dev/null)
    echo "$r" | grep -q '"ok":true' && return 0
    return 2
}

# Safe identifiers/passwords (no quotes/specials that break SQL or config.php)
valid_db_ident() { [[ "$1" =~ ^[A-Za-z0-9_]{1,32}$ ]]; }
valid_db_pass()  { [[ "$1" =~ ^[A-Za-z0-9_]{6,64}$ ]]; }

# Whole-server pre-flight before installing
preflight() {
    local ok=1
    _sec "Pre-flight checks"

    if command -v apt-get >/dev/null 2>&1; then
        _kv "Package mgr" "$(_dot ok) ${C_OK}apt detected${CR}"
    else
        _kv "Package mgr" "$(_dot bad) ${C_BAD}apt not found (Ubuntu/Debian required)${CR}"; ok=0
    fi

    local arch; arch=$(uname -m)
    case "$arch" in
        x86_64|amd64|aarch64|arm64) _kv "Arch" "$(_dot ok) ${C_OK}${arch}${CR}" ;;
        *) _kv "Arch" "$(_dot warn) ${C_WARN}${arch} (untested)${CR}" ;;
    esac

    local free_mb; free_mb=$(df -Pm / 2>/dev/null | awk 'NR==2{print $4}')
    if [ "${free_mb:-0}" -ge 2048 ]; then
        _kv "Disk free" "$(_dot ok) ${C_OK}${free_mb} MB${CR}"
    else
        _kv "Disk free" "$(_dot bad) ${C_BAD}${free_mb:-0} MB (need >= 2048 MB)${CR}"; ok=0
    fi

    local mem; mem=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}')
    if [ "${mem:-0}" -ge 900 ]; then
        _kv "RAM" "$(_dot ok) ${C_OK}${mem} MB${CR}"
    else
        _kv "RAM" "$(_dot warn) ${C_WARN}${mem:-0} MB (low; MySQL may struggle)${CR}"
    fi

    if ensure_connectivity; then
        _kv "Network" "$(_dot ok) ${C_OK}online${CR}"
    else
        _kv "Network" "$(_dot bad) ${C_BAD}offline (cannot reach GitHub/Telegram)${CR}"; ok=0
    fi

    local b80 b443
    b80=$(ss -ltnH 'sport = :80' 2>/dev/null | head -1)
    b443=$(ss -ltnH 'sport = :443' 2>/dev/null | head -1)
    if [ -n "$b80" ] || [ -n "$b443" ]; then
        _kv "Ports 80/443" "$(_dot warn) ${C_WARN}in use (will be freed for Apache/SSL)${CR}"
    else
        _kv "Ports 80/443" "$(_dot ok) ${C_OK}free${CR}"
    fi

    if [ "$ok" -ne 1 ]; then
        echo ""
        echo -e "  ${C_BAD}●${CR} ${C_BAD}Pre-flight checks failed. Aborting to avoid a broken install.${CR}"
        return 1
    fi
    return 0
}

function install_bot() {
    echo -e "\e[32mInstalling Mirza script ... \033[0m\n"

    # Guard: refuse to install if Mirza is already installed
    if [ -f "$CONFIG_FILE_DEFAULT" ] || [ -d "$BOT_DIR_DEFAULT" ]; then
        clear
        banner
        _sec "Install blocked"
        printf "    ${C_BAD}●${CR} ${C_BAD}Mirza is already installed on this server.${CR}\n"
        printf "    ${C_DIM}Path:${CR} %s\n" "$BOT_DIR_DEFAULT"
        echo ""
        printf "    ${C_DIM}To upgrade, use option ${CR}${C_KEY}2 (Update)${CR}${C_DIM}.${CR}\n"
        printf "    ${C_DIM}To reinstall, first remove it with option ${CR}${C_KEY}3 (Remove)${CR}${C_DIM}.${CR}\n"
        echo ""
        printf "  ${C_PROMPT}❯${CR} Press Enter to return to the menu... "
        read -r _
        show_menu
        return 1
    fi

    if check_marzban_installed; then
        echo -e "\033[41m[IMPORTANT WARNING]\033[0m \033[1;33mMarzban detected. Proceeding with Marzban-compatible installation.\033[0m"
        install_bot_with_marzban "$@"
        return 0
    fi

    # ── Pre-flight checks (network/DNS/disk/ram/ports) ──
    clear
    banner
    if ! preflight; then
        echo ""
        printf "  ${C_PROMPT}❯${CR} Press Enter to return to the menu... "
        read -r _
        show_menu
        return 1
    fi

    # ── Choose which version to install (release / automatic / beta) ──
    echo ""
    choose_source
    local _rc=$?
    if [ "$_rc" -eq 2 ]; then show_menu; return 0; fi
    if [ "$_rc" -ne 0 ]; then sleep 2; show_menu; return 1; fi
    echo ""
    echo -e "  ${C_DIM}Install target:${CR} ${C_KEY}${SRC_LABEL}${CR}"
    sleep 1

    print_header "Installing Dependencies"

    if ! run_step "Adding PHP repository (ondrej/php)" "add-apt-repository -y ppa:ondrej/php"; then
        if ! run_step "Retrying PHP repository with locale override" "LC_ALL=C.UTF-8 add-apt-repository -y ppa:ondrej/php"; then
            show_step_error
            echo -e "\e[91mError: Failed to add PPA ondrej/php. Exiting...\033[0m"
            exit 1
        fi
    fi

    if ! run_step "Updating & upgrading system packages" "apt update && apt upgrade -y"; then
        echo -e "\e[93mUpdate/upgrade failed. Attempting to fix using alternative mirrors...\033[0m"
        if fix_update_issues; then
            if ! run_step "Re-running system update after mirror fix" "apt update && apt upgrade -y"; then
                show_step_error
                echo -e "\e[91mError: Failed to update even after trying alternative mirrors.\033[0m"
                exit 1
            fi
        else
            echo -e "\e[91mError: Failed to update/upgrade packages and mirror fix failed.\033[0m"
            exit 1
        fi
    fi

    run_step "Installing base tools (git, curl, wget, unzip, jq)" \
        "apt-get install -y software-properties-common git unzip curl wget jq" \
        || { show_step_error; echo -e "\e[91mError: Failed to install base tools.\033[0m"; exit 1; }

    run_step "Installing PHP 8.2 (fpm + mysql)" \
        "DEBIAN_FRONTEND=noninteractive apt install -y php8.2 php8.2-fpm php8.2-mysql" \
        || { show_step_error; echo -e "\e[91mError: Failed to install PHP 8.2.\033[0m"; exit 1; }

    run_step "Installing web stack (Apache, MySQL, PHP modules)" \
        "DEBIAN_FRONTEND=noninteractive apt install -y lamp-server^ libapache2-mod-php mysql-server apache2 php-mbstring php-zip php-gd php-json php-curl" \
        || { show_step_error; echo -e "\e[91mError: Failed to install web stack.\033[0m"; exit 1; }

    echo 'phpmyadmin phpmyadmin/dbconfig-install boolean true' | sudo debconf-set-selections
    echo 'phpmyadmin phpmyadmin/app-password-confirm password mirzahipass' | sudo debconf-set-selections
    echo 'phpmyadmin phpmyadmin/mysql/admin-pass password mirzahipass' | sudo debconf-set-selections
    echo 'phpmyadmin phpmyadmin/mysql/app-pass password mirzahipass' | sudo debconf-set-selections
    echo 'phpmyadmin phpmyadmin/reconfigure-webserver multiselect apache2' | sudo debconf-set-selections
    run_step "Installing phpMyAdmin" \
        "DEBIAN_FRONTEND=noninteractive apt-get install -y phpmyadmin" \
        || { show_step_error; echo -e "\e[91mError: Failed to install phpMyAdmin.\033[0m"; exit 1; }

    if [ -f /etc/apache2/conf-available/phpmyadmin.conf ]; then
        sudo rm -f /etc/apache2/conf-available/phpmyadmin.conf
    fi
    sudo ln -s /etc/phpmyadmin/apache.conf /etc/apache2/conf-available/phpmyadmin.conf || {
        echo -e "\e[91mError: Failed to create symbolic link for phpMyAdmin configuration.\033[0m"
        exit 1
    }

    run_step "Installing extra modules (php-soap, php-ssh2, libssh2)" \
        "apt-get install -y php-soap libapache2-mod-php php-ssh2 libssh2-1-dev libssh2-1" \
        || { show_step_error; echo -e "\e[91mError: Failed to install extra PHP modules.\033[0m"; exit 1; }

    run_step "Enabling & starting services (MySQL, Apache)" \
        "systemctl enable mysql.service && systemctl start mysql.service && systemctl enable apache2 && systemctl start apache2" \
        || { show_step_error; echo -e "\e[91mError: Failed to enable/start core services.\033[0m"; exit 1; }

    run_step "Configuring firewall (UFW + Apache)" \
        "apt-get install -y ufw && ufw allow 'Apache'" \
        || { show_step_error; echo -e "\e[91mError: Failed to configure UFW.\033[0m"; exit 1; }
    run_step "Restarting Apache" "systemctl restart apache2" \
        || { show_step_error; echo -e "\e[91mError: Failed to restart Apache2.\033[0m"; exit 1; }

    echo -e "\n\e[92m All dependencies installed successfully.\033[0m"

    print_header "Downloading Bot Files"
    BOT_DIR="/var/www/html/mirzaprobotconfig"
    if [ -d "$BOT_DIR" ]; then
        echo -e "\e[93mDirectory $BOT_DIR already exists. Removing...\033[0m"
        sudo rm -rf "$BOT_DIR" || {
            echo -e "\e[91mError: Failed to remove existing directory $BOT_DIR.\033[0m"
            exit 1
        }
    fi
    sudo mkdir -p "$BOT_DIR"
    if [ ! -d "$BOT_DIR" ]; then
        echo -e "\e[91mError: Failed to create directory $BOT_DIR.\033[0m"
        exit 1
    fi

    ZIP_URL="$SRC_ZIP_URL"
    TEMP_DIR="/tmp/mirzaprobot"
    mkdir -p "$TEMP_DIR"
    run_step "Downloading Mirza (${SRC_LABEL})" "wget -O '$TEMP_DIR/bot.zip' '$ZIP_URL'" \
        || { show_step_error; echo -e "\e[91mError: Failed to download the specified version.\033[0m"; exit 1; }
    run_step "Extracting source files" "unzip -o '$TEMP_DIR/bot.zip' -d '$TEMP_DIR'" \
        || { show_step_error; echo -e "\e[91mError: Failed to extract source files.\033[0m"; exit 1; }

    EXTRACTED_DIR=$(find "$TEMP_DIR" -mindepth 1 -maxdepth 1 -type d)
    mv "$EXTRACTED_DIR"/* "$BOT_DIR" || {
        echo -e "\e[91mError: Failed to move extracted files.\033[0m"
        exit 1
    }
    rm -rf "$TEMP_DIR"
    sudo chown -R www-data:www-data "$BOT_DIR"
    sudo chmod -R 755 "$BOT_DIR"
    echo -e "\n\033[33mMirza config and script have been installed successfully.\033[0m"
    wait
    if [ ! -d "/root/confmirza" ]; then
        sudo mkdir /root/confmirza || {
            echo -e "\e[91mError: Failed to create /root/confmirza directory.\033[0m"
            exit 1
        }
        sleep 1
        touch /root/confmirza/dbrootmirza.txt || {
            echo -e "\e[91mError: Failed to create dbrootmirza.txt.\033[0m"
            exit 1
        }
        sudo chmod -R 777 /root/confmirza/dbrootmirza.txt || {
            echo -e "\e[91mError: Failed to set permissions for dbrootmirza.txt.\033[0m"
            exit 1
        }
        sleep 1
        randomdbpasstxt=$(openssl rand -base64 10 | tr -dc 'a-zA-Z0-9' | cut -c1-8)
        echo "\$user = 'root';" >> /root/confmirza/dbrootmirza.txt
        echo "\$pass = '${randomdbpasstxt}';" >> /root/confmirza/dbrootmirza.txt
        echo "\$path = '${RANDOM_NUMBER}';" >> /root/confmirza/dbrootmirza.txt
        sleep 1
        passs=$(cat /root/confmirza/dbrootmirza.txt | grep '$pass' | cut -d"'" -f2)
        userrr=$(cat /root/confmirza/dbrootmirza.txt | grep '$user' | cut -d"'" -f2)
        sudo mysql -u $userrr -p$passs -e "alter user '$userrr'@'localhost' identified with mysql_native_password by '$passs';FLUSH PRIVILEGES;" || {
            echo -e "\e[91mError: Failed to alter MySQL user. Attempting recovery...\033[0m"
            sudo sed -i '$ a skip-grant-tables' /etc/mysql/mysql.conf.d/mysqld.cnf
            sudo systemctl restart mysql
            sudo mysql <<EOF
DROP USER IF EXISTS 'root'@'localhost';
CREATE USER 'root'@'localhost' IDENTIFIED BY '${passs}';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'localhost' WITH GRANT OPTION;
FLUSH PRIVILEGES;
EOF
            sudo sed -i '/skip-grant-tables/d' /etc/mysql/mysql.conf.d/mysqld.cnf
            sudo systemctl restart mysql
            echo "SELECT 1" | mysql -u$userrr -p$passs 2>/dev/null || {
                echo -e "\e[91mError: Recovery failed. MySQL login still not working.\033[0m"
                exit 1
            }
        }
        echo "Folder created successfully!"
    else
        echo "Folder already exists."
    fi
    clear
    print_header "SSL Certificate Setup"
    if [ -n "$ARG_DOMAIN" ]; then
        domainname="$ARG_DOMAIN"
        echo -e "  ${C_DIM}Domain (from --domain):${CR} ${C_KEY}${domainname}${CR}"
    else
        read -p "Enter the domain: " domainname
    fi
    while ! validate_domain "$domainname"; do
        echo -e "\e[91mInvalid domain. Enter a full domain like bot.example.com (no http://, no slash).\033[0m"
        read -p "Enter the domain: " domainname
    done
    # Verify the domain actually points to this server (certbot needs this)
    domain_points_here "$domainname"
    case $? in
        0) echo -e "  ${C_OK}●${CR} ${C_OK}Domain resolves to this server.${CR}" ;;
        1) echo -e "  ${C_WARN}!${CR} ${C_WARN}Domain does NOT point to this server's IP ($(get_server_ip)).${CR}"
           echo -e "  ${C_DIM}Let's Encrypt will fail until the DNS A record points here.${CR}"
           printf "  ${C_PROMPT}❯${CR} Continue anyway? ${C_DIM}[y/N]${CR}: "
           read -r _gd
           if [[ ! "$_gd" =~ ^[Yy]$ ]]; then echo -e "  ${C_BAD}Aborted. Fix the DNS A record and retry.${CR}"; sleep 1; show_menu; return 1; fi ;;
        2) echo -e "  ${C_WARN}!${CR} ${C_WARN}Could not resolve the domain yet (DNS may still be propagating).${CR}"
           printf "  ${C_PROMPT}❯${CR} Continue anyway? ${C_DIM}[y/N]${CR}: "
           read -r _gd
           if [[ ! "$_gd" =~ ^[Yy]$ ]]; then echo -e "  ${C_BAD}Aborted.${CR}"; sleep 1; show_menu; return 1; fi ;;
    esac
    DOMAIN_NAME="$domainname"
    PATHS=$(cat /root/confmirza/dbrootmirza.txt | grep '$path' | cut -d"'" -f2)

    run_step "Opening firewall ports 80 & 443" "ufw allow 80 && ufw allow 443" \
        || { show_step_error; echo -e "\e[91mError: Failed to open firewall ports.\033[0m"; exit 1; }
    run_step "Stopping Apache for certificate issuance" "systemctl stop apache2 && systemctl disable apache2" \
        || { show_step_error; echo -e "\e[91mError: Failed to stop Apache2.\033[0m"; exit 1; }
    run_step "Installing Let's Encrypt (certbot)" "apt install letsencrypt -y && systemctl enable certbot.timer" \
        || { show_step_error; echo -e "\e[91mError: Failed to install letsencrypt.\033[0m"; exit 1; }

    echo -e "\n\e[36mRequesting SSL certificate from Let's Encrypt (this step is interactive)...\033[0m"
    sudo certbot certonly --standalone --agree-tos --preferred-challenges http -d $DOMAIN_NAME || {
        echo -e "\e[91mError: Failed to generate SSL certificate.\033[0m"
        exit 1
    }
    run_step "Installing Apache certbot plugin" "apt install python3-certbot-apache -y" \
        || { show_step_error; echo -e "\e[91mError: Failed to install python3-certbot-apache.\033[0m"; exit 1; }
    sudo certbot --apache --agree-tos --preferred-challenges http -d $DOMAIN_NAME || {
        echo -e "\e[91mError: Failed to configure SSL with Certbot.\033[0m"
        exit 1
    }
    run_step "Enabling & starting Apache" "systemctl enable apache2 && systemctl start apache2" \
        || { show_step_error; echo -e "\e[91mError: Failed to start Apache2.\033[0m"; exit 1; }

    VHOST_FILE="/etc/apache2/sites-available/${DOMAIN_NAME}.conf"
    sudo tee "$VHOST_FILE" > /dev/null <<EOF
<VirtualHost *:80>
    ServerName $DOMAIN_NAME
    DocumentRoot $BOT_DIR
    <Directory $BOT_DIR>
        Options Indexes FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
    Include /etc/apache2/conf-available/phpmyadmin.conf
    ErrorLog \${APACHE_LOG_DIR}/${DOMAIN_NAME}-error.log
    CustomLog \${APACHE_LOG_DIR}/${DOMAIN_NAME}-access.log combined
</VirtualHost>
EOF
    VHOST_SSL_FILE="/etc/apache2/sites-available/${DOMAIN_NAME}-ssl.conf"
    sudo tee "$VHOST_SSL_FILE" > /dev/null <<EOF
<VirtualHost *:443>
    ServerName $DOMAIN_NAME
    DocumentRoot $BOT_DIR
    SSLEngine on
    SSLCertificateFile /etc/letsencrypt/live/$DOMAIN_NAME/fullchain.pem
    SSLCertificateKeyFile /etc/letsencrypt/live/$DOMAIN_NAME/privkey.pem
    <Directory $BOT_DIR>
        Options Indexes FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
    Include /etc/apache2/conf-available/phpmyadmin.conf
    ErrorLog \${APACHE_LOG_DIR}/${DOMAIN_NAME}-error.log
    CustomLog \${APACHE_LOG_DIR}/${DOMAIN_NAME}-access.log combined
</VirtualHost>
EOF
    run_step "Configuring Apache virtual hosts" \
        "a2ensite '${DOMAIN_NAME}.conf' && a2ensite '${DOMAIN_NAME}-ssl.conf' ; a2dissite 000-default.conf 2>/dev/null ; a2dissite 000-default-le-ssl.conf 2>/dev/null ; a2dissite default-ssl.conf 2>/dev/null ; rm -f /etc/apache2/sites-enabled/000-default.conf /etc/apache2/sites-enabled/000-default-le-ssl.conf /etc/apache2/sites-enabled/default-ssl.conf ; rm -f /etc/apache2/sites-available/000-default.conf /etc/apache2/sites-available/000-default-le-ssl.conf /etc/apache2/sites-available/default-ssl.conf ; a2enmod ssl && systemctl restart apache2" \
        || { show_step_error; echo -e "\e[91mError: Failed to configure Apache virtual hosts.\033[0m"; exit 1; }

    clear
    print_header "Bot Configuration"
    if [ -n "$ARG_TOKEN" ]; then
        YOUR_BOT_TOKEN="$ARG_TOKEN"
        echo -e "\e[33m[+] \e[36mBot Token (from --token):\e[0m ${YOUR_BOT_TOKEN:0:10}..."
    else
        printf "\e[33m[+] \e[36mBot Token: \033[0m"
        read YOUR_BOT_TOKEN
    fi
    while [[ ! "$YOUR_BOT_TOKEN" =~ ^[0-9]{8,10}:[a-zA-Z0-9_-]{35}$ ]]; do
        echo -e "\e[91mInvalid bot token format. Please try again.\033[0m"
        printf "\e[33m[+] \e[36mBot Token: \033[0m"
        read YOUR_BOT_TOKEN
    done
    # Live-verify the token with Telegram (getMe)
    while true; do
        validate_token "$YOUR_BOT_TOKEN"
        case $? in
            0) echo -e "  ${C_OK}●${CR} ${C_OK}Token verified with Telegram.${CR}"; break ;;
            2) echo -e "  ${C_BAD}●${CR} ${C_BAD}Telegram rejected this token (or API unreachable).${CR}"
               printf "  ${C_PROMPT}❯${CR} Re-enter token, or press Enter to keep it anyway: "
               read -r _t
               if [ -z "$_t" ]; then break; fi
               YOUR_BOT_TOKEN="$_t"
               while [[ ! "$YOUR_BOT_TOKEN" =~ ^[0-9]{8,10}:[a-zA-Z0-9_-]{35}$ ]]; do
                   echo -e "\e[91mInvalid format.\033[0m"; printf "  ${C_PROMPT}❯${CR} Bot Token: "; read -r YOUR_BOT_TOKEN
               done ;;
            *) break ;;
        esac
    done
    if [ -n "$ARG_ADMIN" ]; then
        YOUR_CHAT_ID="$ARG_ADMIN"
        echo -e "\e[33m[+] \e[36mChat id (from --admin):\e[0m ${YOUR_CHAT_ID}"
    else
        printf "\e[33m[+] \e[36mChat id: \033[0m"
        read YOUR_CHAT_ID
    fi
    while [[ ! "$YOUR_CHAT_ID" =~ ^-?[0-9]+$ ]]; do
        echo -e "\e[91mInvalid chat ID format. Please try again.\033[0m"
        printf "\e[33m[+] \e[36mChat id: \033[0m"
        read YOUR_CHAT_ID
    done
    YOUR_DOMAIN="$DOMAIN_NAME"
    if [ -n "$ARG_NAME" ]; then
        YOUR_BOTNAME="$ARG_NAME"
        echo -e "\e[33m[+] \e[36musernamebot (from --name):\e[0m ${YOUR_BOTNAME}"
    else
        while true; do
            printf "\e[33m[+] \e[36musernamebot: \033[0m"
            read YOUR_BOTNAME
            if [ "$YOUR_BOTNAME" != "" ]; then
                break
            else
                echo -e "\e[91mError: Bot username cannot be empty. Please enter a valid username.\033[0m"
            fi
        done
    fi
    ROOT_PASSWORD=$(cat /root/confmirza/dbrootmirza.txt | grep '$pass' | cut -d"'" -f2)
    ROOT_USER="root"
    echo "SELECT 1" | mysql -u$ROOT_USER -p$ROOT_PASSWORD 2>/dev/null || {
        echo -e "\e[91mError: MySQL connection failed.\033[0m"
        exit 1
    }
    if [ $? -eq 0 ]; then
        wait
        randomdbpass=$(openssl rand -base64 10 | tr -dc 'a-zA-Z0-9' | cut -c1-8)
        randomdbdb=$(openssl rand -base64 10 | tr -dc 'a-zA-Z' | cut -c1-8)
        if [[ $(mysql -u root -p$ROOT_PASSWORD -e "SHOW DATABASES LIKE 'mirzaprobot'") ]]; then
            clear
            echo -e "\n\e[91mYou have already created the database\033[0m\n"
        else
            dbname=mirzaprobot
            clear
            if [ -n "$ARG_DBUSER" ]; then
                dbuser="$ARG_DBUSER"
                echo -e "\e[32mDatabase username (from --db-user):\e[0m ${dbuser}"
            else
                echo -e "\n\e[32mPlease enter the database username!\033[0m"
                printf "[+] Default user name is \e[91m${randomdbdb}\e[0m ( let it blank to use this user name ): "
                read dbuser
            fi
            if [ "$dbuser" = "" ]; then
                dbuser=$randomdbdb
            fi
            # Validate DB username charset (letters/digits/underscore)
            if ! valid_db_ident "$dbuser"; then
                echo -e "  ${C_WARN}!${CR} ${C_WARN}Invalid DB username (use only A-Z a-z 0-9 _). Using generated name.${CR}"
                dbuser=$randomdbdb
            fi
            if [ -n "$ARG_DBPASS" ]; then
                dbpass="$ARG_DBPASS"
                echo -e "\e[32mDatabase password (from --db-pass): [hidden]\033[0m"
            else
                echo -e "\n\e[32mPlease enter the database password!\033[0m"
                printf "[+] Default password is \e[91m${randomdbpass}\e[0m ( let it blank to use this password ): "
                read dbpass
            fi
            if [ "$dbpass" = "" ]; then
                dbpass=$randomdbpass
            fi
            # Validate DB password charset (avoid quotes/specials that break SQL & config.php)
            if ! valid_db_pass "$dbpass"; then
                echo -e "  ${C_WARN}!${CR} ${C_WARN}Password has unsafe characters or is too short (need 6+, A-Z a-z 0-9 _). Using generated password.${CR}"
                dbpass=$randomdbpass
            fi
            mysql -u root -p$ROOT_PASSWORD -e "CREATE DATABASE IF NOT EXISTS $dbname;"
            mysql -u root -p$ROOT_PASSWORD -e "CREATE USER IF NOT EXISTS '$dbuser'@'%' IDENTIFIED WITH mysql_native_password BY '$dbpass'; GRANT ALL PRIVILEGES ON $dbname.* TO '$dbuser'@'%'; FLUSH PRIVILEGES;"
            mysql -u root -p$ROOT_PASSWORD -e "CREATE USER IF NOT EXISTS '$dbuser'@'localhost' IDENTIFIED WITH mysql_native_password BY '$dbpass'; GRANT ALL PRIVILEGES ON $dbname.* TO '$dbuser'@'localhost'; FLUSH PRIVILEGES;" || {
                echo -e "\e[91mError: Failed to create database or user.\033[0m"
                exit 1
            }
            echo -e "\n\e[95mDatabase Created.\033[0m"
            clear
            ASAS="$"
            wait
            sleep 1
            file_path="/var/www/html/mirzaprobotconfig/config.php"
            if [ -f "$file_path" ]; then
              rm "$file_path" || {
                echo -e "\e[91mError: Failed to delete old config.php.\033[0m"
                exit 1
              }
              echo -e "File deleted successfully."
            else
              echo -e "File not found."
            fi
            sleep 1
            secrettoken=$(openssl rand -base64 10 | tr -dc 'a-zA-Z0-9' | cut -c1-8)
            cat <<EOF > /var/www/html/mirzaprobotconfig/config.php
<?php
// This variable added for high load panels which their response time is long and bot can't communicate with online panel!
// null for default settings
\$request_exec_timeout = null;
\$dbhost = 'localhost';
\$dbname = '$dbname';
\$usernamedb = '$dbuser';
\$passworddb = '$dbpass';
\$connect = mysqli_connect(\$dbhost, \$usernamedb, \$passworddb, \$dbname);
if (\$connect->connect_error) { die("error" . \$connect->connect_error); }
mysqli_set_charset(\$connect, "utf8mb4");
\$options = [ PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION, PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC, PDO::ATTR_EMULATE_PREPARES => false, ];
\$dsn = "mysql:host=\$dbhost;dbname=\$dbname;charset=utf8mb4";
try { \$pdo = new PDO(\$dsn, \$usernamedb, \$passworddb, \$options); } catch (\PDOException \$e) { error_log("Database connection failed: " . \$e->getMessage()); }
\$APIKEY = '${YOUR_BOT_TOKEN}';
\$adminnumber = '${YOUR_CHAT_ID}';
\$domainhosts = '${YOUR_DOMAIN}';
\$usernamebot = '${YOUR_BOTNAME}';
?>
EOF
            sleep 1
            run_step "Setting Telegram webhook" \
                "curl -s -F \"url=https://${YOUR_DOMAIN}/index.php\" -F \"secret_token=${secrettoken}\" \"https://api.telegram.org/bot${YOUR_BOT_TOKEN}/setWebhook\"" \
                || { show_step_error; echo -e "\e[91mError: Failed to set webhook for bot.\033[0m"; exit 1; }

            MESSAGE="✅ The Mirza bot is installed! for start the bot send /start command."
            curl -s -X POST "https://api.telegram.org/bot${YOUR_BOT_TOKEN}/sendMessage" -d chat_id="${YOUR_CHAT_ID}" -d text="$MESSAGE" > /dev/null 2>&1 || {
                echo -e "\e[91mError: Failed to send message to Telegram.\033[0m"
                exit 1
            }
            sleep 3
            run_step "Starting Apache" "systemctl start apache2" \
                || { show_step_error; echo -e "\e[91mError: Failed to start Apache2.\033[0m"; exit 1; }
            sleep 5
            url="https://${YOUR_DOMAIN}/table.php"
            run_step "Initializing database tables" "curl -k --max-time 15 '$url' > /dev/null 2>&1" \
                || echo -e "\e[93mWarning: Could not reach URL immediately, but installation may still be successful.\033[0m"
            clear
            banner
            _sec "Installation complete"
            printf "    ${C_OK}●${CR} ${C_OK}Mirza is installed and the webhook is set.${CR}\n"
            printf "    ${C_DIM}Open Telegram and send ${CR}${C_KEY}/start${CR}${C_DIM} to your bot.${CR}\n"

            _sec "Access"
            _kv "Bot URL" "${C_DIM}https://${YOUR_DOMAIN}${CR}"
            _kv "phpMyAdmin" "${C_DIM}https://${YOUR_DOMAIN}/phpmyadmin${CR}"

            _sec "Database"
            _kv "Name" "${C_KEY}${dbname}${CR}"
            _kv "Username" "${C_KEY}${dbuser}${CR}"
            _kv "Password" "${C_KEY}${dbpass}${CR}"
            printf "    ${C_WARN}!${CR} ${C_DIM}Save these credentials somewhere safe.${CR}\n"

            _sec "Manage"
            _kv "Command" "${C_DIM}run ${CR}${C_KEY}mirza${CR}${C_DIM} anytime to open this panel${CR}"
            echo ""
            _rule
            echo ""
        fi
    elif [ "$ROOT_PASSWORD" = "" ] || [ "$ROOT_USER" = "" ]; then
        echo -e "\n\e[36mThe password is empty.\033[0m\n"
    else
        echo -e "\n\e[36mThe password is not correct.\033[0m\n"
    fi
    chmod +x /root/install.sh
    ln -sf /root/install.sh /usr/local/bin/mirza
    self_update_script
}
function update_bot() {
    clear
    banner
    BOT_DIR="/var/www/html/mirzaprobotconfig"
    if [ ! -d "$BOT_DIR" ]; then
        _sec "Update"
        printf "    ${C_BAD}●${CR} ${C_BAD}Mirza is not installed. Install it first.${CR}\n"
        sleep 2
        show_menu
        return 1
    fi

    # ── Show current version + choose source (has Back option) ──
    local current
    current=$(get_installed_version); [ -z "$current" ] && current="unknown"
    _sec "Update"
    printf "    ${C_DIM}Currently installed:${CR} ${C_OK}%s${CR}\n" "$current"
    if ! ensure_connectivity; then
        printf "    ${C_BAD}●${CR} ${C_BAD}No internet connection (even after DNS reset). Try again later.${CR}\n"
        sleep 2; show_menu; return 1
    fi
    choose_source
    local _rc=$?
    if [ "$_rc" -eq 2 ]; then show_menu; return 0; fi
    if [ "$_rc" -ne 0 ]; then sleep 2; show_menu; return 1; fi
    local ZIP_URL="$SRC_ZIP_URL" TARGET_LABEL="$SRC_LABEL"

    echo ""
    echo -e "  ${C_DIM}Update target:${CR} ${C_KEY}${TARGET_LABEL}${CR}"
    print_header "Updating Mirza Bot"
    run_step "Updating system packages" "apt update && apt upgrade -y" \
        || { show_step_error; echo -e "\e[91mError updating the server. Exiting...\033[0m"; exit 1; }
    echo -e "\e[92mServer packages updated successfully...\033[0m\n"
    TEMP_DIR="/tmp/mirzaprobot_update"
    rm -rf "$TEMP_DIR"; mkdir -p "$TEMP_DIR"
    run_step "Downloading ${TARGET_LABEL}" "wget -q -O '$TEMP_DIR/bot.zip' '$ZIP_URL'" \
        || { show_step_error; echo -e "\e[91mError: Failed to download update package.\033[0m"; exit 1; }
    run_step "Extracting update package" "unzip -o -q '$TEMP_DIR/bot.zip' -d '$TEMP_DIR'" \
        || { show_step_error; echo -e "\e[91mError: Failed to extract update package.\033[0m"; exit 1; }
    EXTRACTED_DIR=$(find "$TEMP_DIR" -mindepth 1 -maxdepth 1 -type d)
    CONFIG_PATH="$BOT_DIR/config.php"
    TEMP_CONFIG="/root/mirzapro_config_backup.php"
    if [ -f "$CONFIG_PATH" ]; then
        cp "$CONFIG_PATH" "$TEMP_CONFIG" || {
            echo -e "\e[91mConfig file backup failed!\033[0m"
            exit 1
        }
    else
        echo -e "\e[93mWarning: config.php not found. Proceeding without backup.\033[0m"
    fi
    sudo rm -rf "$BOT_DIR" || {
        echo -e "\e[91mFailed to remove old bot files!\033[0m"
        exit 1
    }
    sudo mkdir -p "$BOT_DIR"
    sudo mv "$EXTRACTED_DIR"/* "$BOT_DIR/" || {
        echo -e "\e[91mFile transfer failed!\033[0m"
        exit 1
    }
    if [ -f "$TEMP_CONFIG" ]; then
        sudo mv "$TEMP_CONFIG" "$CONFIG_PATH" || {
            echo -e "\e[91mConfig file restore failed!\033[0m"
            exit 1
        }
    fi
    if [ -f "$BOT_DIR/install.sh" ]; then
        sudo cp "$BOT_DIR/install.sh" /root/install.sh
        echo -e "\n\e[92mCopied latest install.sh to /root/install.sh.\033[0m"
    else
        echo -e "\n\e[91mWarning: install.sh not found in update files.\033[0m"
    fi
    sudo chown -R www-data:www-data "$BOT_DIR"
    sudo chmod -R 755 "$BOT_DIR"
    DOMAIN_NAME=""
    if [ -f "$CONFIG_PATH" ]; then
        DOMAIN_NAME=$(grep "^\$domainhosts" "$CONFIG_PATH" | cut -d"'" -f2 | cut -d'/' -f1)
    fi
    if [ -n "$DOMAIN_NAME" ]; then
        echo -e "\e[33mUpdating Apache VirtualHost configuration for domain: $DOMAIN_NAME\033[0m"
        VHOST_FILE="/etc/apache2/sites-available/${DOMAIN_NAME}.conf"
        sudo tee "$VHOST_FILE" > /dev/null <<EOF
<VirtualHost *:80>
    ServerName $DOMAIN_NAME
    DocumentRoot $BOT_DIR
    <Directory $BOT_DIR>
        Options Indexes FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
    Include /etc/apache2/conf-available/phpmyadmin.conf
    ErrorLog \${APACHE_LOG_DIR}/${DOMAIN_NAME}-error.log
    CustomLog \${APACHE_LOG_DIR}/${DOMAIN_NAME}-access.log combined
</VirtualHost>
EOF
        VHOST_SSL_FILE="/etc/apache2/sites-available/${DOMAIN_NAME}-ssl.conf"
        sudo tee "$VHOST_SSL_FILE" > /dev/null <<EOF
<VirtualHost *:443>
    ServerName $DOMAIN_NAME
    DocumentRoot $BOT_DIR
    SSLEngine on
    SSLCertificateFile /etc/letsencrypt/live/$DOMAIN_NAME/fullchain.pem
    SSLCertificateKeyFile /etc/letsencrypt/live/$DOMAIN_NAME/privkey.pem
    <Directory $BOT_DIR>
        Options Indexes FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
    Include /etc/apache2/conf-available/phpmyadmin.conf
    ErrorLog \${APACHE_LOG_DIR}/${DOMAIN_NAME}-error.log
    CustomLog \${APACHE_LOG_DIR}/${DOMAIN_NAME}-access.log combined
</VirtualHost>
EOF
        if ! sudo apache2ctl -S 2>/dev/null | grep -q "$DOMAIN_NAME"; then
            sudo a2ensite "${DOMAIN_NAME}.conf" 2>/dev/null || true
            sudo a2ensite "${DOMAIN_NAME}-ssl.conf" 2>/dev/null || true
            echo -e "\e[33mCleaning up conflicting default Apache sites...\033[0m"
            sudo a2dissite 000-default.conf 2>/dev/null || true
            sudo a2dissite 000-default-le-ssl.conf 2>/dev/null || true
            sudo a2dissite default-ssl.conf 2>/dev/null || true
            sudo rm -f /etc/apache2/sites-enabled/000-default* 2>/dev/null || true
            sudo rm -f /etc/apache2/sites-enabled/default-ssl* 2>/dev/null || true
            sudo rm -f /etc/apache2/sites-available/000-default.conf 2>/dev/null || true
            sudo rm -f /etc/apache2/sites-available/000-default-le-ssl.conf 2>/dev/null || true
            sleep 3
            sudo a2enmod ssl 2>/dev/null || true
        fi
        if sudo apache2ctl configtest 2>/dev/null | grep -q "Syntax OK"; then
            sudo systemctl restart apache2 || {
                echo -e "\e[91mWarning: Failed to restart Apache2 after updating VirtualHost.\033[0m"
            }
            echo -e "\e[92mVirtualHost configuration updated and Apache restarted.\033[0m"
        else
            echo -e "\e[93mWarning: Apache configuration test failed. Skipping restart.\033[0m"
        fi
    fi
    if [ -f "$CONFIG_PATH" ]; then
        URL_PATH=$(grep "^\$domainhosts" "$CONFIG_PATH" | cut -d"'" -f2)
        if [ -n "$URL_PATH" ]; then
            run_step "Updating database tables" "curl -s 'https://$URL_PATH/table.php' > /dev/null" \
                || echo -e "\e[91mSetup script execution failed! Check logs.\033[0m"
        fi
    fi
    rm -rf "$TEMP_DIR"
    echo -e "\n\e[92mMirza Bot updated to latest version successfully!\033[0m"
    if [ -f "/root/install.sh" ]; then
        sudo chmod +x /root/install.sh
        sudo ln -sf /root/install.sh /usr/local/bin/mirza
        echo -e "\e[92mEnsured /root/install.sh is executable and 'mirza' command is linked.\033[0m"
    else
        echo -e "\e[91mError: /root/install.sh not found after update attempt.\033[0m"
    fi
}
function remove_bot() {
    echo -e "\e[33mStarting Mirza Bot removal process...\033[0m"
    LOG_FILE="/var/log/remove_bot.log"
    echo "Log file: $LOG_FILE" > "$LOG_FILE"
    BOT_DIR="/var/www/html/mirzaprobotconfig"
    if [ ! -d "$BOT_DIR" ]; then
        echo -e "\e[31m[ERROR]\033[0m Mirza Bot is not installed (/var/www/html/mirzaprobotconfig not found)." | tee -a "$LOG_FILE"
        echo -e "\e[33mNothing to remove. Exiting...\033[0m" | tee -a "$LOG_FILE"
        sleep 2
        exit 1
    fi
    read -p "Are you sure you want to remove Mirza Bot and its dependencies? (y/n): " choice
    if [[ "$choice" != "y" ]]; then
        echo "Aborting..." | tee -a "$LOG_FILE"
        exit 0
    fi
    if check_marzban_installed; then
        echo -e "\e[41m[IMPORTANT NOTICE]\033[0m \e[33mMarzban detected. Proceeding with Marzban-compatible removal.\033[0m" | tee -a "$LOG_FILE"
        remove_bot_with_marzban
        return 0
    fi
    echo "Removing Mirza Bot..." | tee -a "$LOG_FILE"
    CONFIG_PATH="/var/www/html/mirzaprobotconfig/config.php"
    if [ -f "$CONFIG_PATH" ]; then
        sudo shred -u -n 5 "$CONFIG_PATH" && echo -e "\e[92mConfig file securely removed: $CONFIG_PATH\033[0m" | tee -a "$LOG_FILE" || {
            echo -e "\e[91mFailed to securely remove config file: $CONFIG_PATH\033[0m" | tee -a "$LOG_FILE"
        }
    fi
    if [ -d "$BOT_DIR" ]; then
        sudo rm -rf "$BOT_DIR" && echo -e "\e[92mBot directory removed: $BOT_DIR\033[0m" | tee -a "$LOG_FILE" || {
            echo -e "\e[91mFailed to remove bot directory: $BOT_DIR. Exiting...\033[0m" | tee -a "$LOG_FILE"
            exit 1
        }
    fi
    echo -e "\e[33mRemoving MySQL and database...\033[0m" | tee -a "$LOG_FILE"
    sudo systemctl stop mysql
    sudo systemctl disable mysql
    sudo systemctl daemon-reload
    sudo apt --fix-broken install -y
    sudo apt-get purge -y mysql-server mysql-client mysql-common mysql-server-core-* mysql-client-core-*
    sudo rm -rf /etc/mysql /var/lib/mysql /var/log/mysql /var/log/mysql.* /usr/lib/mysql /usr/include/mysql /usr/share/mysql
    sudo rm /lib/systemd/system/mysql.service
    sudo rm /etc/init.d/mysql
    sudo dpkg --remove --force-remove-reinstreq mysql-server mysql-server-8.0
    sudo find /etc/systemd /lib/systemd /usr/lib/systemd -name "*mysql*" -exec rm -f {} \;
    sudo apt-get purge -y mysql-server mysql-server-8.0 mysql-client mysql-client-8.0
    sudo apt-get purge -y mysql-client-core-8.0 mysql-server-core-8.0 mysql-common php-mysql php8.2-mysql php8.3-mysql php-mariadb-mysql-kbs
    sudo apt-get autoremove --purge -y
    sudo apt-get clean
    sudo apt-get update
    echo -e "\e[92mMySQL has been completely removed.\033[0m" | tee -a "$LOG_FILE"
    echo -e "\e[33mRemoving PHPMyAdmin...\033[0m" | tee -a "$LOG_FILE"
    if dpkg -s phpmyadmin &>/dev/null; then
        sudo apt-get purge -y phpmyadmin && echo -e "\e[92mPHPMyAdmin removed.\033[0m" | tee -a "$LOG_FILE"
        sudo apt-get autoremove -y && sudo apt-get autoclean -y
    else
        echo -e "\e[93mPHPMyAdmin is not installed.\033[0m" | tee -a "$LOG_FILE"
    fi
    echo -e "\e[33mRemoving Apache...\033[0m" | tee -a "$LOG_FILE"
    sudo systemctl stop apache2 || {
        echo -e "\e[91mFailed to stop Apache. Continuing anyway...\033[0m" | tee -a "$LOG_FILE"
    }
    sudo systemctl disable apache2 || {
        echo -e "\e[91mFailed to disable Apache. Continuing anyway...\033[0m" | tee -a "$LOG_FILE"
    }
    sudo apt-get purge -y apache2 apache2-utils apache2-bin apache2-data libapache2-mod-php* || {
        echo -e "\e[91mFailed to purge Apache packages.\033[0m" | tee -a "$LOG_FILE"
    }
    sudo apt-get autoremove --purge -y
    sudo apt-get autoclean -y
    sudo rm -rf /etc/apache2 /var/www/html
    echo -e "\e[33mRemoving Apache and PHP configurations...\033[0m" | tee -a "$LOG_FILE"
    sudo a2disconf phpmyadmin.conf &>/dev/null
    sudo rm -f /etc/apache2/conf-available/phpmyadmin.conf
    sudo systemctl restart apache2
    echo -e "\e[33mRemoving additional packages...\033[0m" | tee -a "$LOG_FILE"
    sudo apt-get remove -y php-soap php-ssh2 libssh2-1-dev libssh2-1 \
        && echo -e "\e[92mRemoved additional PHP packages.\033[0m" | tee -a "$LOG_FILE" || echo -e "\e[93mSome additional PHP packages may not be installed.\033[0m" | tee -a "$LOG_FILE"
    echo -e "\e[33mResetting firewall rules (except SSL)...\033[0m" | tee -a "$LOG_FILE"
    sudo ufw delete allow 'Apache'
    sudo ufw reload
    echo -e "\e[92mMirza Bot, MySQL, and their dependencies have been completely removed.\033[0m" | tee -a "$LOG_FILE"
}

function migrate_to_pro() {
    clear
    echo -e "\033[1;33mStarting Migration from Free to Pro Version...\033[0m"
    if ! ensure_connectivity; then
        echo -e "  ${C_BAD}●${CR} ${C_BAD}No internet connection (even after DNS reset). Aborting.${CR}"
        sleep 2; show_menu; return 1
    fi
    OLD_BOT_DIR="/var/www/html/mirzabotconfig"
    if [ ! -d "$OLD_BOT_DIR" ]; then
        echo -e "\033[31m[ERROR] Free version source code not found in $OLD_BOT_DIR.\033[0m"
        echo -e "\033[33mMake sure the free version is installed.\033[0m"
        exit 1
    fi
    if ! systemctl is-active --quiet mysql; then
        echo -e "\033[31m[ERROR] MySQL service is not active or not installed.\033[0m"
        echo -e "\033[33mPlease ensure MySQL is running locally.\033[0m"
        exit 1
    else
        echo -e "\033[32mMySQL is running.\033[0m"
    fi
    echo ""
    read -p "Are you sure you want to migrate to the Pro version? (y/n): " confirm_mig
    if [[ "$confirm_mig" != "y" && "$confirm_mig" != "Y" ]]; then
        echo -e "\033[31mMigration aborted.\033[0m"
        exit 0
    fi
    echo ""
    read -p "Have you created a backup of your database? (y/n): " confirm_backup
    if [[ "$confirm_backup" != "y" && "$confirm_backup" != "Y" ]]; then
        echo -e "\033[31mPlease create a backup first!\033[0m"
        exit 1
    fi
    BACKUP_FILE="/root/mirzabot_backup.sql"
    if [ ! -f "$BACKUP_FILE" ]; then
        echo -e "\033[31m[ERROR] Backup file not found at $BACKUP_FILE\033[0m"
        echo -e "\033[33mPlease run the 'mirza' command (Free Version Script) and use option 4 to create a backup.\033[0m"
        exit 1
    else
        echo -e "\033[32mBackup file found.\033[0m"
    fi
    echo ""
    echo -e "\033[43;30m[WARNING] Additional Bots Notice\033[0m"
    echo -e "\033[33mThis migration process will reconfigure Apache for the Pro version.\033[0m"
    echo -e "\033[33mOnly the main bot (mirzabotconfig) will be migrated.\033[0m"
    echo -e "\033[33mExisting Additional Bots in /var/www/html/ might stop working.\033[0m"
    echo -e "\033[36mFound directories:\033[0m"
    ls -d /var/www/html/*/ 2>/dev/null | grep -v "mirzabotconfig"
    echo ""
    read -p "Do you understand and want to proceed? (y/n): " confirm_add
    if [[ "$confirm_add" != "y" && "$confirm_add" != "Y" ]]; then
        echo -e "\033[31mMigration aborted.\033[0m"
        exit 0
    fi
    echo -e "\n\033[36mChecking Database Credentials...\033[0m"
    ROOT_CRED_FILE="/root/confmirza/dbrootmirza.txt"
    ROOT_PASS=""
    ROOT_USER="root"
    if [ -f "$ROOT_CRED_FILE" ]; then
        ROOT_PASS=$(grep '$pass' "$ROOT_CRED_FILE" | cut -d"'" -f2)
    fi
    if [ -z "$ROOT_PASS" ]; then
        echo -e "\033[33mRoot password not found in config file.\033[0m"
        read -s -p "Please enter MySQL root password: " ROOT_PASS
        echo ""
    fi
    if ! mysql -u "$ROOT_USER" -p"$ROOT_PASS" -e "SELECT 1;" &>/dev/null; then
        echo -e "\033[31m[ERROR] Incorrect MySQL root password. Migration stopped.\033[0m"
        exit 1
    fi
    echo -e "\033[32mDatabase connection successful.\033[0m"
    OLD_DB="mirzabot"
    NEW_DB="mirzaprobot"
    if ! mysql -u "$ROOT_USER" -p"$ROOT_PASS" -e "USE $OLD_DB;" &>/dev/null; then
        echo -e "\033[31m[ERROR] Database '$OLD_DB' not found!\033[0m"
        exit 1
    fi
    echo -e "\033[33mCleaning up old tables (setting, admin, channels)...\033[0m"
    mysql -u "$ROOT_USER" -p"$ROOT_PASS" "$OLD_DB" -e "DROP TABLE IF EXISTS setting, admin, channels;"
    echo -e "\033[33mUpdating panel status...\033[0m"
    if mysql -u "$ROOT_USER" -p"$ROOT_PASS" "$OLD_DB" -e "DESCRIBE marzban_panel;" &>/dev/null; then
         mysql -u "$ROOT_USER" -p"$ROOT_PASS" "$OLD_DB" -e "UPDATE marzban_panel SET status = 'active';"
    fi
    echo -e "\033[33mMigrating Database from $OLD_DB to $NEW_DB...\033[0m"
    mysql -u "$ROOT_USER" -p"$ROOT_PASS" -e "CREATE DATABASE IF NOT EXISTS $NEW_DB;"
    TABLES=$(mysql -u "$ROOT_USER" -p"$ROOT_PASS" -N -e "SHOW TABLES FROM $OLD_DB")
    for t in $TABLES; do
        mysql -u "$ROOT_USER" -p"$ROOT_PASS" -e "RENAME TABLE $OLD_DB.$t TO $NEW_DB.$t"
    done
    mysql -u "$ROOT_USER" -p"$ROOT_PASS" -e "DROP DATABASE IF EXISTS $OLD_DB;"
    echo -e "\033[32mDatabase migrated successfully.\033[0m"
    OLD_CONFIG="/var/www/html/mirzabotconfig/config.php"
    OLD_DB_USER=$(grep '$usernamedb' "$OLD_CONFIG" | cut -d"'" -f2)
    if [ -n "$OLD_DB_USER" ]; then
        echo -e "\033[33mRemoving old database user ($OLD_DB_USER)...\033[0m"
        mysql -u "$ROOT_USER" -p"$ROOT_PASS" -e "DROP USER IF EXISTS '$OLD_DB_USER'@'localhost';"
        mysql -u "$ROOT_USER" -p"$ROOT_PASS" -e "DROP USER IF EXISTS '$OLD_DB_USER'@'%';"
    fi
    NEW_DB_USER=$(openssl rand -base64 10 | tr -dc 'a-zA-Z' | cut -c1-8)
    NEW_DB_PASS=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | cut -c1-10)
    echo -e "\033[33mCreating new database user...\033[0m"
    mysql -u "$ROOT_USER" -p"$ROOT_PASS" -e "CREATE USER '$NEW_DB_USER'@'localhost' IDENTIFIED WITH mysql_native_password BY '$NEW_DB_PASS';"
    mysql -u "$ROOT_USER" -p"$ROOT_PASS" -e "GRANT ALL PRIVILEGES ON $NEW_DB.* TO '$NEW_DB_USER'@'localhost';"
    mysql -u "$ROOT_USER" -p"$ROOT_PASS" -e "CREATE USER '$NEW_DB_USER'@'%' IDENTIFIED WITH mysql_native_password BY '$NEW_DB_PASS';"
    mysql -u "$ROOT_USER" -p"$ROOT_PASS" -e "GRANT ALL PRIVILEGES ON $NEW_DB.* TO '$NEW_DB_USER'@'%';"
    mysql -u "$ROOT_USER" -p"$ROOT_PASS" -e "FLUSH PRIVILEGES;"
    echo -e "\033[33mReading old configuration...\033[0m"
    OLD_API_KEY=$(grep '$APIKEY' "$OLD_CONFIG" | cut -d"'" -f2)
    OLD_ADMIN_ID=$(grep '$adminnumber' "$OLD_CONFIG" | cut -d"'" -f2)
    OLD_BOT_NAME=$(grep '$usernamebot' "$OLD_CONFIG" | cut -d"'" -f2)
    OLD_DOMAIN_FULL=$(grep '$domainhosts' "$OLD_CONFIG" | cut -d"'" -f2)
    DOMAIN_NAME=$(echo "$OLD_DOMAIN_FULL" | cut -d'/' -f1)
    echo -e "\033[32mDomain detected: $DOMAIN_NAME\033[0m"
    NEW_BOT_DIR="/var/www/html/mirzaprobotconfig"
    rm -rf "$OLD_BOT_DIR"
    mkdir -p "$NEW_BOT_DIR"
    ZIP_URL="https://github.com/mahdiMGF2/mirza_pro/archive/refs/heads/main.zip"
    TEMP_DIR="/tmp/mirza_pro_mig"
    mkdir -p "$TEMP_DIR"
    run_step "Downloading Mirza source" "wget -q -O '$TEMP_DIR/bot.zip' '$ZIP_URL'" \
        || { show_step_error; echo -e "\033[31mError: Failed to download Mirza source.\033[0m"; exit 1; }
    run_step "Extracting source files" "unzip -o -q '$TEMP_DIR/bot.zip' -d '$TEMP_DIR'" \
        || { show_step_error; echo -e "\033[31mError: Failed to extract source files.\033[0m"; exit 1; }
    EXTRACTED_DIR=$(find "$TEMP_DIR" -mindepth 1 -maxdepth 1 -type d)
    mv "$EXTRACTED_DIR"/* "$NEW_BOT_DIR"
    rm -rf "$TEMP_DIR"
    NEW_SECRET_TOKEN=$(openssl rand -base64 10 | tr -dc 'a-zA-Z0-9' | cut -c1-8)
    cat <<EOF > "$NEW_BOT_DIR/config.php"
<?php
// This variable added for high load panels which their response time is long and bot can't communicate with online panel!
// null for default settings
\$request_exec_timeout = null;
\$dbhost = 'localhost';
\$dbname = '$NEW_DB';
\$usernamedb = '$NEW_DB_USER';
\$passworddb = '$NEW_DB_PASS';
\$connect = mysqli_connect(\$dbhost, \$usernamedb, \$passworddb, \$dbname);
if (\$connect->connect_error) { die("error" . \$connect->connect_error); }
mysqli_set_charset(\$connect, "utf8mb4");
\$options = [ PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION, PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC, PDO::ATTR_EMULATE_PREPARES => false, ];
\$dsn = "mysql:host=\$dbhost;dbname=\$dbname;charset=utf8mb4";
try { \$pdo = new PDO(\$dsn, \$usernamedb, \$passworddb, \$options); } catch (\PDOException \$e) { error_log("Database connection failed: " . \$e->getMessage()); }
\$APIKEY = '${OLD_API_KEY}';
\$adminnumber = '${OLD_ADMIN_ID}';
\$domainhosts = '${DOMAIN_NAME}';
\$usernamebot = '${OLD_BOT_NAME}';
?>
EOF
    chown -R www-data:www-data "$NEW_BOT_DIR"
    chmod -R 755 "$NEW_BOT_DIR"
    echo -e "\033[33mReconfiguring Apache...\033[0m"
    a2dissite 000-default.conf 2>/dev/null || true
    a2dissite 000-default-le-ssl.conf 2>/dev/null || true
    rm -f /etc/apache2/sites-enabled/000-default* 2>/dev/null
    rm -f /etc/apache2/sites-available/000-default* 2>/dev/null
    VHOST_FILE="/etc/apache2/sites-available/${DOMAIN_NAME}.conf"
    cat <<EOF > "$VHOST_FILE"
<VirtualHost *:80>
    ServerName $DOMAIN_NAME
    DocumentRoot $NEW_BOT_DIR
    <Directory $NEW_BOT_DIR>
        Options Indexes FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
    Include /etc/apache2/conf-available/phpmyadmin.conf
    ErrorLog \${APACHE_LOG_DIR}/${DOMAIN_NAME}-error.log
    CustomLog \${APACHE_LOG_DIR}/${DOMAIN_NAME}-access.log combined
</VirtualHost>
EOF
    VHOST_SSL_FILE="/etc/apache2/sites-available/${DOMAIN_NAME}-ssl.conf"
    cat <<EOF > "$VHOST_SSL_FILE"
<VirtualHost *:443>
    ServerName $DOMAIN_NAME
    DocumentRoot $NEW_BOT_DIR
    SSLEngine on
    SSLCertificateFile /etc/letsencrypt/live/$DOMAIN_NAME/fullchain.pem
    SSLCertificateKeyFile /etc/letsencrypt/live/$DOMAIN_NAME/privkey.pem
    <Directory $NEW_BOT_DIR>
        Options Indexes FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
    Include /etc/apache2/conf-available/phpmyadmin.conf
    ErrorLog \${APACHE_LOG_DIR}/${DOMAIN_NAME}-error.log
    CustomLog \${APACHE_LOG_DIR}/${DOMAIN_NAME}-access.log combined
</VirtualHost>
EOF
    a2ensite "${DOMAIN_NAME}.conf"
    a2ensite "${DOMAIN_NAME}-ssl.conf"
    a2enmod ssl
    a2enmod rewrite
    systemctl restart apache2
    echo -e "\033[33mUpdating Webhook and Tables...\033[0m"
    curl -F "url=https://${DOMAIN_NAME}/index.php" \
         -F "secret_token=${NEW_SECRET_TOKEN}" \
         "https://api.telegram.org/bot${OLD_API_KEY}/setWebhook"
    sleep 2
    curl -k "https://${DOMAIN_NAME}/table.php" > /dev/null 2>&1
    cp /root/install.sh /usr/local/bin/mirza
    chmod +x /usr/local/bin/mirza
    clear
    echo -e "\033[32m====================================================\033[0m"
    echo -e "\033[32m       MIGRATION SUCCESSFUL (Free -> Pro)           \033[0m"
    echo -e "\033[32m====================================================\033[0m"
    echo -e "\033[36mNew Database:\033[0m $NEW_DB"
    echo -e "\033[36mNew User:\033[0m     $NEW_DB_USER"
    echo -e "\033[36mNew Pass:\033[0m     $NEW_DB_PASS"
    echo -e "\033[36mBot Domain:\033[0m   https://$DOMAIN_NAME"
    echo -e "\033[33mUse command 'mirza' to manage the bot from now on.\033[0m"
    echo ""
}

# ── Command-line argument parsing ────────────────────────────
# Globals filled from flags (consumed by install/update where relevant)
ARG_NAME=""     ARG_TOKEN=""   ARG_ADMIN=""    ARG_DOMAIN=""
ARG_DBUSER=""   ARG_DBPASS=""  ARG_VERSION=""  ARG_CHANNEL=""

print_usage() {
    cat <<USAGE

  Mirza - management script

  Usage:
    mirza [command] [options]

  Commands:
    install            Install Mirza
    update             Update Mirza
    remove             Remove Mirza
    migrate            Migrate Free -> Pro
    menu               Show interactive menu (default)

  Options:
    --name   <user>    Bot username
    --token  <token>   Telegram bot token
    --admin  <id>      Admin chat id
    --domain <domain>  Domain name (e.g. bot.example.com)
    --db-user <user>   Database username
    --db-pass <pass>   Database password
    --version <tag>    Install/update a specific release tag (e.g. 0.1.7)
    --channel <name>   Source channel: beta | release | auto
    -h, --help         Show this help and exit

  Examples:
    mirza install --channel auto
    mirza install --name myvpnbot --token 123:ABC --admin 111 --domain bot.example.com --version 0.1.7
    mirza update --channel release
    mirza update --version 0.1.6

USAGE
}

process_arguments() {
    local cmd="menu"
    # First non-flag token is the command
    case "$1" in
        install|update|remove|migrate|menu) cmd="$1"; shift ;;
        -h|--help) print_usage; exit 0 ;;
        "") cmd="menu" ;;
        --*) cmd="menu" ;;            # only flags given -> menu, but still parse flags
        *) cmd="menu" ;;
    esac

    # Parse remaining flags
    while [ $# -gt 0 ]; do
        case "$1" in
            --name)    ARG_NAME="$2";    shift 2 ;;
            --token)   ARG_TOKEN="$2";   shift 2 ;;
            --admin)   ARG_ADMIN="$2";   shift 2 ;;
            --domain)  ARG_DOMAIN="$2";  shift 2 ;;
            --db-user) ARG_DBUSER="$2";  shift 2 ;;
            --db-pass) ARG_DBPASS="$2";  shift 2 ;;
            --version) ARG_VERSION="$2"; shift 2 ;;
            --channel) ARG_CHANNEL="$2"; shift 2 ;;
            -h|--help) print_usage; exit 0 ;;
            *) echo -e "\e[91mUnknown option: $1\033[0m"; print_usage; exit 1 ;;
        esac
    done

    case "$cmd" in
        install) install_bot ;;
        update)  update_bot ;;
        remove)  remove_bot ;;
        migrate) migrate_to_pro ;;
        menu|*)  show_menu ;;
    esac
}
process_arguments "$@"