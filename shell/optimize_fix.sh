#!/usr/bin/env bash

# 颜色配置
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'  # 无颜色

# 检测系统发行版
if [[ -f /etc/redhat-release ]]; then
    release="centos"
elif cat /etc/issue | grep -q -E -i "debian|raspbian"; then
    release="debian"
elif cat /etc/issue | grep -q -E -i "ubuntu"; then
    release="ubuntu"
elif cat /etc/issue | grep -q -E -i "centos|red hat|redhat"; then
    release="centos"
elif cat /proc/version | grep -q -E -i "raspbian|debian"; then
    release="debian"
elif cat /proc/version | grep -q -E -i "ubuntu"; then
    release="ubuntu"
elif cat /proc/version | grep -q -E -i "centos|red hat|redhat"; then
    release="centos"
else
    echo -e "${RED}不支持的操作系统！${NC}"
    exit 1
fi

# 更新系统
if [[ ${release} == "centos" ]]; then
    yum makecache
    yum install epel-release -y
    yum update -y
else
    apt update -y
    apt autoremove --purge -y
fi

backup_dir="/etc/backup_tcp_tuning"

# 备份配置文件
backup_config() {
    mkdir -p "$backup_dir"
    cp /etc/sysctl.conf "$backup_dir/sysctl.conf.bak"
    cp /etc/security/limits.conf "$backup_dir/limits.conf.bak"
    cp /etc/systemd/journald.conf "$backup_dir/journald.conf.bak"
    echo -e "${GREEN}[信息] 配置文件已备份到 $backup_dir${NC}"
}

# 恢复备份的源函数
recovery_cof() {
    if [[ -f "$backup_dir/sysctl.conf.bak" ]]; then
        cp "$backup_dir/sysctl.conf.bak" /etc/sysctl.conf
        cp "$backup_dir/limits.conf.bak" /etc/security/limits.conf
        cp "$backup_dir/journald.conf.bak" /etc/systemd/journald.conf
    else
        echo -e "${YELLOW}开始备份${NC}"
    fi
}

# 恢复原始配置
restore_config() {
    if [[ -f "$backup_dir/sysctl.conf.bak" ]]; then
        cp "$backup_dir/sysctl.conf.bak" /etc/sysctl.conf
        cp "$backup_dir/limits.conf.bak" /etc/security/limits.conf
        cp "$backup_dir/journald.conf.bak" /etc/systemd/journald.conf
        sysctl --system
        echo -e "${GREEN}[信息] 原始配置已恢复${NC}"
    else
        echo -e "${RED}[错误] 备份文件不存在，无法恢复${NC}"
    fi
    exit 0
}

# 配置优化参数
optimize_system() {
    # 获取系统架构和内存信息
    memory_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    memory_mb=$((memory_kb / 1024))

    # 计算优化参数
    fs_file_max=$((memory_mb * 256))
    fs_file_max=$((fs_file_max > 4194304 ? 4194304 : fs_file_max))

    conntrack_max=$((memory_mb * 32))
    conntrack_max=$((conntrack_max > 4194304 ? 4194304 : conntrack_max))  # 10Gbps 调整上限

    buckets=$((conntrack_max / 8))

    rmem_max=$((memory_mb * 1024 * 8))  # 提高缓冲区
    rmem_max=$((rmem_max > 67108864 ? 67108864 : rmem_max))  # 10Gbps 调整上限

    wmem_max=$((memory_mb * 1024 * 8))
    wmem_max=$((wmem_max > 67108864 ? 67108864 : wmem_max))

    netdev_max_backlog=$((memory_mb * 128))
    netdev_max_backlog=$((netdev_max_backlog > 262144 ? 262144 : netdev_max_backlog))  # 10Gbps 上限

    somaxconn=$((memory_mb * 16))
    somaxconn=$((somaxconn > 65535 ? 65535 : somaxconn))

    tcp_max_tw_buckets=$((memory_mb * 8))  # 适当提高 TIME_WAIT 连接数
    tcp_max_tw_buckets=$((tcp_max_tw_buckets > 2097152 ? 2097152 : tcp_max_tw_buckets))  # 10Gbps 上限

    # 配置 sysctl
    cat > /etc/sysctl.conf << EOF
fs.file-max = $fs_file_max

# 增强网络缓冲区
net.core.rmem_max = $rmem_max
net.core.wmem_max = $wmem_max
net.core.netdev_max_backlog = $netdev_max_backlog
net.core.somaxconn = $somaxconn

# 启用 IP 转发
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.forwarding = 1

# TCP 连接优化
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 16384 67108864
net.ipv4.udp_mem = 4096 87380 4194304
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_max_tw_buckets = $tcp_max_tw_buckets
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 2
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_rfc1337 = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_ecn = 1
net.ipv4.tcp_fack = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_adv_win_scale = 2

# NAT 连接追踪优化
net.netfilter.nf_conntrack_max = $conntrack_max
net.netfilter.nf_conntrack_buckets = $buckets
net.netfilter.nf_conntrack_tcp_timeout_established = 600
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 120
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 60
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 60
net.netfilter.nf_conntrack_tcp_timeout_syn_recv = 30
net.netfilter.nf_conntrack_tcp_be_liberal = 1

# 默认使用 fq 调度器
net.core.default_qdisc = fq

# 其他优化
vm.swappiness = 0
vm.overcommit_memory = 1
vm.dirty_ratio = 20
vm.dirty_background_ratio = 5
EOF

    # 配置文件句柄和进程限制
    cat > /etc/security/limits.conf << EOF
* soft nofile $fs_file_max
* hard nofile $fs_file_max
* soft nproc $fs_file_max
* hard nproc $fs_file_max
root soft nofile $fs_file_max
root hard nofile $fs_file_max
root soft nproc $fs_file_max
root hard nproc $fs_file_max
EOF

    # 配置 systemd 日志限制
    cat > /etc/systemd/journald.conf << EOF
[Journal]
SystemMaxUse=384M
SystemMaxFileSize=128M
ForwardToSyslog=no
EOF

    # 应用优化参数
    echo -e "${GREEN}[信息] 正在应用 TCP 优化参数...${NC}"

    # 加载 nf_conntrack 模块
    if ! lsmod | grep -q nf_conntrack; then
        modprobe nf_conntrack && echo -e "${GREEN}nf_conntrack 模块已加载${NC}"
    fi

    # 确保模块在启动时加载
    if ! grep -q "nf_conntrack" /etc/modules-load.d/nf_conntrack.conf; then
        echo "nf_conntrack" >> /etc/modules-load.d/nf_conntrack.conf
        echo -e "${GREEN}nf_conntrack 已添加到开机加载${NC}"
    fi
    
    sysctl --system

    echo -e "${GREEN}[信息] TCP 调优完成！${NC}"
    exit 0
}

echo -e "${BLUE}请选择操作：${NC}"
echo "1. TCP 调优"
echo "2. 恢复原始配置"
echo "0. 退出脚本"
read -rp "请输入选项（1/2/0）: " option

case "$option" in
    1)
        recovery_cof
        backup_config
        optimize_system
        ;;
    2)
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
