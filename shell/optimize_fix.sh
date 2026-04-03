#!/usr/bin/env bash

# 颜色配置
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SYSCTL_FILE="/etc/sysctl.conf"
LIMITS_FILE="/etc/security/limits.d/99-tcp-tuning.conf"
JOURNALD_FILE="/etc/systemd/journald.conf.d/99-tcp-tuning.conf"
MODULES_FILE="/etc/modules-load.d/nf_conntrack.conf"
backup_dir="/etc/backup_tcp_tuning"

# 函数: require_root
# 作用: 检查是否以 root 运行，非 root 直接退出
require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}[错误] 需要 root 权限执行此脚本。${NC}"
        exit 1
    fi
}

# 函数: detect_os
# 作用: 识别发行版类型，未知则退出
detect_os() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        case "$ID" in
            debian|ubuntu|raspbian)
                release="$ID"
                ;;
            centos|rhel|rocky|almalinux)
                release="centos"
                ;;
            *)
                release="unknown"
                ;;
        esac
    else
        release="unknown"
    fi

    if [[ "$release" == "debian" && "$VERSION_ID" == "13" ]]; then
        SYSCTL_FILE="/etc/sysctl.d/99-sysctl.conf"
    else
        SYSCTL_FILE="/etc/sysctl.conf"
    fi

    if [[ "$release" == "unknown" ]]; then
        echo -e "${RED}不支持的操作系统！${NC}"
        exit 1
    fi
}

# 函数: update_system
# 作用: 按发行版更新软件包
update_system() {
    if [[ ${release} == "centos" ]]; then
        yum makecache
        yum install -y epel-release
        yum -y update
    else
        apt update
        apt -y upgrade
        apt -y autoremove --purge
    fi
}

# 函数: backup_once
# 作用: 仅在未备份时保存指定文件
backup_once() {
    local src="$1"
    local dst="$backup_dir/$(basename "$src").bak"
    if [[ -f "$src" && ! -f "$dst" ]]; then
        cp "$src" "$dst"
    fi
}

# 函数: backup_all
# 作用: 备份脚本相关配置文件
backup_all() {
    mkdir -p "$backup_dir"
    backup_once "$SYSCTL_FILE"
    backup_once "$LIMITS_FILE"
    backup_once "$JOURNALD_FILE"
    backup_once "$MODULES_FILE"
    echo -e "${GREEN}[信息] 已备份当前配置（如有）到 $backup_dir${NC}"
}

# 函数: restore_config
# 作用: 恢复备份配置；无备份则提示并跳过
restore_config() {
    local restored=0

    if [[ -f "$backup_dir/$(basename "$SYSCTL_FILE").bak" ]]; then
        cp "$backup_dir/$(basename "$SYSCTL_FILE").bak" "$SYSCTL_FILE"
        restored=1
    else
        echo -e "${YELLOW}[提示] 未找到 $SYSCTL_FILE 备份，已跳过处理${NC}"
    fi

    if [[ -f "$backup_dir/$(basename "$LIMITS_FILE").bak" ]]; then
        cp "$backup_dir/$(basename "$LIMITS_FILE").bak" "$LIMITS_FILE"
        restored=1
    else
        echo -e "${YELLOW}[提示] 未找到 $LIMITS_FILE 备份，已跳过处理${NC}"
    fi

    if [[ -f "$backup_dir/$(basename "$JOURNALD_FILE").bak" ]]; then
        cp "$backup_dir/$(basename "$JOURNALD_FILE").bak" "$JOURNALD_FILE"
        restored=1
    else
        echo -e "${YELLOW}[提示] 未找到 $JOURNALD_FILE 备份，已跳过处理${NC}"
    fi

    if [[ -f "$backup_dir/$(basename "$MODULES_FILE").bak" ]]; then
        cp "$backup_dir/$(basename "$MODULES_FILE").bak" "$MODULES_FILE"
        restored=1
    else
        echo -e "${YELLOW}[提示] 未找到 $MODULES_FILE 备份，已跳过处理${NC}"
    fi

    if sysctl --system >/dev/null 2>&1; then
        echo -e "${GREEN}[信息] 已恢复并应用 sysctl 配置${NC}"
    else
        echo -e "${YELLOW}[警告] sysctl 应用时有部分参数未生效（可能内核不支持）${NC}"
    fi

    systemctl restart systemd-journald 2>/dev/null || true

    if [[ $restored -eq 1 ]]; then
        echo -e "${GREEN}[信息] 原始配置已恢复${NC}"
    else
        echo -e "${YELLOW}[提示] 未找到备份，已移除该脚本写入的配置${NC}"
    fi
    exit 0
}

# 函数: calc_bdp_bytes
# 作用: 根据目标带宽与 RTT 估算带宽-时延积（BDP），并乘以安全系数作为缓冲上限参考
calc_bdp_bytes() {
    local bw_mbps="$1"
    local rtt_ms="$2"
    local factor="$3"

    if [[ -z "$bw_mbps" || -z "$rtt_ms" || -z "$factor" ]]; then
        echo 0
        return
    fi

    awk -v bw="$bw_mbps" -v rtt="$rtt_ms" -v factor="$factor" 'BEGIN {
        bytes_per_sec = bw * 1000000 / 8
        bdp = bytes_per_sec * (rtt / 1000)
        printf "%.0f", bdp * factor
    }'
}

# 函数: clamp_value
# 作用: 将数值限制在指定范围内
clamp_value() {
    local value="$1"
    local min="$2"
    local max="$3"

    if (( value < min )); then
        echo "$min"
    elif (( value > max )); then
        echo "$max"
    else
        echo "$value"
    fi
}

# 函数: calc_params
# 作用: 计算并收敛各档位参数，按统一上限策略进行高 RTT 吞吐优化
calc_params() {
    local memory_kb memory_mb bdp_bytes bdp_cap_by_mem
    memory_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
    memory_mb=$((memory_kb / 1024))

    fs_file_max=$((memory_mb * 256))
    if [[ $fs_file_max -gt 2097152 ]]; then
        fs_file_max=2097152
    fi

    bdp_bytes=$(calc_bdp_bytes "$target_bw_mbps" "$target_rtt_ms" 3)
    if [[ -z "$bdp_bytes" || "$bdp_bytes" -le 0 ]]; then
        bdp_bytes=33554432
    fi

    bdp_cap_by_mem=$((memory_mb * 1024 * 1024 / 8))
    if [[ $bdp_cap_by_mem -lt 16777216 ]]; then
        bdp_cap_by_mem=16777216
    fi
    if [[ $bdp_cap_by_mem -gt 268435456 ]]; then
        bdp_cap_by_mem=268435456
    fi
    if [[ $bdp_bytes -gt $bdp_cap_by_mem ]]; then
        bdp_bytes=$bdp_cap_by_mem
    fi

    case "$profile" in
        minimal)
            rmem_max=$((memory_mb * 1024 * 10))
            wmem_max=$((memory_mb * 1024 * 10))
            if [[ $rmem_max -gt 16777216 ]]; then rmem_max=16777216; fi
            if [[ $wmem_max -gt 16777216 ]]; then wmem_max=16777216; fi
            rmem_default=262144
            wmem_default=262144
            tcp_rmem_mid=524288
            tcp_wmem_mid=524288
            netdev_max_backlog=$((memory_mb * 64))
            if [[ $netdev_max_backlog -gt 65536 ]]; then netdev_max_backlog=65536; fi
            somaxconn=$((memory_mb * 4))
            if [[ $somaxconn -gt 32768 ]]; then somaxconn=32768; fi
            tcp_fin_timeout=20
            tcp_syn_retries=4
            tcp_synack_retries=4
            tcp_max_syn_backlog=8192
            tcp_tw_reuse=0
            tcp_fastopen=0
            tcp_ecn=0
            tcp_moderate_rcvbuf=1
            ;;
        conservative)
            rmem_max=$((memory_mb * 1024 * 18))
            wmem_max=$((memory_mb * 1024 * 18))
            if [[ $rmem_max -gt 33554432 ]]; then rmem_max=33554432; fi
            if [[ $wmem_max -gt 33554432 ]]; then wmem_max=33554432; fi
            if [[ $memory_mb -lt 2048 ]]; then
                rmem_default=524288
                wmem_default=524288
            else
                rmem_default=1048576
                wmem_default=1048576
            fi
            tcp_rmem_mid=4194304
            tcp_wmem_mid=1048576
            if [[ $bdp_bytes -gt $rmem_max ]]; then rmem_max=$bdp_bytes; fi
            if [[ $bdp_bytes -gt $wmem_max ]]; then wmem_max=$bdp_bytes; fi
            netdev_max_backlog=$((memory_mb * 128))
            if [[ $netdev_max_backlog -gt 131072 ]]; then netdev_max_backlog=131072; fi
            somaxconn=$((memory_mb * 8))
            if [[ $somaxconn -gt 65535 ]]; then somaxconn=65535; fi
            tcp_fin_timeout=15
            tcp_syn_retries=3
            tcp_synack_retries=3
            tcp_max_syn_backlog=16384
            tcp_tw_reuse=0
            tcp_fastopen=0
            tcp_ecn=0
            tcp_moderate_rcvbuf=1
            ;;
        aggressive)
            rmem_max=$((memory_mb * 1024 * 32))
            wmem_max=$((memory_mb * 1024 * 32))
            if [[ $rmem_max -gt 134217728 ]]; then rmem_max=134217728; fi
            if [[ $wmem_max -gt 134217728 ]]; then wmem_max=134217728; fi
            if [[ $bdp_bytes -gt $rmem_max ]]; then rmem_max=$bdp_bytes; fi
            if [[ $bdp_bytes -gt $wmem_max ]]; then wmem_max=$bdp_bytes; fi
            if [[ $memory_mb -lt 4096 ]]; then
                rmem_default=1048576
                wmem_default=1048576
            else
                rmem_default=2097152
                wmem_default=2097152
            fi
            tcp_rmem_mid=8388608
            tcp_wmem_mid=2097152
            netdev_max_backlog=$((memory_mb * 256))
            if [[ $netdev_max_backlog -gt 262144 ]]; then netdev_max_backlog=262144; fi
            somaxconn=$((memory_mb * 16))
            if [[ $somaxconn -gt 65535 ]]; then somaxconn=65535; fi
            tcp_fin_timeout=10
            tcp_syn_retries=2
            tcp_synack_retries=2
            tcp_max_syn_backlog=65535
            tcp_tw_reuse=1
            tcp_fastopen=3
            tcp_ecn=1
            tcp_moderate_rcvbuf=1
            ;;
        *)
            echo -e "${RED}[错误] 未知配置档位${NC}"
            exit 1
            ;;
    esac

    rmem_max=$(clamp_value "$rmem_max" 8388608 268435456)
    wmem_max=$(clamp_value "$wmem_max" 8388608 268435456)
    tcp_rmem_mid=$(clamp_value "$tcp_rmem_mid" 262144 "$rmem_max")
    tcp_wmem_mid=$(clamp_value "$tcp_wmem_mid" 262144 "$wmem_max")

    conntrack_max=65536
    conntrack_buckets=8192
    conntrack_established=600
    conntrack_time_wait=120
    conntrack_close_wait=60
    conntrack_fin_wait=60
    conntrack_syn_recv=30
    conntrack_udp_timeout=30
    conntrack_udp_timeout_stream=120
}

# 函数: supports_bbr
# 作用: 检测内核是否支持 BBR
supports_bbr() {
    if [[ -f /proc/sys/net/ipv4/tcp_available_congestion_control ]]; then
        grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control
    else
        return 1
    fi
}

# 函数: supports_fq
# 作用: 检测并尝试加载 fq 调度器
supports_fq() {
    if lsmod | grep -q '^sch_fq'; then
        return 0
    fi
    modprobe sch_fq >/dev/null 2>&1
}

# 函数: enable_conntrack
# 作用: 检测并尝试加载 nf_conntrack 模块
enable_conntrack() {
    if lsmod | grep -q nf_conntrack; then
        return 0
    fi
    modprobe nf_conntrack >/dev/null 2>&1
}

# 函数: write_sysctl
# 作用: 生成 sysctl 配置内容并写入 sysctl 配置文件
write_sysctl() {
    if [[ "$SYSCTL_FILE" == /etc/sysctl.d/* ]]; then
        mkdir -p /etc/sysctl.d
    fi

    local content
    content="fs.file-max = $fs_file_max

# 网络缓冲区
net.core.rmem_default = $rmem_default
net.core.wmem_default = $wmem_default
net.core.rmem_max = $rmem_max
net.core.wmem_max = $wmem_max
net.core.netdev_max_backlog = $netdev_max_backlog
net.core.somaxconn = $somaxconn
net.core.optmem_max = 262144
net.core.netdev_budget = 1200
net.core.netdev_budget_usecs = 16000

# TCP 连接优化
net.ipv4.tcp_rmem = 4096 $tcp_rmem_mid $rmem_max
net.ipv4.tcp_wmem = 4096 $tcp_wmem_mid $wmem_max
net.ipv4.tcp_fin_timeout = $tcp_fin_timeout
net.ipv4.tcp_max_syn_backlog = $tcp_max_syn_backlog
net.ipv4.tcp_tw_reuse = $tcp_tw_reuse
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = $tcp_fastopen
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_synack_retries = $tcp_synack_retries
net.ipv4.tcp_syn_retries = $tcp_syn_retries
net.ipv4.tcp_rfc1337 = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_moderate_rcvbuf = $tcp_moderate_rcvbuf
net.ipv4.tcp_no_metrics_save = 0
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_adv_win_scale = 1
net.ipv4.tcp_notsent_lowat = 262144
net.ipv4.tcp_ecn = $tcp_ecn

"

    content+="
# UDP
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384

# ICMP 限速
net.ipv4.icmp_ratelimit = 100
net.ipv4.icmp_ratemask = 88089
"

    if [[ $enable_forwarding -eq 1 ]]; then
        content+="
# IP 转发
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.forwarding = 1
"
    fi

    if supports_bbr; then
        content+="
# 拥塞控制
net.ipv4.tcp_congestion_control = bbr
"
    fi

    if supports_fq; then
        content+="
# 默认队列调度
net.core.default_qdisc = fq
"
    fi

    if enable_conntrack; then
        content+="
# NAT 连接追踪
net.netfilter.nf_conntrack_max = $conntrack_max
net.netfilter.nf_conntrack_buckets = $conntrack_buckets
net.netfilter.nf_conntrack_tcp_timeout_established = $conntrack_established
net.netfilter.nf_conntrack_tcp_timeout_time_wait = $conntrack_time_wait
net.netfilter.nf_conntrack_tcp_timeout_close_wait = $conntrack_close_wait
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = $conntrack_fin_wait
net.netfilter.nf_conntrack_tcp_timeout_syn_recv = $conntrack_syn_recv
net.netfilter.nf_conntrack_tcp_be_liberal = 1
net.netfilter.nf_conntrack_udp_timeout = $conntrack_udp_timeout
net.netfilter.nf_conntrack_udp_timeout_stream = $conntrack_udp_timeout_stream
"
    fi

    if [[ "$profile" == "aggressive" ]]; then
        content+="
# 系统内存策略
vm.swappiness = 0
vm.overcommit_memory = 1
vm.dirty_ratio = 20
vm.dirty_background_ratio = 5
"
    elif [[ "$profile" == "conservative" ]]; then
        content+="
# 系统内存策略
vm.swappiness = 10
vm.overcommit_memory = 0
vm.dirty_ratio = 20
vm.dirty_background_ratio = 5
"
    fi

    printf "%s" "$content" > "$SYSCTL_FILE"
}

# 函数: write_limits
# 作用: 写入进程与文件句柄限制
write_limits() {
    mkdir -p /etc/security/limits.d

    local nofile_max nproc_max
    nofile_max=$fs_file_max
    if [[ $nofile_max -gt 1048576 ]]; then
        nofile_max=1048576
    fi
    nproc_max=65535

    cat > "$LIMITS_FILE" << EOF
* soft nofile $nofile_max
* hard nofile $nofile_max
* soft nproc $nproc_max
* hard nproc $nproc_max
root soft nofile $nofile_max
root hard nofile $nofile_max
root soft nproc $nproc_max
root hard nproc $nproc_max
EOF
}

# 函数: write_journald
# 作用: 写入 journald 限制配置
write_journald() {
    mkdir -p /etc/systemd/journald.conf.d

    cat > "$JOURNALD_FILE" << EOF
[Journal]
SystemMaxUse=384M
SystemMaxFileSize=128M
ForwardToSyslog=no
EOF
}

# 函数: persist_modules
# 作用: 持久化需要的内核模块加载
persist_modules() {
    if enable_conntrack; then
        mkdir -p /etc/modules-load.d
        echo "nf_conntrack" > "$MODULES_FILE"
    fi
}

# 函数: apply_config
# 作用: 应用 sysctl 并重启 journald
apply_config() {
    echo -e "${GREEN}[信息] 正在应用配置...${NC}"

    if sysctl --system >/dev/null 2>&1; then
        echo -e "${GREEN}[信息] sysctl 已应用${NC}"
    else
        echo -e "${YELLOW}[警告] sysctl 应用时有部分参数未生效（可能内核不支持）${NC}"
    fi

    systemctl restart systemd-journald 2>/dev/null || true
    echo -e "${GREEN}[信息] 配置完成${NC}"
}

require_root
detect_os

read -rp "是否需要更新系统软件包？[y/N]: " do_update
if [[ -n "$do_update" && ! "$do_update" =~ ^[YyNn]$ ]]; then
    echo -e "${RED}[错误] 请输入 y 或 n${NC}"
    exit 1
fi
if [[ "$do_update" =~ ^[Yy]$ ]]; then
    update_system
fi

echo -e "${BLUE}请选择调优档位：${NC}"
echo "1. 最小修改（更保守）"
echo "2. 保守（推荐）"
echo "3. 激进（高性能，可能影响稳定性）"
echo "4. 恢复原始配置"
echo "0. 退出脚本"
read -rp "请输入选项（1/2/3/4/0）: " option
if [[ ! "$option" =~ ^[0-4]$ ]]; then
    echo -e "${RED}[错误] 请输入有效的选项！${NC}"
    exit 1
fi

case "$option" in
    1)
        profile="minimal"
        ;;
    2)
        profile="conservative"
        ;;
    3)
        profile="aggressive"
        ;;
    4)
        restore_config
        ;;
    0)
        echo -e "${GREEN}[信息] 退出脚本${NC}"
        exit 0
        ;;
    *)
        echo -e "${RED}[错误] 请输入有效的选项！${NC}"
        exit 1
        ;;
esac

echo -e "${BLUE}高 RTT 吞吐优化目标（默认按 1Gbps 设计）：${NC}"
read -rp "目标 RTT（毫秒，默认 150）: " target_rtt_ms
if [[ -z "$target_rtt_ms" ]]; then
    target_rtt_ms=150
elif [[ ! "$target_rtt_ms" =~ ^[0-9]+$ ]] || [[ "$target_rtt_ms" -le 0 ]]; then
    echo -e "${RED}[错误] RTT 请输入正整数毫秒值${NC}"
    exit 1
fi

read -rp "目标带宽（Mbps，默认 1000）: " target_bw_mbps
if [[ -z "$target_bw_mbps" ]]; then
    target_bw_mbps=1000
elif [[ ! "$target_bw_mbps" =~ ^[0-9]+$ ]] || [[ "$target_bw_mbps" -le 0 ]]; then
    echo -e "${RED}[错误] 目标带宽请输入正整数 Mbps${NC}"
    exit 1
fi

read -rp "是否开启 IP 转发（路由/NAT 场景）？[y/N]: " forwarding
if [[ -n "$forwarding" && ! "$forwarding" =~ ^[YyNn]$ ]]; then
    echo -e "${RED}[错误] 请输入 y 或 n${NC}"
    exit 1
fi
if [[ "$forwarding" =~ ^[Yy]$ ]]; then
    enable_forwarding=1
else
    enable_forwarding=0
fi

backup_all
calc_params
write_sysctl
write_limits
write_journald
persist_modules
apply_config

echo -e "${GREEN}[信息] 已按 RTT=${target_rtt_ms}ms、目标带宽=${target_bw_mbps}Mbps 生成调优参数${NC}"
echo -e "${YELLOW}[提示] 想接近跑满 1Gbps，系统调优只是其中一环；还取决于网卡 offload、队列、ISP/链路质量、对端拥塞控制与应用层并发。${NC}"

exit 0
