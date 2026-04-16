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

declare -a USERS=()
declare -a PASSWDS=()

need_cmd() {
    command -v "$1" >/dev/null 2>&1
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
        read -rsp "密码: " p
        echo
        if [[ -z "$p" ]]; then
            red "密码不能为空"
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
    bash /root/.acme.sh/acme.sh --issue -d "${domain}" --standalone -k ec-256 --insecure

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
            ;;
        3)
            read -rp "请输入证书 crt 文件路径: " CERT_PATH
            read -rp "请输入私钥 key 文件路径: " KEY_PATH
            read -rp "请输入证书域名（SNI）: " SNI
            [[ -f "$CERT_PATH" && -f "$KEY_PATH" ]] || { red "证书或私钥不存在"; exit 1; }
            [[ -n "$SNI" ]] || { red "SNI 不能为空"; exit 1; }
            ;;
        *)
            mkdir -p "${CONFIG_DIR}"
            openssl ecparam -genkey -name prime256v1 -out "${KEY_FILE}"
            openssl req -new -x509 -days 36500 -key "${KEY_FILE}" -out "${CERT_FILE}" -subj "/CN=${SNI}"
            chmod 600 "${KEY_FILE}"
            chmod 644 "${CERT_FILE}"
            CERT_PATH="${CERT_FILE}"
            KEY_PATH="${KEY_FILE}"
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
    if [[ -n "$FIRST_HOP_PORT" && -n "$END_HOP_PORT" ]]; then
        need_cmd iptables && iptables -t nat -A PREROUTING -p udp --dport "${FIRST_HOP_PORT}:${END_HOP_PORT}" -j DNAT --to-destination ":${PORT}" || true
        need_cmd ip6tables && ip6tables -t nat -A PREROUTING -p udp --dport "${FIRST_HOP_PORT}:${END_HOP_PORT}" -j DNAT --to-destination ":${PORT}" || true
        need_cmd netfilter-persistent && netfilter-persistent save >/dev/null 2>&1 || true
    fi
}

get_public_ip() {
    local ip
    ip="$(curl -s4m8 ip.sb -k || true)"
    if [[ -z "$ip" ]]; then
        ip="$(curl -s6m8 ip.sb -k || true)"
    fi
    echo "$ip"
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
  insecure: true

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
    "insecure": true
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
    "insecure": true
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
        echo "hysteria2://${USERS[$i]}:${PASSWDS[$i]}@${server_host}:${server_port}/?insecure=1&sni=${SNI}#${USERS[$i]}" >> "${LINK_FILE}"
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

main() {
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

main
