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

# 检查用户是否为root
if [ "$(id -u)" != "0" ]; then
    echo -e "${RED}该脚本必须以root身份运行。${NC}"
    exit 1
fi

# 检查依赖
check_dependencies() {
    local deps=("openssl" "timeout" "bc")
    local missing_deps=()

    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            missing_deps+=("$dep")
        fi
    done

    if [ ${#missing_deps[@]} -gt 0 ]; then
        echo -e "${YELLOW}[!] 缺少依赖: ${missing_deps[*]}${NC}"
        echo -e "${YELLOW}[*] 正在尝试安装...${NC}"
        # 检测包管理器
        if command -v apt &>/dev/null; then
            apt update
            for dep in "${missing_deps[@]}"; do
                if [ "$dep" = "timeout" ]; then
                    dep="coreutils"
                fi
                apt install -y "$dep"
            done
        elif command -v yum &>/dev/null; then
            for dep in "${missing_deps[@]}"; do
                if [ "$dep" = "timeout" ]; then
                    dep="coreutils"
                fi
                yum install -y "$dep"
            done
        elif command -v dnf &>/dev/null; then
            for dep in "${missing_deps[@]}"; do
                if [ "$dep" = "timeout" ]; then
                    dep="coreutils"
                fi
                dnf install -y "$dep"
            done
        elif command -v apk &>/dev/null; then
            apk update
            for dep in "${missing_deps[@]}"; do
                if [ "$dep" = "timeout" ]; then
                    dep="coreutils"
                fi
                apk add "$dep"
            done
        else
            echo -e "${RED}[!] 无法自动安装依赖，请手动安装: ${missing_deps[*]}${NC}"
            echo -e "${YELLOW}[*] 然后重新运行脚本${NC}"
            exit 1
        fi

        # 再次检查依赖是否安装成功
        for dep in "${deps[@]}"; do
            if ! command -v "$dep" &>/dev/null; then
                echo -e "${RED}[!] 依赖安装失败: $dep${NC}"
                exit 1
            fi
        done

        echo -e "${GREEN}[+] 依赖安装完成${NC}"
    fi
}

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
    echo "  -v               详细输出模式"
    echo "  --check-cert     检查证书详细信息（现在也会输出 TLS 协议版本）"
    echo "  --rate-limit     启用速率限制(毫秒)，默认: 100"
    echo "  --show-closed    显示关闭的端口"
    echo "  --output <文件>  将结果保存到文件"
    echo ""
    echo "示例:"
    echo "  $0 example.com -p 443 -j 50"
    echo "  $0 192.168.1.1 -p 80,443,8443"
    echo "  $0 example.com -f ports.txt --check-cert"
}

test_target_port() {
    local target=$1
    local port=$2
    local timeout_val=$3
    local check_cert=$4
    local test_ciphers=$5
    local thread_id=$6

    local output=""
    local success=false

    # 尝试 TLS 连接获取证书、TLS 版本和 Cipher
    if result=$(timeout "$timeout_val" openssl s_client -connect "$target:$port" -servername "$target" < /dev/null 2>&1); then
        if echo "$result" | grep -q "CONNECTED"; then
            success=true
            output="[+] $target:$port - SSL/TLS 连接成功"

            if [ "$check_cert" = true ]; then
                local x509info=""
                if cert_pem=$(echo "$result" | sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p'); then
                    if [ -n "$cert_pem" ]; then
                        x509info=$(printf "%s\n" "$cert_pem" | openssl x509 -noout -subject -dates -issuer 2>/dev/null)
                    fi
                fi
                if [ -z "$x509info" ]; then
                    x509info=$(timeout "$timeout_val" openssl s_client -connect "$target:$port" -servername "$target" 2>/dev/null | openssl x509 -noout -subject -dates -issuer 2>/dev/null)
                fi

                local tls_version cipher
                tls_version=$(echo "$result" | awk -F',' '/New, TLS/ {gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2; exit}')
                cipher=$(echo "$result" | awk -F',' '/New, TLS/ {gsub(/^[ \t]+|[ \t]+$/,"",$3); sub("Cipher is ","",$3); print $3; exit}')

                if [ -n "$x509info" ]; then
                    output="$output\n$(printf "%s\n" "$x509info" | sed 's/^/    /')"
                else
                    output="$output\n    未能获取证书信息"
                fi
                output="$output\n    TLS 协议版本: ${tls_version:-未检测到}\n    Cipher: ${cipher:-未检测到}"
            fi
        fi
    fi

    # HTTP 请求检测（只在 port 是 HTTP 或任意需要检测 HTTP 的端口时使用）
    if response=$(timeout "$timeout_val" curl -Is http://$target:$port 2>/dev/null | head -n 1); then
        if [[ "$response" =~ ^HTTP ]]; then
            success=true
            output="$output\n[+] $target:$port - HTTP 服务，响应: $response"
        fi
    fi

    # 输出结果
    if [ "$success" = true ]; then
        echo -e "${GREEN}线程${thread_id}: $output${NC}"
        [ "$check_cert" = true ] && echo "$target:$port" >> "$open_ports_file"
    else
        if [ "$show_closed" = true ] || [ "$verbose" = true ]; then
            echo -e "${RED}线程${thread_id}: $target:$port - 无响应${NC}"
        fi
    fi

    # 记录到结果文件（追加）
    echo "$target:$port: $([ "$success" = true ] && echo "成功" || echo "失败")" >> "$result_file"

    return $([ "$success" = true ] && echo 0 || echo 1)
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

            # 保存结果到文件（追加模式，文件已存在且非空时先加换行）
            if [ -n "$output_file" ]; then
                if [ -f "$output_file" ] && [ -s "$output_file" ]; then
                    echo "" >> "$output_file"
                fi
                {
                    echo "========================================"
                    echo "OpenSSL端口扫描结果"
                    echo "扫描时间: $(date)"
                    echo "目标: $target"
                    echo "扫描端口数: $total_ports"
                    echo "发现的SSL服务: $open_count"
                    echo ""
                    cat "$open_ports_file"
                } >> "$output_file"
                echo -e "${CYAN}[+] 结果已保存到: $output_file${NC}"
            fi
        fi
    else
        echo -e "${RED}未发现SSL服务${NC}"
    fi
}

# 主函数
main() {
    check_dependencies

    # 默认参数
    local target=""
    local port_spec=""
    local timeout_val=3
    local max_jobs=20
    local verbose=false
    local check_cert=false
    local test_ciphers=false    # 选项保留，但已不做套件测试
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
                # 旧选项保留以兼容，但脚本现在不执行套件逐个测试
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
    echo "示例功能未实现"
    exit 0
fi

# 运行主函数
main "$@"
