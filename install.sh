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
DEFAULT_MASQ_URL="https://www.bing.com"

need_cmd() {
    command -v "$1" >/dev/null 2>&1
}

install_base_packages() {
    if need_cmd apt-get; then
        apt-get update
        apt-get install -y curl wget openssl ufw
    elif need_cmd yum; then
        yum -y install curl wget openssl
    else
        red "不支持的系统，未找到 apt-get 或 yum"
        exit 1
    fi
}

detect_arch() {
    local arch
    arch="$(uname -m)"
    case "$arch" in
        x86_64|amd64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        armv7l|armv7) echo "armv7" ;;
        *)
            red "暂不支持的架构: $arch"
            exit 1
            ;;
    esac
}

install_hysteria() {
    local arch url
    arch="$(detect_arch)"
    url="https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${arch}"

    green "下载 Hysteria2 二进制..."
    wget -O "${BIN_PATH}" "${url}"
    chmod +x "${BIN_PATH}"

    green "当前版本："
    "${BIN_PATH}" version
}

prompt_config() {
    read -rp "请输入监听端口 [默认 3032]: " PORT
    PORT="${PORT:-3032}"

    if ! [[ "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then
        red "端口不合法"
        exit 1
    fi

    read -rp "请输入用户名 [默认 ding]: " USERNAME
    USERNAME="${USERNAME:-ding}"

    if [[ -z "$USERNAME" ]]; then
        red "用户名不能为空"
        exit 1
    fi

    read -rsp "请输入密码: " PASSWORD
    echo
    if [[ -z "$PASSWORD" ]]; then
        red "密码不能为空"
        exit 1
    fi

    read -rp "请输入 SNI/证书域名 [默认 ${DEFAULT_SNI}]: " SNI
    SNI="${SNI:-$DEFAULT_SNI}"

    read -rp "请输入伪装网站完整 URL [默认 ${DEFAULT_MASQ_URL}]: " MASQ_URL
    MASQ_URL="${MASQ_URL:-$DEFAULT_MASQ_URL}"

    if [[ ! "$MASQ_URL" =~ ^https?:// ]]; then
        red "伪装网站必须写完整 URL，例如 https://www.bing.com"
        exit 1
    fi
}

generate_cert() {
    mkdir -p "${CONFIG_DIR}"

    green "生成自签证书..."
    openssl ecparam -genkey -name prime256v1 -out "${KEY_FILE}"
    openssl req -new -x509 -days 36500 \
        -key "${KEY_FILE}" \
        -out "${CERT_FILE}" \
        -subj "/CN=${SNI}"

    chmod 600 "${KEY_FILE}"
    chmod 644 "${CERT_FILE}"
}

write_config() {
    cat > "${CONFIG_FILE}" <<EOF
listen: :${PORT}

tls:
  cert: ${CERT_FILE}
  key: ${KEY_FILE}

quic:
  initStreamReceiveWindow: 16777216
  maxStreamReceiveWindow: 16777216
  initConnReceiveWindow: 33554432
  maxConnReceiveWindow: 33554432

auth:
  type: userpass
  userpass:
    ${USERNAME}: ${PASSWORD}

masquerade:
  type: proxy
  proxy:
    url: ${MASQ_URL}
    rewriteHost: true
EOF
}

write_service() {
    cat > "${SERVICE_FILE}" <<EOF
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
EOF
}

get_public_ip() {
    local ip=""
    ip="$(curl -4 -s --max-time 8 https://api.ipify.org || true)"
    if [[ -z "$ip" ]]; then
        ip="$(curl -4 -s --max-time 8 https://ip.sb || true)"
    fi
    echo "$ip"
}

write_client_info() {
    local public_ip
    public_ip="$(get_public_ip)"
    mkdir -p "${INFO_DIR}"

    cat > "${CLIENT_YAML}" <<EOF
server: ${public_ip}:${PORT}

auth: ${USERNAME}:${PASSWORD}

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
EOF

    cat > "${CLIENT_JSON}" <<EOF
{
  "server": "${public_ip}:${PORT}",
  "auth": "${USERNAME}:${PASSWORD}",
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
EOF

    echo "hysteria2://${USERNAME}:${PASSWORD}@${public_ip}:${PORT}/?insecure=1&sni=${SNI}#${USERNAME}" > "${LINK_FILE}"
}

open_firewall() {
    if need_cmd ufw; then
        ufw allow "${PORT}/udp" || true
    fi
}

start_service() {
    systemctl daemon-reload
    systemctl enable hysteria-server.service
    systemctl restart hysteria-server.service
}

show_result() {
    green "安装完成"
    echo
    yellow "服务状态："
    systemctl --no-pager --full status hysteria-server.service | sed -n '1,12p'
    echo
    yellow "服务端配置文件：${CONFIG_FILE}"
    yellow "客户端 YAML：${CLIENT_YAML}"
    yellow "客户端 JSON：${CLIENT_JSON}"
    yellow "分享链接：${LINK_FILE}"
    echo
    green "分享链接："
    cat "${LINK_FILE}"
}

main() {
    install_base_packages
    prompt_config
    install_hysteria
    generate_cert
    write_config
    write_service
    open_firewall
    write_client_info
    start_service
    show_result
}

main