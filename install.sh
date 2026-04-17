#!/usr/bin/env bash
set -euo pipefail

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
PLAIN="\033[0m"

green() { echo -e "${GREEN}$1${PLAIN}"; }
yellow() { echo -e "${YELLOW}$1${PLAIN}"; }
red() { echo -e "${RED}$1${PLAIN}"; }

[[ $EUID -ne 0 ]] && { red "请用 root 运行"; exit 1; }

BIN_PATH="/usr/local/bin/hysteria"
CONFIG_DIR="/etc/hysteria"
CONFIG_FILE="${CONFIG_DIR}/config.yaml"
CERT_FILE="${CONFIG_DIR}/cert.crt"
KEY_FILE="${CONFIG_DIR}/private.key"
SERVICE_FILE="/etc/systemd/system/hysteria-server.service"
INFO_DIR="/root/hy"
LINK_FILE="${INFO_DIR}/url.txt"
CLIENT_YAML="${INFO_DIR}/hy-client.yaml"
CLIENT_JSON="${INFO_DIR}/hy-client.json"

DEFAULT_SNI="www.bing.com"
DEFAULT_MASQ_URL="https://en.snu.ac.kr"
PORT=""
SNI="${DEFAULT_SNI}"
MASQ_URL="${DEFAULT_MASQ_URL}"
FIRST_HOP_PORT=""
END_HOP_PORT=""
CERT_PATH="${CERT_FILE}"
KEY_PATH="${KEY_FILE}"
CLIENT_INSECURE="true"

declare -a USERS=()
declare -a PASSWDS=()

need_cmd() {
    command -v "$1" >/dev/null 2>&1
}

validate_username() {
    local u="$1"
    [[ "$u" =~ ^[A-Za-z0-9._-]{1,32}$ ]]
}

validate_password() {
    local p="$1"
    [[ -n "$p" ]] || return 1
    [[ "$p" =~ ^[^[:space:]#:@/\?&]+$ ]]
}

extract_server_host() {
    local s="$1"
    sed -E 's/^(\[[^]]+\]|[^:]+):.*/\1/' <<< "$s"
}

extract_server_suffix() {
    local s="$1"
    sed -E 's/^(\[[^]]+\]|[^:]+):([0-9]+)(,.*)?$/\3/' <<< "$s"
}

load_hop_range_from_server() {
    local server="$1"
    FIRST_HOP_PORT=""
    END_HOP_PORT=""
    if [[ "$server" =~ ,([0-9]+)-([0-9]+)$ ]]; then
        FIRST_HOP_PORT="${BASH_REMATCH[1]}"
        END_HOP_PORT="${BASH_REMATCH[2]}"
    fi
}

install_base_packages() {
    if need_cmd apt-get; then
        apt-get update
        apt-get install -y curl wget openssl ufw socat cron iptables iptables-persistent netfilter-persistent
        systemctl enable --now cron >/dev/null 2>&1 || true
    elif need_cmd yum; then
        yum -y install curl wget openssl socat cronie iptables-services
        systemctl enable --now crond >/dev/null 2>&1 || true
    else
        red "不支持的系统，未找到 apt-get 或 yum"
        exit 1
    fi
}

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        armv7l|armv7) echo "armv7" ;;
        *) red "暂不支持的架构: $(uname -m)"; exit 1 ;;
    esac
}

install_hysteria() {
    local arch url
    arch="$(detect_arch)"
    url="https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${arch}"

    green "下载 Hysteria2 二进制..."
    wget -O "${BIN_PATH}" "${url}"
    chmod +x "${BIN_PATH}"
    "${BIN_PATH}" version
}

port_in_use() {
    local p="$1"
    ss -tunlp | awk '{print $5}' | sed 's/.*://g' | grep -qw "$p"
}

prompt_port_and_hop() {
    read -rp "设置 Hysteria 2 端口 [1-65535]（回车则随机）: " PORT
    PORT="${PORT:-$(shuf -i 2000-65535 -n 1)}"

    if ! [[ "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then
        red "端口不合法"
        exit 1
    fi

    while port_in_use "$PORT"; do
        yellow "端口 $PORT 已被占用，请重新输入"
        read -rp "设置 Hysteria 2 端口 [1-65535]（回车则随机）: " PORT
        PORT="${PORT:-$(shuf -i 2000-65535 -n 1)}"
    done

    echo
    echo "1) 单端口（默认）"
    echo "2) 端口跳跃"
    read -rp "请选择端口模式 [1-2]: " mode
    if [[ "${mode:-1}" == "2" ]]; then
        read -rp "输入跳跃起始端口: " FIRST_HOP_PORT
        read -rp "输入跳跃结束端口: " END_HOP_PORT
        if ! [[ "$FIRST_HOP_PORT" =~ ^[0-9]+$ && "$END_HOP_PORT" =~ ^[0-9]+$ ]]; then
            red "跳跃端口必须是数字"
            exit 1
        fi
        if (( FIRST_HOP_PORT >= END_HOP_PORT )); then
            red "起始端口必须小于结束端口"
            exit 1
        fi
    fi
}

prompt_users() {
    echo
    yellow "配置多用户（至少 1 个）"
    while true; do
        local u p
        read -rp "用户名（回车结束添加）: " u
        if [[ -z "$u" ]]; then
            break
        fi
        if ! validate_username "$u"; then
            red "用户名仅支持 1-32 位：字母、数字、点、下划线、短横线"
            continue
        fi
        read -rsp "密码: " p
        echo
        if ! validate_password "$p"; then
            red "密码不能为空，且不能包含空白或 # : @ / ? &"
            continue
        fi
        USERS+=("$u")
        PASSWDS+=("$p")
    done

    if (( ${#USERS[@]} == 0 )); then
        yellow "未输入用户，使用默认用户 ding"
        USERS+=("ding")
        PASSWDS+=("$(date +%s%N | md5sum | cut -c 1-10)")
    fi
}

prompt_site() {
    read -rp "请输入 SNI/证书域名 [默认 ${DEFAULT_SNI}]: " SNI
    SNI="${SNI:-$DEFAULT_SNI}"

    read -rp "请输入伪装网站完整 URL [默认 ${DEFAULT_MASQ_URL}]: " MASQ_URL
    MASQ_URL="${MASQ_URL:-$DEFAULT_MASQ_URL}"
    if [[ ! "$MASQ_URL" =~ ^https?:// ]]; then
        red "伪装网站必须写完整 URL，例如 https://www.bing.com"
        exit 1
    fi
}

install_acme_cert() {
    local domain="$1"
    local ip domain_ip

    ip="$(curl -s4m8 ip.sb -k || curl -s6m8 ip.sb -k || true)"
    domain_ip="$(curl -sm8 "https://ipget.net/?ip=${domain}" || true)"

    if [[ -n "$ip" && -n "$domain_ip" && "$ip" != "$domain_ip" ]]; then
        red "域名解析 IP (${domain_ip}) 与本机公网 IP (${ip}) 不一致"
        exit 1
    fi

    if [[ ! -d /root/.acme.sh ]]; then
        curl https://get.acme.sh | sh -s email="$(date +%s%N | md5sum | cut -c 1-12)@gmail.com"
    fi

    bash /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt
    if ! bash /root/.acme.sh/acme.sh --issue -d "${domain}" --standalone -k ec-256; then
        yellow "ACME 证书申请失败。"
        yellow "是否使用 --insecure 重试（仅在证书校验异常时建议）？"
        read -rp "请输入 [y/N]: " retry_insecure
        retry_insecure="${retry_insecure:-N}"
        if [[ "${retry_insecure,,}" =~ ^(y|yes)$ ]]; then
            bash /root/.acme.sh/acme.sh --issue -d "${domain}" --standalone -k ec-256 --insecure
        else
            red "证书申请失败，已取消不安全重试。"
            exit 1
        fi
    fi

    mkdir -p "${CONFIG_DIR}"
    bash /root/.acme.sh/acme.sh --install-cert -d "${domain}" \
        --key-file "${KEY_FILE}" \
        --fullchain-file "${CERT_FILE}" --ecc

    CERT_PATH="${CERT_FILE}"
    KEY_PATH="${KEY_FILE}"
}

prompt_cert_mode() {
    echo
    green "Hysteria 2 证书申请方式："
    echo "1) 自签证书（默认）"
    echo "2) acme 自动申请"
    echo "3) 自定义证书路径"

    read -rp "请输入选项 [1-3]: " cert_mode
    cert_mode="${cert_mode:-1}"

    case "$cert_mode" in
        2)
            read -rp "请输入需要申请证书的域名: " domain
            [[ -z "$domain" ]] && { red "域名不能为空"; exit 1; }
            SNI="$domain"
            install_acme_cert "$domain"
            CLIENT_INSECURE="false"
            ;;
        3)
            read -rp "请输入证书 crt 文件路径: " CERT_PATH
            read -rp "请输入私钥 key 文件路径: " KEY_PATH
            read -rp "请输入证书域名（SNI）: " SNI
            [[ -f "$CERT_PATH" && -f "$KEY_PATH" ]] || { red "证书或私钥不存在"; exit 1; }
            [[ -n "$SNI" ]] || { red "SNI 不能为空"; exit 1; }
            CLIENT_INSECURE="false"
            ;;
        *)
            mkdir -p "${CONFIG_DIR}"
            openssl ecparam -genkey -name prime256v1 -out "${KEY_FILE}"
            openssl req -new -x509 -days 36500 -key "${KEY_FILE}" -out "${CERT_FILE}" -subj "/CN=${SNI}"
            chmod 600 "${KEY_FILE}"
            chmod 644 "${CERT_FILE}"
            CERT_PATH="${CERT_FILE}"
            KEY_PATH="${KEY_FILE}"
            CLIENT_INSECURE="true"
            ;;
    esac
}

write_config() {
    mkdir -p "${CONFIG_DIR}"
    {
        echo "listen: :${PORT}"
        echo
        echo "tls:"
        echo "  cert: ${CERT_PATH}"
        echo "  key: ${KEY_PATH}"
        echo
        echo "quic:"
        echo "  initStreamReceiveWindow: 16777216"
        echo "  maxStreamReceiveWindow: 16777216"
        echo "  initConnReceiveWindow: 33554432"
        echo "  maxConnReceiveWindow: 33554432"
        echo
        echo "auth:"
        echo "  type: userpass"
        echo "  userpass:"
        for i in "${!USERS[@]}"; do
            echo "    ${USERS[$i]}: ${PASSWDS[$i]}"
        done
        echo
        echo "masquerade:"
        echo "  type: proxy"
        echo "  proxy:"
        echo "    url: ${MASQ_URL}"
        echo "    rewriteHost: true"
    } > "${CONFIG_FILE}"
}

write_service() {
    cat > "${SERVICE_FILE}" <<EOF_SERVICE
[Unit]
Description=Hysteria 2 Server
After=network.target

[Service]
Type=simple
ExecStart=${BIN_PATH} server --config ${CONFIG_FILE}
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF_SERVICE
}

apply_port_hop_rules() {
    local chain="HYSTERIA2_HOP"

    if need_cmd iptables; then
        iptables -t nat -N "${chain}" >/dev/null 2>&1 || true
        iptables -t nat -C PREROUTING -p udp -j "${chain}" >/dev/null 2>&1 || \
            iptables -t nat -A PREROUTING -p udp -j "${chain}" >/dev/null 2>&1 || true
        iptables -t nat -F "${chain}" >/dev/null 2>&1 || true
        if [[ -n "$FIRST_HOP_PORT" && -n "$END_HOP_PORT" ]]; then
            iptables -t nat -A "${chain}" -p udp --dport "${FIRST_HOP_PORT}:${END_HOP_PORT}" \
                -j DNAT --to-destination ":${PORT}" >/dev/null 2>&1 || true
        fi
    fi

    if need_cmd ip6tables; then
        ip6tables -t nat -N "${chain}" >/dev/null 2>&1 || true
        ip6tables -t nat -C PREROUTING -p udp -j "${chain}" >/dev/null 2>&1 || \
            ip6tables -t nat -A PREROUTING -p udp -j "${chain}" >/dev/null 2>&1 || true
        ip6tables -t nat -F "${chain}" >/dev/null 2>&1 || true
        if [[ -n "$FIRST_HOP_PORT" && -n "$END_HOP_PORT" ]]; then
            ip6tables -t nat -A "${chain}" -p udp --dport "${FIRST_HOP_PORT}:${END_HOP_PORT}" \
                -j DNAT --to-destination ":${PORT}" >/dev/null 2>&1 || true
        fi
    fi

    need_cmd netfilter-persistent && netfilter-persistent save >/dev/null 2>&1 || true
}

cleanup_port_hop_rules() {
    local chain="HYSTERIA2_HOP"

    if need_cmd iptables; then
        iptables -t nat -F "${chain}" >/dev/null 2>&1 || true
        iptables -t nat -D PREROUTING -p udp -j "${chain}" >/dev/null 2>&1 || true
        iptables -t nat -X "${chain}" >/dev/null 2>&1 || true
    fi
    if need_cmd ip6tables; then
        ip6tables -t nat -F "${chain}" >/dev/null 2>&1 || true
        ip6tables -t nat -D PREROUTING -p udp -j "${chain}" >/dev/null 2>&1 || true
        ip6tables -t nat -X "${chain}" >/dev/null 2>&1 || true
    fi

    need_cmd netfilter-persistent && netfilter-persistent save >/dev/null 2>&1 || true
}

get_public_ip() {
    local ip
    ip="$(curl -s4m8 ip.sb -k || true)"
    if [[ -z "$ip" ]]; then
        ip="$(curl -s6m8 ip.sb -k || true)"
    fi
    echo "$ip"
}

build_share_link() {
    local user="$1"
    local pass="$2"
    local server_host="$3"
    local server_port="$4"

    if [[ "${CLIENT_INSECURE}" == "true" ]]; then
        echo "hysteria2://${user}:${pass}@${server_host}:${server_port}/?insecure=1&sni=${SNI}#${user}"
    else
        echo "hysteria2://${user}:${pass}@${server_host}:${server_port}/?sni=${SNI}#${user}"
    fi
}

write_client_info() {
    local ip server_host server_port auth_line
    ip="$(get_public_ip)"
    server_port="$PORT"

    if [[ -n "$FIRST_HOP_PORT" ]]; then
        server_port="${PORT},${FIRST_HOP_PORT}-${END_HOP_PORT}"
    fi

    if [[ "$ip" == *":"* ]]; then
        server_host="[${ip}]"
    else
        server_host="$ip"
    fi

    auth_line="${USERS[0]}:${PASSWDS[0]}"

    mkdir -p "${INFO_DIR}"

    cat > "${CLIENT_YAML}" <<EOF_YAML
server: ${server_host}:${server_port}

auth: ${auth_line}

tls:
  sni: ${SNI}
  insecure: ${CLIENT_INSECURE}

quic:
  initStreamReceiveWindow: 16777216
  maxStreamReceiveWindow: 16777216
  initConnReceiveWindow: 33554432
  maxConnReceiveWindow: 33554432

fastOpen: true

socks5:
  listen: 127.0.0.1:5678
EOF_YAML

    if [[ -n "$FIRST_HOP_PORT" ]]; then
        cat >> "${CLIENT_YAML}" <<'EOF_HOP'

transport:
  udp:
    hopInterval: 30s
EOF_HOP
    fi

    cat > "${CLIENT_JSON}" <<EOF_JSON
{
  "server": "${server_host}:${server_port}",
  "auth": "${auth_line}",
  "tls": {
    "sni": "${SNI}",
    "insecure": ${CLIENT_INSECURE}
  },
  "quic": {
    "initStreamReceiveWindow": 16777216,
    "maxStreamReceiveWindow": 16777216,
    "initConnReceiveWindow": 33554432,
    "maxConnReceiveWindow": 33554432
  },
  "socks5": {
    "listen": "127.0.0.1:5678"
  }
}
EOF_JSON

    if [[ -n "$FIRST_HOP_PORT" ]]; then
        cat > "${CLIENT_JSON}" <<EOF_JSON_HOP
{
  "server": "${server_host}:${server_port}",
  "auth": "${auth_line}",
  "tls": {
    "sni": "${SNI}",
    "insecure": ${CLIENT_INSECURE}
  },
  "quic": {
    "initStreamReceiveWindow": 16777216,
    "maxStreamReceiveWindow": 16777216,
    "initConnReceiveWindow": 33554432,
    "maxConnReceiveWindow": 33554432
  },
  "socks5": {
    "listen": "127.0.0.1:5678"
  },
  "transport": {
    "udp": {
      "hopInterval": "30s"
    }
  }
}
EOF_JSON_HOP
    fi

    : > "${LINK_FILE}"
    for i in "${!USERS[@]}"; do
        build_share_link "${USERS[$i]}" "${PASSWDS[$i]}" "${server_host}" "${server_port}" >> "${LINK_FILE}"
    done
}

open_firewall() {
    if need_cmd ufw; then
        ufw allow "${PORT}/udp" >/dev/null 2>&1 || true
    fi
}

start_service() {
    systemctl daemon-reload
    systemctl enable hysteria-server.service >/dev/null 2>&1
    systemctl restart hysteria-server.service
}

show_result() {
    green "安装完成"
    yellow "配置文件: ${CONFIG_FILE}"
    yellow "客户端 YAML: ${CLIENT_YAML}"
    yellow "客户端 JSON: ${CLIENT_JSON}"
    yellow "分享链接: ${LINK_FILE}"
    echo
    cat "${LINK_FILE}"
}

install_main() {
    install_base_packages
    install_hysteria
    prompt_port_and_hop
    prompt_users
    prompt_site
    prompt_cert_mode
    write_config
    write_service
    apply_port_hop_rules
    open_firewall
    write_client_info
    start_service
    show_result
}

start_hysteria() {
    systemctl enable hysteria-server.service >/dev/null 2>&1 || true
    systemctl start hysteria-server.service
    green "hysteria-server 已启动"
}

stop_hysteria() {
    systemctl stop hysteria-server.service
    yellow "hysteria-server 已停止"
}

restart_hysteria() {
    systemctl restart hysteria-server.service
    green "hysteria-server 已重启"
}

uninstall_hysteria() {
    systemctl stop hysteria-server.service >/dev/null 2>&1 || true
    systemctl disable hysteria-server.service >/dev/null 2>&1 || true
    rm -f "${SERVICE_FILE}"
    rm -f "${BIN_PATH}"
    rm -rf "${CONFIG_DIR}" "${INFO_DIR}"

    cleanup_port_hop_rules

    systemctl daemon-reload
    green "已卸载 Hysteria 2"
}

add_user() {
    [[ -f "${CONFIG_FILE}" ]] || { red "未找到服务端配置: ${CONFIG_FILE}"; exit 1; }

    local new_user new_pass sni server
    read -rp "输入要添加的用户名: " new_user
    [[ -n "${new_user}" ]] || { red "用户名不能为空"; exit 1; }
    validate_username "${new_user}" || { red "用户名仅支持 1-32 位：字母、数字、点、下划线、短横线"; exit 1; }

    read -rsp "输入密码: " new_pass
    echo
    validate_password "${new_pass}" || { red "密码不能为空，且不能包含空白或 # : @ / ? &"; exit 1; }

    if grep -qE "^    ${new_user}:" "${CONFIG_FILE}"; then
        red "用户 ${new_user} 已存在"
        exit 1
    fi

    awk -v line="    ${new_user}: ${new_pass}" '
        {print}
        /^  userpass:$/ {print line}
    ' "${CONFIG_FILE}" > "${CONFIG_FILE}.tmp"
    mv "${CONFIG_FILE}.tmp" "${CONFIG_FILE}"

    sni="$(awk '/^[[:space:]]+sni:/{print $2; exit}' "${CLIENT_YAML}" 2>/dev/null || true)"
    server="$(awk '/^server:/{print $2; exit}' "${CLIENT_YAML}" 2>/dev/null || true)"
    if [[ -n "${server}" && -n "${sni}" ]]; then
        if grep -qE '^[[:space:]]+insecure:[[:space:]]+true$' "${CLIENT_YAML}" 2>/dev/null; then
            echo "hysteria2://${new_user}:${new_pass}@${server}/?insecure=1&sni=${sni}#${new_user}" >> "${LINK_FILE}"
        else
            echo "hysteria2://${new_user}:${new_pass}@${server}/?sni=${sni}#${new_user}" >> "${LINK_FILE}"
        fi
    fi

    restart_hysteria
    green "用户 ${new_user} 已添加"
}

rebuild_links_from_config() {
    [[ -f "${CONFIG_FILE}" && -f "${CLIENT_YAML}" ]] || return 0

    local sni server insecure_flag
    sni="$(awk '/^[[:space:]]+sni:/{print $2; exit}' "${CLIENT_YAML}" 2>/dev/null || true)"
    server="$(awk '/^server:/{print $2; exit}' "${CLIENT_YAML}" 2>/dev/null || true)"
    insecure_flag="$(awk '/^[[:space:]]+insecure:/{print $2; exit}' "${CLIENT_YAML}" 2>/dev/null || true)"
    [[ -n "${sni}" && -n "${server}" ]] || return 0

    : > "${LINK_FILE}"
    awk '
        /^  userpass:$/ {in=1; next}
        in && /^$/ {in=0}
        in && /^    [^:]+:/ {
            sub(/^    /, "", $0)
            print
        }
    ' "${CONFIG_FILE}" | while IFS= read -r kv; do
        local u p
        u="${kv%%:*}"
        p="${kv#*: }"
        if [[ "${insecure_flag}" == "true" ]]; then
            echo "hysteria2://${u}:${p}@${server}/?insecure=1&sni=${sni}#${u}" >> "${LINK_FILE}"
        else
            echo "hysteria2://${u}:${p}@${server}/?sni=${sni}#${u}" >> "${LINK_FILE}"
        fi
    done
}

delete_user() {
    [[ -f "${CONFIG_FILE}" ]] || { red "未找到服务端配置: ${CONFIG_FILE}"; exit 1; }
    local target_user
    read -rp "输入要删除的用户名: " target_user
    [[ -n "${target_user}" ]] || { red "用户名不能为空"; exit 1; }

    if ! awk -v u="${target_user}" '
        /^  userpass:$/ {in=1; next}
        in && /^$/ {in=0}
        in && $0 ~ "^    " u ":" {found=1}
        END {exit(found?0:1)}
    ' "${CONFIG_FILE}"; then
        red "用户 ${target_user} 不存在"
        exit 1
    fi

    cp -f "${CONFIG_FILE}" "${CONFIG_FILE}.bak"
    awk -v u="${target_user}" '
        /^  userpass:$/ {in=1; print; next}
        in && /^$/ {in=0; print; next}
        in && $0 ~ "^    " u ":" {next}
        {print}
    ' "${CONFIG_FILE}" > "${CONFIG_FILE}.tmp"
    mv "${CONFIG_FILE}.tmp" "${CONFIG_FILE}"

    local user_count
    user_count="$(awk '
        /^  userpass:$/ {in=1; next}
        in && /^$/ {in=0}
        in && /^    [^:]+:/ {c++}
        END {print c+0}
    ' "${CONFIG_FILE}")"
    if [[ "${user_count}" == "0" ]]; then
        red "至少需要保留 1 个用户，已回滚"
        mv "${CONFIG_FILE}.bak" "${CONFIG_FILE}"
        exit 1
    fi
    rm -f "${CONFIG_FILE}.bak"

    rebuild_links_from_config
    restart_hysteria
    green "用户 ${target_user} 已删除"
}

change_user_password() {
    [[ -f "${CONFIG_FILE}" ]] || { red "未找到服务端配置: ${CONFIG_FILE}"; exit 1; }
    local target_user new_pass
    read -rp "输入要修改密码的用户名: " target_user
    [[ -n "${target_user}" ]] || { red "用户名不能为空"; exit 1; }
    read -rsp "输入新密码: " new_pass
    echo
    validate_password "${new_pass}" || { red "密码不能为空，且不能包含空白或 # : @ / ? &"; exit 1; }

    if ! awk -v u="${target_user}" '
        /^  userpass:$/ {in=1; next}
        in && /^$/ {in=0}
        in && $0 ~ "^    " u ":" {found=1}
        END {exit(found?0:1)}
    ' "${CONFIG_FILE}"; then
        red "用户 ${target_user} 不存在"
        exit 1
    fi

    awk -v u="${target_user}" -v p="${new_pass}" '
        /^  userpass:$/ {in=1; print; next}
        in && /^$/ {in=0; print; next}
        in && $0 ~ "^    " u ":" {print "    " u ": " p; next}
        {print}
    ' "${CONFIG_FILE}" > "${CONFIG_FILE}.tmp"
    mv "${CONFIG_FILE}.tmp" "${CONFIG_FILE}"

    rebuild_links_from_config
    restart_hysteria
    green "用户 ${target_user} 密码已更新"
}

change_config() {
    [[ -f "${CONFIG_FILE}" ]] || { red "未找到服务端配置: ${CONFIG_FILE}"; exit 1; }

    echo "1) 修改监听端口"
    echo "2) 修改伪装 URL"
    echo "3) 修改 SNI（仅客户端文件）"
    read -rp "请选择 [1-3]: " c

    case "${c}" in
        1)
            local new_port old_server host_only server_suffix new_server
            read -rp "输入新端口 [1-65535]: " new_port
            if ! [[ "${new_port}" =~ ^[0-9]+$ ]] || (( new_port < 1 || new_port > 65535 )); then
                red "端口不合法"
                exit 1
            fi
            if port_in_use "${new_port}"; then
                red "端口 ${new_port} 已被占用"
                exit 1
            fi
            old_server="$(awk '/^server:/{print $2; exit}' "${CLIENT_YAML}" 2>/dev/null || true)"
            host_only="$(extract_server_host "${old_server}")"
            server_suffix="$(extract_server_suffix "${old_server}")"
            new_server="${host_only}:${new_port}${server_suffix}"
            load_hop_range_from_server "${old_server}"
            PORT="${new_port}"
            sed -i -E "s/^listen: :.*/listen: :${new_port}/" "${CONFIG_FILE}"
            [[ -n "${old_server}" ]] && sed -i -E "s#^server: .*#server: ${new_server}#" "${CLIENT_YAML}" || true
            [[ -n "${old_server}" ]] && sed -i -E "s#\"server\": \".*\"#\"server\": \"${new_server}\"#" "${CLIENT_JSON}" || true
            rebuild_links_from_config
            apply_port_hop_rules
            if need_cmd ufw; then
                ufw allow "${new_port}/udp" >/dev/null 2>&1 || true
            fi
            restart_hysteria
            green "端口已修改为 ${new_port}"
            ;;
        2)
            local new_url
            read -rp "输入新的伪装 URL (https://...): " new_url
            [[ "${new_url}" =~ ^https?:// ]] || { red "URL 格式错误"; exit 1; }
            sed -i -E "s#^[[:space:]]+url: .*#    url: ${new_url}#" "${CONFIG_FILE}"
            restart_hysteria
            green "伪装 URL 已更新"
            ;;
        3)
            local new_sni
            read -rp "输入新的 SNI: " new_sni
            [[ -n "${new_sni}" ]] || { red "SNI 不能为空"; exit 1; }
            sed -i -E "s#^[[:space:]]+sni: .*#  sni: ${new_sni}#" "${CLIENT_YAML}" 2>/dev/null || true
            sed -i -E "s#\"sni\": \".*\"#\"sni\": \"${new_sni}\"#" "${CLIENT_JSON}" 2>/dev/null || true
            sed -i -E "s#(sni=)[^#]+#\\1${new_sni}#" "${LINK_FILE}" 2>/dev/null || true
            green "客户端 SNI 已更新（服务端证书未自动重签）"
            ;;
        *)
            red "无效选项"
            exit 1
            ;;
    esac
}

show_info() {
    yellow "服务状态："
    systemctl --no-pager --full status hysteria-server.service | sed -n '1,12p' || true
    echo
    [[ -f "${CONFIG_FILE}" ]] && { yellow "服务端配置 ${CONFIG_FILE}"; cat "${CONFIG_FILE}"; echo; }
    [[ -f "${CLIENT_YAML}" ]] && { yellow "客户端 YAML ${CLIENT_YAML}"; cat "${CLIENT_YAML}"; echo; }
    [[ -f "${CLIENT_JSON}" ]] && { yellow "客户端 JSON ${CLIENT_JSON}"; cat "${CLIENT_JSON}"; echo; }
    [[ -f "${LINK_FILE}" ]] && { yellow "分享链接 ${LINK_FILE}"; cat "${LINK_FILE}"; echo; }
}

menu() {
    echo "=============================="
    echo "Hysteria 2 管理菜单"
    echo "1) 安装"
    echo "2) 卸载"
    echo "3) 启动服务"
    echo "4) 停止服务"
    echo "5) 重启服务"
    echo "6) 查看配置/链接"
    echo "7) 修改配置"
    echo "8) 添加用户"
    echo "9) 删除用户"
    echo "10) 修改用户密码"
    echo "0) 退出"
    echo "=============================="
    read -rp "请选择 [0-10]: " choice

    case "${choice}" in
        1) install_main ;;
        2) uninstall_hysteria ;;
        3) start_hysteria ;;
        4) stop_hysteria ;;
        5) restart_hysteria ;;
        6) show_info ;;
        7) change_config ;;
        8) add_user ;;
        9) delete_user ;;
        10) change_user_password ;;
        0) exit 0 ;;
        *) red "无效选项"; exit 1 ;;
    esac
}

menu
