#!/bin/bash

# OpenSSL批量端口扫描脚本（多线程版）- 单个目标版本
# 用法: bash ssl.sh <目标> [选项]

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
    echo "目标: 域名或IP地址 (如: example.com 或 192.168.1.1)"
    echo ""
    echo "选项:"
    echo "  -p <端口>        指定端口 (如: 80-443 或 80,443,8080)"
    echo "  -f <文件>        从文件读取端口列表"
    echo "  -t <超时时间>    设置连接超时时间(秒)，默认: 3"
    echo "  -j <线程数>      设置并发线程数，默认: 20"
    echo "  -v              详细输出模式"
    echo "  --check-cert    检查证书详细信息"
    echo "  --ciphers       测试支持的加密套件"
    echo "  --rate-limit    启用速率限制(毫秒)，默认: 100"
    echo "  --show-closed   显示关闭的端口"
    echo "  --output <文件> 将结果保存到文件"
    echo ""
    echo "示例:"
    echo "  $0 example.com -p 443"
    echo "  $0 192.168.1.1 -p 80,443,8443 -j 24"
    echo "  $0 192.168.1.1 -p 52000-52400 -j 24 --check-cert --output result.txt"
}

# IP验证函数
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

# 检查依赖工具
check_dependencies() {
    local deps=("openssl" "timeout")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            echo -e "${RED}错误: 未找到 $dep 命令${NC}"
            exit 1
        fi
    done
}

# 生成端口序列
generate_ports() {
    local port_spec=$1
    
    local ports=()
    
    # 如果是文件
    if [ -f "$port_spec" ]; then
        echo -e "${CYAN}[*] 从文件读取端口: $port_spec${NC}"
        while IFS= read -r port; do
            port=$(echo "$port" | sed 's/#.*//' | tr -d '[:space:]' | tr -d '\r')
            if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
                ports+=("$port")
            fi
        done < "$port_spec"
    # 如果是范围 (如: 1-100)
    elif [[ "$port_spec" =~ ^[0-9]+-[0-9]+$ ]]; then
        local start=${port_spec%-*}
        local end=${port_spec#*-}
        echo -e "${CYAN}[*] 解析端口范围: $start-$end${NC}"
        
        # 验证端口范围有效性
        if [ "$start" -ge 1 ] && [ "$end" -le 65535 ] && [ "$start" -le "$end" ]; then
            for port in $(seq "$start" "$end"); do
                ports+=("$port")
            done
        else
            echo -e "${RED}错误: 无效的端口范围 $start-$end${NC}"
            return 1
        fi
    # 如果是逗号分隔的列表 (如: 80,443,8080)
    elif [[ "$port_spec" =~ ^[0-9]+(,[0-9]+)*$ ]]; then
        echo -e "${CYAN}[*] 解析端口列表: $port_spec${NC}"
        IFS=',' read -ra port_array <<< "$port_spec"
        for port in "${port_array[@]}"; do
            if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
                ports+=("$port")
            fi
        done
    else
        # 单个端口
        if [[ "$port_spec" =~ ^[0-9]+$ ]] && [ "$port_spec" -ge 1 ] && [ "$port_spec" -le 65535 ]; then
            ports=("$port_spec")
        else
            echo -e "${RED}错误: 无效的端口格式 '$port_spec'${NC}"
            return 1
        fi
    fi
    
    # 去重和排序
    local unique_ports=($(printf "%s\n" "${ports[@]}" | sort -nu))
    local total_ports=${#unique_ports[@]}
    
    if [ $total_ports -eq 0 ]; then
        echo -e "${RED}错误: 未找到有效端口${NC}"
        return 1
    fi
    
    echo -e "${GREEN}[√] 端口解析完成: 共 $total_ports 个端口${NC}"
    
    printf "%s\n" "${unique_ports[@]}"
}

# 测试SSL端口
test_ssl_port() {
    local target=$1
    local port=$2
    local timeout_val=$3
    local check_cert=$4
    local thread_id=$5
    local show_closed=$6
    
    local output=""
    local success=false
    
    # 尝试建立SSL连接
    if result=$(timeout "$timeout_val" openssl s_client -connect "${target}:${port}" -servername "$target" < /dev/null 2>&1); then
        if echo "$result" | grep -q "CONNECTED"; then
            output="[+] ${target}:${port} - SSL/TLS 连接成功"
            success=true
            
            # 获取证书信息
            if [ "$check_cert" = true ]; then
                local cert_info=$(timeout "$timeout_val" openssl s_client -connect "${target}:${port}" -servername "$target" 2>/dev/null | \
                    openssl x509 -noout -subject -dates -issuer 2>/dev/null)
                if [ -n "$cert_info" ]; then
                    output="$output\n证书信息:\n$cert_info" | sed 's/^/    /'
                fi
            fi
        fi
    fi
    
    # 输出结果
    if [ "$success" = true ]; then
        echo -e "${GREEN}线程${thread_id}: $output${NC}"
        # 使用锁机制安全写入文件
        (flock -x 200; echo "${target}:${port}" >> "$open_ports_file") 200>"$lock_file"
        return 0
    else
        if [ "$show_closed" = true ]; then
            echo -e "${RED}线程${thread_id}: ${target}:${port} - 连接失败${NC}"
        fi
        return 1
    fi
}

# 多线程扫描函数
parallel_scan() {
    local target=$1
    local ports=($2)
    local timeout_val=$3
    local check_cert=$4
    local max_jobs=$5
    local rate_limit=$6
    local show_closed=$7
    
    local total_ports=${#ports[@]}
    local completed_tasks=0
    local open_ports=0
    local thread_id=0
    
    echo -e "${CYAN}[*] 开始多线程扫描${NC}"
    echo -e "${CYAN}[*] 目标: $target${NC}"
    echo -e "${CYAN}[*] 端口数量: $total_ports${NC}"
    echo -e "${CYAN}[*] 线程数: $max_jobs${NC}"
    
    # 创建锁文件
    lock_file="/tmp/ssl_scan_lock_$(date +%s).lock"
    touch "$lock_file"
    
    # 创建命名管道用于控制并发
    local fifo=$(mktemp -u)
    mkfifo "$fifo"
    exec 3<>"$fifo"
    rm -f "$fifo"
    
    # 初始化令牌
    for ((i=0; i<max_jobs; i++)); do
        echo >&3
    done
    
    # 扫描每个端口
    for port in "${ports[@]}"; do
        ((thread_id=thread_id % max_jobs + 1))
        
        read -u3
        {
            # 执行扫描
            if test_ssl_port "$target" "$port" "$timeout_val" "$check_cert" "$thread_id" "$show_closed"; then
                ((open_ports++))
            fi
            
            # 更新进度
            ((completed_tasks++))
            local progress=$((completed_tasks * 100 / total_ports))
            
            # 显示进度（每10%或最后显示）
            if [ $((completed_tasks % (total_ports / 10 + 1))) -eq 0 ] || [ $completed_tasks -eq $total_ports ]; then
                echo -e "${YELLOW}[进度] $completed_tasks/$total_ports (${progress}%) - 发现: $open_ports 个开放端口${NC}"
            fi
            
            # 速率限制
            if [ "$rate_limit" -gt 0 ]; then
                sleep $(echo "scale=3; $rate_limit/1000" | bc)
            fi
            
            echo >&3
        } &
    done
    
    wait
    exec 3>&-
    
    # 从文件中读取实际的开放端口数量
    local actual_open_ports=0
    if [ -f "$open_ports_file" ]; then
        actual_open_ports=$(wc -l < "$open_ports_file" | tr -d ' ')
    fi
    
    echo -e "${GREEN}[√] 扫描完成! 发现 $actual_open_ports 个开放端口${NC}"
    
    # 清理锁文件
    rm -f "$lock_file"
}

# 显示摘要信息
show_summary() {
    local target=$1
    local total_ports=$2
    local open_ports_file=$3
    local output_file=$4
    local port_spec=$5
    
    echo "========================================"
    echo -e "${PURPLE}[*] 扫描摘要${NC}"
    echo -e "${CYAN}目标: $target${NC}"
    echo -e "${CYAN}端口范围: $port_spec${NC}"
    echo -e "${CYAN}扫描端口数: $total_ports${NC}"
    
    if [ -f "$open_ports_file" ] && [ -s "$open_ports_file" ]; then
        local open_count=$(wc -l < "$open_ports_file" | tr -d ' ')
        echo -e "${GREEN}发现SSL服务: $open_count${NC}"
        
        if [ "$open_count" -gt 0 ]; then
            echo -e "${GREEN}开放的SSL端口:${NC}"
            # 对端口进行排序显示
            sort -t: -k2 -n "$open_ports_file" | while IFS= read -r service; do
                echo -e "  ${GREEN}✓${NC} $service"
            done
            
            # 保存结果到文件
            if [ -n "$output_file" ]; then
                {
                    echo "OpenSSL端口扫描结果"
                    echo "扫描时间: $(date)"
                    echo "目标: $target"
                    echo "端口范围: $port_spec"
                    echo "扫描端口数: $total_ports"
                    echo "发现的SSL服务: $open_count"
                    echo ""
                    echo "开放端口:"
                    sort -t: -k2 -n "$open_ports_file"
                } > "$output_file"
                echo -e "${CYAN}[+] 结果已保存到: $output_file${NC}"
            fi
        fi
    else
        echo -e "${RED}未发现SSL服务${NC}"
    fi
}

# 主函数
main() {
    # 默认参数
    local target=""
    local port_spec=""
    local timeout_val=3
    local max_jobs=20
    local verbose=false
    local check_cert=false
    local rate_limit=100
    local show_closed=false
    local output_file=""
    
    # 检查依赖
    check_dependencies
    
    # 解析参数
    while [ $# -gt 0 ]; do
        case $1 in
            -p)
                port_spec=$2
                shift 2
                ;;
            -f)
                if [ ! -f "$2" ]; then
                    echo -e "${RED}错误: 文件 $2 不存在${NC}"
                    exit 1
                fi
                port_spec=$2
                shift 2
                ;;
            -t)
                timeout_val=$2
                shift 2
                ;;
            -j)
                max_jobs=$2
                shift 2
                ;;
            -v)
                verbose=true
                shift
                ;;
            --check-cert)
                check_cert=true
                shift
                ;;
            --rate-limit)
                rate_limit=$2
                shift 2
                ;;
            --show-closed)
                show_closed=true
                shift
                ;;
            --output)
                output_file=$2
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
                    target=$1
                else
                    echo -e "${RED}错误: 只能指定一个目标${NC}"
                    usage
                    exit 1
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
    
    # 验证目标格式
    if ! is_valid_ip "$target" && ! [[ "$target" =~ ^[a-zA-Z0-9.-]+$ ]]; then
        echo -e "${RED}错误: 无效的目标格式 '$target'${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}[√] 目标设置: $target${NC}"
    
    # 生成端口列表
    local ports=($(generate_ports "$port_spec"))
    if [ $? -ne 0 ] || [ ${#ports[@]} -eq 0 ]; then
        exit 1
    fi
    
    # 初始化结果文件
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
    parallel_scan "$target" "${ports[*]}" "$timeout_val" "$check_cert" "$max_jobs" "$rate_limit" "$show_closed"
    
    # 显示摘要
    show_summary "$target" "${#ports[@]}" "$open_ports_file" "$output_file" "$port_spec"
    
    # 清理
    rm -f "$open_ports_file"
    
    echo -e "${BLUE}[*] 扫描结束: $(date)${NC}"
}

# 设置信号处理
cleanup() {
    if [ -n "$open_ports_file" ] && [ -f "$open_ports_file" ]; then
        rm -f "$open_ports_file"
    fi
    if [ -n "$lock_file" ] && [ -f "$lock_file" ]; then
        rm -f "$lock_file"
    fi
}

trap cleanup EXIT INT TERM

# 运行主函数
main "$@"
