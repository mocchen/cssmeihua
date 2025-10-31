#!/bin/bash
#
# SNAT 管理脚本 (优化版 + 交互式输入允许IP)
#

set -euo pipefail

# ---------- 颜色定义 ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

# ---------- 全局变量 ----------
INTERNAL_IF="${INTERNAL_IF:-ens20}"
EXTERNAL_IF="${EXTERNAL_IF:-ens18}"
IPTABLES_SAVE_PATH="/etc/iptables/rules.v4"
DEFAULT_ALLOWED_IPS=()

# ---------- 日志函数 ----------
log()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ---------- 公共函数 ----------
require_root() { (( EUID == 0 )) || { err "请使用 root 权限运行"; exit 1; }; }

check_if() {
    local ifname="$1"
    ip link show "$ifname" &>/dev/null || { err "网卡 $ifname 不存在"; exit 1; }
}

get_ip_cidr() {
    ip -o -f inet addr show "$1" | awk '{print $4}'
}

get_ip() {
    get_ip_cidr "$1" | cut -d'/' -f1
}

save_rules() {
    mkdir -p "$(dirname "$IPTABLES_SAVE_PATH")"
    iptables-save > "$IPTABLES_SAVE_PATH"
    log "iptables 规则已保存至 $IPTABLES_SAVE_PATH"
}

# ---------- SNAT 初始化 ----------
init_snat() {
    require_root
    check_if "$INTERNAL_IF"
    check_if "$EXTERNAL_IF"

    # 交互式输入允许的IP
    read -p "请输入允许转发的IP（空格分隔，例如 192.168.1.12 192.168.1.0/24）: " input_ips
    DEFAULT_ALLOWED_IPS=($input_ips)
    if [ ${#DEFAULT_ALLOWED_IPS[@]} -eq 0 ]; then
        warn "未输入任何IP，初始化将不会允许任何内网IP"
    fi

    local internal_net external_ip
    internal_net=$(get_ip_cidr "$INTERNAL_IF")
    external_ip=$(get_ip "$EXTERNAL_IF")

    log "内网网段: $internal_net"
    log "外网 IP: $external_ip"

    echo 1 > /proc/sys/net/ipv4/ip_forward
    grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf || echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf

    # 清除旧规则
    iptables -t nat -D POSTROUTING -s "$internal_net" -o "$EXTERNAL_IF" -j SNAT --to-source "$external_ip" 2>/dev/null || true

    # 设置策略
    iptables -P FORWARD DROP
    iptables -C FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
        iptables -I FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT

    # 添加允许IP
    for ip in "${DEFAULT_ALLOWED_IPS[@]}"; do add_ip "$ip" "silent"; done

    # 拒绝其他IP
    iptables -C FORWARD -i "$INTERNAL_IF" -o "$EXTERNAL_IF" -j REJECT 2>/dev/null || \
        iptables -A FORWARD -i "$INTERNAL_IF" -o "$EXTERNAL_IF" -j REJECT --reject-with icmp-host-prohibited

    # SNAT
    iptables -t nat -A POSTROUTING -s "$internal_net" -o "$EXTERNAL_IF" -j SNAT --to-source "$external_ip"

    save_rules
    log "SNAT 初始化完成"
}

# ---------- 添加/删除 ----------
add_ip() {
    require_root
    local ip="${1:-}" mode="${2:-show}"
    [[ -z "$ip" ]] && { err "请指定 IP"; return 1; }

    if iptables -C FORWARD -s "$ip" -i "$INTERNAL_IF" -o "$EXTERNAL_IF" -j ACCEPT 2>/dev/null; then
        [[ "$mode" == "show" ]] && warn "$ip 已存在"
        return 0
    fi

    iptables -I FORWARD 2 -s "$ip" -i "$INTERNAL_IF" -o "$EXTERNAL_IF" -j ACCEPT
    [[ "$mode" == "show" ]] && log "已添加允许转发 IP: $ip"
    save_rules
}

del_ip() {
    require_root
    local ip="${1:-}"
    [[ -z "$ip" ]] && { err "请指定 IP"; return 1; }

    iptables -D FORWARD -s "$ip" -i "$INTERNAL_IF" -o "$EXTERNAL_IF" -j ACCEPT 2>/dev/null || {
        warn "$ip 不存在"; return 0;
    }
    log "已删除 $ip"
    save_rules
}

# ---------- 列出规则 ----------
list_ips() {
    echo ""
    log "当前允许转发的 IP："
    echo "------------------------------------"
    iptables -L FORWARD -n -v | awk "/$EXTERNAL_IF/ && /ACCEPT/ && !/state RELATED,ESTABLISHED/"'{print NR".",$8}'
    echo "------------------------------------"
    echo ""
    log "SNAT 规则:"
    iptables -t nat -L POSTROUTING -n -v | grep "$EXTERNAL_IF" || warn "未检测到 SNAT 规则"
}

# ---------- 清除 ----------
clear_all() {
    require_root
    read -p "确认清除所有 SNAT 配置？(yes/no): " ans
    [[ "$ans" != "yes" ]] && { log "操作已取消"; return; }

    local internal_net external_ip
    internal_net=$(get_ip_cidr "$INTERNAL_IF")
    external_ip=$(get_ip "$EXTERNAL_IF")

    iptables -t nat -D POSTROUTING -s "$internal_net" -o "$EXTERNAL_IF" -j SNAT --to-source "$external_ip" 2>/dev/null || true
    iptables -F FORWARD
    iptables -P FORWARD ACCEPT
    save_rules
    log "SNAT 规则已清除"
}

# ---------- 帮助 ----------
show_help() {
cat <<EOF
${GREEN}SNAT 管理脚本 (优化版 + 交互式输入IP)${NC}

用法:
  $0 init                 初始化 SNAT 配置 (会提示输入允许转发IP)
  $0 add <IP>             添加允许转发 IP
  $0 del <IP>             删除允许转发 IP
  $0 list                 列出当前允许转发的 IP
  $0 clear                清除所有 SNAT 规则
  $0 help                 显示帮助信息

环境变量:
  INTERNAL_IF=${INTERNAL_IF}
  EXTERNAL_IF=${EXTERNAL_IF}

EOF
}

# ---------- 主逻辑 ----------
cmd="${1:-help}"
case "$cmd" in
    init) init_snat ;;
    add)  add_ip "${2:-}" ;;
    del|delete|remove) del_ip "${2:-}" ;;
    list|ls) list_ips ;;
    clear|reset) clear_all ;;
    help|-h|--help|*) show_help ;;
esac
