#!/bin/bash

# OpenSSL批量端口扫描脚本（多线程版）- 完整优化版
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
    local deps=("openssl" "timeout" "bc" "curl")
    local missing_deps=()
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            missing_deps+=("$dep")
        fi
    done
    if [ ${#missing_deps[@]} -gt 0 ]; then
        echo -e "${YELLOW}[!] 缺少依赖: ${missing_deps[*]}${NC}"
        echo -e "${YELLOW}[*] 尝试安装...${NC}"
        if command -v apt &>/dev/null; then
            apt update
            for dep in "${missing_deps[@]}"; do
                [ "$dep" = "timeout" ] && dep="coreutils"
                apt install -y "$dep"
            done
        elif command -v yum &>/dev/null; then
            for dep in "${missing_deps[@]}"; do
                [ "$dep" = "timeout" ] && dep="coreutils"
                yum install -y "$dep"
            done
        elif command -v dnf &>/dev/null; then
            for dep in "${missing_deps[@]}"; do
                [ "$dep" = "timeout" ] && dep="coreutils"
                dnf install -y "$dep"
            done
        elif command -v apk &>/dev/null; then
            apk update
            for dep in "${missing_deps[@]}"; do
                [ "$dep" = "timeout" ] && dep="coreutils"
                apk add "$dep"
            done
        else
            echo -e "${RED}[!] 无法自动安装依赖，请手动安装: ${missing_deps[*]}${NC}"
            exit 1
        fi
    fi
}

# 用法信息
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
    echo "  --check-cert     检查证书详细信息"
    echo "  --rate-limit     启用速率限制(毫秒)，默认: 100"
    echo "  --show-closed    显示关闭的端口"
    echo "  --output <文件>  将结果保存到文件"
    echo ""
    echo "示例:"
    echo "  $0 example.com -p 443 -j 50"
    echo "  $0 192.168.1.1 -p 80,443,8443"
}

# 端口生成函数 + 合法性检查
generate_ports() {
    local port_spec=$1
    local ports_raw
    if [ -f "$port_spec" ]; then
        ports_raw=$(grep -v '^#' "$port_spec" | grep -v '^$')
    elif [[ "$port_spec" =~ ^[0-9]+-[0-9]+$ ]]; then
        local start=${port_spec%-*}
        local end=${port_spec#*-}
        ports_raw=$(seq "$start" "$end")
    elif [[ "$port_spec" =~ ^[0-9]+(,[0-9]+)*$ ]]; then
        ports_raw=$(echo "$port_spec" | tr ',' '\n')
    else
        ports_raw="$port_spec"
    fi

    # 端口合法性检查 1-65535
    echo "$ports_raw" | awk '$1>=1 && $1<=65535'
}

# 扫描单个端口
test_target_port() {
    local target=$1
    local port=$2
    local timeout_val=$3
    local check_cert=$4
    local thread_id=$5

    local output=""
    local success=false
    local tls_success=false

    # 尝试 TLS 扫描
    if result=$(timeout "$timeout_val" openssl s_client -connect "$target:$port" -servername "$target" < /dev/null 2>&1); then
        if echo "$result" | grep -q "CONNECTED"; then
            tls_success=true
            success=true
            output="[+] $target:$port - SSL/TLS 连接成功"

            if [ "$check_cert" = true ]; then
                local x509info=""
                if cert_pem=$(echo "$result" | sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p'); then
                    if [ -n "$cert_pem" ]; then
                        x509info=$(printf "%s\n" "$cert_pem" | openssl x509 -noout -subject -dates -issuer 2>/dev/null)
                    fi
                fi
                [ -z "$x509info" ] && x509info="未能获取证书信息"

                local tls_version cipher
                tls_version=$(echo "$result" | awk -F',' '/New, TLS/ {gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2; exit}')
                cipher=$(echo "$result" | awk -F',' '/New, TLS/ {gsub(/^[ \t]+|[ \t]+$/,"",$3); sub("Cipher is ","",$3); print $3; exit}')

                output="$output\n$(printf "%s\n" "$x509info" | sed 's/^/    /')"
                output="$output\n    TLS 协议版本: ${tls_version:-未检测到}\n    Cipher: ${cipher:-未检测到}"
            fi
        fi
    fi

    # TLS扫描失败才尝试HTTP/HTTPS
    if [ "$tls_success" = false ]; then
        # 尝试 HTTP
        http_info=$(timeout "$timeout_val" curl -k -s -D - "http://$target:$port" -o /dev/null 2>/dev/null | head -n 1)
        if [[ "$http_info" =~ ^HTTP/ ]]; then
        # 提取协议版本和状态码
            http_version=$(echo "$http_info" | awk '{print $1}')
            http_status=$(echo "$http_info" | awk '{print $2}')
            output="[+] $target:$port - HTTP服务响应 (协议: $http_version, 状态码: $http_status)"
            success=true
        else
        # 尝试 HTTPS
            https_info=$(timeout "$timeout_val" curl -k -s -D - "https://$target:$port" -o /dev/null 2>/dev/null | head -n 1)
            if [[ "$https_info" =~ ^HTTP/ ]]; then
                http_version=$(echo "$https_info" | awk '{print $1}')
                http_status=$(echo "$https_info" | awk '{print $2}')
                output="[+] $target:$port - HTTPS服务响应 (协议: $http_version, 状态码: $http_status)"
                success=true
            else
                output="[!] $target:$port - 无响应"
            fi
        fi
    fi

    # 输出信息
    if [ "$success" = true ]; then
        echo -e "${GREEN}线程${thread_id}: $output${NC}"
        [ "$check_cert" = true ] && echo "$target:$port" >> "$open_ports_file"
    else
        if [ "$show_closed" = true ] || [ "$verbose" = true ]; then
            echo -e "${RED}线程${thread_id}: $target:$port - 无响应${NC}"
        fi
    fi

    echo "$target:$port: $([ "$success" = true ] && echo "成功" || echo "失败")" >> "$result_file"
}

# 多线程扫描
parallel_scan() {
    local target=$1
    local ports=($2)
    local timeout_val=$3
    local check_cert=$4
    local max_jobs=$5
    local rate_limit=$6

    local thread_id=0
    local fifo=$(mktemp -u)
    mkfifo "$fifo"
    exec 3<>"$fifo"
    rm -f "$fifo"

    for ((i=0; i<max_jobs; i++)); do
        echo >&3
    done

    for port in "${ports[@]}"; do
        ((thread_id++))
        [ $thread_id -gt $max_jobs ] && thread_id=1

        read -u3
        {
            test_target_port "$target" "$port" "$timeout_val" "$check_cert" "$thread_id"
            [ "$rate_limit" -gt 0 ] && sleep $(echo "scale=3; $rate_limit/1000" | bc)
            echo >&3
        } &
    done

    wait
    exec 3>&-
}

# 显示摘要
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

            if [ -n "$output_file" ]; then
                [ -f "$output_file" ] && [ -s "$output_file" ] && echo "" >> "$output_file"
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

    local target=""
    local port_spec=""
    local timeout_val=3
    local max_jobs=20
    local verbose=false
    local check_cert=false
    local rate_limit=100
    local show_closed=false
    local output_file=""

    while [ $# -gt 0 ]; do
        case $1 in
            -p) port_spec=$2; shift 2 ;;
            -f) [ ! -f "$2" ] && echo -e "${RED}文件 $2 不存在${NC}" && exit 1; port_spec=$2; shift 2 ;;
            -t) timeout_val=$2; shift 2 ;;
            -j) max_jobs=$2; shift 2 ;;
            -v) verbose=true; shift ;;
            --check-cert) check_cert=true; shift ;;
            --rate-limit) rate_limit=$2; shift 2 ;;
            --show-closed) show_closed=true; shift ;;
            --output) output_file=$2; shift 2 ;;
            -h|--help) usage; exit 0 ;;
            -* ) echo -e "${RED}未知参数 $1${NC}"; usage; exit 1 ;;
            * ) target=$1; shift ;;
        esac
    done

    [ -z "$target" ] && echo -e "${RED}错误: 必须指定目标${NC}" && usage && exit 1
    [ -z "$port_spec" ] && port_spec="443,993,995,22,21,25,587,465,8443,9443" && echo -e "${YELLOW}[!] 使用默认端口列表: $port_spec${NC}"

    local ports=($(generate_ports "$port_spec"))
    [ ${#ports[@]} -eq 0 ] && echo -e "${RED}错误: 未找到有效端口${NC}" && exit 1

    result_file=$(mktemp /tmp/ssl_scan_result_XXXXXX.txt)
    open_ports_file=$(mktemp /tmp/ssl_open_ports_XXXXXX.txt)

    echo "========================================"
    echo -e "${BLUE}[*] 开始扫描...${NC}"
    echo -e "${BLUE}[*] 目标: $target${NC}"
    echo -e "${BLUE}[*] 端口数量: ${#ports[@]}${NC}"
    echo -e "${BLUE}[*] 超时时间: ${timeout_val}秒${NC}"
    echo -e "${BLUE}[*] 线程数: $max_jobs${NC}"
    echo -e "${BLUE}[*] 开始时间: $(date)${NC}"
    echo "========================================"

    parallel_scan "$target" "${ports[*]}" "$timeout_val" "$check_cert" "$max_jobs" "$rate_limit"
    show_summary "$target" "${#ports[@]}" "$open_ports_file" "$output_file"
}

# 信号处理 + 临时文件清理
trap 'rm -f "$result_file" "$open_ports_file"; exit 1' INT TERM EXIT

# 脚本入口
if [ "$1" = "--create-examples" ]; then
    echo "示例功能未实现"
    exit 0
fi

main "$@"
