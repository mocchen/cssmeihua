#!/bin/bash

# OpenSSL批量端口扫描脚本（多线程版）- 简化版
# 用法: ./ssl.sh <目标> [选项]

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
    echo "  $0 example.com -p 443 -j 50"
    echo "  $0 192.168.1.1 -p 80,443,8443"
    echo "  $0 example.com -f ports.txt --check-cert"
}

# 测试单个目标的端口
test_target_port() {
    local target=$1
    local port=$2
    local timeout_val=$3
    local check_cert=$4
    local test_ciphers=$5
    local thread_id=$6
    
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
                    openssl x509 -noout -subject -dates -issuer 2>/dev/null | sed 's/^/    /')
            fi
            
            # 测试加密套件
            local cipher_info=""
            if [ "$test_ciphers" = true ] && [ "$success" = true ]; then
                cipher_info=$(test_cipher_suites "$target" "$port" "$timeout_val")
            fi
            
            # 组合输出信息
            if [ -n "$cert_info" ] || [ -n "$cipher_info" ]; then
                output="$output\n$cert_info$cipher_info"
            fi
        fi
    fi
    
    # 输出结果
    if [ "$success" = true ]; then
        echo -e "${GREEN}线程${thread_id}: $output${NC}"
        echo "$target:$port" >> "$open_ports_file"
    else
        if [ "$show_closed" = true ]; then
            echo -e "${RED}线程${thread_id}: $target:$port - SSL/TLS 连接失败${NC}"
        elif [ "$verbose" = true ]; then
            echo -e "${RED}线程${thread_id}: $target:$port - SSL/TLS 连接失败${NC}"
        fi
    fi
    
    # 记录到结果文件
    echo "$target:$port: $([ "$success" = true ] && echo "成功" || echo "失败")" >> "$result_file"
    
    return $([ "$success" = true ] && echo 0 || echo 1)
}

# 测试支持的加密套件
test_cipher_suites() {
    local target=$1
    local port=$2
    local timeout_val=$3
    
    local output=""
    local supported_ciphers=()
    
    # 常见的加密套件列表
    local ciphers=(
        "TLS_AES_256_GCM_SHA384"
        "TLS_AES_128_GCM_SHA256"
        "TLS_CHACHA20_POLY1305_SHA256"
        "ECDHE-ECDSA-AES256-GCM-SHA384"
        "ECDHE-RSA-AES256-GCM-SHA384"
        "ECDHE-ECDSA-AES128-GCM-SHA256"
        "ECDHE-RSA-AES128-GCM-SHA256"
        "ECDHE-ECDSA-CHACHA20-POLY1305"
        "ECDHE-RSA-CHACHA20-POLY1305"
        "DHE-RSA-AES256-GCM-SHA384"
        "DHE-RSA-AES128-GCM-SHA256"
    )
    
    for cipher in "${ciphers[@]}"; do
        if timeout "$timeout_val" openssl s_client -cipher "$cipher" -connect "$target:$port" -servername "$target" < /dev/null 2>&1 | grep -q "Cipher is"; then
            supported_ciphers+=("$cipher")
        fi
    done
    
    if [ ${#supported_ciphers[@]} -gt 0 ]; then
        output="\n    支持的加密套件:"
        for cipher in "${supported_ciphers[@]}"; do
            output="$output\n      ${GREEN}✓${NC} $cipher"
        done
    else
        output="\n    未检测到支持的加密套件"
    fi
    
    echo -e "$output"
}

# 生成端口序列
generate_ports() {
    local port_spec=$1
    
    # 如果是文件
    if [ -f "$port_spec" ]; then
        cat "$port_spec" | grep -v '^#' | grep -v '^$' | sort -n
    # 如果是范围 (如: 1-100)
    elif [[ "$port_spec" =~ ^[0-9]+-[0-9]+$ ]]; then
        local start=${port_spec%-*}
        local end=${port_spec#*-}
        seq "$start" "$end"
    # 如果是逗号分隔的列表 (如: 80,443,8080)
    elif [[ "$port_spec" =~ ^[0-9]+(,[0-9]+)*$ ]]; then
        echo "$port_spec" | tr ',' '\n'
    else
        echo "$port_spec"
    fi
}

# 多线程扫描函数
parallel_scan() {
    local target=$1
    local ports=($2)
    local timeout_val=$3
    local check_cert=$4
    local test_ciphers=$5
    local max_jobs=$6
    local rate_limit=$7
    
    local total_tasks=${#ports[@]}
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
    echo -e "${CYAN}[*] 目标: $target${NC}"
    echo -e "${CYAN}[*] 端口数量: ${#ports[@]}${NC}"
    echo -e "${CYAN}[*] 总任务数: $total_tasks, 线程数: $max_jobs${NC}"
    
    # 扫描每个端口
    for port in "${ports[@]}"; do
        ((thread_id++))
        if [ $thread_id -gt $max_jobs ]; then
            thread_id=1
        fi
        
        read -u3
        {
            # 执行扫描
            test_target_port "$target" "$port" "$timeout_val" "$check_cert" "$test_ciphers" "$thread_id"
            
            # 速率限制
            if [ "$rate_limit" -gt 0 ]; then
                sleep $(echo "scale=3; $rate_limit/1000" | bc)
            fi
            
            echo >&3
        } &
    done
    
    wait
    exec 3>&-
}

# 显示摘要信息
show_summary() {
    local target=$1
    local total_ports=$2
    local open_ports_file=$3
    local output_file=$4
    
    if [ -f "$open_ports_file" ]; then
        local open_count=$(wc -l < "$open_ports_file" | tr -d ' ')
        
        echo "========================================"
        echo -e "${PURPLE}[*] 扫描摘要${NC}"
        echo -e "${CYAN}目标: $target${NC}"
        echo -e "${CYAN}扫描端口数: $total_ports${NC}"
        echo -e "${GREEN}发现SSL服务: $open_count${NC}"
        
        if [ $open_count -gt 0 ]; then
            echo -e "${GREEN}发现的SSL服务:${NC}"
            cat "$open_ports_file" | while read service; do
                echo -e "  ${GREEN}✓${NC} $service"
            done
            
            # 保存结果到文件
            if [ -n "$output_file" ]; then
                {
                    echo "OpenSSL端口扫描结果"
                    echo "扫描时间: $(date)"
                    echo "目标: $target"
                    echo "扫描端口数: $total_ports"
                    echo "发现的SSL服务: $open_count"
                    echo ""
                    cat "$open_ports_file"
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
    local test_ciphers=false
    local rate_limit=100
    local show_closed=false
    local output_file=""
    
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
            --ciphers)
                test_ciphers=true
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
                target=$1
                shift
                ;;
        esac
    done
    
    # 检查目标指定
    if [ -z "$target" ]; then
        echo -e "${RED}错误: 必须指定目标${NC}"
        usage
        exit 1
    fi
    
    # 如果没有指定端口，使用常见SSL端口
    if [ -z "$port_spec" ]; then
        port_spec="443,993,995,22,21,25,587,465,8443,9443"
        echo -e "${YELLOW}[!] 使用默认端口列表: $port_spec${NC}"
    fi
    
    # 生成端口列表
    local ports=($(generate_ports "$port_spec"))
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
    echo -e "${BLUE}[*] 目标: $target${NC}"
    echo -e "${BLUE}[*] 端口数量: ${#ports[@]}${NC}"
    echo -e "${BLUE}[*] 超时时间: ${timeout_val}秒${NC}"
    echo -e "${BLUE}[*] 线程数: $max_jobs${NC}"
    echo -e "${BLUE}[*] 开始时间: $(date)${NC}"
    echo "========================================"
    
    # 执行扫描
    parallel_scan "$target" "${ports[*]}" "$timeout_val" "$check_cert" "$test_ciphers" "$max_jobs" "$rate_limit"
    
    # 显示摘要
    show_summary "$target" "${#ports[@]}" "$open_ports_file" "$output_file"
    
    # 清理
    rm -f "$result_file" "$open_ports_file"
}

# 设置信号处理
trap 'rm -f /tmp/ssl_scan_*.txt /tmp/ssl_open_ports_*.txt; exit 1' INT TERM

# 脚本入口
if [ "$1" = "--create-examples" ]; then
    create_example_files
    exit 0
fi

# 运行主函数
main "$@"
