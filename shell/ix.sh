#!/bin/bash
set -euo pipefail

# ---------- 固定配置 ----------
ENS18="ens18"                     # 用于 ix 网段的接口
ENS20="ens20"                     # 用于 sdwan 的接口
GATEWAY165="165.101.144.1"        # ix 网关
RT_TABLE_ID="100"                 # 路由表ID
RT_TABLE_NAME="ix-route"          # 路由表名

# ---------- 手动输入配置区域 ----------
echo "=== 网络策略路由配置脚本 ==="
echo "固定配置："
echo "  - ix网段接口: $ENS18"
echo "  - sdwan接口: $ENS20" 
echo "  - ix网关: $GATEWAY165"
echo "  - 路由表ID: $RT_TABLE_ID"
echo "  - 路由表名: $RT_TABLE_NAME"
echo

read -p "请输入ix入口IP地址: " IP165
if [ -z "$IP165" ]; then
    echo "错误：必须输入ix入口IP地址"
    exit 1
fi

read -p "请输入ix在内网的IP地址 [192.168.80.x]: " IP192
IP192=${IP192:-192.168.80.12}

read -p "请输入香港出口的内网IP: " GATEWAY_B
if [ -z "$GATEWAY_B" ]; then
    echo "错误：必须输入香港出口的内网IP"
    exit 1
fi

# 服务配置
SERVICE_NAME="net-policy-165.service"
SERVICE_SCRIPT="/usr/local/sbin/net-policy-165.sh"
SYSCTL_CONF="/etc/sysctl.d/99-rpfilter-165.conf"

# 显示配置摘要
echo
echo "=== 配置摘要 ==="
echo "固定配置："
echo "  - ix网段接口: $ENS18"
echo "  - sdwan接口: $ENS20"
echo "  - ix网关: $GATEWAY165"
echo "  - 路由表ID: $RT_TABLE_ID"
echo "  - 路由表名: $RT_TABLE_NAME"
echo "手动输入："
echo "  - ix入口IP地址: $IP165"
echo "  - ix在内网的IP地址: $IP192"
echo "  - 香港出口的内网IP: $GATEWAY_B"
echo
read -p "确认以上配置是否正确？(y/N): " CONFIRM
if [[ ! $CONFIRM =~ ^[Yy]$ ]]; then
    echo "配置已取消"
    exit 0
fi

echo "==> 开始配置..."

# ---------- 1) 接口校验 ----------
echo "==> 校验网络接口..."
ip -o link show "$ENS18" >/dev/null || { echo "错误：接口 $ENS18 不存在"; exit 1; }
ip -o link show "$ENS20" >/dev/null || { echo "错误：接口 $ENS20 不存在"; exit 1; }

# ---------- 2) 设置 rp_filter（并持久化） ----------
echo "==> 配置rp_filter..."
cat > "$SYSCTL_CONF" <<EOF
# loosen rp_filter to support asymmetric routing for ix<>sdwan scenario
net.ipv4.conf.all.rp_filter=2
net.ipv4.conf.default.rp_filter=2
net.ipv4.conf.$ENS18.rp_filter=2
net.ipv4.conf.$ENS20.rp_filter=2
EOF

echo "应用 sysctl 配置..."
sysctl --system >/dev/null

# ---------- 3) 在 /etc/iproute2/rt_tables 添加自定义表 ----------
echo "==> 配置路由表..."
if ! grep -qE "^[[:space:]]*$RT_TABLE_ID[[:space:]]+$RT_TABLE_NAME" /etc/iproute2/rt_tables 2>/dev/null; then
  echo "$RT_TABLE_ID $RT_TABLE_NAME" >> /etc/iproute2/rt_tables
  echo "已添加路由表：$RT_TABLE_ID $RT_TABLE_NAME"
else
  echo "路由表 $RT_TABLE_NAME 已存在，跳过添加"
fi

# ---------- 4) 配置 runtime 路由与规则 ----------
echo "==> 配置运行时路由规则..."

# 先删除可能存在的旧规则（避免重复）
ip rule delete from "$IP165" table "$RT_TABLE_NAME" 2>/dev/null || true
ip route flush table "$RT_TABLE_NAME" 2>/dev/null || true

# 在自定义表里添加通过 ens18 的默认路由（用于 ix 源流量）
ip route add default via "$GATEWAY165" dev "$ENS18" table "$RT_TABLE_NAME"
# 添加 policy rule：来自 ix 的包使用 ix-route 表
ip rule add from "$IP165" table "$RT_TABLE_NAME" priority 1000

# 设置主路由表的默认路由走香港出口（ens20）
ip route replace default via "$GATEWAY_B" dev "$ENS20"

echo "运行时路由配置完成。"

# ---------- 5) 显示当前配置状态 ----------
echo
echo "=== 当前路由规则 ==="
ip rule show | grep -E "(1000|$RT_TABLE_NAME)" || echo "未找到相关规则"

echo
echo "=== 自定义路由表内容 ==="
ip route show table "$RT_TABLE_NAME" || echo "路由表 $RT_TABLE_NAME 为空"

echo
echo "=== 主路由表默认路由 ==="
ip route show | grep "^default" || echo "未找到默认路由"

# ---------- 6) 写 systemd 服务脚本（开机自动生效） ----------
echo
echo "==> 创建systemd服务..."
mkdir -p /usr/local/sbin

cat > "$SERVICE_SCRIPT" <<EOF
#!/bin/bash
set -euo pipefail

# 固定配置
ENS18="$ENS18"
ENS20="$ENS20"
GATEWAY165="$GATEWAY165"
RT_TABLE_ID="$RT_TABLE_ID"
RT_TABLE_NAME="$RT_TABLE_NAME"

# 手动输入配置
IP165="$IP165"
GATEWAY_B="$GATEWAY_B"

echo "应用网络策略路由配置..."

# 应用 sysctl 配置
sysctl --system >/dev/null

# 确保自定义路由表存在
if ! grep -qE "^[[:space:]]*${RT_TABLE_ID}[[:space:]]+${RT_TABLE_NAME}" /etc/iproute2/rt_tables 2>/dev/null; then
  echo "${RT_TABLE_ID} ${RT_TABLE_NAME}" >> /etc/iproute2/rt_tables
fi

# 清理旧规则
ip rule delete from "\$IP165" table "\$RT_TABLE_NAME" 2>/dev/null || true
ip route flush table "\$RT_TABLE_NAME" 2>/dev/null || true

# 添加策略路由
ip route add default via "\$GATEWAY165" dev "\$ENS18" table "\$RT_TABLE_NAME"
ip rule add from "\$IP165" table "\$RT_TABLE_NAME" priority 1000

# 设置主路由表默认路由
ip route replace default via "\$GATEWAY_B" dev "\$ENS20"

echo "网络策略路由配置完成"
EOF

chmod +x "$SERVICE_SCRIPT"

# 创建 systemd 服务文件
cat > /etc/systemd/system/$SERVICE_NAME <<EOF
[Unit]
Description=Apply policy routing for ix asymmetric routing
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$SERVICE_SCRIPT
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now "$SERVICE_NAME"

echo "systemd 服务 $SERVICE_NAME 已创建并启用"

# ---------- 7) 完成提示 ----------
echo
echo "=== 配置完成 ==="
echo "✅ 策略路由已配置并持久化"
echo
echo "📋 配置详情："
echo "   - ix网段接口: $ENS18"
echo "   - sdwan接口: $ENS20"
echo "   - ix入口IP地址: $IP165"
echo "   - ix网关: $GATEWAY165"
echo "   - 香港出口的内网IP: $GATEWAY_B"
echo "   - 路由表: $RT_TABLE_NAME (ID: $RT_TABLE_ID)"
echo
echo "🔍 验证命令："
echo "   ip rule show | grep 1000"
echo "   ip route show table $RT_TABLE_NAME"
echo "   ip route show | grep default"
echo
echo "🌐 测试建议："
echo "   1. 从外部测试连接到 $IP165"
echo "   2. 在本机运行: curl ifconfig.me （应该显示香港出口的公网IP）"
echo "   3. 使用 tcpdump 监控流量路径："
echo "      tcpdump -i $ENS18 -n host $IP165"
echo "      tcpdump -i $ENS20 -n host $GATEWAY_B"
echo
