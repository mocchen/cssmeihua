#!/bin/bash

# OpenSSL批量端口扫描脚本 - 修复版
# 用法: ./ssl_port_scanner.sh <目标> [选项]

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# 显示用法信息
usage() {
    echo "用法: $0 <目标> [选项]"
    echo ""
    echo "目标: 域名或IP地址"
    echo ""
    echo "选项:"
    echo "  -p <端口>        指定端口 (如: 80-443 或 80,443,8080)"
    echo "  -j <线程数>      设置并发线程数，默认: 20"
    echo "  -t <超时时间>    设置连接超时时间(秒)，默认: 3"
    echo "  --check-cert    检查证书详细信息"
    echo "  --output <文件> 将结果保存到文件"
    echo ""
    echo "示例:"
    echo "  $0 example.com -p 443"
    echo "  $0 192.168.1.1 -p 80,443,8443 -j 24"
    echo "  $0 183.2.133.238 -p 52000-52400 -j 24 --check-cert --output result.txt"
}

# 严格的IP验证
is_valid_ip() {
    local ip=$1
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        IFS='.' read -r i1 i2 i3 i4 <<< "$ip"
        if [ "$i1" -le 255 ] && [ "$i1" -ge 0 ] &&
           [ "$i2" -le 255 ] && [ "$i2" -ge 0 ] &&
           [ "$i3" -le 255 ] && [ "$i3" -ge 0 ] &&
           [ "$i4" -le 255 ] && [ "$i4" -ge 0 ]; then
            return 0
        fi
    fi
    return 1
}

# 生成端口序列
generate_ports() {
    local port_spec=$1
    
    if [[ "$port_spec" =~ ^[0-9]+-[0-9]+$ ]]; then
        local start=${port_spec%-*}
        local end=${port_spec#*-}
        if [ "$start" -le "$end" ] && [ "$start" -ge 1 ] && [ "$end" -le 65535 ]; then
            seq "$start" "$end"
        else
            echo -e "${RED}错误: 无效的端口范围 $port_spec${NC}"
            return 1
        fi
    else
        echo -e "${RED}错误: 不支持的端口格式 $port_spec${NC}"
        return 1
    fi
}

# 测试SSL端口
test_ssl_port() {
    local target=$1
    local port=$2
    local timeout_val=$3
    local check_cert=$4
    local thread_id=$5
    
    if result=$(timeout "$timeout_val" openssl s_client -connect "${target}:${port}" -servername "$target" < /dev/null 2>&1); then
        if echo "$result" | grep -q "CONNECTED"; then
            echo -e "${GREEN}[+] ${target}:${port} - SSL/TLS 连接成功${NC}"
            
            if [ "$check_cert" = true ]; then
                local cert_info=$(timeout "$timeout_val" openssl s_client -connect "${target}:${port}" -servername "$target" 2>/dev/null | \
                    openssl x509 -noout -subject -dates -issuer 2>/dev/null 2>/dev/null)
                if [ -n "$cert_info" ]; then
                    echo "$cert_info" | sed 's/^/    /'
                fi
            fi
            
            echo "${target}:${port}" >> "$open_ports_file"
            return 0
        fi
    fi
    return 1
}

# 多线程扫描
parallel_scan() {
    local target=$1
    local ports=($2)
    local timeout_val=$3
    local check_cert=$4
    local max_jobs=$5
    local output_file=$6
    
    local total_ports=${#ports[@]}
    local completed=0
    local open_ports=0
    
    echo -e "${CYAN}[*] 开始扫描 ${target}${NC}"
    echo -e "${CYAN}[*] 端口数量: $total_ports${NC}"
    echo -e "${CYAN}[*] 线程数: $max_jobs${NC}"
    
    # 创建进程控制
    local fifo=$(mktemp -u)
    mkfifo "$fifo"
    exec 3<>"$fifo"
    rm -f "$fifo"
    
    for ((i=0; i<max_jobs; i++)); do
        echo >&3
    done
    
    for port in "${ports[@]}"; do
        read -u3
        {
            if test_ssl_port "$target" "$port" "$timeout_val" "$check_cert" "$i"; then
                ((open_ports++))
            fi
            
            ((completed++))
            local progress=$((completed * 100 / total_ports))
            
            # 显示进度
            if [ $((completed % 10)) -eq 0 ] || [ $completed -eq $total_ports ]; then
                echo -e "${YELLOW}[进度] ${completed}/${total_ports} (${progress}%) - 发现: ${open_ports}${NC}"
            fi
            
            echo >&3
        } &
    done
    
    wait
    exec 3>&-
    
    echo -e "${GREEN}[√] 扫描完成! 发现 ${open_ports} 个开放端口${NC}"
    
    # 保存结果
    if [ -n "$output_file" ] && [ -f "$open_ports_file" ]; then
        if [ -s "$open_ports_file" ]; then
            {
                echo "OpenSSL端口扫描结果"
                echo "目标: $target"
                echo "端口范围: $port_spec"
                echo "扫描时间: $(date)"
                echo "发现的SSL服务:"
                cat "$open_ports_file"
            } > "$output_file"
            echo -e "${CYAN}[+] 结果已保存到: $output_file${NC}"
        fi
    fi
}

# 主函数 - 简化版
main() {
    # 保存原始参数
    local original_args="$*"
    
    # 默认参数
    local target=""
    local port_spec=""
    local timeout_val=3
    local max_jobs=20
    local check_cert=false
    local output_file=""
    
    echo -e "${BLUE}[*] 命令行参数: $original_args${NC}"
    
    # 手动解析参数（避免getopts复杂性问题）
    while [ $# -gt 0 ]; do
        case "$1" in
            -p)
                port_spec="$2"
                shift 2
                ;;
            -j)
                max_jobs="$2"
                shift 2
                ;;
            -t)
                timeout_val="$2"
                shift 2
                ;;
            --check-cert)
                check_cert=true
                shift
                ;;
            --output)
                output_file="$2"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            -*)
                echo -e "${RED}错误: 未知参数 $1${NC}"
                usage
                exit 1
                ;;
            *)
                if [ -z "$target" ]; then
                    target="$1"
                    echo -e "${GREEN}[√] 设置目标: $target${NC}"
                else
                    echo -e "${RED}警告: 忽略额外参数 '$1'${NC}"
                fi
                shift
                ;;
        esac
    done
    
    # 验证参数
    if [ -z "$target" ]; then
        echo -e "${RED}错误: 必须指定目标${NC}"
        usage
        exit 1
    fi
    
    if [ -z "$port_spec" ]; then
        echo -e "${RED}错误: 必须指定端口范围${NC}"
        usage
        exit 1
    fi
    
    if ! is_valid_ip "$target" && ! [[ "$target" =~ ^[a-zA-Z0-9.-]+$ ]]; then
        echo -e "${RED}错误: 无效的目标格式 '$target'${NC}"
        exit 1
    fi
    
    # 生成端口列表
    echo -e "${CYAN}[*] 解析端口范围: $port_spec${NC}"
    local ports=($(generate_ports "$port_spec"))
    if [ $? -ne 0 ] || [ ${#ports[@]} -eq 0 ]; then
        echo -e "${RED}错误: 无法解析端口范围${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}[√] 有效端口数量: ${#ports[@]}${NC}"
    
    # 初始化临时文件
    open_ports_file="/tmp/ssl_open_ports_$(date +%s).txt"
    echo -n "" > "$open_ports_file"
    
    # 显示开始信息
    echo "========================================"
    echo -e "${PURPLE}[*] OpenSSL端口扫描开始${NC}"
    echo -e "${CYAN}目标: $target${NC}"
    echo -e "${CYAN}端口范围: $port_spec${NC}"
    echo -e "${CYAN}超时: ${timeout_val}秒${NC}"
    echo -e "${CYAN}线程: $max_jobs${NC}"
    echo -e "${CYAN}开始时间: $(date)${NC}"
    echo "========================================"
    
    # 执行扫描
    parallel_scan "$target" "${ports[*]}" "$timeout_val" "$check_cert" "$max_jobs" "$output_file"
    
    # 清理
    rm -f "$open_ports_file"
    
    echo -e "${BLUE}[*] 扫描结束: $(date)${NC}"
}

# 设置信号处理
cleanup() {
    if [ -n "$open_ports_file" ] && [ -f "$open_ports_file" ]; then
        rm -f "$open_ports_file"
    fi
}

trap cleanup EXIT INT TERM

# 运行主函数
main "$@"
