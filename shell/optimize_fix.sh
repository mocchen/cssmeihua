#!/usr/bin/env bash
#
# TCP/IP 网络优化脚本 v3.2
#
# 支持:
#   Debian / Ubuntu / CentOS / AlmaLinux / Rocky Linux
#
# 功能:
#   1. 基于带宽、RTT 和内存计算 TCP 缓冲区
#   2. 检测并启用 BBR + FQ
#   3. 配置 UDP 最小缓冲区
#   4. 可选开启 IPv4/IPv6 转发
#   5. 可选配置 nf_conntrack 容量和超时
#   6. 安全备份配置文件及运行时 sysctl
#   7. 应用失败自动回滚
#   8. 支持逐层恢复
#

set -Eeuo pipefail
umask 077

if (( BASH_VERSINFO[0] < 4 )); then
    printf '[错误] 本脚本需要 Bash 4.0 或更高版本。\n' >&2
    exit 1
fi

# ============================================================
# 基础配置
# ============================================================

SCRIPT_VERSION="3.2"

# 使用独立的 sysctl.d 配置文件。
SYSCTL_FILE="/etc/sysctl.d/99-z-network-optimize.conf"

# v3.1 及更早版本使用的配置文件。
LEGACY_SYSCTL_FILE="/etc/sysctl.d/99-network-optimize.conf"

LIMITS_FILE="/etc/security/limits.d/99-network-optimize.conf"
MODULES_FILE="/etc/modules-load.d/network-optimize.conf"

# 旧版脚本可能生成的 journald 配置。
LEGACY_JOURNALD_FILE="/etc/systemd/journald.conf.d/99-network-optimize.conf"

STATE_DIR="/var/lib/network-optimize"
BACKUP_ROOT="${STATE_DIR}/backups"
CURRENT_FILE="${STATE_DIR}/current"

# ============================================================
# 全局变量
# ============================================================

OS_ID="unknown"
memory_mb=0

profile=""
target_bw_mbps=1000
target_rtt_ms=100

# enable_forwarding 仅代表 IPv4 转发。
enable_forwarding=0
enable_ipv6_forwarding=0
enable_conntrack_tuning=0
enable_conntrack_timeout_tuning=0
enable_limits=0

conntrack_available=0
use_bbr=0
use_fq=0

bdp_bytes=0

rmem_max=0
wmem_max=0

tcp_rmem_min=4096
tcp_rmem_mid=0
tcp_wmem_min=4096
tcp_wmem_mid=0

udp_rmem_min=16384
udp_wmem_min=16384

netdev_max_backlog=0
somaxconn=0
tcp_max_syn_backlog=0

conntrack_max=0
nofile_target=0

ACTIVE_BACKUP=""
TRANSACTION_ACTIVE=0

declare -a PARAM_ORDER=()
declare -A PARAM_VALUES=()
declare -a SKIPPED_KEYS=()
declare -a MODULES_TO_LOAD=()

# ============================================================
# 颜色与日志
# ============================================================

if [[ -t 1 ]]; then
    RED=$'\033[0;31m'
    GREEN=$'\033[0;32m'
    YELLOW=$'\033[1;33m'
    BLUE=$'\033[0;34m'
    NC=$'\033[0m'
else
    RED=""
    GREEN=""
    YELLOW=""
    BLUE=""
    NC=""
fi

info() {
    printf '%s[信息]%s %s\n' "$GREEN" "$NC" "$*"
}

warn() {
    printf '%s[警告]%s %s\n' "$YELLOW" "$NC" "$*" >&2
}

error() {
    printf '%s[错误]%s %s\n' "$RED" "$NC" "$*" >&2
}

die() {
    error "$*"

    if [[ $TRANSACTION_ACTIVE -eq 1 && -n "$ACTIVE_BACKUP" ]]; then
        warn "检测到未完成的配置事务，正在自动回滚……"

        TRANSACTION_ACTIVE=0

        set +e
        restore_backup_contents "$ACTIVE_BACKUP" "rollback"
        set -e
    fi

    exit 1
}

# ============================================================
# 异常处理
# ============================================================

on_error() {
    local rc=$1
    local line=$2

    trap - ERR INT TERM

    error "脚本在第 ${line} 行发生错误，退出码: ${rc}"

    if [[ $TRANSACTION_ACTIVE -eq 1 && -n "$ACTIVE_BACKUP" ]]; then
        warn "正在恢复本次修改前的配置……"

        TRANSACTION_ACTIVE=0

        set +e
        restore_backup_contents "$ACTIVE_BACKUP" "rollback"
        set -e

        warn "自动回滚已执行。"
        warn "失败事务备份保留在: $ACTIVE_BACKUP"
    fi

    exit "$rc"
}

on_signal() {
    local rc=$1

    trap - ERR INT TERM

    warn "收到中断信号。"

    if [[ $TRANSACTION_ACTIVE -eq 1 && -n "$ACTIVE_BACKUP" ]]; then
        warn "正在恢复本次修改前的配置……"

        TRANSACTION_ACTIVE=0

        set +e
        restore_backup_contents "$ACTIVE_BACKUP" "rollback"
        set -e
    fi

    exit "$rc"
}

trap 'on_error $? $LINENO' ERR
trap 'on_signal 130' INT
trap 'on_signal 143' TERM

# ============================================================
# 通用工具
# ============================================================

require_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        die "此脚本必须以 root 权限运行。"
    fi
}

require_commands() {
    local command_name=""
    local missing=0

    for command_name in \
        sysctl mktemp cp mv rm mkdir chmod chown stat \
        date grep tee basename dirname awk cat id
    do
        if ! command -v "$command_name" >/dev/null 2>&1; then
            error "缺少必要命令: $command_name"
            missing=1
        fi
    done

    if [[ $missing -ne 0 ]]; then
        die "请先安装缺少的基础工具。"
    fi
}

min_value() {
    local a=$1
    local b=$2

    if (( a < b )); then
        printf '%s\n' "$a"
    else
        printf '%s\n' "$b"
    fi
}

max_value() {
    local a=$1
    local b=$2

    if (( a > b )); then
        printf '%s\n' "$a"
    else
        printf '%s\n' "$b"
    fi
}

is_uint() {
    [[ ${1:-} =~ ^[0-9]+$ ]]
}

get_sysctl_value() {
    local key=$1
    sysctl -n "$key" 2>/dev/null
}

get_sysctl_uint() {
    local key=$1
    local fallback=$2
    local value=""

    if value=$(get_sysctl_value "$key"); then
        if is_uint "$value"; then
            printf '%s\n' "$value"
            return 0
        fi
    fi

    printf '%s\n' "$fallback"
}

sysctl_key_exists() {
    local key=$1
    sysctl -n "$key" >/dev/null 2>&1
}

add_param() {
    local key=$1
    local value=$2

    if ! sysctl_key_exists "$key"; then
        SKIPPED_KEYS+=("$key")
        return 0
    fi

    if [[ -n ${PARAM_VALUES[$key]+present} ]]; then
        PARAM_VALUES["$key"]="$value"
        return 0
    fi

    PARAM_ORDER+=("$key")
    PARAM_VALUES["$key"]="$value"
}

add_module_once() {
    local module=$1
    local existing=""

    for existing in "${MODULES_TO_LOAD[@]}"; do
        if [[ "$existing" == "$module" ]]; then
            return 0
        fi
    done

    MODULES_TO_LOAD+=("$module")
}

ask_yes_no() {
    local prompt=$1
    local default_value=$2
    local answer=""

    while true; do
        read -r -p "$prompt" answer || die "无法读取输入。"

        if [[ -z "$answer" ]]; then
            answer=$default_value
        fi

        case "$answer" in
            y|Y|yes|YES|Yes)
                ASK_RESULT=1
                return 0
                ;;
            n|N|no|NO|No)
                ASK_RESULT=0
                return 0
                ;;
            *)
                error "请输入 y 或 n。"
                ;;
        esac
    done
}

read_integer() {
    local prompt=$1
    local default_value=$2
    local min_allowed=$3
    local max_allowed=$4
    local input=""

    while true; do
        read -r -p "$prompt" input || die "无法读取输入。"

        input=${input:-$default_value}

        if ! is_uint "$input"; then
            error "请输入有效的正整数。"
            continue
        fi

        if (( input < min_allowed || input > max_allowed )); then
            error "请输入 ${min_allowed} 到 ${max_allowed} 之间的数值。"
            continue
        fi

        READ_INTEGER_RESULT=$input
        return 0
    done
}

normalize_sysctl_value() {
    local value=${1:-}
    local -a fields=()

    read -r -a fields <<< "$value" || true
    printf '%s' "${fields[*]}"
}

# ============================================================
# 系统检测
# ============================================================

detect_os() {
    local mem_kb=0

    if [[ -r /etc/os-release ]]; then
        OS_ID=$(
            awk -F= '
                $1 == "ID" {
                    gsub(/"/, "", $2)
                    print $2
                    exit
                }
            ' /etc/os-release
        )

        OS_ID=${OS_ID:-unknown}
    elif [[ -f /etc/debian_version ]]; then
        OS_ID="debian"
    elif [[ -f /etc/redhat-release ]]; then
        OS_ID="rhel"
    fi

    if [[ -r /proc/meminfo ]]; then
        mem_kb=$(
            awk '
                /^MemTotal:/ {
                    print $2
                    exit
                }
            ' /proc/meminfo
        )
    fi

    if ! is_uint "${mem_kb:-}" || (( mem_kb <= 0 )); then
        memory_mb=1024
        warn "无法准确读取内存容量，暂按 1024 MB 计算。"
    else
        memory_mb=$((mem_kb / 1024))

        if (( memory_mb <= 0 )); then
            memory_mb=1
        fi
    fi

    info "操作系统: ${OS_ID}"
    info "物理内存: ${memory_mb} MB"
}

# ============================================================
# 安全状态目录
# ============================================================

ensure_secure_state_dir() {
    local path=""
    local owner_uid=""

    for path in "$STATE_DIR" "$BACKUP_ROOT"; do
        if [[ -L "$path" ]]; then
            die "安全检查失败，路径是符号链接: $path"
        fi

        if [[ -e "$path" && ! -d "$path" ]]; then
            die "安全检查失败，路径不是目录: $path"
        fi

        mkdir -p -- "$path"
        chown root:root "$path"
        chmod 0700 "$path"

        owner_uid=$(stat -c '%u' "$path")

        if [[ "$owner_uid" != "0" ]]; then
            die "安全检查失败，目录不属于 root: $path"
        fi
    done

    if [[ -L "$CURRENT_FILE" ]]; then
        die "安全检查失败，current 状态文件不能是符号链接。"
    fi

    if [[ -e "$CURRENT_FILE" && ! -f "$CURRENT_FILE" ]]; then
        die "安全检查失败，current 状态路径不是普通文件。"
    fi
}

# ============================================================
# 配置文件映射
# ============================================================

target_for_id() {
    local id=$1

    case "$id" in
        sysctl-z)
            printf '%s\n' "$SYSCTL_FILE"
            ;;
        sysctl-legacy)
            printf '%s\n' "$LEGACY_SYSCTL_FILE"
            ;;
        # 兼容 v3.1 及更早版本的备份格式。
        sysctl)
            printf '%s\n' "$LEGACY_SYSCTL_FILE"
            ;;
        limits)
            printf '%s\n' "$LIMITS_FILE"
            ;;
        modules)
            printf '%s\n' "$MODULES_FILE"
            ;;
        legacy-journald)
            printf '%s\n' "$LEGACY_JOURNALD_FILE"
            ;;
        *)
            return 1
            ;;
    esac
}

managed_ids() {
    printf '%s\n' \
        "sysctl-z" \
        "sysctl-legacy" \
        "limits" \
        "modules" \
        "legacy-journald"
}

validate_managed_target() {
    local path=$1

    if [[ -L "$path" ]]; then
        die "拒绝修改符号链接配置文件: $path"
    fi

    if [[ -e "$path" && ! -f "$path" ]]; then
        die "配置目标不是普通文件: $path"
    fi
}

get_current_backup_name() {
    local value=""

    if [[ ! -f "$CURRENT_FILE" ]]; then
        return 1
    fi

    value=$(<"$CURRENT_FILE")
    value=${value//$'\n'/}

    if [[ ! "$value" =~ ^[A-Za-z0-9._-]+$ ]]; then
        warn "current 状态文件内容无效，将忽略。"
        return 1
    fi

    if [[ -L "${BACKUP_ROOT}/${value}" ]]; then
        warn "current 指向了符号链接备份，将忽略。"
        return 1
    fi

    if [[ ! -d "${BACKUP_ROOT}/${value}" ]]; then
        warn "current 指向的备份不存在，将忽略: $value"
        return 1
    fi

    printf '%s\n' "$value"
}

set_current_backup_name() {
    local value=${1:-}
    local temp_file=""

    if [[ -z "$value" ]]; then
        rm -f -- "$CURRENT_FILE"
        return 0
    fi

    if [[ ! "$value" =~ ^[A-Za-z0-9._-]+$ ]]; then
        return 1
    fi

    temp_file=$(mktemp "${STATE_DIR}/.current.XXXXXX")

    printf '%s\n' "$value" > "$temp_file"

    chmod 0600 "$temp_file"
    chown root:root "$temp_file"

    mv -f -- "$temp_file" "$CURRENT_FILE"
}

# ============================================================
# 备份与恢复
# ============================================================

create_backup() {
    local timestamp=""
    local previous=""
    local id=""
    local target=""
    local backup_name=""

    ensure_secure_state_dir

    timestamp=$(date -u '+%Y%m%dT%H%M%SZ')
    ACTIVE_BACKUP=$(mktemp -d "${BACKUP_ROOT}/${timestamp}.XXXXXX")

    chmod 0700 "$ACTIVE_BACKUP"
    chown root:root "$ACTIVE_BACKUP"

    backup_name=$(basename "$ACTIVE_BACKUP")

    mkdir -p "${ACTIVE_BACKUP}/files"
    chmod 0700 "${ACTIVE_BACKUP}/files"

    if previous=$(get_current_backup_name); then
        printf '%s\n' "$previous" > "${ACTIVE_BACKUP}/previous"
    else
        : > "${ACTIVE_BACKUP}/previous"
    fi

    {
        printf 'version=%s\n' "$SCRIPT_VERSION"
        printf 'date_utc=%s\n' "$timestamp"
        printf 'os=%s\n' "$OS_ID"
        printf 'memory_mb=%s\n' "$memory_mb"
        printf 'profile=%s\n' "$profile"
        printf 'bandwidth_mbps=%s\n' "$target_bw_mbps"
        printf 'rtt_ms=%s\n' "$target_rtt_ms"
        printf 'ipv4_forwarding=%s\n' "$enable_forwarding"
        printf 'ipv6_forwarding=%s\n' "$enable_ipv6_forwarding"
        printf 'conntrack=%s\n' "$enable_conntrack_tuning"
        printf 'conntrack_timeout=%s\n' "$enable_conntrack_timeout_tuning"
        printf 'backup_name=%s\n' "$backup_name"
    } > "${ACTIVE_BACKUP}/metadata"

    : > "${ACTIVE_BACKUP}/manifest"

    while IFS= read -r id; do
        target=$(target_for_id "$id")
        validate_managed_target "$target"

        if [[ -f "$target" ]]; then
            cp -a -- "$target" "${ACTIVE_BACKUP}/files/${id}"
            printf '%s\tpresent\n' "$id" >> "${ACTIVE_BACKUP}/manifest"
        else
            printf '%s\tabsent\n' "$id" >> "${ACTIVE_BACKUP}/manifest"
        fi
    done < <(managed_ids)

    snapshot_runtime_sysctl

    info "本次配置备份已创建: $ACTIVE_BACKUP"
}

snapshot_runtime_sysctl() {
    local key=""
    local value=""
    local snapshot_file="${ACTIVE_BACKUP}/runtime-sysctl.tsv"

    : > "$snapshot_file"
    chmod 0600 "$snapshot_file"

    for key in "${PARAM_ORDER[@]}"; do
        if value=$(get_sysctl_value "$key"); then
            value=${value//$'\n'/ }
            value=${value//$'\t'/ }

            printf '%s\t%s\n' "$key" "$value" >> "$snapshot_file"
        else
            warn "无法保存运行时参数: $key"
        fi
    done
}

restore_managed_files() {
    local backup_dir=$1
    local id=""
    local state=""
    local target=""
    local source_file=""

    if [[ ! -f "${backup_dir}/manifest" ]]; then
        error "备份缺少 manifest: $backup_dir"
        return 1
    fi

    while IFS=$'\t' read -r id state; do
        [[ -n "$id" ]] || continue

        if ! target=$(target_for_id "$id"); then
            error "备份中包含未知配置项目: $id"
            return 1
        fi

        if [[ -L "$target" ]]; then
            error "恢复目标被替换为符号链接，拒绝继续: $target"
            return 1
        fi

        if [[ -e "$target" && ! -f "$target" ]]; then
            error "恢复目标不是普通文件: $target"
            return 1
        fi

        case "$state" in
            present)
                source_file="${backup_dir}/files/${id}"

                if [[ -L "$source_file" || ! -f "$source_file" ]]; then
                    error "备份文件损坏或类型异常: $source_file"
                    return 1
                fi

                mkdir -p "$(dirname "$target")"
                rm -f -- "$target"
                cp -a -- "$source_file" "$target"
                ;;
            absent)
                rm -f -- "$target"
                ;;
            *)
                error "无效的备份状态: $id -> $state"
                return 1
                ;;
        esac
    done < "${backup_dir}/manifest"
}

restore_runtime_sysctl() {
    local backup_dir=$1
    local mode=${2:-restore}
    local snapshot_file="${backup_dir}/runtime-sysctl.tsv"
    local log_file="${backup_dir}/${mode}-runtime.log"
    local key=""
    local value=""
    local failures=0

    if [[ ! -f "$snapshot_file" ]]; then
        warn "备份中不存在运行时 sysctl 快照。"
        return 0
    fi

    : > "$log_file"

    while IFS=$'\t' read -r key value; do
        [[ -n "$key" ]] || continue

        if [[ ! "$key" =~ ^[A-Za-z0-9_.]+$ ]]; then
            warn "跳过备份中的无效 sysctl 名称: $key"
            failures=$((failures + 1))
            continue
        fi

        if ! sysctl -w "${key}=${value}" >> "$log_file" 2>&1; then
            warn "恢复运行时参数失败: $key"
            failures=$((failures + 1))
        fi
    done < "$snapshot_file"

    if (( failures > 0 )); then
        warn "共有 ${failures} 个运行时参数未能恢复。"
        warn "详细日志: $log_file"
    fi

    return 0
}

restore_backup_contents() {
    local backup_dir=$1
    local mode=${2:-restore}
    local system_log="${backup_dir}/${mode}-sysctl-system.log"

    if [[ -L "$backup_dir" ]]; then
        error "备份目录不能是符号链接: $backup_dir"
        return 1
    fi

    if [[ ! -d "$backup_dir" ]]; then
        error "备份目录不存在: $backup_dir"
        return 1
    fi

    info "正在恢复配置文件……"

    if ! restore_managed_files "$backup_dir"; then
        error "配置文件恢复失败。"
        return 1
    fi

    if ! sysctl --system > "$system_log" 2>&1; then
        warn "执行 sysctl --system 时存在错误。"
        warn "详细日志: $system_log"
    fi

    restore_runtime_sysctl "$backup_dir" "$mode"

    return 0
}

restore_latest_backup() {
    local backup_name=""
    local backup_dir=""
    local previous=""
    local answer=""

    ensure_secure_state_dir

    if ! backup_name=$(get_current_backup_name); then
        die "没有找到可恢复的有效备份。"
    fi

    backup_dir="${BACKUP_ROOT}/${backup_name}"

    printf '\n'
    warn "即将恢复以下备份:"
    printf '  %s\n\n' "$backup_dir"

    read -r -p "确认恢复吗？[y/N]: " answer || die "无法读取输入。"
    answer=${answer:-N}

    if [[ ! "$answer" =~ ^[Yy]$ ]]; then
        info "已取消恢复。"
        return 0
    fi

    restore_backup_contents "$backup_dir" "restore"

    if [[ -f "${backup_dir}/previous" ]]; then
        previous=$(<"${backup_dir}/previous")
        previous=${previous//$'\n'/}
    fi

    if [[ -n "$previous" \
        && "$previous" =~ ^[A-Za-z0-9._-]+$ \
        && ! -L "${BACKUP_ROOT}/${previous}" \
        && -d "${BACKUP_ROOT}/${previous}" ]]; then

        set_current_backup_name "$previous"
    else
        set_current_backup_name ""
    fi

    info "配置恢复完成。"

    warn "已经加载的内核模块不会被强制卸载。"
    warn "limits.d 的变化只影响新的登录会话。"
}

# ============================================================
# 内核功能检测
# ============================================================

prepare_kernel_features() {
    local available_cc=""
    local fq_ready=0
    local modprobe_output=""

    use_bbr=0
    use_fq=0
    conntrack_available=0
    MODULES_TO_LOAD=()

    # --------------------------------------------------------
    # 检测 BBR
    # --------------------------------------------------------

    if command -v modprobe >/dev/null 2>&1; then
        modprobe tcp_bbr >/dev/null 2>&1 || true
    fi

    if available_cc=$(
        get_sysctl_value "net.ipv4.tcp_available_congestion_control"
    ); then
        if grep -qw "bbr" <<< "$available_cc"; then
            use_bbr=1

            if command -v modprobe >/dev/null 2>&1; then
                add_module_once "tcp_bbr"
            fi
        fi
    fi

    if [[ $use_bbr -eq 1 ]]; then
        if command -v modprobe >/dev/null 2>&1; then
            if modprobe sch_fq >/dev/null 2>&1; then
                fq_ready=1
                add_module_once "sch_fq"
            fi
        fi

        if [[ -d /sys/module/sch_fq ]]; then
            fq_ready=1
        fi

        if [[ $fq_ready -eq 1 ]] \
            && sysctl_key_exists "net.core.default_qdisc"; then

            use_fq=1
        else
            warn "内核支持 BBR，但未确认 FQ 队列模块可用。"
            warn "将启用 BBR，但保留当前默认 qdisc。"
        fi
    else
        warn "当前内核未提供 BBR，将保留原有拥塞控制算法。"
    fi

    # --------------------------------------------------------
    # 检测 conntrack
    # --------------------------------------------------------

    if [[ $enable_conntrack_tuning -eq 1 ]]; then
        info "用户已请求启用 nf_conntrack 调优。"

        if ! sysctl_key_exists "net.netfilter.nf_conntrack_max"; then
            if ! command -v modprobe >/dev/null 2>&1; then
                die "系统不存在 modprobe，且 nf_conntrack 尚未加载。"
            fi

            info "正在加载 nf_conntrack 内核模块……"

            if ! modprobe_output=$(modprobe nf_conntrack 2>&1); then
                error "加载 nf_conntrack 失败:"
                printf '%s\n' "$modprobe_output" >&2
                die "用户请求了 conntrack 调优，但模块无法加载。"
            fi
        fi

        if ! sysctl_key_exists "net.netfilter.nf_conntrack_max"; then
            die "nf_conntrack 已尝试加载，但内核未提供 nf_conntrack_max。"
        fi

        conntrack_available=1

        if command -v modprobe >/dev/null 2>&1; then
            add_module_once "nf_conntrack"
        fi

        info "nf_conntrack 已就绪，将写入连接追踪配置。"
    fi
}

# ============================================================
# 参数计算
# ============================================================

calculate_params() {
    local profile_buffer_cap=0
    local profile_mid_rmem=0
    local profile_mid_wmem=0

    local desired_backlog=0
    local desired_somaxconn=0
    local desired_syn_backlog=0
    local desired_conntrack=0

    local memory_bytes=0
    local memory_socket_cap=0
    local effective_cap=0
    local desired_buffer=0

    local memory_conntrack_cap=0
    local current_conntrack_count=0
    local conntrack_live_min=0

    local nr_open=1048576

    # 1 Mbps × 1 ms = 125 bytes。
    bdp_bytes=$((target_bw_mbps * 125 * target_rtt_ms))
    memory_bytes=$((memory_mb * 1024 * 1024))

    case "$profile" in
        minimal)
            profile_buffer_cap=$((16 * 1024 * 1024))
            profile_mid_rmem=131072
            profile_mid_wmem=16384

            desired_backlog=2048
            desired_somaxconn=4096
            desired_syn_backlog=4096
            desired_conntrack=65536
            nofile_target=65536
            ;;
        conservative)
            profile_buffer_cap=$((64 * 1024 * 1024))
            profile_mid_rmem=262144
            profile_mid_wmem=65536

            desired_backlog=8192
            desired_somaxconn=8192
            desired_syn_backlog=8192
            desired_conntrack=262144
            nofile_target=262144
            ;;
        aggressive)
            profile_buffer_cap=$((256 * 1024 * 1024))
            profile_mid_rmem=$((1 * 1024 * 1024))
            profile_mid_wmem=262144

            desired_backlog=32768
            desired_somaxconn=32768
            desired_syn_backlog=32768
            desired_conntrack=1048576
            nofile_target=1048576
            ;;
        *)
            die "未知配置档位: $profile"
            ;;
    esac

    # 单个 socket 的最大缓冲区预算约为物理内存的 1/16。
    memory_socket_cap=$((memory_bytes / 16))

    if (( memory_socket_cap < 8 * 1024 * 1024 )); then
        memory_socket_cap=$((8 * 1024 * 1024))
    fi

    effective_cap=$(
        min_value "$profile_buffer_cap" "$memory_socket_cap"
    )

    # 最大缓冲区按 2 倍 BDP 计算。
    desired_buffer=$((bdp_bytes * 2))

    # 最低为 8 MiB。
    if (( desired_buffer < 8 * 1024 * 1024 )); then
        desired_buffer=$((8 * 1024 * 1024))
    fi

    desired_buffer=$(
        min_value "$desired_buffer" "$effective_cap"
    )

    # --------------------------------------------------------
    # TCP 缓冲区
    #
    # 完全使用本次档位计算结果，不继承旧脚本留下的值。
    # --------------------------------------------------------

    tcp_rmem_min=4096
    tcp_wmem_min=4096

    rmem_max=$desired_buffer
    wmem_max=$desired_buffer

    tcp_rmem_mid=$profile_mid_rmem
    tcp_wmem_mid=$profile_mid_wmem

    if (( tcp_rmem_mid > rmem_max )); then
        tcp_rmem_mid=$rmem_max
    fi

    if (( tcp_wmem_mid > wmem_max )); then
        tcp_wmem_mid=$wmem_max
    fi

    # --------------------------------------------------------
    # 队列参数
    #
    # 使用本次档位值，不继承旧脚本的激进参数。
    # --------------------------------------------------------

    netdev_max_backlog=$desired_backlog
    somaxconn=$desired_somaxconn
    tcp_max_syn_backlog=$desired_syn_backlog

    # UDP 最小缓冲区。
    udp_rmem_min=16384
    udp_wmem_min=16384

    # --------------------------------------------------------
    # Conntrack 容量
    # --------------------------------------------------------

    if [[ $conntrack_available -eq 1 ]]; then
        # 按每个潜在 conntrack 条目预留约 16 KiB 总内存预算。
        memory_conntrack_cap=$((memory_bytes / 16384))

        if (( memory_conntrack_cap < 32768 )); then
            memory_conntrack_cap=32768
        fi

        conntrack_max=$(
            min_value "$desired_conntrack" "$memory_conntrack_cap"
        )

        current_conntrack_count=$(
            get_sysctl_uint "net.netfilter.nf_conntrack_count" 0
        )

        # 至少保留当前使用量的 25% 余量，并额外保留 1024 个条目。
        conntrack_live_min=$(( current_conntrack_count * 5 / 4 + 1024 ))

        if (( conntrack_live_min < 32768 )); then
            conntrack_live_min=32768
        fi

        if (( conntrack_max < conntrack_live_min )); then
            conntrack_max=$conntrack_live_min

            warn "Conntrack 当前使用量较高。"
            warn "为避免容量低于当前使用量，上限调整为 ${conntrack_max}。"
        fi
    fi

    # --------------------------------------------------------
    # 文件句柄
    # --------------------------------------------------------

    if sysctl_key_exists "fs.nr_open"; then
        nr_open=$(get_sysctl_uint "fs.nr_open" 1048576)
    fi

    if (( nofile_target > nr_open )); then
        nofile_target=$nr_open
    fi
}

# ============================================================
# 构造 sysctl 参数
# ============================================================

build_sysctl_params() {
    PARAM_ORDER=()
    PARAM_VALUES=()
    SKIPPED_KEYS=()

    # 网络核心缓冲区。
    add_param "net.core.rmem_max" "$rmem_max"
    add_param "net.core.wmem_max" "$wmem_max"
    add_param "net.core.netdev_max_backlog" "$netdev_max_backlog"
    add_param "net.core.somaxconn" "$somaxconn"

    # TCP 缓冲区。
    add_param \
        "net.ipv4.tcp_rmem" \
        "${tcp_rmem_min} ${tcp_rmem_mid} ${rmem_max}"

    add_param \
        "net.ipv4.tcp_wmem" \
        "${tcp_wmem_min} ${tcp_wmem_mid} ${wmem_max}"

    add_param \
        "net.ipv4.tcp_max_syn_backlog" \
        "$tcp_max_syn_backlog"

    add_param "net.ipv4.tcp_mtu_probing" "1"
    add_param "net.ipv4.tcp_window_scaling" "1"
    add_param "net.ipv4.tcp_moderate_rcvbuf" "1"

    # TCP Fast Open 仅启用客户端模式。
    add_param "net.ipv4.tcp_fastopen" "1"

    # UDP 最小缓冲区。
    add_param "net.ipv4.udp_rmem_min" "$udp_rmem_min"
    add_param "net.ipv4.udp_wmem_min" "$udp_wmem_min"

    # IPv4 转发。
    if [[ $enable_forwarding -eq 1 ]]; then
        add_param "net.ipv4.ip_forward" "1"
    fi

    # IPv6 转发。
    if [[ $enable_ipv6_forwarding -eq 1 ]]; then
        add_param "net.ipv6.conf.all.forwarding" "1"
        add_param "net.ipv6.conf.default.forwarding" "1"
    fi

    # Conntrack。
    if [[ $conntrack_available -eq 1 ]]; then
        add_param \
            "net.netfilter.nf_conntrack_max" \
            "$conntrack_max"

        if [[ $enable_conntrack_timeout_tuning -eq 1 ]]; then
            add_param \
                "net.netfilter.nf_conntrack_tcp_timeout_established" \
                "7200"

            add_param \
                "net.netfilter.nf_conntrack_tcp_timeout_time_wait" \
                "120"

            add_param \
                "net.netfilter.nf_conntrack_tcp_timeout_close_wait" \
                "60"

            add_param \
                "net.netfilter.nf_conntrack_tcp_timeout_fin_wait" \
                "120"

            add_param \
                "net.netfilter.nf_conntrack_tcp_timeout_syn_recv" \
                "60"

            add_param \
                "net.netfilter.nf_conntrack_udp_timeout" \
                "30"

            add_param \
                "net.netfilter.nf_conntrack_udp_timeout_stream" \
                "120"
        fi
    fi

    # BBR 和 FQ。
    if [[ $use_bbr -eq 1 ]]; then
        add_param \
            "net.ipv4.tcp_congestion_control" \
            "bbr"
    fi

    if [[ $use_fq -eq 1 ]]; then
        add_param "net.core.default_qdisc" "fq"
    fi
}

# ============================================================
# 检查重复配置
# ============================================================

check_sysctl_conflicts() {
    local key=""
    local escaped_key=""
    local file=""
    local conflict_count=0
    local -a files=(
        /etc/sysctl.conf
        /etc/sysctl.d/*.conf
        /usr/lib/sysctl.d/*.conf
        /lib/sysctl.d/*.conf
    )

    for key in "${PARAM_ORDER[@]}"; do
        escaped_key=${key//./\\.}

        for file in "${files[@]}"; do
            [[ -f "$file" ]] || continue

            if [[ "$file" == "$SYSCTL_FILE" \
                || "$file" == "$LEGACY_SYSCTL_FILE" ]]; then
                continue
            fi

            if grep -Eq \
                "^[[:space:]]*${escaped_key}[[:space:]]*=" \
                "$file" 2>/dev/null; then

                warn "发现重复 sysctl 参数: $key"
                warn "冲突文件: $file"
                conflict_count=$((conflict_count + 1))
            fi
        done
    done

    if (( conflict_count > 0 )); then
        warn "其他配置文件可能在启动或执行 sysctl --system 时覆盖本脚本参数。"
        warn "建议检查并移除重复配置。"
    fi
}

# ============================================================
# 原子写入配置
# ============================================================

write_sysctl_file() {
    local temp_file=""
    local key=""

    validate_managed_target "$SYSCTL_FILE"

    mkdir -p "$(dirname "$SYSCTL_FILE")"
    temp_file=$(mktemp "${SYSCTL_FILE}.tmp.XXXXXX")

    {
        printf '# TCP/IP network optimization\n'
        printf '# Generated by network optimize script v%s\n' \
            "$SCRIPT_VERSION"
        printf '# Profile: %s\n' "$profile"
        printf '# Bandwidth: %s Mbps\n' "$target_bw_mbps"
        printf '# RTT: %s ms\n' "$target_rtt_ms"
        printf '# BDP: %s bytes\n' "$bdp_bytes"
        printf '\n'

        for key in "${PARAM_ORDER[@]}"; do
            printf '%s = %s\n' "$key" "${PARAM_VALUES[$key]}"
        done
    } > "$temp_file"

    chmod 0644 "$temp_file"
    chown root:root "$temp_file"

    mv -f -- "$temp_file" "$SYSCTL_FILE"
}

remove_legacy_sysctl_file() {
    validate_managed_target "$LEGACY_SYSCTL_FILE"

    if [[ -f "$LEGACY_SYSCTL_FILE" ]]; then
        rm -f -- "$LEGACY_SYSCTL_FILE"
        info "已迁移并移除旧版 sysctl 配置文件。"
    fi
}

write_limits_file() {
    local temp_file=""

    validate_managed_target "$LIMITS_FILE"

    mkdir -p "$(dirname "$LIMITS_FILE")"

    if [[ $enable_limits -ne 1 ]]; then
        rm -f -- "$LIMITS_FILE"
        return 0
    fi

    temp_file=$(mktemp "${LIMITS_FILE}.tmp.XXXXXX")

    cat > "$temp_file" <<EOF
# Generated by network optimize script v${SCRIPT_VERSION}
#
# 主要影响新的 PAM 登录会话。
# systemd 服务请在服务单元中设置 LimitNOFILE。

*    soft    nofile    ${nofile_target}
*    hard    nofile    ${nofile_target}
root soft    nofile    ${nofile_target}
root hard    nofile    ${nofile_target}
EOF

    chmod 0644 "$temp_file"
    chown root:root "$temp_file"

    mv -f -- "$temp_file" "$LIMITS_FILE"
}

write_modules_file() {
    local temp_file=""
    local module=""

    validate_managed_target "$MODULES_FILE"

    mkdir -p "$(dirname "$MODULES_FILE")"
    temp_file=$(mktemp "${MODULES_FILE}.tmp.XXXXXX")

    {
        printf '# Generated by network optimize script v%s\n' \
            "$SCRIPT_VERSION"

        for module in "${MODULES_TO_LOAD[@]}"; do
            printf '%s\n' "$module"
        done
    } > "$temp_file"

    chmod 0644 "$temp_file"
    chown root:root "$temp_file"

    mv -f -- "$temp_file" "$MODULES_FILE"
}

remove_legacy_journald_file() {
    validate_managed_target "$LEGACY_JOURNALD_FILE"

    if [[ -f "$LEGACY_JOURNALD_FILE" ]]; then
        rm -f -- "$LEGACY_JOURNALD_FILE"
        info "已移除旧版脚本生成的 journald 配置。"
    fi
}

# ============================================================
# 应用与验证
# ============================================================

apply_sysctl_file() {
    local output=""
    local rc=0
    local log_file="${ACTIVE_BACKUP}/apply.log"

    info "正在应用网络参数……"

    if output=$(sysctl -p "$SYSCTL_FILE" 2>&1); then
        rc=0
    else
        rc=$?
    fi

    printf '%s\n' "$output" | tee "$log_file"

    if (( rc != 0 )); then
        error "sysctl 配置应用失败，准备自动回滚。"
        return "$rc"
    fi

    info "sysctl 配置应用成功。"
}

verify_param() {
    local key=$1
    local expected=$2

    local actual=""
    local expected_normalized=""
    local actual_normalized=""

    if ! actual=$(get_sysctl_value "$key"); then
        printf '  %-48s %s无法读取%s\n' \
            "$key" "$RED" "$NC"
        return 0
    fi

    expected_normalized=$(normalize_sysctl_value "$expected")
    actual_normalized=$(normalize_sysctl_value "$actual")

    if [[ "$actual_normalized" == "$expected_normalized" ]]; then
        printf '  %-48s %sOK%s\n' \
            "$key" "$GREEN" "$NC"
    else
        printf '  %-48s %s不一致%s\n' \
            "$key" "$YELLOW" "$NC"

        printf '    期望: %s\n' "$expected"
        printf '    实际: %s\n' "$actual"
    fi
}

verify_applied_config() {
    local key=""

    printf '\n'
    printf '%s================ 应用验证 ================%s\n' \
        "$BLUE" "$NC"

    for key in "${PARAM_ORDER[@]}"; do
        verify_param "$key" "${PARAM_VALUES[$key]}"
    done

    printf '%s==========================================%s\n' \
        "$BLUE" "$NC"
}

# ============================================================
# 配置摘要
# ============================================================

show_summary() {
    local actual_cc="unknown"
    local actual_qdisc="unknown"
    local actual_ipv4_forwarding="unknown"
    local actual_ipv6_forwarding="unknown"

    actual_cc=$(
        get_sysctl_value "net.ipv4.tcp_congestion_control" \
            || printf 'unknown'
    )

    actual_qdisc=$(
        get_sysctl_value "net.core.default_qdisc" \
            || printf 'unknown'
    )

    actual_ipv4_forwarding=$(
        get_sysctl_value "net.ipv4.ip_forward" \
            || printf 'unknown'
    )

    actual_ipv6_forwarding=$(
        get_sysctl_value "net.ipv6.conf.all.forwarding" \
            || printf 'unknown'
    )

    printf '\n'
    printf '%s================ 配置摘要 ================%s\n' \
        "$GREEN" "$NC"

    printf '配置档位       : %s\n' "$profile"
    printf '目标带宽       : %s Mbps\n' "$target_bw_mbps"
    printf '目标 RTT       : %s ms\n' "$target_rtt_ms"
    printf '目标 BDP       : %s bytes\n' "$bdp_bytes"
    printf '系统内存       : %s MB\n' "$memory_mb"

    printf '最大接收缓冲   : %s bytes\n' "$rmem_max"
    printf '最大发送缓冲   : %s bytes\n' "$wmem_max"

    printf 'TCP 接收中间值 : %s bytes\n' "$tcp_rmem_mid"
    printf 'TCP 发送中间值 : %s bytes\n' "$tcp_wmem_mid"

    printf 'UDP 接收最小值 : %s bytes\n' "$udp_rmem_min"
    printf 'UDP 发送最小值 : %s bytes\n' "$udp_wmem_min"

    printf 'netdev backlog : %s\n' "$netdev_max_backlog"
    printf 'somaxconn      : %s\n' "$somaxconn"
    printf 'SYN backlog    : %s\n' "$tcp_max_syn_backlog"

    printf '拥塞控制       : %s\n' "$actual_cc"
    printf '默认 qdisc     : %s\n' "$actual_qdisc"

    if [[ $enable_forwarding -eq 1 ]]; then
        printf 'IPv4 转发      : 已开启\n'
    else
        printf 'IPv4 转发      : 本次未修改，当前值 %s\n' \
            "$actual_ipv4_forwarding"
    fi

    if [[ $enable_ipv6_forwarding -eq 1 ]]; then
        printf 'IPv6 转发      : 已开启\n'
    else
        printf 'IPv6 转发      : 本次未修改，当前值 %s\n' \
            "$actual_ipv6_forwarding"
    fi

    if [[ $conntrack_available -eq 1 ]]; then
        printf 'Conntrack 状态 : 已调优\n'
        printf 'Conntrack 上限 : %s\n' "$conntrack_max"

        if [[ $enable_conntrack_timeout_tuning -eq 1 ]]; then
            printf 'Conntrack 超时 : 已启用高周转配置\n'
            printf '  established  : 7200 秒\n'
            printf '  time_wait    : 120 秒\n'
            printf '  close_wait   : 60 秒\n'
            printf '  fin_wait     : 120 秒\n'
            printf '  syn_recv     : 60 秒\n'
            printf '  UDP          : 30 秒\n'
            printf '  UDP stream   : 120 秒\n'
        else
            printf 'Conntrack 超时 : 本次未修改\n'
        fi
    else
        printf 'Conntrack 调优 : 本次未启用\n'
    fi

    if [[ $enable_limits -eq 1 ]]; then
        printf '登录会话 nofile: %s\n' "$nofile_target"
    else
        printf '登录会话 limits: 未配置\n'
    fi

    printf 'sysctl 文件    : %s\n' "$SYSCTL_FILE"
    printf '配置备份       : %s\n' "$ACTIVE_BACKUP"

    printf '%s==========================================%s\n' \
        "$GREEN" "$NC"

    if (( ${#SKIPPED_KEYS[@]} > 0 )); then
        printf '\n'
        warn "以下内核参数不存在，因此已跳过:"
        printf '  - %s\n' "${SKIPPED_KEYS[@]}"
    fi

    if [[ $enable_limits -eq 1 ]]; then
        printf '\n'
        warn "limits.d 仅影响新的 PAM 登录会话和部分应用。"
        warn "systemd 服务应单独配置 LimitNOFILE。"
    fi
}

# ============================================================
# 用户配置
# ============================================================

select_profile() {
    local choice=""

    printf '\n请选择优化档位:\n'
    printf '1) minimal      小型 VPS / 低内存环境\n'
    printf '2) conservative 普通服务器，推荐默认值\n'
    printf '3) aggressive   高并发 / 高吞吐服务器\n'

    while true; do
        read -r -p "请输入选项 [1-3]，默认 2: " choice \
            || die "无法读取输入。"

        choice=${choice:-2}

        case "$choice" in
            1)
                profile="minimal"
                return 0
                ;;
            2)
                profile="conservative"
                return 0
                ;;
            3)
                profile="aggressive"
                return 0
                ;;
            *)
                error "请输入 1、2 或 3。"
                ;;
        esac
    done
}

collect_user_options() {
    local ASK_RESULT=0
    local READ_INTEGER_RESULT=0

    select_profile

    printf '\n'

    ask_yes_no \
        "是否开启 IPv4 转发？仅路由器或 NAT 网关需要 [y/N]: " \
        "N"

    enable_forwarding=$ASK_RESULT

    ask_yes_no \
        "是否开启 IPv6 转发？可能影响 RA/SLAAC 获取默认路由 [y/N]: " \
        "N"

    enable_ipv6_forwarding=$ASK_RESULT

    ask_yes_no \
        "是否调优 nf_conntrack？仅 NAT/状态防火墙节点建议开启 [y/N]: " \
        "N"

    enable_conntrack_tuning=$ASK_RESULT

    if [[ $enable_conntrack_tuning -eq 1 ]]; then
        ask_yes_no \
            "是否缩短 conntrack 空闲连接超时？高连接周转节点可开启 [y/N]: " \
            "N"

        enable_conntrack_timeout_tuning=$ASK_RESULT
    else
        enable_conntrack_timeout_tuning=0
    fi

    printf '\n'

    read_integer \
        "请输入目标网络带宽 Mbps，默认 1000: " \
        "1000" \
        "1" \
        "1000000"

    target_bw_mbps=$READ_INTEGER_RESULT

    read_integer \
        "请输入目标 RTT 毫秒，默认 100: " \
        "100" \
        "1" \
        "60000"

    target_rtt_ms=$READ_INTEGER_RESULT

    printf '\n'

    ask_yes_no \
        "是否写入登录会话 nofile 限制？systemd 服务通常需单独配置 [y/N]: " \
        "N"

    enable_limits=$ASK_RESULT
}

# ============================================================
# 优化事务
# ============================================================

optimize_network() {
    local backup_name=""

    collect_user_options

    info "正在检测内核功能……"
    prepare_kernel_features

    info "正在计算网络参数……"
    calculate_params
    build_sysctl_params

    if (( ${#PARAM_ORDER[@]} == 0 )); then
        die "没有可应用的 sysctl 参数。"
    fi

    check_sysctl_conflicts

    create_backup
    TRANSACTION_ACTIVE=1

    write_sysctl_file
    remove_legacy_sysctl_file
    write_limits_file
    write_modules_file
    remove_legacy_journald_file

    apply_sysctl_file

    backup_name=$(basename "$ACTIVE_BACKUP")
    set_current_backup_name "$backup_name"

    TRANSACTION_ACTIVE=0

    verify_applied_config
    show_summary

    printf '\n'
    info "网络优化完成。"
    info "如需恢复，请重新运行脚本并选择“恢复最近一次配置”。"

    if [[ $enable_limits -eq 1 ]]; then
        warn "nofile 限制需要重新登录或重启对应服务后才会生效。"
    fi

    if [[ $enable_forwarding -eq 1 ]]; then
        warn "开启 IPv4 转发并不等于已配置 NAT。"
        warn "NAT 和防火墙规则仍需通过 nftables/iptables/firewalld 配置。"
    fi

    if [[ $enable_ipv6_forwarding -eq 1 ]]; then
        warn "开启 IPv6 转发可能改变 RA 接收行为。"
        warn "如果上游通过 RA 提供默认路由，请检查对应接口的 accept_ra。"
    fi
}

# ============================================================
# 主菜单
# ============================================================

show_banner() {
    printf '%s\n' \
        "${GREEN}==============================================${NC}" \
        "${GREEN}       TCP/IP 网络优化脚本 v${SCRIPT_VERSION}${NC}" \
        "${GREEN}==============================================${NC}"
}

show_usage() {
    cat <<EOF
用法:
  $0
  $0 --optimize
  $0 --restore
  $0 --help

选项:
  --optimize    进入网络优化流程
  --restore     恢复最近一次配置
  --help        显示帮助
EOF
}

interactive_menu() {
    local choice=""

    printf '\n'
    printf '请选择操作:\n'
    printf '1) 优化网络配置\n'
    printf '2) 恢复最近一次配置\n'
    printf '3) 退出\n'

    while true; do
        read -r -p "请输入选项 [1-3]: " choice \
            || die "无法读取输入。"

        case "$choice" in
            1)
                optimize_network
                return 0
                ;;
            2)
                restore_latest_backup
                return 0
                ;;
            3)
                return 0
                ;;
            *)
                error "请输入 1、2 或 3。"
                ;;
        esac
    done
}

main() {
    local action=${1:-}

    case "$action" in
        --help|-h)
            show_usage
            return 0
            ;;
    esac

    require_root
    require_commands
    detect_os
    ensure_secure_state_dir
    show_banner

    case "$action" in
        "")
            interactive_menu
            ;;
        --optimize)
            optimize_network
            ;;
        --restore)
            restore_latest_backup
            ;;
        *)
            show_usage
            exit 1
            ;;
    esac
}

main "$@"
