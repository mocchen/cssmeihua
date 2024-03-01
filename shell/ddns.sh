#!/bin/bash

# 输出字体颜色
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[0;33m"
NC="\033[0m"
GREEN_ground="\033[42;37m" # 全局绿色
RED_ground="\033[41;37m"   # 全局红色
Info="${GREEN}[信息]${NC}"
Error="${RED}[错误]${NC}"
Tip="${YELLOW}[提示]${NC}"

# 版权信息
cop_info(){
clear
echo -e "${GREEN}######################################
#           ${RED}DDNS 一键脚本            ${GREEN}#
#           作者: ${YELLOW}末晨                ${GREEN}#
######################################${NC}"
echo
}

# 检查是否为root用户
check_root(){
    if [[ $(whoami) != "root" ]]; then
        echo -e "${Error}请以root身份执行该脚本！"
        exit 1
    fi
}

# 开始安装DDNS
install_ddns(){
    if [ ! -f "/usr/bin/ddns" ]; then
        curl -o /usr/bin/ddns 脚本url && chmod +x /usr/bin/ddns
    fi
    mkdir -p /etc/DDNS
    cat <<'EOF' > /etc/DDNS/DDNS
#!/bin/bash

# 引入环境变量文件
source /etc/DDNS/.config

# 更新IPv4 DNS记录
curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$Zone_id/dns_records/$DNS_IDv4" \
     -H "X-Auth-Email: $Email" \
     -H "X-Auth-Key: $Api_key" \
     -H "Content-Type: application/json" \
     --data "{\"type\":\"A\",\"name\":\"$Domain\",\"content\":\"$Public_IPv4\"}" >/dev/null 2>&1

# 更新IPv6 DNS记录
curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$Zone_id/dns_records/$DNS_IDv6" \
     -H "X-Auth-Email: $Email" \
     -H "X-Auth-Key: $Api_key" \
     -H "Content-Type: application/json" \
     --data "{\"type\":\"AAAA\",\"name\":\"$Domain\",\"content\":\"$Public_IPv6\"}" >/dev/null 2>&1
EOF
    cat <<'EOF' > /etc/DDNS/.config
Domain="your_domain.com"		# 你要解析的域名
Email="your_email@gmail.com"     # 你在Cloudflare注册的邮箱
Api_key="your_api_key"  # 你的Cloudflare API密钥

# 获取根域名
Root_domain=$(echo "$Domain" | cut -d'.' -f2-)

# 获取公网IP地址
regex_pattern='^(eth|ens|eno|esp|enp)[0-9]+'

InterFace=($(ip link show | awk -F': ' '{print $2}' | grep -E "$regex_pattern" | sed "s/@.*//g"))

Public_IPv4=""
Public_IPv6=""

for i in "${InterFace[@]}"; do
    ipv4=$(curl -s4m8 --interface "$i" api64.ipify.org -k | sed '/^\(2a09\|104\.28\)/d')
    ipv6=$(curl -s6m8 --interface "$i" api64.ipify.org -k | sed '/^\(2a09\|104\.28\)/d')
    
    # 检查是否获取到IP地址
    if [[ -n "$ipv4" ]]; then
        Public_IPv4="$ipv4"
    fi
    
    if [[ -n "$ipv6" ]]; then
        Public_IPv6="$ipv6"
    fi
done

# 使用Cloudflare API获取根域名的区域ID
Zone_id=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$Root_domain" \
     -H "X-Auth-Email: $Email" \
     -H "X-Auth-Key: $Api_key" \
     -H "Content-Type: application/json" \
     | grep -Po '(?<="id":")[^"]*' | head -1)

# 获取IPv4 DNS记录ID
DNS_IDv4=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$Zone_id/dns_records?type=A&name=$Domain" \
     -H "X-Auth-Email: $Email" \
     -H "X-Auth-Key: $Api_key" \
     -H "Content-Type: application/json" \
     | grep -Po '(?<="id":")[^"]*' | head -1)

# 获取IPv6 DNS记录ID
DNS_IDv6=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$Zone_id/dns_records?type=AAAA&name=$Domain" \
     -H "X-Auth-Email: $Email" \
     -H "X-Auth-Key: $Api_key" \
     -H "Content-Type: application/json" \
     | grep -Po '(?<="id":")[^"]*' | head -1)
EOF
    echo -e "${Info}DDNS 安装完成！"
    echo
}

# 检查 DDNS 状态
check_ddns_status(){
    if [[ -f "/etc/systemd/system/ddns.timer" ]]; then
        STatus=$(systemctl status ddns.timer | grep Active | awk '{print $3}' | cut -d "(" -f2 | cut -d ")" -f1)
        if [[ $STatus =~ "waiting"|"running" ]]; then
            ddns_status=running
        else
            ddns_status=dead
        fi
    fi
}

# 后续操作
go_ahead(){
    echo -e "${Tip}选择一个选项：
  ${GREEN}0${NC}：退出
  ${GREEN}1${NC}：重启 DDNS
  ${GREEN}2${NC}：${RED}卸载 DDNS${NC}
  ${GREEN}3${NC}：修改要解析的域名
  ${GREEN}4${NC}：修改 Cloudflare Api"
    echo
    read -p "选项: " option
    until [[ "$option" =~ ^[0-4]$ ]]; do
        echo -e "${Error}请输入正确的数字 [0-4]"
        echo
        exit 1
    done
    case "$option" in
        0)
            exit 1
        ;;
        1)
            restart_ddns
            check_ddns_install
        ;;
        2)
            systemctl disable ddns.service ddns.timer >/dev/null 2>&1
            systemctl stop ddns.service ddns.timer >/dev/null 2>&1
            rm -rf /etc/systemd/system/ddns.service /etc/systemd/system/ddns.timer /etc/DDNS /usr/bin/ddns
            echo -e "${Info}DDNS 已卸载！"
            echo
        ;;
        3)
            set_domain
            restart_ddns
            sleep 2
            check_ddns_install
        ;;
        4)
            set_cloudflare_api
            set_domain
            if [ ! -f "/etc/systemd/system/ddns.service" ] || [ ! -f "/etc/systemd/system/ddns.timer" ]; then
                run_ddns
                sleep 2
            else
               restart_ddns
               sleep 2
            fi
            check_ddns_install
        ;;
    esac
}

# 配置Cloudflare Api
set_cloudflare_api(){
    echo -e "${Tip}开始配置CloudFlare API..."
    echo

    echo -e "${Tip}请输入您的Cloudflare邮箱"
    read -rp "邮箱: " EMail
    if [ -z "$EMail" ]; then
        echo -e "${Error}未输入邮箱，无法执行操作！"
        exit 1
    else
        EMAIL="$EMail"
    fi
    echo -e "${Info}你的邮箱：${RED_ground}${EMAIL}${NC}"
    echo

    echo -e "${Tip}请输入您的Cloudflare API密钥"
    read -rp "密钥: " Api_Key
    if [ -z "Api_Key" ]; then
        echo -e "${Error}未输入密钥，无法执行操作！"
        exit 1
    else
        API_KEY="$Api_Key"
    fi
    echo -e "${Info}你的密钥：${RED_ground}${API_KEY}${NC}"
    echo

    sed -i 's/^#\?Email=".*"/Email="'"${EMAIL}"'"/g' /etc/DDNS/.config
    sed -i 's/^#\?Api_key=".*"/Api_key="'"${API_KEY}"'"/g' /etc/DDNS/.config
}

# 配置解析的域名
set_domain(){
    echo -e "${Tip}请输入您解析的域名"
    read -rp "域名: " DOmain
    if [ -z "$DOmain" ]; then
        echo -e "${Error}未输入域名，无法执行操作！"
        exit 1
    else
        DOMAIN="$DOmain"
    fi
    echo -e "${Info}你的域名：${RED_ground}${DOMAIN}${NC}"
    echo

    sed -i 's/^#\?Domain=".*"/Domain="'"${DOMAIN}"'"/g' /etc/DDNS/.config
}

# 运行DDNS服务
run_ddns(){
    service='[Unit]
Description=ddns
After=network.target

[Service]
Type=simple
WorkingDirectory=/etc/DDNS
ExecStart=bash DDNS

[Install]
WantedBy=multi-user.target'

    timer='[Unit]
Description=ddns timer

[Timer]
OnUnitActiveSec=60s
Unit=ddns.service

[Install]
WantedBy=multi-user.target'

    if [ ! -f "/etc/systemd/system/ddns.service" ] || [ ! -f "/etc/systemd/system/ddns.timer" ]; then
        echo -e "${Info}创建ddns定时任务..."
        echo "$service" >/etc/systemd/system/ddns.service
        echo "$timer" >/etc/systemd/system/ddns.timer
        echo -e "${Info}ddns定时任务已创建，每1分钟执行一次！"
        systemctl enable --now ddns.service >/dev/null 2>&1
        systemctl enable --now ddns.timer >/dev/null 2>&1
    else
        echo -e "${Tip}服务和定时器单元文件已存在，无需再次创建！"
    fi
}

# 重启DDNS服务
restart_ddns(){
    systemctl restart ddns.service >/dev/null 2>&1
    systemctl restart ddns.timer >/dev/null 2>&1
}

# 检查是否安装DDNS
check_ddns_install(){
    if [ ! -f "/etc/DDNS/.config" ]; then
        cop_info
        echo -e "${Tip}DDNS 未安装，现在开始安装..."
        echo
        install_ddns
        set_cloudflare_api
        set_domain
        run_ddns
        echo -e "${Info}执行 ${GREEN}ddns${NC} 可呼出菜单！"
    else
        cop_info
        check_ddns_status
        if [[ "$ddns_status" == "running" ]]; then
            echo -e "${Info}DDNS：${GREEN}已安装${NC} 并 ${GREEN}已启动${NC}"
        else
            echo -e "${Tip}DDNS：${GREEN}已安装${NC} 但 ${RED}未启动${NC}"
            echo -e "${Tip}请选择 ${GREEN}4${NC} 重新配置 Cloudflare Api"
        fi
    echo
    go_ahead
    fi
}

check_root
check_ddns_install
