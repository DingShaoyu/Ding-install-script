# copy.sh 与 install.sh 配置对比

结论：两者**不是仅差“多用户 + 不做端口跳转”**，还存在若干行为差异。

## 核心结论

1. **认证方式确实不同**
   - `copy.sh` 使用 `password`（单密码）认证。
   - `install.sh` 使用 `userpass`（用户名:密码）认证。

2. **端口跳跃确实被移除**
   - `copy.sh` 支持 `iptables`/`ip6tables` 的 UDP 端口段 DNAT 跳跃。
   - `install.sh` 仅单端口监听，并通过 `ufw allow <port>/udp` 放行。

3. **证书流程不一样（不只是多用户）**
   - `copy.sh` 有三种证书模式：自签、acme 自动申请、自定义路径。
   - `install.sh` 仅自动生成自签证书（CN 为输入 SNI，默认 `www.bing.com`）。

4. **安装来源和服务文件写法不同**
   - `copy.sh` 拉取第三方 `install_server.sh` 执行安装。
   - `install.sh` 直接下载 GitHub release 二进制并自己写 systemd service。

5. **客户端输出细节不同**
   - `copy.sh` 在客户端 YAML/JSON 里带 `transport.udp.hopInterval: 30s`（配合端口跳跃）。
   - `install.sh` 不含 `transport.udp`（因为无端口跳跃）。

6. **运维能力不同**
   - `copy.sh` 还有启动/停止/重启、改端口、改密码、卸载等菜单能力。
   - `install.sh` 是一次性安装脚本，不含这些管理菜单。

## 关于 “copy 是否支持 IPv6”

结论：**支持，但属于“部分支持”**。

1. `copy.sh` 会尝试获取 IPv4，失败再取 IPv6（`realip`）。
2. 生成客户端地址时，如果检测到 IPv6，会给地址加 `[]`，这点是正确做法。
3. 开启端口跳跃时，同时写了 `iptables` 和 `ip6tables` 的 NAT 规则。
4. 但在普通模式下，它并没有显式配置放行 IPv6 UDP 端口的防火墙策略，且实际监听/可达性还受系统网络与云厂商安全组影响，所以不算“全链路自动化 IPv6”。

## 你的 IP `45.76.68.74` 的判断

- `45.76.68.74` 是标准 **IPv4** 地址，不是 IPv6。
- 你当前 `install.sh` 的公网 IP 发现逻辑使用 `curl -4`，因此在 IPv4 VPS 上“天生可用”这个判断是对的。
- 也就是说：在你这台只用 IPv4 的机器上，现版本并不会因为缺少 IPv6 逻辑而影响基本使用。

## 如果你想做到“除多用户外完全对齐”

建议你在 `install.sh` 里再补齐以下能力（按优先级）：

1. 证书选项（acme / 自定义证书路径）。
2. 端口冲突检测（当前仅校验范围，不检查端口是否被占用）。
3. IPv6 地址输出处理（当前只取 IPv4 公网地址）。
4. 管理/卸载脚本（可拆成独立子命令）。
5. 可选端口跳跃（即便默认关闭，也可保留开关）。
