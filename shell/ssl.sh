#!/bin/bash

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
    local deps=("openssl" "timeout" "bc" "curl" "python3")
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
    echo "  --output <文件>  将**探测成功**的结果追加保存到文件"
    echo "  --http           开启http扫描"
    echo "  --socks          开启socks扫描"
    echo ""
    echo "示例:"
    echo "  $0 example.com -p 443 -j 50 --output results.txt"
    echo "  $0 192.168.1.1 -p 80,443,8443 --check-cert --output ssl.txt"
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

# 全局临时文件（在 main 中会被设置）
result_file=""
open_ports_file=""
output_file=""      # 当用户指定 --output 时，会写入详细记录

# 向详细输出文件写入（并发安全：若系统支持 flock 则使用）
write_detailed_output() {
    local text="$1"
    local outfile="$output_file"
    if [ -z "$outfile" ]; then
        return
    fi

    if command -v flock &>/dev/null; then
        mkdir -p "$(dirname "$outfile")" 2>/dev/null || true
        : > "${outfile}.lock" 2>/dev/null
        (
            flock -x 200
            printf "%s\n" "$text" >> "$outfile"
        ) 200>"${outfile}.lock"
    else
        printf "%s\n" "$text" >> "$outfile"
    fi
}

# 扫描单个端口
test_target_port() {
    local target=$1
    local port=$2
    local timeout_val=$3
    local check_cert=$4
    local thread_id=$5

    local start_ts=$(date +%s%3N)  # ms 精度
    local success=false
    local method="none"
    local cert_info=""
    local http_proto=""
    local http_status=""
    local tls_version=""
    local cipher=""
    local note=""
    local duration_ms=0

    # 尝试 TLS 扫描（openssl s_client）
    openssl_cmd_output=""
    if [ "$scan_tls" = true ] && openssl_cmd_output=$(timeout "$timeout_val" openssl s_client -connect "$target:$port" -servername "$target" < /dev/null 2>&1); then
        if echo "$openssl_cmd_output" | grep -q "CONNECTED"; then
            # 提取 TLS 版本与 Cipher（兼容多种输出形式）
            tls_version=""
            cipher=""

            # 1) 常见 openssl s_client 输出形式（多种厂商/版本的差异）
            tls_version=$(printf "%s\n" "$openssl_cmd_output" | awk -F: '/^\s*Protocol/ {gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2; exit}')
            if [ -z "$tls_version" ]; then
                tls_version=$(printf "%s\n" "$openssl_cmd_output" | awk '/Protocol  :/ {gsub(/^[ \t]+|[ \t]+$/,"",$3); print $3; exit}')
            fi

            cipher=$(printf "%s\n" "$openssl_cmd_output" | awk -F: '/^\s*Cipher/ {gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2; exit}')
            if [ -z "$cipher" ]; then
                cipher=$(printf "%s\n" "$openssl_cmd_output" | awk '/Cipher    :/ {gsub(/^[ \t]+|[ \t]+$/,"",$3); print $3; exit}')
            fi

            # 2) 兼容 CSV/其它工具输出（例如含 "New, TLS, TLSv1.2, Cipher is AES..." 的行）
            #    如果上面没解析到，再尝试从逗号分隔行中抓取（使用 openssl_cmd_output 的内容）
            if [ -z "$tls_version" ] || [ -z "$cipher" ]; then
                csv_line=$(printf "%s\n" "$openssl_cmd_output" | grep -m1 -E 'New,[[:space:]]*(TLS|SSL)' || true)
                if [ -n "$csv_line" ]; then
                    # 以逗号分割并清理空白
                    tls_from_csv=$(printf "%s\n" "$csv_line" | awk -F',' '{gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2}')
                    cipher_from_csv=$(printf "%s\n" "$csv_line" | awk -F',' '{gsub(/^[ \t]+|[ \t]+$/,"",$3); sub(/^[ \t]*Cipher is[ \t]*/,"",$3); print $3}')
                    [ -n "$tls_from_csv" ] && tls_version="$tls_from_csv"
                    [ -n "$cipher_from_csv" ] && cipher="$cipher_from_csv"
                fi
            fi

            # 3) 额外回退：有时格式为 "TLSv1.3 (TLS_AES_256_GCM_SHA384)", 尽量拆分
            if [ -z "$cipher" ]; then
                # 从可能的括号格式中提取 Cipher
                possible_combined=$(printf "%s\n" "$openssl_cmd_output" | grep -m1 -E 'TLSv|SSLv' || true)
                if [ -n "$possible_combined" ]; then
                    # 提取括号内内容作为 cipher（如果有）
                    bracket_cipher=$(printf "%s\n" "$possible_combined" | sed -n 's/.*(\(.*\)).*/\1/p' | head -n1)
                    [ -n "$bracket_cipher" ] && cipher="$bracket_cipher"
                fi
            fi

            method="TLS"
            success=true
            # 证书信息（如果需要）
            if [ "$check_cert" = true ]; then
                cert_pem=$(printf "%s\n" "$openssl_cmd_output" | sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p')
                if [ -n "$cert_pem" ]; then
                    cert_info=$(printf "%s\n" "$cert_pem" | openssl x509 -noout -subject -issuer -dates 2>/dev/null)
                    if [ -z "$cert_info" ]; then
                        cert_info="无法解析证书信息"
                    fi
                else
                    cert_info="未发现证书 PEM 内容"
                fi
            fi
        fi
    fi

    # 如果 TLS 未成功，再尝试 HTTP
    if [ "$success" = false ] && [ "$scan_http" = true ]; then
        # 获取响应头与前 N 字节的 body（使用 --max-time 控制超时）
        raw_response=$(timeout "$timeout_val" bash -c "curl -k -s -D - --max-time $timeout_val http://$target:$port -o - 2>/dev/null" ) || raw_response=""
        # 解析第一行状态
        first_line=$(printf "%s\n" "$raw_response" | sed -n '1p' | tr -d '\r')
        if [[ "$first_line" =~ ^HTTP/ ]]; then
            http_proto=$(echo "$first_line" | awk '{print $1}')
            http_status=$(echo "$first_line" | awk '{print $2}')
            method="HTTP"
            success=true

            # 提取常用响应头（Server, Content-Type, Location, Set-Cookie）
            server_hdr=$(printf "%s\n" "$raw_response" | awk 'BEGIN{IGNORECASE=1} /^Server:/ {sub(/^Server:[ \t]*/,""); print; exit}')
            content_type_hdr=$(printf "%s\n" "$raw_response" | awk 'BEGIN{IGNORECASE=1} /^Content-Type:/ {sub(/^Content-Type:[ \t]*/,""); print; exit}')
            location_hdr=$(printf "%s\n" "$raw_response" | awk 'BEGIN{IGNORECASE=1} /^Location:/ {sub(/^Location:[ \t]*/,""); print; exit}')
            setcookie_hdr=$(printf "%s\n" "$raw_response" | awk 'BEGIN{IGNORECASE=1} /^Set-Cookie:/ {sub(/^Set-Cookie:[ \t]*/,""); print; exit}')

            # 获取 body 前几行（先跳过头部到空行，再取前 N 行）
            body_snippet=$(printf "%s\n" "$raw_response" | awk 'BEGIN{p=0} /^$/ { if(p==0){p=1; next} } { if(p==1) print }' | head -n 20)
            # 提取 <title>
            page_title=$(printf "%s\n" "$body_snippet" | tr '\n' ' ' | sed -n 's/.*<title[^>]*>\(.*\)<\/title>.*/\1/Ip')
        else
            note="无响应"
        fi
    fi

    # 如果仍未成功，尝试 SOCKS5 和 SOCKS4 探测
    if [ "$success" = false ] && [ "$scan_socks" = true ]; then
        # SOCKS5: 发送 [0x05, 0x01, 0x00]，期望服务端返回 [0x05, 0x00]
        socks5_ok=$(python3 - <<PY
import socket,sys
s=socket.socket()
s.settimeout(${timeout_val})
try:
    s.connect(("${target}", ${port}))
    s.send(b"\x05\x01\x00")
    r=s.recv(2)
    if len(r)>=2 and r[0]==5 and r[1]==0:
        print('ok')
except Exception:
    pass
finally:
    s.close()
PY
)
        if [ "$socks5_ok" = "ok" ]; then
            method="SOCKS5"
            success=true
            cipher=""
        else
            # SOCKS4: 发送一个简单的 SOCKS4 CONNECT 请求（目标 IP: 1.2.3.4, 端口 80），检查返回第2字节是否为 0x5a（授权成功）
            socks4_ok=$(python3 - <<PY
import socket,sys,struct
s=socket.socket()
s.settimeout(${timeout_val})
try:
    s.connect(("${target}", ${port}))
    port_bytes=struct.pack('>H', 80)
    ip_bytes=bytes([1,2,3,4])
    req=b"\x04\x01"+port_bytes+ip_bytes+b"\x00"
    s.send(req)
    r=s.recv(8)
    if len(r)>=2 and r[1]==0x5a:
        print('ok')
except Exception:
    pass
finally:
    s.close()
PY
)
            if [ "$socks4_ok" = "ok" ]; then
                method="SOCKS4"
                success=true
            fi
        fi
    fi

    local end_ts=$(date +%s%3N)
    duration_ms=$((end_ts - start_ts))

    # 控制台输出（保留原先行为）
    if [ "$success" = true ]; then
        if [ "$method" = "TLS" ]; then
            echo -e "${GREEN}线程${thread_id}: [+] $target:$port - SSL/TLS 连接成功${NC}"
            if [ "$check_cert" = true ]; then
                echo -e "${GREEN}:     TLS ${tls_version:-未知}, Cipher: ${cipher:-未知}${NC}"
                echo -e "${GREEN}:     证书信息:${NC}"
                printf "    %s\n" "$cert_info" | sed 's/^/    /'
                echo ""
            else
                echo -e "${GREEN}:     TLS ${tls_version:-未知}, Cipher: ${cipher:-未知}${NC}"
            fi
            # 写入 open_ports_file，标注方法
            echo "$target:$port | TLS" >> "$open_ports_file"
        elif [ "$method" = "SOCKS5" ] || [ "$method" = "SOCKS4" ]; then
            echo -e "${GREEN}线程${thread_id}: [+] $target:$port - ${method} 代理 可能可用${NC}"
            echo "$target:$port | ${method}" >> "$open_ports_file"
        else
            # HTTP 成功：显示要点
            echo -e "${GREEN}线程${thread_id}: [+] $target:$port - HTTP 服务响应 (协议: ${http_proto:-未知}, 状态码: ${http_status:-未知})${NC}"
            [ -n "$server_hdr" ] && echo -e "${GREEN}:     Server: ${server_hdr}${NC}"
            [ -n "$content_type_hdr" ] && echo -e "${GREEN}:     Content-Type: ${content_type_hdr}${NC}"
            [ -n "$location_hdr" ] && echo -e "${GREEN}:     Location: ${location_hdr}${NC}"
            if [ -n "$page_title" ]; then
                echo -e "${GREEN}:     <title>: ${page_title}${NC}"
            fi
            # 如果 verbose 或 show_closed，也打印 body snippet（有限制）
            if [ "$verbose" = true ]; then
                echo -e "${GREEN}:     Body snippet:${NC}"
                printf "%s\n" "$body_snippet" | sed 's/^/    /' | sed -n '1,10p'
            fi
            # 写入 open_ports_file，标注方法
            echo "$target:$port | HTTP" >> "$open_ports_file"
        fi
    else
        if [ "$show_closed" = true ] || [ "$verbose" = true ]; then
            echo -e "${RED}线程${thread_id}: $target:$port - 无响应${NC}"
        fi
    fi

    # 结果记录（简短版）
    echo "$target:$port: $([ "$success" = true ] && echo "成功" || echo "失败")" >> "$result_file"

    # 仅当探测成功（TLS/HTTP/SOCKS）时才写入 --output 文件（如果指定）
    if [ -n "$output_file" ] && [ "$success" = true ]; then
        short="$(printf "==== %s | %s:%s ==== 结果: 成功  探测方式: %s  探测耗时: %s ms" \
            "$(date '+%Y-%m-%d %H:%M:%S')" "$target" "$port" "${method:-未知}" "$duration_ms")"
        write_detailed_output "$short"
    fi
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
            if [ "$rate_limit" -gt 0 ]; then
                sleep $(echo "scale=3; $rate_limit/1000" | bc)
            fi
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
    local outfile=$4

    if [ -f "$open_ports_file" ]; then
        local open_count=$(wc -l < "$open_ports_file" | tr -d ' ')
        echo "========================================"
        echo -e "${PURPLE}[*] 扫描摘要${NC}"
        echo -e "${CYAN}目标: $target${NC}"
        echo -e "${CYAN}扫描端口数: $total_ports${NC}"
        echo -e "${GREEN}发现服务: $open_count${NC}"

        if [ $open_count -gt 0 ]; then
            echo -e "${GREEN}发现的服务:${NC}"
            cat "$open_ports_file" | while read service; do
                echo -e "  ${GREEN}✓${NC} $service"
            done

            if [ -n "$outfile" ]; then
                header="========================================
OpenSSL/HTTP/SOCKS 端口扫描结果
扫描时间: $(date '+%Y-%m-%d %H:%M:%S')
目标: $target
扫描端口数: $total_ports
发现的服务: $open_count

发现的服务列表:"
                write_detailed_output "$header"
                while IFS= read -r svc; do
                    write_detailed_output "  - $svc"
                done < "$open_ports_file"
                write_detailed_output ""
                echo -e "${CYAN}[+] 结果已追加到: $outfile${NC}"
            fi
        fi
    else
        echo -e "${RED}未发现服务${NC}"
        if [ -n "$outfile" ]; then
            write_detailed_output "未发现服务; 扫描时间: $(date '+%Y-%m-%d %H:%M:%S')"
            echo -e "${CYAN}[+] 结果已追加到: $outfile${NC}"
        fi
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
    output_file=""

    # 探测选项（默认仅 TLS）
    scan_tls=true
    scan_http=false
    scan_socks=false

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
            --http) scan_http=true; shift ;;
            --socks) scan_socks=true; shift ;;
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

    # 如果指定了输出文件，不再覆盖，改为追加（保留历史），但确保目录存在
    if [ -n "$output_file" ]; then
        mkdir -p "$(dirname "$output_file")" 2>/dev/null || true
        # 不清空文件，直接追加
    fi

    echo "========================================"
    echo -e "${BLUE}[*] 开始扫描...${NC}"
    echo -e "${BLUE}[*] 目标: $target${NC}"
    echo -e "${BLUE}[*] 端口数量: ${#ports[@]}${NC}"
    echo -e "${BLUE}[*] 超时时间: ${timeout_val}秒${NC}"
    echo -e "${BLUE}[*] 线程数: $max_jobs${NC}"
    echo -e "${BLUE}[*] 开始时间: $(date)${NC}"
    if [ -n "$output_file" ]; then
        echo -e "${BLUE}[*] 详细结果输出文件: $output_file${NC}"
    fi
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
