#!/bin/sh
set -eu

# Dante SOCKS5 installer + manager
# Supported: Alpine / Debian / Ubuntu
# Shortcut is a real executable command under /usr/local/bin.

INSTALLER_PATH="$0"
STATE_FILE="/root/dante-state.conf"
INFO_FILE="/root/dante-info.txt"
MANAGER="/usr/local/bin/dante-manager"

need_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "请使用 root 运行此脚本。"
        exit 1
    fi
}

need_root

. /etc/os-release
OS_ID="${ID:-}"
case "$OS_ID" in
    alpine)
        OS="alpine"
        SERVICE="sockd"
        CONFIG="/etc/sockd.conf"
        ;;
    debian|ubuntu)
        OS="$OS_ID"
        SERVICE="danted"
        CONFIG="/etc/danted.conf"
        ;;
    *)
        echo "不支持的系统：${PRETTY_NAME:-$OS_ID}"
        exit 1
        ;;
esac

install_pkg() {
    case "$OS" in
        alpine) apk add --no-cache "$@" ;;
        debian|ubuntu) apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" ;;
    esac
}

ensure_base_packages() {
    case "$OS" in
        alpine)
            apk add --no-cache dante-server openssl iproute2
            ;;
        debian|ubuntu)
            apt-get update
            DEBIAN_FRONTEND=noninteractive apt-get install -y dante-server openssl iproute2
            ;;
    esac
}

ensure_http_client() {
    if command -v curl >/dev/null 2>&1; then return 0; fi
    if command -v wget >/dev/null 2>&1; then return 0; fi
    install_pkg curl
}

random_string() {
    n="$1"
    out=""
    while [ "${#out}" -lt "$n" ]; do
        part="$(openssl rand -base64 64 2>/dev/null | tr -dc 'A-Za-z0-9' | cut -c 1-64 || true)"
        out="${out}${part}"
    done
    printf '%s' "$(printf '%s' "$out" | cut -c 1-"$n")"
}

get_interface() {
    ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'
}

get_local_ipv4() {
    ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}'
}

get_local_ipv6() {
    ip -6 route get 2606:4700:4700::1111 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}'
}

get_public_ipv4() {
    if command -v curl >/dev/null 2>&1; then
        curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true
    elif command -v wget >/dev/null 2>&1; then
        wget -4 -qO- --timeout=5 https://api.ipify.org 2>/dev/null || true
    fi
}

get_public_ipv6() {
    if command -v curl >/dev/null 2>&1; then
        curl -6 -fsS --max-time 5 https://api6.ipify.org 2>/dev/null || true
    elif command -v wget >/dev/null 2>&1; then
        wget -6 -qO- --timeout=5 https://api6.ipify.org 2>/dev/null || true
    fi
}

show_nat() {
    echo
    echo "=========================================="
    echo "          网络 / NAT 检测"
    echo "=========================================="
    IFACE="$(get_interface || true)"
    LOCAL4="$(get_local_ipv4 || true)"
    LOCAL6="$(get_local_ipv6 || true)"
    PUB4="$(get_public_ipv4 || true)"
    PUB6="$(get_public_ipv6 || true)"
    echo "网卡：${IFACE:-无法获取}"
    echo "本机 IPv4：${LOCAL4:-无法获取}"
    echo "公网 IPv4：${PUB4:-无法获取}"
    if [ -n "$LOCAL4" ] && [ -n "$PUB4" ]; then
        if [ "$LOCAL4" = "$PUB4" ]; then
            echo "IPv4 NAT：未检测到（本机出口地址与公网地址一致）"
        else
            echo "IPv4 NAT：检测到（本机出口地址与公网地址不同）"
        fi
    else
        echo "IPv4 NAT：无法判断"
    fi
    echo "本机 IPv6：${LOCAL6:-无法获取}"
    echo "公网 IPv6：${PUB6:-无法获取}"
    if [ -n "$LOCAL6" ] && [ -n "$PUB6" ]; then
        if [ "$LOCAL6" = "$PUB6" ]; then
            echo "IPv6 地址转换：未检测到"
        else
            echo "IPv6 地址转换：地址不同，请结合网络环境判断"
        fi
    fi
    echo
}

extract_old() {
    file="$1"
    key="$2"
    sed -n "/^${key}:/ {n;p;q;}" "$file" 2>/dev/null || true
}

valid_username() {
    case "$1" in
        ''|*[!A-Za-z0-9._-]*) return 1 ;;
        *) return 0 ;;
    esac
}

valid_port() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$1" -ge 1 ] 2>/dev/null && [ "$1" -le 65535 ] 2>/dev/null
}

valid_key() {
    case "$1" in
        [A-Za-z0-9]) return 0 ;;
        *) return 1 ;;
    esac
}

create_user() {
    user="$1"
    pass="$2"
    if id "$user" >/dev/null 2>&1; then
        printf '%s:%s\n' "$user" "$pass" | chpasswd
        return 0
    fi
    case "$OS" in
        alpine) adduser -D -H -s /sbin/nologin "$user" ;;
        debian|ubuntu) useradd --system --no-create-home --shell /usr/sbin/nologin "$user" ;;
    esac
    printf '%s:%s\n' "$user" "$pass" | chpasswd
}

write_state() {
    {
        echo 'PORT:'
        echo "$PORT"
        echo 'USERNAME:'
        echo "$USERNAME"
        echo 'PASSWORD:'
        echo "$PASSWORD"
        echo 'INTERFACE:'
        echo "$INTERFACE"
    } > "$STATE_FILE"
    chmod 600 "$STATE_FILE"
}

write_info() {
    LOCAL4="$(get_local_ipv4 || true)"
    LOCAL6="$(get_local_ipv6 || true)"
    PUB4="$(get_public_ipv4 || true)"
    PUB6="$(get_public_ipv6 || true)"
    {
        echo "Dante SOCKS5 配置"
        echo
        echo "本机 IPv4："
        echo "${LOCAL4:-未获取}"
        echo "公网 IPv4："
        echo "${PUB4:-未获取}"
        echo "本机 IPv6："
        echo "${LOCAL6:-未获取}"
        echo "公网 IPv6："
        echo "${PUB6:-未获取}"
        echo "端口："
        echo "$PORT"
        echo "用户名："
        echo "$USERNAME"
        echo "密码："
        echo "$PASSWORD"
        echo "网卡："
        echo "$INTERFACE"
        echo "服务："
        echo "$SERVICE"
        echo "配置文件："
        echo "$CONFIG"
        echo
        if [ -n "$PUB4" ]; then
            echo "SOCKS5 IPv4："
            echo "socks5://${USERNAME}:${PASSWORD}@${PUB4}:${PORT}"
            echo "SOCKS5H IPv4："
            echo "socks5h://${USERNAME}:${PASSWORD}@${PUB4}:${PORT}"
        fi
        if [ -n "$PUB6" ]; then
            echo "SOCKS5 IPv6："
            echo "socks5://[${USERNAME}:${PASSWORD}@${PUB6}]:${PORT}"
            echo "SOCKS5H IPv6："
            echo "socks5h://[${USERNAME}:${PASSWORD}@${PUB6}]:${PORT}"
        fi
    } > "$INFO_FILE"
    chmod 600 "$INFO_FILE"
}

write_config() {
    cat > "$CONFIG" <<EOF
logoutput: syslog
internal: 0.0.0.0 port = $PORT
external: $INTERFACE
socksmethod: username
clientmethod: none
user.privileged: root
user.notprivileged: nobody

client pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
}

socks pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    command: connect udpassociate
}
EOF
    chmod 600 "$CONFIG"
}

service_restart() {
    case "$OS" in
        alpine)
            rc-service "$SERVICE" restart 2>/dev/null || rc-service "$SERVICE" start
            ;;
        debian|ubuntu)
            systemctl restart "$SERVICE" 2>/dev/null || systemctl start "$SERVICE"
            ;;
    esac
}

service_enable() {
    case "$OS" in
        alpine)
            rc-update add "$SERVICE" default >/dev/null 2>&1 || true
            ;;
        debian|ubuntu)
            systemctl enable "$SERVICE" >/dev/null 2>&1
            ;;
    esac
}

service_disable() {
    case "$OS" in
        alpine)
            rc-update del "$SERVICE" default >/dev/null 2>&1 || true
            ;;
        debian|ubuntu)
            systemctl disable "$SERVICE" >/dev/null 2>&1 || true
            ;;
    esac
}

service_status() {
    case "$OS" in
        alpine) rc-service "$SERVICE" status 2>&1 || true ;;
        debian|ubuntu) systemctl --no-pager --full status "$SERVICE" 2>&1 || true ;;
    esac
}

is_enabled() {
    case "$OS" in
        alpine) rc-update show default 2>/dev/null | grep -Eq "(^|[[:space:]])${SERVICE}([[:space:]]|$)" ;;
        debian|ubuntu) systemctl is-enabled "$SERVICE" >/dev/null 2>&1 ;;
    esac
}

is_running() {
    case "$OS" in
        alpine) rc-service "$SERVICE" status >/dev/null 2>&1 ;;
        debian|ubuntu) systemctl is-active --quiet "$SERVICE" 2>/dev/null ;;
    esac
}

port_listening() {
    command -v ss >/dev/null 2>&1 || return 1
    ss -lnt 2>/dev/null | awk -v p=":$PORT" '$4 ~ p"$" {found=1} END{exit !found}'
}

install_manager() {
    cat > "$MANAGER" <<'MANAGER_EOF'
#!/bin/sh
set -eu

STATE_FILE="/root/dante-state.conf"
INFO_FILE="/root/dante-info.txt"
MANAGER="/usr/local/bin/dante-manager"
SHORTCUT_CONF="/root/dante-manager.conf"

need_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "Dante 管理需要 root 权限。"
        exit 1
    fi
}
need_root

. /etc/os-release
case "${ID:-}" in
    alpine) OS=alpine; SERVICE=sockd; CONFIG=/etc/sockd.conf ;;
    debian|ubuntu) OS="${ID}"; SERVICE=danted; CONFIG=/etc/danted.conf ;;
    *) echo "不支持的系统。"; exit 1 ;;
esac

random_string() {
    n="$1"; out=""
    while [ "${#out}" -lt "$n" ]; do
        part="$(openssl rand -base64 64 2>/dev/null | tr -dc 'A-Za-z0-9' | cut -c 1-64 || true)"
        out="${out}${part}"
    done
    printf '%s' "$(printf '%s' "$out" | cut -c 1-"$n")"
}

get_interface() {
    ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'
}
get_local_ipv4() {
    ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}'
}
get_local_ipv6() {
    ip -6 route get 2606:4700:4700::1111 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}'
}
get_public_ipv4() {
    if command -v curl >/dev/null 2>&1; then curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true
    elif command -v wget >/dev/null 2>&1; then wget -4 -qO- --timeout=5 https://api.ipify.org 2>/dev/null || true; fi
}
get_public_ipv6() {
    if command -v curl >/dev/null 2>&1; then curl -6 -fsS --max-time 5 https://api6.ipify.org 2>/dev/null || true
    elif command -v wget >/dev/null 2>&1; then wget -6 -qO- --timeout=5 https://api6.ipify.org 2>/dev/null || true; fi
}

load_state() {
    if [ ! -f "$STATE_FILE" ]; then
        echo "状态文件不存在，尝试从旧版信息文件读取。"
        if [ ! -f "$INFO_FILE" ]; then
            echo "找不到 Dante 配置状态。"
            exit 1
        fi
        PORT="$(sed -n '/^端口：/ {n;p;q;}' "$INFO_FILE")"
        USERNAME="$(sed -n '/^用户名：/ {n;p;q;}' "$INFO_FILE")"
        PASSWORD="$(sed -n '/^密码：/ {n;p;q;}' "$INFO_FILE")"
        INTERFACE="$(sed -n '/^网卡：/ {n;p;q;}' "$INFO_FILE")"
    else
        PORT="$(sed -n '/^PORT:/ {n;p;q;}' "$STATE_FILE")"
        USERNAME="$(sed -n '/^USERNAME:/ {n;p;q;}' "$STATE_FILE")"
        PASSWORD="$(sed -n '/^PASSWORD:/ {n;p;q;}' "$STATE_FILE")"
        INTERFACE="$(sed -n '/^INTERFACE:/ {n;p;q;}' "$STATE_FILE")"
    fi
}

write_state() {
    {
        echo 'PORT:'; echo "$PORT"
        echo 'USERNAME:'; echo "$USERNAME"
        echo 'PASSWORD:'; echo "$PASSWORD"
        echo 'INTERFACE:'; echo "$INTERFACE"
    } > "$STATE_FILE"
    chmod 600 "$STATE_FILE"
}

write_info() {
    L4="$(get_local_ipv4 || true)"
    L6="$(get_local_ipv6 || true)"
    P4="$(get_public_ipv4 || true)"
    P6="$(get_public_ipv6 || true)"
    {
        echo "Dante SOCKS5 配置"
        echo
        echo "本机 IPv4："; echo "${L4:-未获取}"
        echo "公网 IPv4："; echo "${P4:-未获取}"
        echo "本机 IPv6："; echo "${L6:-未获取}"
        echo "公网 IPv6："; echo "${P6:-未获取}"
        echo "端口："; echo "$PORT"
        echo "用户名："; echo "$USERNAME"
        echo "密码："; echo "$PASSWORD"
        echo "网卡："; echo "$INTERFACE"
        echo "服务："; echo "$SERVICE"
        echo "配置文件："; echo "$CONFIG"
        echo
        [ -z "$P4" ] || { echo "SOCKS5 IPv4："; echo "socks5://${USERNAME}:${PASSWORD}@${P4}:${PORT}"; echo "SOCKS5H IPv4："; echo "socks5h://${USERNAME}:${PASSWORD}@${P4}:${PORT}"; }
        [ -z "$P6" ] || { echo "SOCKS5 IPv6："; echo "socks5://[${USERNAME}:${PASSWORD}@${P6}]:${PORT}"; echo "SOCKS5H IPv6："; echo "socks5h://[${USERNAME}:${PASSWORD}@${P6}]:${PORT}"; }
    } > "$INFO_FILE"
    chmod 600 "$INFO_FILE"
}

backup() {
    file="$1"
    if [ -f "$file" ]; then
        cp -a "$file" "${file}.backup.$(date +%Y%m%d-%H%M%S)"
    fi
}

write_config() {
    cat > "$CONFIG" <<EOF
logoutput: syslog
internal: 0.0.0.0 port = $PORT
external: $INTERFACE
socksmethod: username
clientmethod: none
user.privileged: root
user.notprivileged: nobody

client pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
}

socks pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    command: connect udpassociate
}
EOF
    chmod 600 "$CONFIG"
}

restart() {
    case "$OS" in
        alpine) rc-service "$SERVICE" restart 2>/dev/null || rc-service "$SERVICE" start ;;
        debian|ubuntu) systemctl restart "$SERVICE" 2>/dev/null || systemctl start "$SERVICE" ;;
    esac
}

restart_check() {
    restart || return 1
    sleep 1
    case "$OS" in
        alpine) rc-service "$SERVICE" status >/dev/null 2>&1 || return 1 ;;
        debian|ubuntu) systemctl is-active --quiet "$SERVICE" 2>/dev/null || return 1 ;;
    esac
    command -v ss >/dev/null 2>&1 || return 0
    ss -lnt 2>/dev/null | awk -v p=":$PORT" '$4 ~ p"$" {found=1} END{exit !found}'
}

show_status_short() {
    echo "运行状态：$(if case "$OS" in alpine) rc-service "$SERVICE" status >/dev/null 2>&1;; debian|ubuntu) systemctl is-active --quiet "$SERVICE" 2>/dev/null;; esac; then echo 运行中; else echo 未运行; fi)"
    if case "$OS" in alpine) rc-update show default 2>/dev/null | grep -Eq "(^|[[:space:]])${SERVICE}([[:space:]]|$)";; debian|ubuntu) systemctl is-enabled "$SERVICE" >/dev/null 2>&1;; esac; then
        echo "开机自启动：已启用"
    else
        echo "开机自启动：未启用"
    fi
}

show_config() {
    load_state
    L4="$(get_local_ipv4 || true)"; L6="$(get_local_ipv6 || true)"
    P4="$(get_public_ipv4 || true)"; P6="$(get_public_ipv6 || true)"
    echo
    echo "=========================================="
    echo "          当前 SOCKS5 配置"
    echo "=========================================="
    echo "本机 IPv4：${L4:-未获取}"
    echo "公网 IPv4：${P4:-未获取}"
    echo "本机 IPv6：${L6:-未获取}"
    echo "公网 IPv6：${P6:-未获取}"
    echo "端口：$PORT"
    echo "用户名：$USERNAME"
    echo "密码：$PASSWORD"
    echo "网卡：$INTERFACE"
    echo "服务：$SERVICE"
    echo "配置文件：$CONFIG"
    echo
    [ -z "$P4" ] || {
        echo "SOCKS5 IPv4：socks5://${USERNAME}:${PASSWORD}@${P4}:${PORT}"
        echo "SOCKS5H IPv4：socks5h://${USERNAME}:${PASSWORD}@${P4}:${PORT}"
    }
    [ -z "$P6" ] || {
        echo "SOCKS5 IPv6：socks5://[${USERNAME}:${PASSWORD}@${P6}]:${PORT}"
        echo "SOCKS5H IPv6：socks5h://[${USERNAME}:${PASSWORD}@${P6}]:${PORT}"
    }
    show_status_short
    echo
    if [ -f "$SHORTCUT_CONF" ]; then
        KEY="$(sed -n '/^MANAGER_KEY:/ {n;p;q;}' "$SHORTCUT_CONF")"
        echo "管理快捷命令：$KEY"
    fi
}

change_port() {
    load_state
    echo "当前端口：$PORT"
    printf "请输入新端口："
    read -r NEWPORT
    case "$NEWPORT" in ''|*[!0-9]*) echo "端口必须是 1-65535 的数字。"; return ;; esac
    if [ "$NEWPORT" -lt 1 ] || [ "$NEWPORT" -gt 65535 ]; then echo "端口必须是 1-65535。"; return; fi
    if [ "$NEWPORT" = "$PORT" ]; then echo "端口未改变。"; return; fi
    OLDPORT="$PORT"
    backup "$CONFIG"
    PORT="$NEWPORT"
    write_config
    if restart_check; then
        write_state; write_info
        echo "端口已修改为：$PORT"
    else
        echo "Dante 启动或端口监听检查失败，正在回滚。"
        PORT="$OLDPORT"
        cp -a "$(ls -1t "${CONFIG}.backup."* 2>/dev/null | head -n 1)" "$CONFIG" 2>/dev/null || true
        restart || true
        return 1
    fi
}

change_credentials() {
    load_state
    OLDUSER="$USERNAME"; OLDPASS="$PASSWORD"
    echo
    echo "当前用户名：$USERNAME"
    echo "当前密码：$PASSWORD"
    printf "新用户名（留空自动生成）："
    read -r NEWUSER
    [ -n "$NEWUSER" ] || NEWUSER="$(random_string 10)"
    case "$NEWUSER" in ''|*[!A-Za-z0-9._-]*) echo "用户名只能包含字母、数字、点、下划线和连字符。"; return ;; esac
    if [ "$NEWUSER" = root ] || [ "$NEWUSER" = nobody ]; then echo "不建议使用 root 或 nobody 作为 SOCKS5 登录账号。"; return; fi
    printf "新密码（留空自动生成）："
    read -r NEWPASS
    [ -n "$NEWPASS" ] || NEWPASS="$(random_string 10)"
    if [ "${#NEWPASS}" -lt 8 ]; then echo "密码至少 8 位。"; return; fi
    echo
    echo "新用户名：$NEWUSER"
    echo "新密码：$NEWPASS"
    echo
    printf "确认修改？[Y/n] "
    read -r ANSWER
    case "$ANSWER" in n|N|no|NO) echo "已取消。"; return ;; esac

    if [ "$NEWUSER" != "$OLDUSER" ] && id "$NEWUSER" >/dev/null 2>&1; then
        echo "目标用户名已存在，请换一个。"
        return 1
    fi

    if [ "$NEWUSER" != "$OLDUSER" ]; then
        case "$OS" in
            alpine) adduser -D -H -s /sbin/nologin "$NEWUSER" ;;
            debian|ubuntu) useradd --system --no-create-home --shell /usr/sbin/nologin "$NEWUSER" ;;
        esac
    fi
    if ! printf '%s:%s\n' "$NEWUSER" "$NEWPASS" | chpasswd; then
        [ "$NEWUSER" = "$OLDUSER" ] || { case "$OS" in alpine) deluser "$NEWUSER" >/dev/null 2>&1 || true;; debian|ubuntu) userdel "$NEWUSER" >/dev/null 2>&1 || true;; esac; }
        echo "密码更新失败。"
        return 1
    fi

    USERNAME="$NEWUSER"; PASSWORD="$NEWPASS"
    write_state
    write_info
    if [ "$NEWUSER" != "$OLDUSER" ]; then
        echo "用户名已修改，旧账号暂不删除，先确认 Dante 正常。"
    fi
    if restart_check; then
        if [ "$NEWUSER" != "$OLDUSER" ]; then
            case "$OS" in alpine) deluser "$OLDUSER" >/dev/null 2>&1 || true;; debian|ubuntu) userdel "$OLDUSER" >/dev/null 2>&1 || true;; esac
        fi
        write_info
        echo "用户名和密码已更新。"
    else
        echo "Dante 重启检查失败。保留新账号以避免误删旧账号；请检查状态。"
        return 1
    fi
}

boot_menu() {
    while :; do
        echo
        echo "=========================================="
        echo "          开机自启动管理"
        echo "=========================================="
        show_status_short
        echo
        echo "1. 启用开机自启动"
        echo "2. 禁用开机自启动"
        echo "0. 返回"
        printf "请选择："
        read -r C
        case "$C" in
            1)
                case "$OS" in alpine) rc-update add "$SERVICE" default;; debian|ubuntu) systemctl enable "$SERVICE";; esac
                echo "已启用。"
                ;;
            2)
                case "$OS" in alpine) rc-update del "$SERVICE" default >/dev/null 2>&1 || true;; debian|ubuntu) systemctl disable "$SERVICE" >/dev/null 2>&1 || true;; esac
                echo "已禁用。"
                ;;
            0) return ;;
            *) echo "无效选择。" ;;
        esac
    done
}

change_shortcut() {
    OLDKEY=""
    [ -f "$SHORTCUT_CONF" ] && OLDKEY="$(sed -n '/^MANAGER_KEY:/ {n;p;q;}' "$SHORTCUT_CONF")"
    echo "当前管理快捷命令：${OLDKEY:-未设置}"
    printf "请输入新的单字符快捷命令（A-Z/a-z/0-9）："
    read -r NEWKEY
    case "$NEWKEY" in
        [A-Za-z0-9]) ;;
        *) echo "必须是一个 ASCII 字母或数字。"; return 1 ;;
    esac
    TARGET="/usr/local/bin/$NEWKEY"
    if [ -e "$TARGET" ] && [ "$TARGET" != "/usr/local/bin/$OLDKEY" ]; then
        echo "$TARGET 已存在，为避免覆盖其他程序，换一个字符。"
        return 1
    fi
    if [ -n "$OLDKEY" ] && [ -f "/usr/local/bin/$OLDKEY" ] && [ "$OLDKEY" != "$NEWKEY" ]; then
        if grep -q '^exec /usr/local/bin/dante-manager' "/usr/local/bin/$OLDKEY" 2>/dev/null; then
            rm -f "/usr/local/bin/$OLDKEY"
        fi
    fi
    cat > "$TARGET" <<EOF
#!/bin/sh
exec /usr/local/bin/dante-manager "\$@"
EOF
    chmod 755 "$TARGET"
    {
        echo 'MANAGER_KEY:'
        echo "$NEWKEY"
    } > "$SHORTCUT_CONF"
    chmod 600 "$SHORTCUT_CONF"
    echo "管理快捷命令已改为：$NEWKEY"
}

restart_menu() {
    load_state
    echo "正在重启 Dante..."
    if restart_check; then
        write_info
        echo "Dante 重启成功，端口 $PORT 正在监听。"
    else
        echo "Dante 重启后检查失败。"
        case "$OS" in alpine) rc-service "$SERVICE" status 2>&1 || true;; debian|ubuntu) systemctl --no-pager --full status "$SERVICE" 2>&1 || true;; esac
        return 1
    fi
}

status_menu() {
    echo
    echo "=========================================="
    echo "             Dante 状态"
    echo "=========================================="
    show_status_short
    echo
    case "$OS" in
        alpine) rc-service "$SERVICE" status 2>&1 || true ;;
        debian|ubuntu) systemctl --no-pager --full status "$SERVICE" 2>&1 || true ;;
    esac
    echo
    if [ -f "$CONFIG" ]; then
        echo "配置文件：$CONFIG"
    fi
}

while :; do
    echo
    echo "=========================================="
    echo "        Dante SOCKS5 管理"
    echo "=========================================="
    echo
    echo "1. 查看当前 SOCKS5 配置"
    echo "2. 更换 SOCKS5 端口"
    echo "3. 管理用户名密码"
    echo "4. 管理开机自启动"
    echo "5. 更换管理快捷键"
    echo "6. 重启 Dante"
    echo "7. 查看 Dante 状态"
    echo "0. 退出"
    echo
    printf "请选择："
    read -r CHOICE
    case "$CHOICE" in
        1) show_config ;;
        2) change_port ;;
        3) change_credentials ;;
        4) boot_menu ;;
        5) change_shortcut ;;
        6) restart_menu ;;
        7) status_menu ;;
        0) exit 0 ;;
        *) echo "无效选择。" ;;
    esac
done
MANAGER_EOF
    chmod 755 "$MANAGER"
}

install_shortcut() {
    current=""
    if [ -f /root/dante-manager.conf ]; then
        current="$(sed -n '/^MANAGER_KEY:/ {n;p;q;}' /root/dante-manager.conf 2>/dev/null || true)"
    fi
    while :; do
        if [ -n "$current" ] && valid_key "$current"; then
            KEY="$current"
            if [ -f "/usr/local/bin/$KEY" ] && grep -q '^exec /usr/local/bin/dante-manager' "/usr/local/bin/$KEY" 2>/dev/null; then
                break
            fi
        fi
        printf "请选择 Dante 管理快捷命令（单个 A-Z/a-z/0-9）："
        read -r KEY
        if ! valid_key "$KEY"; then
            echo "必须是一个 ASCII 字母或数字。"
            continue
        fi
        TARGET="/usr/local/bin/$KEY"
        if [ -e "$TARGET" ] && ! grep -q '^exec /usr/local/bin/dante-manager' "$TARGET" 2>/dev/null; then
            echo "$TARGET 已存在，为避免覆盖其他程序，请换一个字符。"
            continue
        fi
        break
    done
    TARGET="/usr/local/bin/$KEY"
    cat > "$TARGET" <<EOF
#!/bin/sh
exec /usr/local/bin/dante-manager "\$@"
EOF
    chmod 755 "$TARGET"
    {
        echo 'MANAGER_KEY:'
        echo "$KEY"
    } > /root/dante-manager.conf
    chmod 600 /root/dante-manager.conf
    echo "管理快捷命令：$KEY"
    echo "以后直接输入 $KEY 并回车即可打开 Dante 管理。"
}

show_old_connection_info() {
    file="$1"
    OLD4="$(sed -n '/^SOCKS5 IPv4：/ {n;p;q;}' "$file" 2>/dev/null || true)"
    OLD4H="$(sed -n '/^SOCKS5H IPv4：/ {n;p;q;}' "$file" 2>/dev/null || true)"
    OLD6="$(sed -n '/^SOCKS5 IPv6：/ {n;p;q;}' "$file" 2>/dev/null || true)"
    OLD6H="$(sed -n '/^SOCKS5H IPv6：/ {n;p;q;}' "$file" 2>/dev/null || true)"
    OLDUSER="$(extract_old "$file" '用户名：')"
    OLDPASS="$(extract_old "$file" '密码：')"
    OLDPORT="$(extract_old "$file" '端口：')"
    echo
    echo "=========================================="
    echo "          发现旧 Dante SOCKS5 配置"
    echo "=========================================="
    echo "用户名：${OLDUSER:-未知}"
    echo "密码：${OLDPASS:-未知}"
    echo "端口：${OLDPORT:-未知}"
    [ -z "$OLD4" ] || echo "SOCKS5 IPv4：$OLD4"
    [ -z "$OLD4H" ] || echo "SOCKS5H IPv4：$OLD4H"
    [ -z "$OLD6" ] || echo "SOCKS5 IPv6：$OLD6"
    [ -z "$OLD6H" ] || echo "SOCKS5H IPv6：$OLD6H"
    echo
}

# ---------- installer flow ----------

echo "=========================================="
echo "       Dante SOCKS5 安装 / 配置"
echo "=========================================="
echo "系统：${PRETTY_NAME:-$OS_ID}"

echo

echo "正在安装/检查 Dante 依赖..."
ensure_base_packages
ensure_http_client

INTERFACE="$(get_interface || true)"
if [ -z "$INTERFACE" ]; then
    echo "无法自动获取默认出口网卡。"
    printf "请输入外网网卡名称："
    read -r INTERFACE
fi
show_nat

OLD_FOUND=0
if [ -f "$CONFIG" ] && [ -f "$INFO_FILE" ]; then
    OLD_FOUND=1
    show_old_connection_info "$INFO_FILE"
    echo "1. 使用旧配置"
    echo "2. 重新配置"
    echo "0. 退出"
    printf "请选择："
    read -r OLD_CHOICE
    case "$OLD_CHOICE" in
        1)
            OLD_USER="$(extract_old "$INFO_FILE" '用户名：')"
            OLD_PASS="$(extract_old "$INFO_FILE" '密码：')"
            OLD_PORT="$(extract_old "$INFO_FILE" '端口：')"
            [ -n "$OLD_USER" ] && [ -n "$OLD_PASS" ] && [ -n "$OLD_PORT" ] || {
                echo "旧信息文件缺少必要字段，无法安全使用旧配置。"
                exit 1
            }
            PORT="$OLD_PORT"
            USERNAME="$OLD_USER"
            PASSWORD="$OLD_PASS"
            if [ -f "$STATE_FILE" ]; then
                OLD_IF="$(sed -n '/^INTERFACE:/ {n;p;q;}' "$STATE_FILE" 2>/dev/null || true)"
                [ -n "$OLD_IF" ] && INTERFACE="$OLD_IF"
            fi
            echo
            echo "正在使用旧 Dante 配置，不改写原配置。"
            ;;
        2) OLD_FOUND=0 ;;
        0) exit 0 ;;
        *) echo "无效选择。"; exit 1 ;;
    esac
fi

if [ "$OLD_FOUND" -eq 0 ]; then
    if [ -f "$CONFIG" ]; then
        cp -a "$CONFIG" "${CONFIG}.backup.$(date +%Y%m%d-%H%M%S)"
        echo "旧配置已备份。"
    fi

    while :; do
        printf "请输入 SOCKS5 端口 [1080]："
        read -r PORT
        [ -n "$PORT" ] || PORT=1080
        if valid_port "$PORT"; then break; fi
        echo "端口必须是 1-65535。"
    done

    while :; do
        printf "请输入 SOCKS5 用户名（留空自动生成）："
        read -r USERNAME
        [ -n "$USERNAME" ] || USERNAME="$(random_string 10)"
        if valid_username "$USERNAME" && [ "$USERNAME" != root ] && [ "$USERNAME" != nobody ]; then break; fi
        echo "用户名只能包含字母、数字、点、下划线和连字符，且不能使用 root/nobody。"
    done

    while :; do
        printf "请输入 SOCKS5 密码（留空自动生成）："
        read -r PASSWORD
        [ -n "$PASSWORD" ] || PASSWORD="$(random_string 10)"
        if [ "${#PASSWORD}" -ge 8 ]; then break; fi
        echo "密码至少 8 位。"
    done
fi

if [ "$OLD_FOUND" -eq 0 ]; then
    echo
    echo "当前配置："
    echo "端口：$PORT"
    echo "用户名：$USERNAME"
    echo "密码：$PASSWORD"
    echo "外网网卡：$INTERFACE"
    echo
    printf "确认继续？[Y/n] "
    read -r CONFIRM
    case "$CONFIRM" in n|N|no|NO) echo "已取消。"; exit 0;; esac

    create_user "$USERNAME" "$PASSWORD"
    write_config
    write_state
else
    # Ensure the old credentials still correspond to a local account.
    create_user "$USERNAME" "$PASSWORD"
    write_state
fi

install_manager

if [ "$OLD_FOUND" -eq 0 ]; then
    service_restart
    service_enable
else
    service_restart
fi

sleep 1
if ! is_running 2>/dev/null; then
    echo "Dante 服务启动失败。"
    service_status
    exit 1
fi

if command -v ss >/dev/null 2>&1 && ! ss -lnt 2>/dev/null | awk -v p=":$PORT" '$4 ~ p"$" {found=1} END{exit !found}'; then
    echo "警告：未检测到 TCP $PORT 监听。"
    service_status
fi

write_info
install_shortcut

LOCAL4="$(get_local_ipv4 || true)"
LOCAL6="$(get_local_ipv6 || true)"
PUB4="$(get_public_ipv4 || true)"
PUB6="$(get_public_ipv6 || true)"

echo
if [ "$OLD_FOUND" -eq 1 ]; then
    echo "=========================================="
    echo "          旧配置已恢复运行"
    echo "=========================================="
else
    echo "=========================================="
    echo "          Dante SOCKS5 安装完成"
    echo "=========================================="
fi
echo "本机 IPv4：${LOCAL4:-未获取}"
echo "公网 IPv4：${PUB4:-未获取}"
echo "本机 IPv6：${LOCAL6:-未获取}"
echo "公网 IPv6：${PUB6:-未获取}"
echo "端口：$PORT"
echo "用户名：$USERNAME"
echo "密码：$PASSWORD"
echo "网卡：$INTERFACE"
echo "服务：$SERVICE"
echo "配置文件：$CONFIG"
echo "管理命令：$KEY"
[ -z "$PUB4" ] || echo "SOCKS5 IPv4：socks5://${USERNAME}:${PASSWORD}@${PUB4}:${PORT}"
[ -z "$PUB4" ] || echo "SOCKS5H IPv4：socks5h://${USERNAME}:${PASSWORD}@${PUB4}:${PORT}"
[ -z "$PUB6" ] || echo "SOCKS5 IPv6：socks5://[${USERNAME}:${PASSWORD}@${PUB6}]:${PORT}"
[ -z "$PUB6" ] || echo "SOCKS5H IPv6：socks5h://[${USERNAME}:${PASSWORD}@${PUB6}]:${PORT}"
echo
echo "配置详情已保存：$INFO_FILE"
echo "注意：如果 VPS 有云防火墙/安全组，还需要放行 TCP $PORT。"
echo
