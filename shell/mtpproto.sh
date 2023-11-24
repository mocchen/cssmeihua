#!/bin/bash

Red="\033[31m" # 红色
Green="\033[32m" # 绿色
Yellow="\033[33m" # 黄色
Blue="\033[34m" # 蓝色
Nc="\033[0m" # 重置颜色
Red_globa="\033[41;37m" # 红底白字
Green_globa="\033[42;37m" # 绿底白字
Yellow_globa="\033[43;37m" # 黄底白字
Blue_globa="\033[44;37m" # 蓝底白字
Info="${Green}[信息]${Nc}"
Error="${Red}[错误]${Nc}"
Tip="${Yellow}[提示]${Nc}"

mtproxy_dir="/usr/local/MTProxy"
mtproxy_file="${mtproxy_dir}/mtproxy"
mtproxy_conf="${mtproxy_dir}/config.toml"
mtproxy_log="${mtproxy_dir}/mtproxy.log"
Old_ver_file="${mtproxy_dir}/ver.txt"

# 检查是否为root用户
check_root(){
    if [[ $(whoami) != "root" ]]; then
        echo -e "${Error} 当前非ROOT账号(或没有ROOT权限)，无法继续操作，请更换ROOT账号或使用 ${Green_globa}sudo -i${Nc} 命令获取临时ROOT权限（执行后可能会提示输入当前账号的密码）。"
        exit 1
    fi
}

# 安装依赖
install_base(){
    if ! command -v wget &>/dev/null || ! command -v tar &>/dev/null || ! command -v ntpdate &>/dev/null; then
        echo -e "${Info} 开始安装依赖软件！"
        OS=$(cat /etc/os-release | grep -o -E "Debian|Ubuntu|CentOS" | head -n 1)
        if [[ "$OS" == "Debian" || "$OS" == "Ubuntu" ]]; then
            apt update -y
            apt install -y wget tar ntpdate
            ntpdate time.google.com
        elif [[ "$OS" == "CentOS" ]]; then
            yum update -y
            yum install -y wget tar ntpdate
            ntpdate time.google.com
        else
        echo -e "${Error}很抱歉，你的系统不受支持！"
        exit 1
        fi
    fi
}

# 检查架构
check_Arch(){
    arch=$(uname -m)
    if [[ ${arch} == "x86_64" ]]; then
        Arch="amd64"
    elif [[ ${arch} == "i386" || ${arch} == "i686" ]]; then
        Arch="386"
    elif [[ ${arch} == "arm64" || ${arch} == "armv6" || ${arch} == "armv7" ]]; then
        Arch="arm64"
    else
        echo -e "${Error}很抱歉，你的架构不受支持！"
        exit 1
    fi
}

check_pid(){
    PID=$(ps -ef | grep "./mtproxy " | grep -v "grep" | grep -v "service" | awk '{print $2}')
}

# 检查是否安装MTProxy
check_installed_status(){
    if [[ ! -e "${mtproxy_file}" ]]; then
        echo -e "${Error} MTProxy 没有安装，请检查 !"
        exit 1
    fi
}

# 检查MTProxy新版本
check_New_ver(){
    New_ver=$(curl -s https://github.com/RyanY610/MTProxy/releases/ | grep -o 'MTProxy-v[0-9.]*' | grep -o 'v[0-9.]*' | sort -rn | head -1)
    Old_ver=$(cat ${Old_ver_file})
    if [[ "${Old_ver}" != "${New_ver}" ]]; then
        echo -e "${Info} 发现 MTProxy 已有新版本 [ ${New_ver} ]，旧版本 [ ${Old_ver} ]"
        read -e -p "是否更新 ? [Y/n] :" yn
        [[ -z "${yn}" ]] && yn="y"
        if [[ $yn == [Yy] ]]; then
            cp ${mtproxy_conf} /tmp/mtproxy.conf
            rm -rf ${mtproxy_dir}
            Download
            mv /tmp/mtproxy.conf ${mtproxy_conf}
        fi
    else
        echo -e "${Info} 当前 MTProxy 已是最新版本 [ ${New_ver} ]"
        sleep 2
        menu
    fi
}

Download(){
    if [[ ! -e "${mtproxy_dir}" ]]; then
        mkdir "${mtproxy_dir}"
    fi
    cd "${mtproxy_dir}"
    echo -e "${Info} 开始下载 mtproxy......"
    check_Arch
    wget --no-check-certificate https://github.com/RyanY610/MTProxy/releases/download/MTProxy-${New_ver}/MTProxy-${New_ver}-linux-${Arch}.tar.gz
    tar xvf MTProxy-${New_ver}-linux-${Arch}.tar.gz
    rm -f MTProxy-${New_ver}-linux-${Arch}.tar.gz
    chmod +x mtproxy
    echo "${New_ver}" >${Old_ver_file}
}

Write_config(){
    cat >${mtproxy_conf} <<-EOF
		PORT=${mtp_port}
		PASSWORD=${mtp_passwd}
		SECURE=${SECURE}
		FAKE-TLS=${mtp_tls}
		TAG=${mtp_tag}
		NAT-IPv4=${mtp_nat_ipv4}
		NTP_TIME=time.google.com
		BUFFER-WRITE=${buffer_write}
		BUFFER-READ=${buffer_read}
		STATS-BIND=${stats_bind}
		ANTI-REPLAY-MAX-SIZE=${anti_replay_max_size}
		MULTIPLEX-PER-CONNECTION=${multiplex_per_connection}
	EOF
}

Write_Service(){
    cat >/etc/systemd/system/mtproxy.service <<-'EOF'
[Unit]
Description=MTProxy
After=network.target

[Service]
Type=simple
WorkingDirectory=/usr/local/MTProxy
EnvironmentFile=/usr/local/MTProxy/config.toml
ExecStart=/usr/local/MTProxy/mtproxy run -b 0.0.0.0:${PORT} ${SECURE} ${TAG} --ntp-server=${NTP_TIME}
StandardOutput=append:/usr/local/MTProxy/mtproxy.log
StandardError=append:/usr/local/MTProxy/mtproxy.log
Restart=always

[Install]
WantedBy=multi-user.target
	EOF
    systemctl enable mtproxy
}

Read_config(){
    [[ ! -e ${mtproxy_conf} ]] && echo -e "${Error} MTProxy 配置文件不存在 !" && exit 1
    port=$(cat ${mtproxy_conf} | grep 'PORT=' | awk -F 'PORT=' '{print $NF}')
    password=$(cat ${mtproxy_conf} | grep 'PASSWORD=' | awk -F 'PASSWORD=' '{print $NF}')
    fake_tls=$(cat ${mtproxy_conf} | grep 'FAKE-TLS=' | awk -F 'FAKE-TLS=' '{print $NF}')
    tag=$(cat ${mtproxy_conf} | grep 'TAG=' | awk -F 'TAG=' '{print $NF}')
    nat_ipv4=$(cat ${mtproxy_conf} | grep 'NAT-IPv4=' | awk -F 'NAT-IPv4=' '{print $NF}')
    nat_ipv6=$(cat ${mtproxy_conf} | grep 'NAT-IPv6=' | awk -F 'NAT-IPv6=' '{print $NF}')
    secure=$(cat ${mtproxy_conf} | grep 'SECURE=' | awk -F 'SECURE=' '{print $NF}')
    buffer_write=$(cat ${mtproxy_conf} | grep 'BUFFER-WRITE=' | awk -F 'BUFFER-WRITE=' '{print $NF}')
    buffer_read=$(cat ${mtproxy_conf} | grep 'BUFFER-READ=' | awk -F 'BUFFER-READ=' '{print $NF}')
    stats_bind=$(cat ${mtproxy_conf} | grep 'STATS-BIND=' | awk -F 'STATS-BIND=' '{print $NF}')
    anti_replay_max_size=$(cat ${mtproxy_conf} | grep 'ANTI-REPLAY-MAX-SIZE=' | awk -F 'ANTI-REPLAY-MAX-SIZE=' '{print $NF}')
    multiplex_per_connection=$(cat ${mtproxy_conf} | grep 'MULTIPLEX-PER-CONNECTION=' | awk -F 'MULTIPLEX-PER-CONNECTION=' '{print $NF}')

}

Set_port(){
    while true; do
        echo -e "请输入 MTProxy 端口 [10000-65535]"
        read -e -p "(默认：随机生成):" mtp_port
        [[ -z "${mtp_port}" ]] && mtp_port=$(shuf -i10000-65000 -n1)
        echo $((${mtp_port} + 0)) &>/dev/null
        if [[ $? -eq 0 ]]; then
            if [[ ${mtp_port} -ge 10000 ]] && [[ ${mtp_port} -le 65535 ]]; then
                echo && echo "========================"
                echo -e "	端口 : ${Red_globa} ${mtp_port} ${Nc}"
                echo "========================" && echo
                break
            else
                echo "输入错误, 请输入正确的端口。"
            fi
        else
            echo "输入错误, 请输入正确的端口。"
        fi
    done
}

Set_passwd(){
    while true; do
        echo "请输入 MTProxy 密匙（普通密钥必须为32位，[0-9][a-z][A-Z]，建议留空随机生成）"
        read -e -p "(若需要开启TLS伪装建议直接回车):" mtp_passwd
        if [[ -z "${mtp_passwd}" ]]; then
            echo -e "是否开启TLS伪装？[Y/n]"
            read -e -p "(默认：Y 启用):" mtp_tls
            [[ -z "${mtp_tls}" ]] && mtp_tls="Y"
            if [[ "${mtp_tls}" == [Yy] ]]; then
                echo -e "请输入TLS伪装域名"
                read -e -p "(默认：itunes.apple.com):" fake_domain
                [[ -z "${fake_domain}" ]] && fake_domain="itunes.apple.com"
                mtp_tls="YES"
                mtp_passwd=$(${mtproxy_dir}/mtproxy generate-secret -c ${fake_domain} tls)
            else
                mtp_tls="NO"
                mtp_passwd=$(date +%s%N | md5sum | head -c 32)
            fi
        else
            if [[ ${#mtp_passwd} != 32 ]]; then
                echo -e "你输入的密钥不是标准秘钥，是否为启用TLS伪装的密钥？[Y/n]"
                read -e -p "(默认：N 不是):" mtp_tls
                [[ -z "${mtp_tls}" ]] && mtp_tls="N"
                if [[ "${mtp_tls}" == [Nn] ]]; then
                    echo -e "${Error} 你输入的密钥不是标准秘钥（32位字符）。" && continue
                else
                    mtp_tls="YES"
                fi
            else
                mtp_tls="NO"
            fi
        fi
        echo && echo "========================"
        echo -e "	密码 : ${Red_globa} ${mtp_passwd} ${Nc}"
        echo
        echo -e "	是否启用TLS伪装 : ${Red_globa} ${mtp_tls} ${Nc}"
        echo "========================" && echo
        break
    done

    echo -e "是否启用强制安全模式？[Y/n]
启用[安全混淆模式]的客户端链接(即密匙头部有 dd 字符)，降低服务器被墙几率，建议开启。"
    read -e -p "(默认：Y 启用):" mtp_secure
    [[ -z "${mtp_secure}" ]] && mtp_secure="Y"
    if [[ "${mtp_secure}" == [Yy] ]]; then
        mtp_secure="YES"
    else
        mtp_secure="NO"
    fi
    if [[ "${mtp_tls}" == "NO" && "${mtp_secure}" == "YES" ]]; then
        SECURE=dd${mtp_passwd}
    else
        SECURE=${mtp_passwd}
    fi
    echo && echo "========================"
    echo -e "	密匙 : ${Red_globa} ${SECURE} ${Nc}"
    echo "========================" && echo
}

Set_tag(){
    echo "请输入 MTProxy 的 TAG标签（TAG标签必须是32位，TAG标签只有在通过官方机器人 @MTProxybot 分享代理账号后才会获得，不清楚请留空回车）"
    read -e -p "(默认：回车跳过):" mtp_tag
    if [[ ! -z "${mtp_tag}" ]]; then
        echo && echo "========================"
        echo -e "	TAG : ${Red_globa} ${mtp_tag} ${Nc}"
        echo "========================" && echo
    else
        echo
    fi
}

Set_nat(){
    echo -e "如果本机是NAT服务器（谷歌云、微软云、阿里云等，网卡绑定的IP为 10.xx.xx.xx 开头的），则需要指定公网 IPv4。"
    read -e -p "(默认：自动检测 IPv4 地址):" mtp_nat_ipv4
    if [[ -z "${mtp_nat_ipv4}" ]]; then
        getipv4
        if [[ "${ipv4}" == "IPv4_Error" ]]; then
            mtp_nat_ipv4=""
        else
            mtp_nat_ipv4="${ipv4}"
        fi
        echo && echo "========================"
        echo -e "	NAT-IPv4 : ${Red_globa} ${mtp_nat_ipv4} ${Nc}"
        echo "========================" && echo
    fi
}

Set(){
    check_installed_status
    echo && echo -e "你要做什么？
 ${Green}1.${Nc}  修改 端口配置
 ${Green}2.${Nc}  修改 密码配置
 ${Green}3.${Nc}  修改 TAG 配置
 ${Green}4.${Nc}  修改 NAT 配置
 ${Green}5.${Nc}  修改 全部配置" && echo
    read -e -p "(默认: 取消):" mtp_modify
    [[ -z "${mtp_modify}" ]] && echo -e "${Info}已取消..." && exit 1
    if [[ "${mtp_modify}" == "1" ]]; then
        Read_config
        mtp_passwd=${password}
        mtp_tls=${fake_tls}
        mtp_tag=${tag}
        mtp_nat_ipv4=${nat_ipv4}
        mtp_nat_ipv6=${nat_ipv6}
        mtp_secure=${secure}
        Set_port
        Write_config
        Restart
    elif [[ "${mtp_modify}" == "2" ]]; then
        Read_config
        mtp_port=${port}
        mtp_tag=${tag}
        mtp_nat_ipv4=${nat_ipv4}
        mtp_nat_ipv6=${nat_ipv6}
        mtp_secure=${secure}
        Set_passwd
        Write_config
        Restart
    elif [[ "${mtp_modify}" == "3" ]]; then
        Read_config
        mtp_port=${port}
        mtp_passwd=${passwd}
        mtp_tls=${fake_tls}
        mtp_nat_ipv4=${nat_ipv4}
        mtp_nat_ipv6=${nat_ipv6}
        mtp_secure=${secure}
        Set_tag
        Write_config
        Restart
    elif [[ "${mtp_modify}" == "4" ]]; then
        Read_config
        mtp_port=${port}
        mtp_passwd=${password}
        mtp_tls=${fake_tls}
        mtp_tag=${tag}
        mtp_secure=${secure}
        Set_nat
        Write_config
        Restart
    elif [[ "${mtp_modify}" == "5" ]]; then
        Read_config
        Set_port
        Set_passwd
        Set_tag
        Set_nat
        Write_config
        Restart
    else
        echo -e "${Error} 请输入正确的数字(1-5)" && exit 1
    fi
}

Install(){
    [[ -e ${mtproxy_file} ]] && echo -e "${Error} 检测到 MTProxy 已安装 !" && exit 1
    echo -e "${Info} 开始安装/配置 依赖..."
    install_base
    echo -e "${Info} 开始下载/安装..."
    check_New_ver
    Download
    echo -e "${Info} 开始设置 用户配置..."
    Set_port
    Set_passwd
    Set_tag
    Set_nat
    echo -e "${Info} 开始写入 配置文件..."
    Write_config
    echo -e "${Info} 开始写入 Service..."
    Write_Service
    echo -e "${Info} 所有步骤 执行完毕，开始启动..."
    Start
}

Start(){
    check_installed_status
    check_pid
    if [[ ! -z ${PID} ]]; then
        echo -e "${Error} MTProxy 正在运行，请检查 !"
        sleep 1s
        menu
    else
        systemctl start mtproxy.service
        sleep 1s
        check_pid
        if [[ ! -z ${PID} ]]; then
            View
        fi
    fi
}

Stop(){
    check_installed_status
    check_pid
    if [[ -z ${PID} ]]; then
        echo -e "${Error} MTProxy 没有运行，请检查 !"
        sleep 1s
        menu
    else
        systemctl stop mtproxy.service
        sleep 1s
        menu
    fi
}

Restart(){
    check_installed_status
    check_pid
    if [[ ! -z ${PID} ]]; then
        systemctl stop mtproxy
        sleep 1s
    fi
    systemctl start mtproxy
    sleep 1s
    check_pid
    [[ ! -z ${PID} ]] && View
}

Update(){
    check_installed_status
    check_New_ver
}

Uninstall(){
    check_installed_status
    echo "确定要卸载 MTProxy ? (y/N)"
    echo
    read -e -p "(默认: n):" unyn
    [[ -z ${unyn} ]] && unyn="n"
    if [[ ${unyn} == [Yy] ]]; then
        check_pid
        if [[ ! -z $PID ]]; then
            systemctl stop mtproxy
        fi
        systemctl disable mtproxy
        rm -rf ${mtproxy_dir}  /etc/systemd/system/mtproxy.service
        echo
        echo "MTProxy 卸载完成 !"
        echo
    else
        echo
        echo -e "${Tip}卸载已取消..."
        echo
    fi
}

getipv4(){
    get_public_ip
    if [[ -z "${ipv4}" ]]; then
        ipv4="IPv4_Error"
    fi
}

getipv6(){
    get_public_ip
    if [[ -z "${ipv6}" ]]; then
        ipv6="IPv6_Error"
    fi
}

get_public_ip(){
    regex_pattern='^(eth|ens|eno|esp|enp)[0-9]+'
    InterFace=($(ip link show | awk -F': ' '{print $2}' | grep -E "$regex_pattern" | sed "s/@.*//g"))
    ipv4=""
    ipv6=""

    for i in "${InterFace[@]}"; do
        Public_IPv4=$(curl -s4m8 --interface "$i" api64.ipify.org -k | sed '/^\(2a09\|104\.28\)/d')
        Public_IPv6=$(curl -s6m8 --interface "$i" api64.ipify.org -k | sed '/^\(2a09\|104\.28\)/d')
    
        # 检查是否获取到IP地址
        if [[ -n "$Public_IPv4" ]]; then
            ipv4="$Public_IPv4"
        fi

        if [[ -n "$Public_IPv6" ]]; then
            ipv6="$Public_IPv6"
        fi
    done
}

View(){
    check_installed_status
    Read_config
    #getipv4
    #getipv6
    clear && echo
    echo -e "Mtproto Proxy 用户配置："
    echo -e "————————————————"
    echo -e " 地址\t: ${Green}${nat_ipv4}${Nc}"
    [[ ! -z "${nat_ipv6}" ]] && echo -e " 地址\t: ${Green}${nat_ipv6}${Nc}"
    echo -e " 端口\t: ${Green}${port}${Nc}"
    echo -e " 密匙\t: ${Green}${secure}${Nc}"
    [[ ! -z "${tag}" ]] && echo -e " TAG \t: ${Green}${tag}${Nc}"
    echo -e " 链接\t: ${Red}tg://proxy?server=${nat_ipv4}&port=${port}&secret=${secure}${Nc}"
    echo -e " 链接\t: ${Red}https://t.me/proxy?server=${nat_ipv4}&port=${port}&secret=${secure}${Nc}"
    [[ ! -z "${nat_ipv6}" ]] && echo -e " 链接\t: ${Red}tg://proxy?server=${nat_ipv6}&port=${port}&secret=${secure}${Nc}"
    [[ ! -z "${nat_ipv6}" ]] && echo -e " 链接\t: ${Red}https://t.me/proxy?server=${nat_ipv6}&port=${port}&secret=${secure}${Nc}"
    echo
    echo -e " TLS伪装模式\t: ${Green}${fake_tls}${Nc}"
    echo
    echo -e " ${Red}注意\t:${Nc} 密匙头部的 ${Green}dd${Nc} 字符是代表客户端启用${Green}安全混淆模式${Nc}（TLS伪装模式除外），可以降低服务器被墙几率。"
    backmenu
}

View_Log(){
    check_installed_status
    [[ ! -e ${mtproxy_log} ]] && echo -e "${Error} MTProxy 日志文件不存在 !" && exit 1
    echo && echo -e "${Tip} 按 ${Red}Ctrl+C${Nc} 终止查看日志" && echo -e "如果需要查看完整日志内容，请用 ${Red}cat ${mtproxy_log}${Nc} 命令。" && echo
    tail -f ${mtproxy_log}
}

get_IP_address(){
    if [[ ! -z ${user_IP} ]]; then
        for ((integer_1 = ${user_IP_total}; integer_1 >= 1; integer_1--)); do
            IP=$(echo "${user_IP}" | sed -n "$integer_1"p)
            IP_address=$(wget -qO- -t1 -T2 http://freeapi.ipip.net/${IP} | sed 's/\"//g;s/,//g;s/\[//g;s/\]//g')
            echo -e "${Green}${IP}${Nc} (${IP_address})"
            sleep 1s
        done
    fi
}

Esc_Shell(){
    exit 0
}

backmenu(){
    echo ""
    read -rp "请输入“y”退出, 或按任意键回到主菜单：" back2menuInput
    case "$backmenuInput" in
    y) exit 1 ;;
    *) menu ;;
    esac
}

menu() {
    clear
    echo -e "${Green}######################################
#          ${Red}MTProxy 一键脚本          ${Green}#
#         作者: ${Yellow}你挺能闹啊🍏          ${Green}#
######################################
  0.${Nc} 退出脚本
———————————————————————
 ${Green} 1.${Nc} 安装 MTProxy
 ${Green} 2.${Nc} 更新 MTProxy
 ${Green} 3.${Nc} 卸载 MTProxy
———————————————————————
 ${Green} 4.${Nc} 启动 MTProxy
 ${Green} 5.${Nc} 停止 MTProxy
 ${Green} 6.${Nc} 重启 MTProxy
———————————————————————
 ${Green} 7.${Nc} 设置 MTProxy配置
 ${Green} 8.${Nc} 查看 MTProxy链接
 ${Green} 9.${Nc} 查看 MTProxy日志
———————————————————————" && echo

    if [[ -e ${mtproxy_file} ]]; then
        check_pid
        if [[ ! -z "${PID}" ]]; then
            echo -e " 当前状态: ${Green}已安装${Nc} 并 ${Green}已启动${Nc}"
            check_installed_status
            Read_config
            echo -e " ${Info}MTProxy 链接: ${Red}https://t.me/proxy?server=${nat_ipv4}&port=${port}&secret=${secure}${Nc}"
        else
            echo -e " 当前状态: ${Green}已安装${Nc} 但 ${Red}未启动${Nc}"
        fi
    else
        echo -e " 当前状态: ${Red}未安装${Nc}"
    fi
    echo
    read -e -p " 请输入数字 [0-9]:" num
    case "$num" in
        0)
            Esc_Shell
            ;;
        1)
            Install
            ;;
        2)
            Update
            ;;
        3)
            Uninstall
            ;;
        4)
            Start
            ;;
        5)
            Stop
            ;;
        6)
            Restart
            ;;
        7)
            Set
            ;;
        8)
            View
            ;;
        9)
            View_Log
            ;;
        *)
            echo -e "${Error} 请输入正确数字 [0-9]"
            ;;
    esac
}
menu
