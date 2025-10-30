#!/bin/bash

## 变量定义
IX_IP="165.101.144.137"
IX_GATEWAY="165.101.144.1"
IX_SDWAN_IP="192.168.80.12"
IX_Intranet_IP=＂10.0.0.7＂
HK_IP="192.168.80.13" 
IX_TABLE="ix_return"
IX_TABLE_ID="100"
IX_MARK="100"

## 创建路由表
if ! grep -q "$IX_TABLE" /etc/iproute2/rt_tables; then
    echo "$IX_TABLE_ID $IX_TABLE" >> /etc/iproute2/rt_tables
fi

## 清理现有配置
# 删除默认路由
ip route del default via 165.101.144.1 dev ens18 2>/dev/null

# 清理旧的策略路由规则
ip rule del from $IX_IP table $IX_TABLE 2>/dev/null
ip rule del fwmark $IX_MARK table $IX_TABLE 2>/dev/null
ip route flush table $IX_TABLE

## 配置新路由

# 设置默认路由走 ens20（主动出站流量）
ip route add default via $IX_SDWAN_IP dev ens20

# 配置 IX 回程路由表
ip route add default via $IX_GATEWAY dev ens18 table $IX_TABLE
ip route add 165.101.144.0/24 dev ens18 src $IX_IP table $IX_TABLE
ip route add 192.168.80.0/24 dev ens20 src $IX_SDWAN_IP table $IX_TABLE
ip route add 10.0.0.0/24 dev ens19 src $IX_Intranet_IP table $IX_TABLE

# 添加策略路由规则
# 源 IP 为 IX 地址的流量使用 ix_return 表
ip rule add from $IX_IP table $IX_TABLE priority 100

# 配置 iptables 连接跟踪
# 清理旧规则
iptables -t mangle -D PREROUTING -i ens18 -j CONNMARK --set-mark $IX_MARK 2>/dev/null
iptables -t mangle -D OUTPUT -j CONNMARK --restore-mark 2>/dev/null

# 添加新规则
iptables -t mangle -A PREROUTING -i ens18 -j CONNMARK --set-mark $IX_MARK
iptables -t mangle -A OUTPUT -j CONNMARK --restore-mark

# 基于连接标记的策略路由
ip rule add fwmark $IX_MARK table $IX_TABLE priority 99

# ====================== 调整反向路径过滤 ======================
sysctl -w net.ipv4.conf.ens18.rp_filter=2
sysctl -w net.ipv4.conf.ens20.rp_filter=2
sysctl -w net.ipv4.conf.all.rp_filter=2

# ====================== 刷新路由缓存 ======================
ip route flush cache

echo "============== 配置完成 ==============="
echo "默认路由: ens20 → $ENS20_GATEWAY"
echo "IX回程: ens18 → $IX_GATEWAY"
echo "策略路由表: $IX_TABLE (ID: $IX_TABLE_ID)"
echo "连接标记: $IX_MARK"
