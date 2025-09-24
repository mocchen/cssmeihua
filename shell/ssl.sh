#!/bin/bash

# OpenSSL批量端口扫描脚本（多线程版）- 支持IP范围扫描
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
    echo "目标格式:"
    echo "  域名: example.com"
    echo "  单个IP: 192.168.1.1"
    echo "  IP范围: 192.168.1.1-192.168.1.100"
    echo "  CIDR: 192.168.1.0/24"
    echo "  IP列表文件: -i ip_list.txt"
    echo ""
    echo "选项:"
    echo "  -i <文件>        IP列表文件（每行一个IP或CIDR）"
    echo "  -p <端口>        指定端口 (如: 80-443 或 80,443,8080)"
    echo "  -f <文件>        从文件读取端口列表"
    echo "  -t <超时时间>    设置连接超时时间(秒)，默认: 3"
    echo "  -j <线程数>      设置并发线程数，默认: 20"
    echo "  -v              详细输出模式"
    echo "  --check-cert    检查证书详细信息"
    echo "  --ciphers       测试支持的加密套件"
    echo "  --rate-limit    启用速率限制(毫秒)，默认: 100"
    echo "  --no-ping       跳过ping检测（直接扫描）"
    echo "  --show-closed   显示关闭的端口"
    echo "  --output <文件> 将结果保存到文件"
    echo "  --debug         显示调试信息"
    echo ""
    echo "示例:"
    echo "  $0 192.168.1.0/24 -p 443 -j 50"
    echo "  $0 -i targets.txt -p 80,443,8443"
    echo "  $0 192.168.1.1-192.168.1.100 -f ports.txt"
    echo "  $0 example.com -p 443 --check-cert"
}

# 增强的IP验证函数
is_valid_ip() {
    local ip=$1
    # 更严格的IP验证
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        # 检查每个数字是否在0-255范围内
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

# 检查CIDR格式
is_valid_cidr() {
    local cidr=$1
    if [[ $cidr =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        local mask=$(echo "$cidr" | cut -d'/' -f2)
        if [ "$mask" -ge 0 ] && [ "$mask" -le 32 ]; then
            return 0
        fi
    fi
    return 1
}

# 检查IP范围格式
is_valid_ip_range() {
    local range=$1
    if [[ $range =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}-[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        return 0
    else
        return 1
    fi
}

# 将CIDR转换为IP列表
cidr_to_ips() {
    local cidr=$1
    local network=$(echo "$cidr" | cut -d'/' -f1)
    local mask=$(echo "$cidr" | cut -d'/' -f2)
    
    # 计算IP数量
    local num_ips=$((2**(32-mask)))
    
    # 将IP地址转换为数字
    local ip_num=0
    IFS='.' read -r i1 i2 i3 i4 <<< "$network"
    ip_num=$(( (i1<<24) + (i2<<16) + (i3<<8) + i4 ))
    
    # 计算网络地址和广播地址
    local network_num=$(( ip_num & (0xFFFFFFFF << (32-mask)) ))
    local broadcast_num=$(( network_num + num_ips - 1 ))
    
    local ips=()
    # 生成IP列表（排除网络地址）
    for (( ip=network_num+1; ip<=broadcast_num; ip++ )); do
        local o1=$(( (ip >> 24) & 0xFF ))
        local o2=$(( (ip >> 16) & 0xFF ))
        local o3=$(( (ip >> 8) & 0xFF ))
        local o4=$(( ip & 0xFF ))
        ips+=("$o1.$o2.$o3.$o4")
    done
    
    printf "%s\n" "${ips[@]}"
}

# 将IP范围转换为IP列表
range_to_ips() {
    local range=$1
    local start_ip=$(echo "$range" | cut -d'-' -f1)
    local end_ip=$(echo "$range" | cut -d'-' -f2)
    
    local start_num=0
    IFS='.' read -r s1 s2 s3 s4 <<< "$start_ip"
    start_num=$(( (s1<<24) + (s2<<16) + (s3<<8) + s4 ))
    
    local end_num=0
    IFS='.' read -r e1 e2 e3 e4 <<< "$end_ip"
    end_num=$(( (e1<<24) + (e2<<16) + (e3<<8) + e4 ))
    
    local ips=()
    for (( ip_num=start_num; ip_num<=end_num; ip_num++ )); do
        local o1=$(( (ip_num >> 24) & 0xFF ))
        local o2=$(( (ip_num >> 16) & 0xFF ))
        local o3=$(( (ip_num >> 8) & 0xFF ))
        local o4=$(( ip_num & 0xFF ))
        ips+=("$o1.$o2.$o3.$o4")
    done
    
    printf "%s\n" "${ips[@]}"
}

# 检测主机是否在线（可选）
ping_host() {
    local host=$1
    local no_ping=$2
    
    if [ "$no_ping" = true ]; then
        return 0
    fi
    
    if ping -c 1 -W 1 "$host" &> /dev/null; then
        return 0
    else
        return 1
    fi
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

# 生成目标列表 - 修复版本
generate_targets() {
    local target_spec=$1
    local ip_file=$2
    local no_ping=$3
    local debug=$4
    
    if [ "$debug" = true ]; then
        echo -e "${RED}[DEBUG] 输入的目标参数: '$target_spec'${NC}"
        echo -e "${RED}[DEBUG] IP文件参数: '$ip_file'${NC}"
    fi
    
    # 清理输入（去除多余空格和特殊字符）
    if [ -n "$target_spec" ]; then
        target_spec=$(echo "$target_spec" | tr -d '[:space:]' | tr -d '\r')
    fi
    
    local targets=()
    
    echo -e "${CYAN}[*] 开始解析目标...${NC}"
    
    # 如果指定了IP文件，优先使用文件
    if [ -n "$ip_file" ] && [ -f "$ip_file" ]; then
        echo -e "${CYAN}[*] 从IP文件读取目标: $ip_file${NC}"
        while IFS= read -r line; do
            line=$(echo "$line" | sed 's/#.*//' | tr -d '[:space:]' | tr -d '\r')
            if [ -z "$line" ]; then
                continue
            fi
            
            if is_valid_ip "$line"; then
                targets+=("$line")
                if [ "$debug" = true ]; then
                    echo -e "  ${GREEN}有效IP: $line${NC}"
                fi
            elif is_valid_cidr "$line"; then
                local cidr_ips=($(cidr_to_ips "$line"))
                targets+=("${cidr_ips[@]}")
                if [ "$debug" = true ]; then
                    echo -e "  ${BLUE}CIDR: $line → ${#cidr_ips[@]} 个IP${NC}"
                fi
            elif is_valid_ip_range "$line"; then
                local range_ips=($(range_to_ips "$line"))
                targets+=("${range_ips[@]}")
                if [ "$debug" = true ]; then
                    echo -e "  ${BLUE}范围: $line → ${#range_ips[@]} 个IP${NC}"
                fi
            else
                targets+=("$line")
                if [ "$debug" = true ]; then
                    echo -e "  ${YELLOW}域名: $line${NC}"
                fi
            fi
        done < "$ip_file"
    elif [ -n "$target_spec" ]; then
        # 直接解析命令行指定的目标
        echo -e "${CYAN}[*] 解析目标: $target_spec${NC}"
        
        if is_valid_ip "$target_spec"; then
            echo -e "${GREEN}[√] 识别为单个IP地址${NC}"
            targets=("$target_spec")
        elif is_valid_cidr "$target_spec"; then
            echo -e "${YELLOW}[!] 识别为CIDR格式${NC}"
            targets=($(cidr_to_ips "$target_spec"))
        elif is_valid_ip_range "$target_spec"; then
            echo -e "${YELLOW}[!] 识别为IP范围格式${NC}"
            targets=($(range_to_ips "$target_spec"))
        elif [ -f "$target_spec" ]; then
            echo -e "${YELLOW}[!] 识别为文件路径${NC}"
            # 递归处理文件
            targets=($(generate_targets "" "$target_spec" "$no_ping" "$debug"))
        else
            echo -e "${BLUE}[?] 识别为域名或主机名${NC}"
            targets=("$target_spec")
        fi
    else
        echo -e "${RED}错误: 未指定目标${NC}"
        return 1
    fi
    
    # 去重
    local unique_targets=($(printf "%s\n" "${targets[@]}" | sort -u))
    local total_targets=${#unique_targets[@]}
    
    echo -e "${GREEN}[√] 目标解析完成: 共 $total_targets 个目标${NC}"
    
    if [ "$debug" = true ] && [ $total_targets -le 10 ]; then
        echo -e "${GREEN}[√] 目标列表: ${unique_targets[*]}${NC}"
    elif [ "$debug" = true ]; then
        echo -e "${GREEN}[√] 前10个目标: ${unique_targets[*]:0:10}...${NC}"
    fi
    
    # 可选ping检测（仅对多个目标生效）
    local final_targets=()
    local online_count=0
    
    if [ "$no_ping" = false ] && [ $total_targets -gt 1 ]; then
        echo -e "${YELLOW}[*] 正在检测在线主机...${NC}"
        local counter=0
        for target in "${unique_targets[@]}"; do
            ((counter++))
            if ping_host "$target" "$no_ping"; then
                final_targets+=("$target")
                ((online_count++))
                if [ "$verbose" = true ] || [ "$debug" = true ]; then
                    echo -e "  ${GREEN}在线: $target${NC}"
                fi
            else
                if [ "$verbose" = true ] || [ "$debug" = true ]; then
                    echo -e "  ${RED}离线: $target${NC}"
                fi
            fi
            
            # 显示进度
            if [ $((counter % 50)) -eq 0 ] || [ $counter -eq $total_targets ]; then
                local progress=$((counter * 100 / total_targets))
                echo -e "  ${YELLOW}[ping进度] $counter/$total_targets ($progress%)${NC}"
            fi
        done
        
        if [ $total_targets -gt 1 ]; then
            echo -e "${CYAN}[*] 在线主机: $online_count/$total_targets${NC}"
        fi
        
        # 如果进行了ping检测，使用检测后的结果
        if [ $online_count -gt 0 ]; then
            unique_targets=("${final_targets[@]}")
        elif [ $total_targets -gt 1 ]; then
            echo -e "${RED}[!] 没有检测到在线主机，但仍将继续扫描${NC}"
        fi
    else
        online_count=$total_targets
    fi
    
    printf "%s\n" "${unique_targets[@]}"
}

# 生成端口序列
generate_ports() {
    local port_spec=$1
    local debug=$2
    
    if [ "$debug" = true ]; then
        echo -e "${RED}[DEBUG] 端口参数: '$port_spec'${NC}"
    fi
    
    local ports=()
    
    # 如果是文件
    if [ -f "$port_spec" ]; then
        if [ "$debug" = true ]; then
            echo -e "${RED}[DEBUG] 从文件读取端口: $port_spec${NC}"
        fi
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
        if [ "$debug" = true ]; then
            echo -e "${RED}[DEBUG] 端口范围: $start-$end${NC}"
        fi
        
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
        if [ "$debug" = true ]; then
            echo -e "${RED}[DEBUG] 端口列表: $port_spec${NC}"
        fi
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
    
    if [ "$debug" = true ] && [ $total_ports -le 20 ]; then
        echo -e "${GREEN}[√] 端口列表: ${unique_ports[*]}${NC}"
    elif [ "$debug" = true ]; then
        echo -e "${GREEN}[√] 前10个端口: ${unique_ports[*]:0:10}...${NC}"
    fi
    
    printf "%s\n" "${unique_ports[@]}"
}

# 测试单个目标的端口
test_target_port() {
    local target=$1
    local port=$2
    local timeout_val=$3
    local check_cert=$4
    local test_ciphers=$5
    local thread_id=$6
    local show_closed=$7
    
    local output=""
    local success=false
    
    # 尝试建立SSL连接
    if result=$(timeout "$timeout_val" openssl s_client -connect "$target:$port" -servername "$target" < /dev/null 2>&1); then
        if echo "$result" | grep -q "CONNECTED"; then
            output="[+] $target:$port - SSL/TLS 连接成功"
            success=true
            
            # 获取证书信息
            local cert_info=""
            if [ "$check_cert" = true ]; then
                cert_info=$(timeout "$timeout_val" openssl s_client -connect "$target:$port" -servername "$target" 2>/dev/null | \
                    openssl x509 -noout -subject -dates -issuer 2>/dev/null | sed 's/^/    /' 2>/dev/null)
            fi
            
            # 组合输出信息
            if [ -n "$cert_info" ]; then
                output="$output\n$cert_info"
            fi
        fi
    fi
    
    # 输出结果
    if [ "$success" = true ]; then
        echo -e "${GREEN}线程${thread_id}: $output${NC}"
        echo "$target:$port" >> "$open_ports_file"
    else
        if [ "$show_closed" = true ]; then
            echo -e "${RED}线程${thread_id}: $target:$port - 连接失败${NC}"
        fi
    fi
    
    return $([ "$success" = true ] && echo 0 || echo 1)
}

# 多线程扫描函数
parallel_scan() {
    local targets=($1)
    local ports=($2)
    local timeout_val=$3
    local check_cert=$4
    local test_ciphers=$5
    local max_jobs=$6
    local rate_limit=$7
    local show_closed=$8
    
    local total_tasks=$((${#targets[@]} * ${#ports[@]}))
    local completed_tasks=0
    local thread_id=0
    
    # 创建命名管道用于控制并发
    local fifo=$(mktemp -u)
    mkfifo "$fifo"
    exec 3<>"$fifo"
    rm -f "$fifo"
    
    # 初始化令牌
    for ((i=0; i<max_jobs; i++)); do
        echo >&3
    done
    
    echo -e "${CYAN}[*] 开始多线程扫描${NC}"
    echo -e "${CYAN}[*] 目标数量: ${#targets[@]}, 端口数量: ${#ports[@]}${NC}"
    echo -e "${CYAN}[*] 总任务数: $total_tasks, 线程数: $max_jobs${NC}"
    
    # 扫描每个目标的每个端口
    for target in "${targets[@]}"; do
        for port in "${ports[@]}"; do
            ((thread_id=thread_id % max_jobs + 1))
            
            read -u3
            {
                # 执行扫描
                test_target_port "$target" "$port" "$timeout_val" "$check_cert" "$test_ciphers" "$thread_id" "$show_closed"
                
                # 更新进度
                ((completed_tasks++))
                
                # 显示进度（每10%或最后显示）
                if [ $total_tasks -gt 0 ]; then
                    local progress=$((completed_tasks * 100 / total_tasks))
                    if [ $((completed_tasks % (total_tasks / 10 + 1))) -eq 0 ] || [ $completed_tasks -eq $total_tasks ]; then
                        echo -e "${YELLOW}[进度] $completed_tasks/$total_tasks ($progress%)${NC}"
                    fi
                fi
                
                # 速率限制
                if [ "$rate_limit" -gt 0 ]; then
                    sleep $(echo "scale=3; $rate_limit/1000" | bc)
                fi
                
                echo >&3
            } &
        done
    done
    
    wait
    exec 3>&-
}

# 显示摘要信息
show_summary() {
    local total_targets=$1
    local total_ports=$2
    local open_ports_file=$3
    local output_file=$4
    
    echo "========================================"
    echo -e "${PURPLE}[*] 扫描摘要${NC}"
    echo -e "${CYAN}目标数量: $total_targets${NC}"
    echo -e "${CYAN}端口数量: $total_ports${NC}"
    echo -e "${CYAN}总任务数: $((total_targets * total_ports))${NC}"
    
    if [ -f "$open_ports_file" ]; then
        local open_count=0
        if [ -s "$open_ports_file" ]; then
            open_count=$(wc -l < "$open_ports_file" | tr -d ' ')
        fi
        
        echo -e "${GREEN}发现SSL服务: $open_count${NC}"
        
        if [ "$open_count" -gt 0 ]; then
            echo -e "${GREEN}发现的SSL服务:${NC}"
            while IFS= read -r service; do
                echo -e "  ${GREEN}✓${NC} $service"
            done < "$open_ports_file"
            
            # 保存结果到文件
            if [ -n "$output_file" ]; then
                {
                    echo "OpenSSL端口扫描结果"
                    echo "扫描时间: $(date)"
                    echo "目标: $target_spec"
                    echo "端口: $port_spec"
                    echo "目标数量: $total_targets"
                    echo "端口数量: $total_ports"
                    echo "发现的SSL服务: $open_count"
                    echo ""
                    echo "开放端口:"
                    cat "$open_ports_file"
                } > "$output_file"
                echo -e "${CYAN}[+] 结果已保存到: $output_file${NC}"
            fi
        else
            echo -e "${RED}未发现SSL服务${NC}"
        fi
    else
        echo -e "${RED}未发现SSL服务${NC}"
    fi
    echo -e "${BLUE}[*] 结束时间: $(date)${NC}"
}

# 主函数
main() {
    # 保存原始参数用于输出
    local original_target="$1"
    local original_ports=""
    
    # 默认参数
    local target_spec=""
    local ip_file=""
    local port_spec=""
    local timeout_val=3
    local max_jobs=20
    local verbose=false
    local check_cert=false
    local test_ciphers=false
    local rate_limit=100
    local no_ping=false
    local show_closed=false
    local output_file=""
    local debug=false
    
    # 检查依赖
    check_dependencies
    
    # 解析参数
    while [ $# -gt 0 ]; do
        case $1 in
            -i)
                ip_file=$2
                shift 2
                ;;
            -p)
                port_spec=$2
                original_ports="$2"
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
            --ciphers)
                test_ciphers=true
                shift
                ;;
            --rate-limit)
                rate_limit=$2
                shift 2
                ;;
            --no-ping)
                no_ping=true
                shift
                ;;
            --show-closed)
                show_closed=true
                shift
                ;;
            --output)
                output_file=$2
                shift 2
                ;;
            --debug)
                debug=true
                shift
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
                if [ -z "$target_spec" ]; then
                    target_spec=$1
                else
                    echo -e "${RED}警告: 忽略额外参数 '$1'${NC}"
                fi
                shift
                ;;
        esac
    done
    
    # 验证必须有目标
    if [ -z "$target_spec" ] && [ -z "$ip_file" ]; then
        echo -e "${RED}错误: 必须指定目标或IP文件${NC}"
        usage
        exit 1
    fi
    
    # 如果没有指定端口，使用常见SSL端口
    if [ -z "$port_spec" ]; then
        port_spec="443,993,995,22,8443,9443"
        original_ports="$port_spec"
        echo -e "${YELLOW}[!] 使用默认端口列表: $port_spec${NC}"
    fi
    
    # 生成目标列表
    echo -e "${CYAN}[*] 解析目标...${NC}"
    local targets=($(generate_targets "$target_spec" "$ip_file" "$no_ping" "$debug"))
    
    if [ ${#targets[@]} -eq 0 ]; then
        echo -e "${RED}错误: 未找到有效目标${NC}"
        exit 1
    fi
    
    # 生成端口列表
    echo -e "${CYAN}[*] 解析端口...${NC}"
    local ports=($(generate_ports "$port_spec" "$debug"))
    if [ ${#ports[@]} -eq 0 ]; then
        echo -e "${RED}错误: 未找到有效端口${NC}"
        exit 1
    fi
    
    # 初始化结果文件
    local result_file="/tmp/ssl_scan_$(date +%s).txt"
    local open_ports_file="/tmp/ssl_open_ports_$(date +%s).txt"
    echo -n "" > "$result_file"
    echo -n "" > "$open_ports_file"
    
    echo -e "${BLUE}[*] 开始扫描...${NC}"
    echo -e "${BLUE}[*] 目标: ${targets[0]}${NC}"  # 只显示第一个目标
    echo -e "${BLUE}[*] 目标数量: ${#targets[@]}${NC}"
    echo -e "${BLUE}[*] 端口数量: ${#ports[@]}${NC}"
    echo -e "${BLUE}[*] 超时时间: ${timeout_val}秒${NC}"
    echo -e "${BLUE}[*] 线程数: $max_jobs${NC}"
    echo -e "${BLUE}[*] 开始时间: $(date)${NC}"
    echo "========================================"
    
    # 执行扫描
    parallel_scan "${targets[*]}" "${ports[*]}" "$timeout_val" "$check_cert" "$test_ciphers" "$max_jobs" "$rate_limit" "$show_closed"
    
    # 显示摘要
    show_summary "${#targets[@]}" "${#ports[@]}" "$open_ports_file" "$output_file"
    
    # 清理
    rm -f "$result_file" "$open_ports_file"
}

# 设置信号处理
cleanup() {
    rm -f /tmp/ssl_scan_*.txt /tmp/ssl_open_ports_*.txt
}

trap cleanup EXIT INT TERM

# 运行主函数
main "$@"
