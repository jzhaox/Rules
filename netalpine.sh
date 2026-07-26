#!/usr/bin/env bash
#
# netalpine.sh
# Alpine Linux VPS network tuning for AnyTLS, VLESS/WS/TLS/CDN,
# sing-box/Xray, Hysteria/QUIC and Shadowsocks-2022 relay workloads.
#
# Alpine port of proxy-net-tune (net.sh). Same logic and flow, but:
#   - OpenRC instead of systemd (rc.conf / conf.d / init.d, no unit drop-ins).
#   - BusyBox userland assumptions (no sysctl --system, no find -printf,
#     no sort -V, no prlimit, no PAM limits.conf by default).
#   - Memory tiers designed for the sub-1 GiB VPS that Alpine usually runs on.
#   - No XanMod / no prebuilt BBRv3: kernel advice uses apk linux-* flavors.
#   - Extra primary-protocol profile: SS2022 relay with partial split routing.
#
# This script intentionally does NOT set panic-on-OOM, kernel panic timers,
# arbitrary TIME_WAIT limits, obsolete TCP knobs, ARP tuning, or CAKE shaping.

# --- POSIX preamble: must stay ash-parsable, runs before any bash syntax. ---
if [ -z "${BASH_VERSION-}" ]; then
    if command -v bash >/dev/null 2>&1; then
        exec bash "$0" "$@"
    fi
    _na_yes=0
    for _na_arg in "$@"; do
        case "$_na_arg" in
            --yes | -y) _na_yes=1 ;;
        esac
    done
    if [ ! -r "$0" ]; then
        echo "此脚本需要 bash，且不能用管道直接运行。" >&2
        echo "请先保存为文件再执行: apk add --no-cache bash && bash netalpine.sh" >&2
        exit 1
    fi
    if [ "$(id -u 2>/dev/null || echo 1)" != "0" ] || ! command -v apk >/dev/null 2>&1; then
        echo "此脚本需要 bash。请先执行: apk add --no-cache bash" >&2
        exit 1
    fi
    if [ "$_na_yes" != "1" ]; then
        if [ -t 0 ]; then
            printf '当前系统没有 bash，本脚本依赖 bash 数组等特性。\n' >&2
            printf '是否现在执行 apk add --no-cache bash? [Y/n]: ' >&2
            read -r _na_ans
            case "$_na_ans" in
                n* | N*) echo "已取消。请手动执行: apk add --no-cache bash" >&2; exit 1 ;;
            esac
        else
            echo "非交互模式且没有 bash。请先执行: apk add --no-cache bash" >&2
            exit 1
        fi
    fi
    echo "正在安装 bash ..." >&2
    apk add --no-cache bash || { echo "bash 安装失败。" >&2; exit 1; }
    exec bash "$0" "$@"
fi
# --- End POSIX preamble. Everything below may use bash features. ---

set -u
set -o pipefail

readonly SCRIPT_VERSION="1.0.0"
readonly BASED_ON="proxy-net-tune 1.4.0 (Debian)"
readonly PROGRAM_NAME="netalpine"
readonly SYSCTL_CONF="/etc/sysctl.d/99-zz-netalpine.conf"
readonly MODULES_CONF="/etc/modules-load.d/99-zz-netalpine.conf"
readonly PROFILE_LIMITS="/etc/profile.d/99-zz-netalpine-limits.sh"
readonly PAM_LIMITS_CONF="/etc/security/limits.d/99-zz-netalpine.conf"
readonly RC_CONF="/etc/rc.conf"
readonly CONFD_DIR="/etc/conf.d"
readonly INITD_DIR="/etc/init.d"
readonly INITCWND_SERVICE="netalpine-initcwnd"
readonly INITCWND_INITD="/etc/init.d/netalpine-initcwnd"
readonly INITCWND_RUNLEVEL="/etc/runlevels/default/netalpine-initcwnd"
readonly STATE_DIR="/var/lib/netalpine"
readonly BACKUP_ROOT="/var/backups/netalpine"
readonly MARK_BEGIN="# >>> netalpine managed block begin >>>"
readonly MARK_END="# <<< netalpine managed block end <<<"
readonly MIB=1048576

ACTION="apply"
DRY_RUN=0
ASSUME_YES=0
NO_APK=0
LOCAL_MBPS=""
SERVER_MBPS=""
IP_MODE=""
RTT_INPUT=""
RELAY_MBPS_INPUT=""
RELAY_RTT_INPUT=""
RELAY_SHARE_INPUT=""
HYSTERIA_RANGE_INPUT="auto"
PROTOCOL_INPUT=""
PROTOCOL="general"
PROTOCOL_LABEL="通用（未指定主力协议）"
INITCWND_INPUT=""
INITCWND=0
APPLYING=0
ACTIVE_BACKUP=""

# Populated by detection/calculation.
MEM_MB=0
SWAP_MB=0
CPU_CORES=1
ARCH="unknown"
KERNEL_RELEASE="unknown"
KERNEL_FLAVOR=""
VIRT_TYPE="unknown"
ALPINE_VERSION=""
PRIMARY_IFACE=""
RTT_MS=0
RTT_SOURCE="用户提供的本机实测值"
RELAY_MBPS=0
RELAY_RTT_MS=0
RELAY_SHARE=50
RELAY_EFFECTIVE_MBPS=0
RELAY_PATH_RTT=0
RELAY_BDP_BYTES=0
DESIGN_BDP_BYTES=0
EFFECTIVE_MBPS=0
BDP_BYTES=0
BUFFER_MIB=0
BUFFER_BYTES=0
BUFFER_CAP_MIB=0
BUFFER_WAS_CAPPED=0
NETDEV_BACKLOG=2048
SOMAXCONN=2048
SYN_BACKLOG=4096
NOTSENT_LOWAT=65536
SOCK_DEFAULT=131072
TCP_RMEM_DEF=131072
TCP_WMEM_DEF=32768
KEEPALIVE_TIME=1200
KEEPALIVE_INTVL=30
KEEPALIVE_PROBES=5
NOFILE_LIMIT=131072
MIN_FREE_KB=0
SELECTED_CC="cubic"
SELECTED_QDISC="fq"
KERNEL_ADVICE=""
KERNEL_ADVICE_DETAIL=""
RECOMMEND_KERNEL=0
OFFER_KERNEL_INSTALL=0
KERNEL_PACKAGE=""
KERNEL_INSTALLED=0
FUTURE_BBR_ONLY=0
INSTALLED_KERNEL_SOURCE=""
CURRENT_BBR_GENERATION="未知"
BBR_MODULE_VERSION=""
HYSTERIA_DETECTED=0
HYSTERIA_RESERVED_PORTS=""
HYSTERIA_RANGE_SOURCE="未检测到"
HYSTERIA_BELOW_RECOMMENDED=0
TCP_MEM_HIGH_MIB=""
HAVE_IPROUTE2=0
HAVE_TC=0
HAVE_PRLIMIT=0
HAVE_OPENRC=0
APK_INSTALLED_PKGS=""

declare -a SYSCTL_KEYS=()
declare -a SYSCTL_VALUES=()
declare -a SYSCTL_NOTES=()
declare -a SKIPPED_SETTINGS=()
declare -a PROFILE_NOTES=()
declare -a PROXY_SERVICES=()
declare -a PROXY_PIDS=()
declare -a CONFD_SERVICES=()
declare -a CONFD_PATHS=()
declare -a MISSING_PKGS=()

if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'
    C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_CYAN=$'\033[36m'
    C_BOLD=$'\033[1m'
else
    C_RESET=""
    C_RED=""
    C_GREEN=""
    C_YELLOW=""
    C_CYAN=""
    C_BOLD=""
fi

info() { printf '%s[信息]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s[注意]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
error() { printf '%s[错误]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
heading() { printf '\n%s%s%s\n' "$C_BOLD$C_CYAN" "$*" "$C_RESET"; }

die() {
    error "$*"
    exit 1
}

usage() {
    cat <<'EOF'
用法:
  bash netalpine.sh [选项]    # 请先登录 root（Alpine Linux 专用）

默认行为是交互式分析并应用配置。

选项:
  --local-mbps N     本地宽带，默认 1000 Mbps
  --server-mbps N    本机 VPS 标称带宽，默认 1000 Mbps
  --ip-mode MODE     4、6 或 dual，默认 dual
  --rtt-ms N         本机到 VPS 的真实往返延迟（毫秒）；CDN 模式填 VPS 到边缘的 RTT
  --protocol P       主力协议: ss2022、anytls、hysteria、vless-cdn、ss2022-relay 或 general
  --relay-mbps N     仅 ss2022-relay：落地 VPS 的标称带宽 Mbps
  --relay-rtt-ms N   仅 ss2022-relay：本机（中转）到落地 VPS 的实测 RTT 毫秒
  --relay-share N    仅 ss2022-relay：走落地机的流量占比 5-100，默认 50
  --initcwnd N       提升默认路由 initcwnd/initrwnd；0 关闭，或 10-64（需 iproute2）
  --hysteria-range R Hysteria 端口跳跃范围；auto、none 或如 50000:51000
  --no-apk           不安装任何缺失的软件包（iproute2 等）
  --dry-run          只生成并显示配置，不修改系统
  --yes              跳过网络配置确认（不会跳过内核操作确认）
  --status           显示当前网络调优状态
  --restore          恢复最近一次网络/FD 配置（不卸载内核或软件包）
  --self-test        执行内置计算测试
  --help             显示帮助

示例:
  bash netalpine.sh
  bash netalpine.sh --dry-run --server-mbps 500 --rtt-ms 80 --ip-mode dual
  bash netalpine.sh --protocol ss2022 --initcwnd 25
  bash netalpine.sh --protocol ss2022-relay --rtt-ms 40 --relay-rtt-ms 130 --relay-mbps 300
  bash netalpine.sh --protocol hysteria --hysteria-range 50000:51000
  bash netalpine.sh --restore
EOF
}

is_uint() {
    [[ ${1:-} =~ ^[0-9]+$ ]]
}

clamp() {
    local value=$1 minimum=$2 maximum=$3
    ((value < minimum)) && value=$minimum
    ((value > maximum)) && value=$maximum
    printf '%s\n' "$value"
}

make_temp() {
    local base candidate
    for base in "${TMPDIR:-/tmp}" /var/tmp /run "$PWD"; do
        [[ -d $base && -w $base ]] || continue
        candidate=$(mktemp "$base/netalpine.XXXXXX" 2>/dev/null) || continue
        printf '%s\n' "$candidate"
        return 0
    done
    return 1
}

make_temp_dir() {
    local base candidate
    for base in "${TMPDIR:-/tmp}" /var/tmp /run "$PWD"; do
        [[ -d $base && -w $base ]] || continue
        candidate=$(mktemp -d "$base/netalpine.XXXXXX" 2>/dev/null) || continue
        printf '%s\n' "$candidate"
        return 0
    done
    return 1
}

cleanup_temp_dir() {
    local path=${1:-}
    case $path in
        /tmp/netalpine.* | /var/tmp/netalpine.* | /run/netalpine.* | "$PWD"/netalpine.*)
            [[ -d $path ]] && rm -rf -- "$path"
            ;;
    esac
}

normalize_sysctl_value() {
    awk '{$1=$1; print}' <<<"${1:-}"
}

normalize_user_input() {
    # Pasted confirmations often carry invisible leading/trailing spaces.
    # Trim them and collapse repeated whitespace without relaxing letter case.
    awk '{$1=$1; print}' <<<"${1:-}"
}

decimal_ge() {
    # Compare non-negative decimal integers without overflowing bash arithmetic.
    local a=${1:-0} b=${2:-0}
    [[ $a =~ ^[0-9]+$ && $b =~ ^[0-9]+$ ]] || return 1
    while [[ $a == 0* && ${#a} -gt 1 ]]; do a=${a#0}; done
    while [[ $b == 0* && ${#b} -gt 1 ]]; do b=${b#0}; done
    if ((${#a} != ${#b})); then
        ((${#a} > ${#b}))
    else
        [[ $a == "$b" || $a > "$b" ]]
    fi
}

# BusyBox sort has no -V, so version comparison is done in pure bash.
version_ge() {
    local have=${1%%-*} want=${2%%-*} index left right
    local -a have_parts=() want_parts=()
    IFS='.' read -r -a have_parts <<<"$have"
    IFS='.' read -r -a want_parts <<<"$want"
    for ((index = 0; index < 4; index++)); do
        left=${have_parts[index]:-0}
        right=${want_parts[index]:-0}
        left=${left//[!0-9]/}
        right=${right//[!0-9]/}
        left=$((10#${left:-0}))
        right=$((10#${right:-0}))
        ((left > right)) && return 0
        ((left < right)) && return 1
    done
    return 0
}

sysctl_path() {
    printf '/proc/sys/%s\n' "${1//./\/}"
}

sysctl_exists() {
    [[ -e $(sysctl_path "$1") ]]
}

get_sysctl() {
    sysctl -n "$1" 2>/dev/null || true
}

set_sysctl() {
    sysctl -q -w "$1=$2" >/dev/null 2>&1
}

word_in_list() {
    local needle=$1 list=$2 word
    for word in $list; do
        [[ $word == "$needle" ]] && return 0
    done
    return 1
}

have_cmd() {
    command -v "$1" >/dev/null 2>&1
}

# BusyBox ships a reduced "ip" applet without initcwnd support; only the real
# iproute2 binary can change route metrics.
have_iproute2_ip() {
    ip -V 2>/dev/null | grep -qi iproute2
}

apk_available() {
    have_cmd apk
}

apk_installed() {
    apk_available && apk info -e "$1" >/dev/null 2>&1
}

proc_field() {
    local pid=$1 label=$2 column=$3
    [[ -r /proc/$pid/limits ]] || return 1
    awk -v want="$label" -v col="$column" '
        index($0, want) == 1 { print $col; exit }
    ' "/proc/$pid/limits" 2>/dev/null
}

proc_nofile_soft() { proc_field "$1" "Max open files" 4; }
proc_nofile_hard() { proc_field "$1" "Max open files" 5; }

proc_name() {
    local pid=$1 name=""
    [[ -r /proc/$pid/comm ]] && read -r name <"/proc/$pid/comm" 2>/dev/null
    printf '%s\n' "$name"
}

# --- managed marker blocks (rc.conf / conf.d files we must not clobber) ---

has_managed_block() {
    [[ -f ${1:-} ]] && grep -Fxq "$MARK_BEGIN" "$1" 2>/dev/null
}

write_managed_block() {
    local file=$1 mode=$2 body temp rc
    body=$(cat)
    temp=$(make_temp) || return 1
    if [[ -f $file ]]; then
        awk -v begin="$MARK_BEGIN" -v end="$MARK_END" '
            $0 == begin { skip = 1; next }
            $0 == end { skip = 0; next }
            skip != 1 { print }
        ' "$file" >"$temp" || { rm -f -- "$temp"; return 1; }
    else
        : >"$temp" || { rm -f -- "$temp"; return 1; }
    fi
    {
        printf '%s\n' "$MARK_BEGIN"
        printf '# Generated by %s v%s -- 请勿手工编辑本块，--restore 会整体还原\n' \
            "$PROGRAM_NAME" "$SCRIPT_VERSION"
        printf '%s\n' "$body"
        printf '%s\n' "$MARK_END"
    } >>"$temp" || { rm -f -- "$temp"; return 1; }
    mkdir -p -- "$(dirname "$file")" || { rm -f -- "$temp"; return 1; }
    install -m "$mode" "$temp" "$file"
    rc=$?
    rm -f -- "$temp"
    return $rc
}

managed_block_body() {
    local file=$1
    [[ -f $file ]] || return 1
    awk -v begin="$MARK_BEGIN" -v end="$MARK_END" '
        $0 == end { inside = 0 }
        inside == 1 { print }
        $0 == begin { inside = 1 }
    ' "$file"
}

write_atomic_file() {
    local destination=$1 mode=$2 temp rc
    temp=$(make_temp) || return 1
    cat >"$temp" || { rm -f -- "$temp"; return 1; }
    mkdir -p -- "$(dirname "$destination")" || { rm -f -- "$temp"; return 1; }
    install -m "$mode" "$temp" "$destination"
    rc=$?
    rm -f -- "$temp"
    return $rc
}

normalize_port_ranges() {
    local raw=${1:-}
    raw=${raw//[[:space:]]/}
    raw=${raw//:/-}
    [[ -n $raw ]] || return 0
    awk -v raw="$raw" '
        BEGIN {
            count = split(raw, parts, ",")
            for (i = 1; i <= count; i++) {
                if (parts[i] !~ /^[0-9]+(-[0-9]+)?$/) exit 2
                fields = split(parts[i], pair, "-")
                start[i] = pair[1] + 0
                finish[i] = (fields == 2 ? pair[2] : pair[1]) + 0
                if (start[i] < 1 || finish[i] > 65535 || start[i] > finish[i]) exit 2
            }
            for (i = 2; i <= count; i++) {
                s = start[i]; e = finish[i]; j = i - 1
                while (j >= 1 && (start[j] > s || (start[j] == s && finish[j] > e))) {
                    start[j + 1] = start[j]; finish[j + 1] = finish[j]; j--
                }
                start[j + 1] = s; finish[j + 1] = e
            }
            current_start = start[1]; current_finish = finish[1]; output = ""
            for (i = 2; i <= count; i++) {
                if (start[i] <= current_finish + 1) {
                    if (finish[i] > current_finish) current_finish = finish[i]
                } else {
                    item = (current_start == current_finish ? current_start : current_start "-" current_finish)
                    output = output (output == "" ? "" : ",") item
                    current_start = start[i]; current_finish = finish[i]
                }
            }
            item = (current_start == current_finish ? current_start : current_start "-" current_finish)
            print output (output == "" ? "" : ",") item
        }
    '
}

merge_port_ranges() {
    local combined="" piece normalized
    for piece in "$@"; do
        piece=${piece//[[:space:]]/}
        [[ -n $piece ]] || continue
        combined+="${combined:+,}$piece"
    done
    [[ -n $combined ]] || return 0
    normalized=$(normalize_port_ranges "$combined") || return 1
    printf '%s\n' "$normalized"
}

# --- Alpine / OpenRC environment detection ---

require_alpine() {
    local os_id="" version_id=""
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        os_id=${ID:-}
        version_id=${VERSION_ID:-}
    fi
    if [[ -z $os_id && -r /etc/alpine-release ]]; then
        os_id="alpine"
    fi
    [[ -z $version_id && -r /etc/alpine-release ]] && read -r version_id </etc/alpine-release
    ALPINE_VERSION=$version_id
    if [[ $os_id != "alpine" ]]; then
        if ((DRY_RUN == 1)); then
            warn "当前不是 Alpine Linux；试运行继续，但不会保证配置兼容。"
            return 0
        fi
        die "此版本只支持 Alpine Linux VPS（Debian/Ubuntu 请使用 net.sh）。"
    fi
}

require_root() {
    ((EUID == 0)) || die "应用或恢复配置需要 root 权限；请先登录 root 后再运行脚本。"
}

require_commands() {
    local missing=() command_name
    for command_name in awk sed grep head sysctl ip uname; do
        have_cmd "$command_name" || missing+=("$command_name")
    done
    ((${#missing[@]} == 0)) \
        || die "缺少必要命令: ${missing[*]}。请执行 apk add --no-cache busybox-extras iproute2 后重试。"
}

is_container_guest() {
    case $VIRT_TYPE in
        docker | lxc | lxc-libvirt | openvz | podman | systemd-nspawn | wsl | proot \
            | container-other | incus | lxd)
            return 0
            ;;
    esac
    [[ -e /.dockerenv || -e /run/.containerenv ]]
}

detect_virt() {
    local vendor="" product="" flags="" marker=""
    VIRT_TYPE="unknown"
    if have_cmd systemd-detect-virt; then
        VIRT_TYPE=$(systemd-detect-virt 2>/dev/null) || VIRT_TYPE="none"
        [[ -n $VIRT_TYPE ]] && return 0
    fi
    [[ -e /.dockerenv ]] && { VIRT_TYPE="docker"; return 0; }
    [[ -e /run/.containerenv ]] && { VIRT_TYPE="podman"; return 0; }
    [[ -e /proc/user_beancounters ]] && { VIRT_TYPE="openvz"; return 0; }
    [[ -d /proc/vz && ! -d /proc/bc ]] && { VIRT_TYPE="openvz"; return 0; }
    [[ -S /dev/lxd/sock ]] && { VIRT_TYPE="lxd"; return 0; }
    if [[ -r /proc/1/environ ]]; then
        marker=$(tr '\0' '\n' </proc/1/environ 2>/dev/null | grep -m1 '^container=' || true)
        [[ -n $marker ]] && { VIRT_TYPE=${marker#container=}; return 0; }
    fi
    if [[ -r /proc/1/cgroup ]]; then
        marker=$(tr '\n' ' ' </proc/1/cgroup 2>/dev/null || true)
        case $marker in
            *docker*) VIRT_TYPE="docker"; return 0 ;;
            *lxc*) VIRT_TYPE="lxc"; return 0 ;;
        esac
    fi
    grep -qs lxcfs /proc/self/mountinfo && { VIRT_TYPE="lxc"; return 0; }
    if [[ -r /sys/hypervisor/type ]]; then
        read -r product </sys/hypervisor/type 2>/dev/null || product=""
        [[ $product == xen ]] && { VIRT_TYPE="xen"; return 0; }
    fi
    [[ -r /sys/class/dmi/id/sys_vendor ]] && read -r vendor </sys/class/dmi/id/sys_vendor 2>/dev/null
    [[ -r /sys/class/dmi/id/product_name ]] && read -r product </sys/class/dmi/id/product_name 2>/dev/null
    case "$vendor $product" in
        *QEMU* | *KVM* | *"Red Hat"*) VIRT_TYPE="kvm"; return 0 ;;
        *VMware*) VIRT_TYPE="vmware"; return 0 ;;
        *VirtualBox* | *innotek*) VIRT_TYPE="virtualbox"; return 0 ;;
        *Microsoft*) VIRT_TYPE="microsoft"; return 0 ;;
        *Xen*) VIRT_TYPE="xen"; return 0 ;;
        *Amazon* | *EC2*) VIRT_TYPE="amazon"; return 0 ;;
        *Google*) VIRT_TYPE="google"; return 0 ;;
        *Bochs* | *Parallels* | *OpenStack*) VIRT_TYPE="vm"; return 0 ;;
    esac
    flags=$(awk -F: '/^flags[[:space:]]*:/ {print " " $2 " "; exit}' /proc/cpuinfo 2>/dev/null || true)
    [[ $flags == *" hypervisor "* ]] && { VIRT_TYPE="vm"; return 0; }
    VIRT_TYPE="none"
    return 0
}

detect_openrc() {
    HAVE_OPENRC=0
    have_cmd rc-update && have_cmd rc-service && [[ -d $INITD_DIR ]] && HAVE_OPENRC=1
    return 0
}

detect_tools() {
    HAVE_IPROUTE2=0
    HAVE_TC=0
    HAVE_PRLIMIT=0
    have_iproute2_ip && HAVE_IPROUTE2=1
    have_cmd tc && HAVE_TC=1
    have_cmd prlimit && HAVE_PRLIMIT=1
    return 0
}

collect_missing_packages() {
    MISSING_PKGS=()
    apk_available || return 0
    ((HAVE_IPROUTE2 == 1)) || MISSING_PKGS+=("iproute2:完整的 ip 命令，支持 initcwnd/initrwnd 与路由细节")
    ((HAVE_TC == 1)) || MISSING_PKGS+=("iproute2-tc:tc 命令，才能把网卡队列即时切换到 fq")
    ((HAVE_PRLIMIT == 1)) || MISSING_PKGS+=("util-linux-misc:prlimit 命令，免重启提升运行中代理进程的 FD 上限")
    return 0
}

maybe_install_packages() {
    local entry name desc answer names=() rendered=""
    ((NO_APK == 1)) && return 0
    ((DRY_RUN == 1)) && return 0
    apk_available || return 0
    ((${#MISSING_PKGS[@]})) || return 0
    heading "可选依赖（Alpine 精简系统默认没有装）"
    for entry in "${MISSING_PKGS[@]}"; do
        name=${entry%%:*}
        desc=${entry#*:}
        printf '  %-18s %s\n' "$name" "$desc"
        names+=("$name")
        rendered+="${rendered:+ }$name"
    done
    printf '说明             : 这些是发行版官方源里的小工具包；--restore 不会卸载它们。\n'
    printf '不装的后果       : initcwnd 与 tc 即时生效会被跳过，sysctl 主体配置仍然照常写入。\n'
    if ((ASSUME_YES == 0)); then
        if [[ ! -t 0 ]]; then
            warn "非交互模式未加 --yes，跳过安装: $rendered"
            return 0
        fi
        read -r -p "现在执行 apk add --no-cache $rendered ? [Y/n]: " answer
        answer=$(normalize_user_input "$answer")
        case ${answer:-Y} in
            n* | N*) info "已跳过依赖安装。"; return 0 ;;
        esac
    fi
    if apk add --no-cache "${names[@]}"; then
        APK_INSTALLED_PKGS=$rendered
        info "已安装: $rendered"
    else
        warn "apk 安装失败；脚本会在缺少这些工具的前提下继续。"
    fi
    detect_tools
    collect_missing_packages
    return 0
}

# --- proxy service / process discovery (OpenRC) ---

is_proxy_process_name() {
    local name=${1##*/}
    name=${name,,}
    case $name in
        xray | xray-* | v2ray | v2ray-* | sing-box | sing-box-* | singbox | singbox-* \
            | hysteria | hysteria-* | hysteria2 | hysteria2-* | hysteria3 | hysteria3-* \
            | anytls | anytls-* | ssserver | ss-server | ss-local | sslocal \
            | shadowsocks-* | ssmanager | snell-server | mihomo | clash | clash-*) return 0 ;;
        *) return 1 ;;
    esac
}

is_proxy_service_name() {
    local name=${1,,}
    case $name in
        *xray* | *v2ray* | *sing-box* | *singbox* | *hysteria* | *anytls* \
            | *shadowsocks* | ss-server | ssserver | *snell* | mihomo | clash | clash-*)
            return 0
            ;;
        *) return 1 ;;
    esac
}

valid_service_name() {
    [[ ${1:-} =~ ^[A-Za-z0-9][-A-Za-z0-9_.]*$ ]]
}

add_unique_service() {
    local name=$1 existing
    valid_service_name "$name" || return 0
    [[ $name == "$INITCWND_SERVICE" ]] && return 0
    for existing in "${PROXY_SERVICES[@]}"; do
        [[ $existing == "$name" ]] && return 0
    done
    PROXY_SERVICES+=("$name")
}

discover_proxy_services() {
    PROXY_SERVICES=()
    PROXY_PIDS=()
    local path name entry pid command_line process_name

    if [[ -d $INITD_DIR ]]; then
        for path in "$INITD_DIR"/*; do
            [[ -f $path ]] || continue
            name=${path##*/}
            is_proxy_service_name "$name" && add_unique_service "$name"
        done
    fi
    # Any conf.d file we previously managed belongs to a service we still own.
    if [[ -d $CONFD_DIR ]]; then
        for path in "$CONFD_DIR"/*; do
            [[ -f $path ]] || continue
            has_managed_block "$path" || continue
            name=${path##*/}
            add_unique_service "$name"
        done
    fi

    # BusyBox find has no -printf, so walk /proc with a plain glob instead.
    for entry in /proc/[0-9]*; do
        pid=${entry#/proc/}
        [[ $pid =~ ^[0-9]+$ ]] || continue
        [[ -r $entry/cmdline ]] || continue
        command_line=$(tr '\0' ' ' 2>/dev/null <"$entry/cmdline" || true)
        process_name=${command_line%% *}
        if ! is_proxy_process_name "$process_name"; then
            process_name=$(proc_name "$pid")
            is_proxy_process_name "$process_name" || continue
        fi
        PROXY_PIDS+=("$pid")
    done
    return 0
}

confd_nofile_value() {
    local path=$1 line value
    [[ -f $path ]] || return 1
    line=$(grep -E '^[[:space:]]*(export[[:space:]]+)?rc_ulimit=' "$path" 2>/dev/null | tail -n1 || true)
    [[ -n $line ]] || return 1
    value=$(sed -nE 's/.*-n[[:space:]]+([0-9]+).*/\1/p' <<<"$line")
    [[ -n $value ]] || return 1
    printf '%s\n' "$value"
}

plan_service_confd() {
    CONFD_SERVICES=()
    CONFD_PATHS=()
    local service path current
    for service in "${PROXY_SERVICES[@]}"; do
        path="$CONFD_DIR/$service"
        if has_managed_block "$path"; then
            CONFD_SERVICES+=("$service")
            CONFD_PATHS+=("$path")
            continue
        fi
        if current=$(confd_nofile_value "$path") && decimal_ge "$current" "$NOFILE_LIMIT"; then
            continue
        fi
        CONFD_SERVICES+=("$service")
        CONFD_PATHS+=("$path")
    done
    return 0
}

detect_hysteria_presence() {
    local service
    for service in "${PROXY_SERVICES[@]}"; do
        [[ ${service,,} == *hysteria* ]] && return 0
    done
    have_cmd hysteria && return 0
    have_cmd hysteria2 && return 0
    [[ -d /etc/hysteria || -d /etc/hysteria2 || -d /usr/local/etc/hysteria ]] && return 0
    return 1
}

detect_hysteria_port_ranges() {
    local raw="" candidate root file rules
    local -a files=()

    for root in /etc/hysteria /etc/hysteria2 /usr/local/etc/hysteria /usr/local/etc/hysteria2; do
        [[ -d $root ]] || continue
        while IFS= read -r -d '' file; do files+=("$file"); done \
            < <(find "$root" -maxdepth 3 -type f \
                \( -name '*.yaml' -o -name '*.yml' -o -name '*.json' \) -size -1024k -print0 2>/dev/null)
    done
    if ((${#files[@]})); then
        while IFS= read -r candidate; do
            [[ -n $candidate ]] && raw+="${raw:+,}$candidate"
        done < <(grep -hEi 'listen.*[0-9]{1,5}-[0-9]{1,5}' "${files[@]}" 2>/dev/null \
            | sed -nE 's/.*listen.*[^0-9]([0-9]{1,5})-([0-9]{1,5})([^0-9].*)?$/\1-\2/p')
    fi

    if have_cmd nft; then
        rules=$(nft list ruleset 2>/dev/null || true)
        while IFS= read -r candidate; do
            [[ -n $candidate ]] && raw+="${raw:+,}$candidate"
        done < <(printf '%s\n' "$rules" \
            | sed -nE '/udp/ {/dport/ {/(redirect|dnat)/ s/.*dport[[:space:]]+(\{[[:space:]]*)?([0-9]{1,5})[-:]([0-9]{1,5}).*/\2-\3/p; }}')
    fi
    for rules in "$(have_cmd iptables-save && iptables-save 2>/dev/null || true)" \
        "$(have_cmd ip6tables-save && ip6tables-save 2>/dev/null || true)"; do
        [[ -n $rules ]] || continue
        while IFS= read -r candidate; do
            [[ -n $candidate ]] && raw+="${raw:+,}$candidate"
        done < <(printf '%s\n' "$rules" \
            | sed -nE '/(-p|--protocol)[[:space:]]+udp/ {/(REDIRECT|DNAT)/ s/.*--dport[[:space:]]+([0-9]{1,5}):([0-9]{1,5}).*/\1-\2/p; }')
    done

    [[ -n $raw ]] || return 0
    normalize_port_ranges "$raw"
}

configure_hysteria_port_hopping() {
    local detected="" answer="" normalized=""
    HYSTERIA_DETECTED=0
    HYSTERIA_RESERVED_PORTS=""
    HYSTERIA_RANGE_SOURCE="未检测到"
    detect_hysteria_presence && HYSTERIA_DETECTED=1
    [[ $PROTOCOL == "hysteria" ]] && HYSTERIA_DETECTED=1

    case ${HYSTERIA_RANGE_INPUT,,} in
        none | off | no)
            HYSTERIA_RANGE_SOURCE="用户明确禁用"
            return 0
            ;;
        auto)
            detected=$(detect_hysteria_port_ranges) || detected=""
            if [[ -n $detected ]]; then
                HYSTERIA_RESERVED_PORTS=$detected
                HYSTERIA_RANGE_SOURCE="从 Hysteria 配置或防火墙自动检测"
                HYSTERIA_DETECTED=1
                return 0
            fi
            if ((HYSTERIA_DETECTED == 1)) && [[ -t 0 ]]; then
                printf '\n检测到 Hysteria，但没有可靠识别端口跳跃范围。\n' >&2
                read -r -p "端口跳跃范围（常见脚本默认 50000:51000；未启用请直接回车）: " answer
                answer=$(normalize_user_input "$answer")
                [[ -n $answer ]] || { HYSTERIA_RANGE_SOURCE="检测到 Hysteria，未启用或未提供跳跃范围"; return 0; }
                normalized=$(normalize_port_ranges "$answer") \
                    || die "Hysteria 端口范围无效；请使用如 50000:51000"
                HYSTERIA_RESERVED_PORTS=$normalized
                HYSTERIA_RANGE_SOURCE="用户提供"
            elif ((HYSTERIA_DETECTED == 1)); then
                HYSTERIA_RANGE_SOURCE="检测到 Hysteria，但非交互模式未取得跳跃范围"
            fi
            ;;
        *)
            normalized=$(normalize_port_ranges "$HYSTERIA_RANGE_INPUT") \
                || die "--hysteria-range 无效；请使用 auto、none 或如 50000:51000"
            [[ -n $normalized ]] || die "--hysteria-range 不能为空"
            HYSTERIA_RESERVED_PORTS=$normalized
            HYSTERIA_RANGE_SOURCE="命令行提供"
            HYSTERIA_DETECTED=1
            ;;
    esac
}

inspect_tcp_mem() {
    local values low pressure high page_size
    TCP_MEM_HIGH_MIB=""
    values=$(get_sysctl net.ipv4.tcp_mem)
    read -r low pressure high <<<"$values"
    is_uint "${high:-}" || return 0
    page_size=$(getconf PAGESIZE 2>/dev/null || printf '4096')
    is_uint "$page_size" || page_size=4096
    TCP_MEM_HIGH_MIB=$((high * page_size / MIB))
}

# --- interactive prompts ---

prompt_uint() {
    local label=$1 default=$2 minimum=$3 maximum=$4 value
    while true; do
        read -r -p "$label [$default]: " value
        value=$(normalize_user_input "$value")
        value=${value:-$default}
        if is_uint "$value" && ((value >= minimum && value <= maximum)); then
            printf '%s\n' "$value"
            return 0
        fi
        warn "请输入 ${minimum}-${maximum} 范围内的整数。"
    done
}

prompt_required_uint() {
    local label=$1 minimum=$2 maximum=$3 value
    while true; do
        read -r -p "$label: " value || return 1
        value=$(normalize_user_input "$value")
        if is_uint "$value" && ((value >= minimum && value <= maximum)); then
            printf '%s\n' "$value"
            return 0
        fi
        warn "此项没有自动估算值，请输入 ${minimum}-${maximum} 范围内的整数。"
    done
}

prompt_ip_mode() {
    local answer
    while true; do
        cat >&2 <<'EOF'
IP 网络类型:
  1) 仅 IPv4
  2) 仅 IPv6
  3) IPv4 + IPv6 双栈（默认）
EOF
        read -r -p "请选择 [3]: " answer
        answer=$(normalize_user_input "$answer")
        case ${answer:-3} in
            1 | 4 | ipv4 | IPv4) printf '4\n'; return 0 ;;
            2 | 6 | ipv6 | IPv6) printf '6\n'; return 0 ;;
            3 | dual | Dual | both) printf 'dual\n'; return 0 ;;
            *) warn "请选择 1、2 或 3。" ;;
        esac
    done
}

confirm_apply() {
    ((ASSUME_YES == 1)) && return 0
    local answer
    read -r -p "确认写入并应用以上配置？输入 YES 继续: " answer
    answer=$(normalize_user_input "$answer")
    [[ $answer == "YES" ]]
}

normalize_protocol() {
    local raw=${1,,}
    case $raw in
        1 | ss | ss2022 | shadowsocks | shadowsocks2022 | shadowsocks-2022) PROTOCOL="ss2022" ;;
        2 | anytls | any-tls) PROTOCOL="anytls" ;;
        3 | hy | hy2 | hysteria | hysteria2) PROTOCOL="hysteria" ;;
        4 | vless | vless-cdn | vless-ws | vless-ws-cdn | cdn | ws) PROTOCOL="vless-cdn" ;;
        5 | relay | ss-relay | ssrelay | ss2022-relay | ss2022relay | ss2022-中转 | 中转) PROTOCOL="ss2022-relay" ;;
        0 | general | auto | none) PROTOCOL="general" ;;
        *) return 1 ;;
    esac
    return 0
}

prompt_protocol() {
    local answer
    while true; do
        cat >&2 <<'EOF'

当前主力代理协议（决定针对性优化方向）:
  1) Shadowsocks 2022        TCP 直连；Quantumult X 原生支持
  2) AnyTLS                  TCP+TLS 多路复用；Quantumult X v1.6.0+ 支持
  3) Hysteria2               UDP/QUIC；QX 不支持，供 sing-box 等客户端使用
  4) VLESS+WS+TLS + CF CDN   TCP，经 Cloudflare 回源；QX 支持
  5) SS2022 + 部分分流中转    本机 SS2022 入站，按规则把部分流量再用 SS2022 转发到落地 VPS
  0) 通用模式                不针对特定协议，保持通用行为
EOF
        read -r -p "请选择 [1]: " answer
        answer=$(normalize_user_input "$answer")
        normalize_protocol "${answer:-1}" && return 0
        warn "请选择 0-5，或直接输入协议名（如 ss2022、hysteria、ss2022-relay）。"
    done
}

select_protocol() {
    if [[ -n $PROTOCOL_INPUT ]]; then
        normalize_protocol "$PROTOCOL_INPUT" \
            || die "--protocol 无效；可用 ss2022、anytls、hysteria、vless-cdn、ss2022-relay 或 general"
    elif [[ -t 0 ]]; then
        prompt_protocol
    else
        PROTOCOL="general"
        warn "非交互模式未提供 --protocol，按通用模式优化（不做协议针对性调整）。"
    fi
}

set_rtt_input() {
    local rtt_label="本机到 VPS 的真实往返延迟 RTT（ms）"
    RTT_SOURCE="用户提供的本机实测值"
    if [[ $PROTOCOL == "vless-cdn" ]]; then
        rtt_label="VPS 到 Cloudflare 回源边缘的 RTT（ms）"
        RTT_SOURCE="用户提供的 VPS 到 CF 边缘实测值"
    elif [[ $PROTOCOL == "ss2022-relay" ]]; then
        rtt_label="客户端到本机（中转机）的真实往返延迟 RTT（ms）"
        RTT_SOURCE="用户提供的客户端到中转机实测值"
    fi
    if [[ -z $RTT_INPUT ]]; then
        if [[ -t 0 ]]; then
            if [[ $PROTOCOL == "vless-cdn" ]]; then
                printf '\nCDN 回源模式：TCP 在 Cloudflare 边缘就终结了，VPS 只看得到 VPS<->CF 这一段。\n' >&2
                printf '请在 VPS 上执行 ping www.cloudflare.com，填写 avg 平均值（通常 1-80 ms）。\n' >&2
            elif [[ $PROTOCOL == "ss2022-relay" ]]; then
                printf '\n中转模式要分两段填：先填客户端到这台中转机的 RTT。\n' >&2
                printf '在你的客户端设备上 ping 这台 VPS，填 avg 平均值；稍后再填中转机到落地机那一段。\n' >&2
            else
                printf '\n请在本机 ping 这台 VPS，填写 avg/平均延迟。\n' >&2
                printf 'ping 显示的 time/avg 本身就是往返 RTT，不要再乘 2；例如 ping avg=80 ms 就输入 80。\n' >&2
            fi
            RTT_INPUT=$(prompt_required_uint "$rtt_label" 1 1000) \
                || die "未读取到 RTT，已取消。"
        else
            die "非交互运行必须提供 --rtt-ms N（$rtt_label）"
        fi
    fi
    is_uint "$RTT_INPUT" && ((RTT_INPUT >= 1 && RTT_INPUT <= 1000)) \
        || die "RTT 必须是 1-1000 ms 的整数"
    RTT_MS=$RTT_INPUT
}

set_relay_inputs() {
    [[ $PROTOCOL == "ss2022-relay" ]] || return 0

    if [[ -z $RELAY_RTT_INPUT ]]; then
        if [[ -t 0 ]]; then
            printf '\n第二段：中转机到落地 VPS 的 RTT。\n' >&2
            printf '在这台中转机上 ping 落地 VPS 的 IP，填 avg 平均值。\n' >&2
            printf '被中转的流量要走完“客户端->中转->落地”两段，缓冲区按两段之和计算。\n' >&2
            RELAY_RTT_INPUT=$(prompt_required_uint "中转机到落地 VPS 的 RTT（ms）" 1 1000) \
                || die "未读取到中转段 RTT，已取消。"
        else
            die "非交互运行 ss2022-relay 必须提供 --relay-rtt-ms N"
        fi
    fi
    is_uint "$RELAY_RTT_INPUT" && ((RELAY_RTT_INPUT >= 1 && RELAY_RTT_INPUT <= 1000)) \
        || die "--relay-rtt-ms 必须是 1-1000 ms 的整数"
    RELAY_RTT_MS=$RELAY_RTT_INPUT

    if [[ -z $RELAY_MBPS_INPUT ]]; then
        if [[ -t 0 ]]; then
            RELAY_MBPS_INPUT=$(prompt_uint "落地 VPS 的标称带宽 Mbps" 1000 10 100000)
        else
            RELAY_MBPS_INPUT=1000
            warn "非交互模式未提供 --relay-mbps，按 1000 Mbps 估算落地机带宽。"
        fi
    fi
    is_uint "$RELAY_MBPS_INPUT" && ((RELAY_MBPS_INPUT >= 10 && RELAY_MBPS_INPUT <= 100000)) \
        || die "--relay-mbps 必须是 10-100000 Mbps"
    RELAY_MBPS=$RELAY_MBPS_INPUT

    if [[ -z $RELAY_SHARE_INPUT ]]; then
        if [[ -t 0 ]]; then
            printf '\n分流比例只影响内存与 FD 的估算：走落地机的连接会同时占用入站+出站两个 socket。\n' >&2
            printf '按经验填个大概值即可（只中转流媒体/特定站点约 20-40，绝大部分走落地约 80-100）。\n' >&2
            RELAY_SHARE_INPUT=$(prompt_uint "走落地机的流量占比 %" 50 5 100)
        else
            RELAY_SHARE_INPUT=50
        fi
    fi
    is_uint "$RELAY_SHARE_INPUT" && ((RELAY_SHARE_INPUT >= 5 && RELAY_SHARE_INPUT <= 100)) \
        || die "--relay-share 必须是 5-100 的整数"
    RELAY_SHARE=$RELAY_SHARE_INPUT
    return 0
}

# Numeric deltas derived from the chosen primary protocol. Pure computation:
# must stay free of sysctl reads so --self-test can exercise it.
apply_protocol_profile() {
    PROFILE_NOTES=()
    KEEPALIVE_TIME=1200
    KEEPALIVE_INTVL=30
    KEEPALIVE_PROBES=5
    HYSTERIA_BELOW_RECOMMENDED=0
    case $PROTOCOL in
        ss2022)
            PROTOCOL_LABEL="Shadowsocks 2022（TCP 直连）"
            PROFILE_NOTES+=("TCP 直连：缓冲区按你本机到 VPS 的端到端 RTT 计算；TFO 已开启，QX 节点可加 fast-open=true 试用。")
            ;;
        anytls)
            PROTOCOL_LABEL="AnyTLS（TCP+TLS 多路复用）"
            PROFILE_NOTES+=("AnyTLS 复用一条 TCP 承载多路请求：空闲不降窗与 notsent_lowat 限制发送积压对它最关键，均已配置。")
            ;;
        hysteria)
            PROTOCOL_LABEL="Hysteria2（UDP/QUIC）"
            local want=16
            if ((want > BUFFER_CAP_MIB)); then
                want=$BUFFER_CAP_MIB
                HYSTERIA_BELOW_RECOMMENDED=1
            fi
            if ((BUFFER_MIB < want)); then
                BUFFER_MIB=$want
                BUFFER_BYTES=$((BUFFER_MIB * MIB))
                PROFILE_NOTES+=("UDP 收发缓冲上限已按 Hysteria 官方建议抬到 ${BUFFER_MIB} MiB。")
            fi
            ((SOCK_DEFAULT < 262144)) && SOCK_DEFAULT=262144
            ((SOCK_DEFAULT > BUFFER_BYTES)) && SOCK_DEFAULT=$BUFFER_BYTES
            if ((HYSTERIA_BELOW_RECOMMENDED == 1)); then
                PROFILE_NOTES+=("本机内存只有 ${MEM_MB} MiB，UDP 缓冲上限被压到 ${BUFFER_MIB} MiB，低于 Hysteria 建议的 16 MiB：高带宽时可能丢包，建议加内存或降低 up/down 配置值。")
            fi
            PROFILE_NOTES+=("Hysteria 速率由自带 Brutal 拥塞控制决定：请把服务端/客户端配置中的 up/down 带宽填真实值；内核 BBR 不影响 QUIC。")
            ;;
        vless-cdn)
            PROTOCOL_LABEL="VLESS+WS+TLS（Cloudflare CDN 回源）"
            SOMAXCONN=$(clamp $((SOMAXCONN * 2)) 1024 16384)
            SYN_BACKLOG=$((SOMAXCONN * 2))
            ((SYN_BACKLOG > 65536)) && SYN_BACKLOG=65536
            KEEPALIVE_TIME=600
            KEEPALIVE_PROBES=3
            PROFILE_NOTES+=("CDN 从多个边缘 IP 并发回源：accept/SYN 队列已加倍，TCP 保活缩短到 600s 以及时清理边缘侧断掉的连接。")
            ;;
        ss2022-relay)
            PROTOCOL_LABEL="Shadowsocks 2022 中转 + 部分分流（再用 SS2022 转发到落地 VPS）"
            KEEPALIVE_TIME=600
            KEEPALIVE_PROBES=3
            # A relayed flow holds an inbound and an outbound socket, so the
            # per-connection FD budget is doubled; move up exactly one tier.
            if ((NOFILE_LIMIT < 1048576)); then
                NOFILE_LIMIT=$((NOFILE_LIMIT * 2))
            fi
            PROFILE_NOTES+=("中转机同时是服务端和客户端：被分流的连接会同时占用入站+出站两个 socket，FD 上限已上调一档到 ${NOFILE_LIMIT}，缓冲上限按 ${RELAY_SHARE}% 分流比例收紧。")
            PROFILE_NOTES+=("缓冲区取两条路径的较大值：被中转流量按 ${RTT_MS}+${RELAY_RTT_MS}=${RELAY_PATH_RTT} ms、三段最小带宽 ${RELAY_EFFECTIVE_MBPS} Mbps 计算；直连流量按 ${RTT_MS} ms、${EFFECTIVE_MBPS} Mbps 计算。")
            PROFILE_NOTES+=("出站连接吃临时端口：ip_local_port_range 已放宽到 10240-65535，tcp_tw_reuse 已开启以缓解 TIME-WAIT 占位。")
            PROFILE_NOTES+=("tcp_fastopen=3 让本机既能作为服务端也能作为客户端用 TFO；落地机同样要开 tcp_fastopen 才省得掉那一次 RTT。")
            PROFILE_NOTES+=("保活缩短到 600s：任一侧掉线时尽快回收配对的另一条连接，小内存中转机尤其重要。")
            PROFILE_NOTES+=("落地段的实际速度由落地机自己的内核参数决定，建议在落地 VPS 上也跑一遍本脚本（那边选 1) SS2022）。")
            ;;
        *)
            PROTOCOL_LABEL="通用（未指定主力协议）"
            ;;
    esac
}

configure_initcwnd() {
    INITCWND=0
    local answer
    if [[ -n $INITCWND_INPUT ]]; then
        if [[ $INITCWND_INPUT == 0 ]]; then
            return 0
        fi
        is_uint "$INITCWND_INPUT" && ((INITCWND_INPUT >= 10 && INITCWND_INPUT <= 64)) \
            || die "--initcwnd 必须是 0（关闭）或 10-64"
        if ((HAVE_IPROUTE2 == 0)); then
            warn "BusyBox 自带的 ip 命令不支持 initcwnd；已跳过。请先 apk add iproute2 再重跑。"
            return 0
        fi
        INITCWND=$INITCWND_INPUT
        [[ $PROTOCOL == "hysteria" ]] \
            && warn "主力协议是 Hysteria/QUIC，initcwnd 只影响顺带的 TCP 流量。"
        return 0
    fi
    case $PROTOCOL in ss2022 | anytls | vless-cdn | ss2022-relay) ;; *) return 0 ;; esac
    if ((HAVE_IPROUTE2 == 0)); then
        warn "未安装 iproute2（BusyBox 的 ip 不支持 initcwnd），跳过初始拥塞窗口调整。"
        return 0
    fi
    [[ -t 0 ]] || return 0
    if [[ -e $INITCWND_INITD ]]; then
        info "已存在 initcwnd 持久化服务；回车可沿用新值覆盖，输入 0 则保持现状。"
    fi
    printf '\n提升初始拥塞窗口 initcwnd/initrwnd：新 TCP 连接前几个往返即可全速发包，网页首开与短请求更快。\n' >&2
    printf '轻微代价是突发发包更陡；脚本会写入 OpenRC 服务保证重启后仍生效，--restore 可完整撤销。\n' >&2
    while true; do
        read -r -p "initcwnd 取值（回车=25 推荐；0=跳过；可输 10-64）: " answer
        answer=$(normalize_user_input "$answer")
        answer=${answer:-25}
        if [[ $answer == 0 ]]; then
            return 0
        fi
        if is_uint "$answer" && ((answer >= 10 && answer <= 64)); then
            INITCWND=$answer
            return 0
        fi
        warn "请输入 0 或 10-64 的整数。"
    done
}

# Print the single default route of one family, normalized. Fails when the
# route is absent or multipath (multiple lines) — those are never touched.
current_default_route() {
    local family=$1 listing count
    listing=$(ip "-$family" route show default 2>/dev/null || true)
    count=$(grep -c . <<<"$listing" || true)
    [[ $count == 1 ]] || return 1
    head -n1 <<<"$listing" | sed -E \
        's/[[:space:]]+/ /g; s/^ //; s/ $//; s/ (initcwnd|initrwnd) [0-9]+//g; s/ expires [0-9]+sec//g; s/ linkdown//g'
}

detect_primary_iface() {
    local iface=""
    case ${IP_MODE:-dual} in
        4) iface=$(ip -4 route show default 2>/dev/null | awk '/default/ {for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}') ;;
        6) iface=$(ip -6 route show default 2>/dev/null | awk '/default/ {for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}') ;;
        *)
            iface=$(ip -4 route show default 2>/dev/null | awk '/default/ {for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
            [[ -n $iface ]] || iface=$(ip -6 route show default 2>/dev/null | awk '/default/ {for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
            ;;
    esac
    [[ $iface =~ ^[[:alnum:]_.:-]+$ ]] && printf '%s\n' "$iface"
}

parse_args() {
    while (($#)); do
        case $1 in
            --local-mbps)
                (($# >= 2)) || die "--local-mbps 缺少数值"
                LOCAL_MBPS=$2
                shift 2
                ;;
            --server-mbps)
                (($# >= 2)) || die "--server-mbps 缺少数值"
                SERVER_MBPS=$2
                shift 2
                ;;
            --ip-mode)
                (($# >= 2)) || die "--ip-mode 缺少模式"
                IP_MODE=$2
                shift 2
                ;;
            --rtt-ms)
                (($# >= 2)) || die "--rtt-ms 缺少数值"
                RTT_INPUT=$2
                shift 2
                ;;
            --protocol)
                (($# >= 2)) || die "--protocol 缺少协议名"
                PROTOCOL_INPUT=$2
                shift 2
                ;;
            --relay-mbps)
                (($# >= 2)) || die "--relay-mbps 缺少数值"
                RELAY_MBPS_INPUT=$2
                shift 2
                ;;
            --relay-rtt-ms)
                (($# >= 2)) || die "--relay-rtt-ms 缺少数值"
                RELAY_RTT_INPUT=$2
                shift 2
                ;;
            --relay-share)
                (($# >= 2)) || die "--relay-share 缺少数值"
                RELAY_SHARE_INPUT=$2
                shift 2
                ;;
            --initcwnd)
                (($# >= 2)) || die "--initcwnd 缺少数值"
                INITCWND_INPUT=$2
                shift 2
                ;;
            --hysteria-range)
                (($# >= 2)) || die "--hysteria-range 缺少范围"
                HYSTERIA_RANGE_INPUT=$2
                shift 2
                ;;
            --no-apk) NO_APK=1; shift ;;
            --dry-run) DRY_RUN=1; shift ;;
            --yes | -y) ASSUME_YES=1; shift ;;
            --status) ACTION="status"; shift ;;
            --restore) ACTION="restore"; shift ;;
            --self-test) ACTION="self-test"; shift ;;
            --help | -h) ACTION="help"; shift ;;
            *) die "未知选项: $1（使用 --help 查看帮助）" ;;
        esac
    done
}

detect_system() {
    local detected_mem
    detected_mem=$(( $(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null || printf '0') / 1024 ))
    MEM_MB=${NETALPINE_TEST_MEM_MB:-$detected_mem}
    ((MEM_MB > 0)) || MEM_MB=256

    SWAP_MB=$(( $(awk '/^SwapTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null || printf '0') / 1024 ))
    CPU_CORES=${NETALPINE_TEST_CPU:-$(nproc 2>/dev/null || printf '1')}
    is_uint "$CPU_CORES" || CPU_CORES=1
    ((CPU_CORES > 0)) || CPU_CORES=1
    ARCH=$(uname -m 2>/dev/null || printf 'unknown')
    KERNEL_RELEASE=$(uname -r 2>/dev/null || printf 'unknown')
    KERNEL_FLAVOR=${KERNEL_RELEASE##*-}
    [[ $KERNEL_FLAVOR =~ ^[a-z]+$ ]] || KERNEL_FLAVOR=""
    detect_virt
    detect_openrc
    detect_tools
    PRIMARY_IFACE=$(detect_primary_iface) || PRIMARY_IFACE=""
    inspect_tcp_mem
    return 0
}

# --- core sizing math (pure computation, exercised by --self-test) ---

calculate_tuning() {
    if ((LOCAL_MBPS <= SERVER_MBPS)); then EFFECTIVE_MBPS=$LOCAL_MBPS; else EFFECTIVE_MBPS=$SERVER_MBPS; fi
    BDP_BYTES=$((EFFECTIVE_MBPS * 125 * RTT_MS))

    RELAY_EFFECTIVE_MBPS=0
    RELAY_PATH_RTT=0
    RELAY_BDP_BYTES=0
    DESIGN_BDP_BYTES=$BDP_BYTES
    if [[ $PROTOCOL == "ss2022-relay" ]]; then
        RELAY_EFFECTIVE_MBPS=$EFFECTIVE_MBPS
        ((RELAY_MBPS > 0 && RELAY_MBPS < RELAY_EFFECTIVE_MBPS)) && RELAY_EFFECTIVE_MBPS=$RELAY_MBPS
        RELAY_PATH_RTT=$((RTT_MS + RELAY_RTT_MS))
        RELAY_BDP_BYTES=$((RELAY_EFFECTIVE_MBPS * 125 * RELAY_PATH_RTT))
        ((RELAY_BDP_BYTES > DESIGN_BDP_BYTES)) && DESIGN_BDP_BYTES=$RELAY_BDP_BYTES
    fi

    # 2.4x BDP provides receive-window overhead plus headroom while retaining
    # Linux autotuning. Small VPS get a 2 MiB grid and a lower floor so a
    # 256-512 MiB box is not forced to reserve headroom it cannot afford.
    local target_bytes target_mib rounded_mib floor_mib
    target_bytes=$(((DESIGN_BDP_BYTES * 24 + 9) / 10))
    if ((MEM_MB <= 768)); then floor_mib=4; else floor_mib=8; fi
    ((target_bytes < floor_mib * MIB)) && target_bytes=$((floor_mib * MIB))
    target_mib=$(((target_bytes + MIB - 1) / MIB))
    if ((target_mib <= 16)); then
        rounded_mib=$((((target_mib + 1) / 2) * 2))
    else
        rounded_mib=$((((target_mib + 3) / 4) * 4))
    fi

    if ((MEM_MB <= 1024)); then
        BUFFER_CAP_MIB=$((MEM_MB / 24))
    else
        BUFFER_CAP_MIB=$((MEM_MB / 16))
    fi
    # A relayed flow keeps two sockets alive, so the safe ceiling shrinks with
    # the share of traffic that actually goes through the landing VPS.
    if [[ $PROTOCOL == "ss2022-relay" ]]; then
        BUFFER_CAP_MIB=$((BUFFER_CAP_MIB * 100 / (100 + RELAY_SHARE)))
    fi
    BUFFER_CAP_MIB=$(((BUFFER_CAP_MIB / 2) * 2))
    BUFFER_CAP_MIB=$(clamp "$BUFFER_CAP_MIB" 4 256)
    BUFFER_WAS_CAPPED=0
    if ((rounded_mib > BUFFER_CAP_MIB)); then
        rounded_mib=$BUFFER_CAP_MIB
        BUFFER_WAS_CAPPED=1
    fi
    BUFFER_MIB=$rounded_mib
    BUFFER_BYTES=$((BUFFER_MIB * MIB))

    if ((EFFECTIVE_MBPS <= 100)); then
        NETDEV_BACKLOG=1024
    elif ((EFFECTIVE_MBPS <= 200)); then
        NETDEV_BACKLOG=2048
    elif ((EFFECTIVE_MBPS <= 1000)); then
        NETDEV_BACKLOG=8192
    elif ((EFFECTIVE_MBPS <= 2500)); then
        NETDEV_BACKLOG=16384
    else
        NETDEV_BACKLOG=32768
    fi
    ((CPU_CORES == 1 && NETDEV_BACKLOG > 8192)) && NETDEV_BACKLOG=8192
    ((MEM_MB <= 256 && NETDEV_BACKLOG > 2048)) && NETDEV_BACKLOG=2048
    ((MEM_MB <= 512 && NETDEV_BACKLOG > 4096)) && NETDEV_BACKLOG=4096
    ((MEM_MB <= 1024 && NETDEV_BACKLOG > 8192)) && NETDEV_BACKLOG=8192

    if ((EFFECTIVE_MBPS <= 200)); then
        NOTSENT_LOWAT=65536
    elif ((EFFECTIVE_MBPS <= 2500)); then
        NOTSENT_LOWAT=131072
    else
        NOTSENT_LOWAT=262144
    fi
    ((MEM_MB <= 1024 && NOTSENT_LOWAT > 65536)) && NOTSENT_LOWAT=65536

    if ((MEM_MB <= 256)); then
        SOMAXCONN=1024
    elif ((MEM_MB <= 512)); then
        SOMAXCONN=2048
    elif ((MEM_MB <= 2048)); then
        SOMAXCONN=4096
    else
        SOMAXCONN=8192
    fi
    SYN_BACKLOG=$((SOMAXCONN * 2))
    ((SYN_BACKLOG > 65536)) && SYN_BACKLOG=65536

    if ((MEM_MB <= 512)); then
        SOCK_DEFAULT=131072
        TCP_RMEM_DEF=131072
        TCP_WMEM_DEF=32768
    elif ((MEM_MB <= 1024)); then
        SOCK_DEFAULT=196608
        TCP_RMEM_DEF=196608
        TCP_WMEM_DEF=65536
    else
        SOCK_DEFAULT=262144
        TCP_RMEM_DEF=262144
        TCP_WMEM_DEF=65536
    fi
    ((TCP_RMEM_DEF > BUFFER_BYTES)) && TCP_RMEM_DEF=$BUFFER_BYTES
    ((TCP_WMEM_DEF > BUFFER_BYTES)) && TCP_WMEM_DEF=$BUFFER_BYTES
    ((SOCK_DEFAULT > BUFFER_BYTES)) && SOCK_DEFAULT=$BUFFER_BYTES

    # FD ceilings cost nothing until used, but a 1M-entry table on a 256 MiB
    # box makes badly written daemons allocate for nothing.
    if ((MEM_MB <= 256)); then
        NOFILE_LIMIT=65536
    elif ((MEM_MB <= 512)); then
        NOFILE_LIMIT=131072
    elif ((MEM_MB <= 1024)); then
        NOFILE_LIMIT=262144
    elif ((MEM_MB <= 2048)); then
        NOFILE_LIMIT=524288
    else
        NOFILE_LIMIT=1048576
    fi

    # Small boxes drop packets in softirq when the free-page watermark is too
    # tight; ~1% of RAM, only ever raised, never lowered.
    MIN_FREE_KB=0
    if ((MEM_MB <= 1024)); then
        MIN_FREE_KB=$((MEM_MB * 1024 / 96))
        MIN_FREE_KB=$(clamp "$MIN_FREE_KB" 4096 32768)
        MIN_FREE_KB=$(((MIN_FREE_KB / 1024) * 1024))
    fi
    return 0
}

select_algorithms() {
    local available="" qdisc_loaded=0 bbr_module_present=0
    if ((DRY_RUN == 0)) && have_cmd modprobe && ! is_container_guest; then
        modprobe tcp_bbr >/dev/null 2>&1 || true
        if modprobe sch_fq >/dev/null 2>&1; then qdisc_loaded=1; fi
    fi
    available=$(get_sysctl net.ipv4.tcp_available_congestion_control)
    if bbr_module_available; then bbr_module_present=1; fi
    if word_in_list bbr "$available"; then
        SELECTED_CC="bbr"
    elif ((bbr_module_present == 1)); then
        SELECTED_CC="bbr"
    elif word_in_list cubic "$available"; then
        SELECTED_CC="cubic"
    else
        SELECTED_CC="reno"
    fi

    if ((qdisc_loaded == 1)) || [[ -d /sys/module/sch_fq ]] \
        || [[ $(get_sysctl net.core.default_qdisc) == "fq" ]] || fq_module_available; then
        SELECTED_QDISC="fq"
    elif ((DRY_RUN == 0)) && have_cmd modprobe && modprobe sch_fq_codel >/dev/null 2>&1; then
        SELECTED_QDISC="fq_codel"
    else
        # Alpine's linux-lts/linux-virt both ship sch_fq as a module; keeping fq
        # in dry-run also makes the intended result clear.
        SELECTED_QDISC="fq"
    fi
}

module_builtin() {
    local name=$1 file="/lib/modules/$KERNEL_RELEASE/modules.builtin"
    [[ -r $file ]] || return 1
    grep -q "/${name}\.ko" "$file" 2>/dev/null
}

bbr_module_available() {
    compgen -G "/lib/modules/$KERNEL_RELEASE/kernel/net/ipv4/tcp_bbr.ko*" >/dev/null && return 0
    module_builtin tcp_bbr && return 0
    have_cmd modinfo && modinfo tcp_bbr >/dev/null 2>&1 && return 0
    return 1
}

fq_module_available() {
    compgen -G "/lib/modules/$KERNEL_RELEASE/kernel/net/sched/sch_fq.ko*" >/dev/null && return 0
    module_builtin sch_fq && return 0
    return 1
}

# Some other kernel version is installed on disk and already carries BBR.
other_kernel_with_bbr() {
    local dir release
    for dir in /lib/modules/*; do
        [[ -d $dir ]] || continue
        release=${dir##*/}
        [[ $release == "$KERNEL_RELEASE" ]] && continue
        if compgen -G "$dir/kernel/net/ipv4/tcp_bbr.ko*" >/dev/null; then
            printf '%s\n' "$release"
            return 0
        fi
    done
    return 1
}

detect_bbr_generation() {
    local available numeric_version=${KERNEL_RELEASE%%-*}
    available=$(get_sysctl net.ipv4.tcp_available_congestion_control)
    BBR_MODULE_VERSION=""
    if have_cmd modinfo; then
        BBR_MODULE_VERSION=$(modinfo -F version tcp_bbr 2>/dev/null | head -n1 || true)
    fi
    if [[ $BBR_MODULE_VERSION =~ ^3([.]|$) ]]; then
        CURRENT_BBR_GENERATION="BBRv3（模块标记 ${BBR_MODULE_VERSION}）"
    elif word_in_list bbr "$available" && word_in_list bbr1 "$available"; then
        CURRENT_BBR_GENERATION="BBRv3（同时保留 bbr1）"
    elif word_in_list bbr "$available"; then
        CURRENT_BBR_GENERATION="普通 BBR（Alpine 官方内核，未标记版本）"
    elif bbr_module_available; then
        CURRENT_BBR_GENERATION="BBR 模块存在但尚未加载"
    else
        CURRENT_BBR_GENERATION="BBR 不可用"
    fi
    version_ge "$numeric_version" "0" || true
}

alpine_kernel_package() {
    case $KERNEL_FLAVOR in
        virt | lts | stable | edge | rpi) printf 'linux-%s\n' "$KERNEL_FLAVOR"; return 0 ;;
    esac
    local candidate
    for candidate in linux-virt linux-lts linux-stable linux-edge; do
        apk_installed "$candidate" && { printf '%s\n' "$candidate"; return 0; }
    done
    printf 'linux-virt\n'
}

build_kernel_advice() {
    local numeric_version=${KERNEL_RELEASE%%-*} other_release="" high_bdp_path=0 design_rtt=$RTT_MS
    RECOMMEND_KERNEL=0
    OFFER_KERNEL_INSTALL=0
    KERNEL_ADVICE_DETAIL=""
    KERNEL_PACKAGE=$(alpine_kernel_package)
    [[ $PROTOCOL == "ss2022-relay" ]] && design_rtt=$RELAY_PATH_RTT

    if ((design_rtt >= 70 && EFFECTIVE_MBPS >= 500 && DESIGN_BDP_BYTES >= 4 * MIB)); then
        high_bdp_path=1
    elif ((design_rtt >= 100 && EFFECTIVE_MBPS >= 200 && DESIGN_BDP_BYTES >= 8 * MIB)); then
        high_bdp_path=1
    fi

    if [[ $CURRENT_BBR_GENERATION == BBRv3* ]]; then
        KERNEL_ADVICE="保留当前内核；已检测到 ${CURRENT_BBR_GENERATION}。"
        KERNEL_ADVICE_DETAIL="无需更换内核；继续使用 bbr + fq。"
        return 0
    fi

    if [[ $SELECTED_CC == "bbr" ]]; then
        if ! version_ge "$numeric_version" "5.10"; then
            RECOMMEND_KERNEL=1
            KERNEL_ADVICE="BBR 可用但内核 ${numeric_version} 偏旧，建议升级 Alpine 版本与 ${KERNEL_PACKAGE}。"
            KERNEL_ADVICE_DETAIL="升级内核主要是拿安全修复和 fq/BBR 的后续改进，不保证提速。"
        else
            KERNEL_ADVICE="Alpine 官方内核的 BBR + fq 已适合当前带宽/延迟规模，不建议折腾内核。"
            KERNEL_ADVICE_DETAIL="Alpine 仓库没有 BBRv3 内核（XanMod 只出 .deb），要 BBRv3 只能自行编译；收益不确定，风险明显更高。"
        fi
        if ((high_bdp_path == 1)); then
            KERNEL_ADVICE_DETAIL+=" 当前是 ${EFFECTIVE_MBPS} Mbps、${design_rtt} ms 的高 BDP 长距离路径；这类场景 BBRv3 理论上有优势，但在 Alpine 上没有可信的预编译内核，建议先把缓冲区和 fq 调好再评估。"
        fi
        return 0
    fi

    # From here on BBR is not usable on the running kernel.
    if other_release=$(other_kernel_with_bbr); then
        KERNEL_ADVICE="磁盘上已有带 BBR 的内核 ${other_release}，但当前运行的是 ${KERNEL_RELEASE}。"
        KERNEL_ADVICE_DETAIL="建议重启后用 uname -r 确认；脚本不会重复安装内核。"
        return 0
    fi
    if is_container_guest; then
        KERNEL_ADVICE="当前是 ${VIRT_TYPE} 容器（LXC/OpenVZ 类），内核由宿主机决定，容器内无法启用 BBR。"
        KERNEL_ADVICE_DETAIL="请联系服务商在宿主机开启 tcp_bbr，或改用 KVM 架构的 VPS；本脚本仍会写入所有容器内允许修改的参数。"
        return 0
    fi
    if [[ $PROTOCOL == "hysteria" ]]; then
        KERNEL_ADVICE="主力协议是 Hysteria/QUIC，速率由应用层 Brutal 拥塞控制决定，不必为 BBR 更换内核。"
        KERNEL_ADVICE_DETAIL="内核拥塞控制只影响顺带的 TCP 流量；保证 UDP 缓冲充足即可。"
        return 0
    fi

    RECOMMEND_KERNEL=1
    KERNEL_ADVICE="当前内核没有 BBR，建议安装/更新 Alpine 官方内核包 ${KERNEL_PACKAGE}。"
    KERNEL_ADVICE_DETAIL="Alpine 的 linux-lts / linux-virt 都把 tcp_bbr 编成模块（CONFIG_TCP_CONG_BBR=m），装好重启即可用；当前暂用 ${SELECTED_CC}。"
    if [[ $ARCH != "x86_64" && $ARCH != "aarch64" ]]; then
        KERNEL_ADVICE_DETAIL+=" 当前架构 ${ARCH} 不在脚本自动安装的范围内，请手动处理。"
    elif ! apk_available; then
        KERNEL_ADVICE_DETAIL+=" 没有 apk，无法自动安装。"
    else
        OFFER_KERNEL_INSTALL=1
    fi
    return 0
}

# --- sysctl set construction ---

add_setting() {
    SYSCTL_KEYS+=("$1")
    SYSCTL_VALUES+=("$2")
    SYSCTL_NOTES+=("${3:-}")
}

prepare_settings() {
    SYSCTL_KEYS=()
    SYSCTL_VALUES=()
    SYSCTL_NOTES=()

    local current_file_max current_nr_open desired_file_max existing_reserved merged_reserved
    current_file_max=$(get_sysctl fs.file-max)
    current_nr_open=$(get_sysctl fs.nr_open)
    desired_file_max=$((NOFILE_LIMIT * 2))
    if [[ -z $current_file_max ]] || ! decimal_ge "$current_file_max" "$desired_file_max"; then
        add_setting fs.file-max "$desired_file_max" "全局文件句柄上限（只增不减）"
    fi
    if [[ -z $current_nr_open ]] || ! decimal_ge "$current_nr_open" "$NOFILE_LIMIT"; then
        add_setting fs.nr_open "$NOFILE_LIMIT" "单进程 FD 硬上限"
    fi

    add_setting net.core.default_qdisc "$SELECTED_QDISC" "本机代理流量的公平队列与 pacing"
    add_setting net.core.rmem_max "$BUFFER_BYTES" "TCP/UDP 接收缓冲区上限"
    add_setting net.core.wmem_max "$BUFFER_BYTES" "TCP/UDP 发送缓冲区上限"
    add_setting net.core.rmem_default "$SOCK_DEFAULT" "非 TCP 套接字默认接收缓冲区（已按 ${MEM_MB} MiB 内存缩放）"
    add_setting net.core.wmem_default "$SOCK_DEFAULT" "非 TCP 套接字默认发送缓冲区（已按 ${MEM_MB} MiB 内存缩放）"
    add_setting net.core.netdev_max_backlog "$NETDEV_BACKLOG" "虚拟网卡突发队列"
    add_setting net.core.somaxconn "$SOMAXCONN" "监听 accept 队列上限"

    local current_optmem
    current_optmem=$(get_sysctl net.core.optmem_max)
    if [[ -z $current_optmem ]] || ! decimal_ge "$current_optmem" 81920; then
        add_setting net.core.optmem_max 81920 "套接字辅助缓冲区，QUIC GSO 等控制消息需要（只增不减）"
    fi

    add_setting net.ipv4.tcp_congestion_control "$SELECTED_CC" "TCP 拥塞控制"
    add_setting net.ipv4.tcp_ecn 1 "主动协商 ECN；异常路径由 tcp_ecn_fallback 兜底"
    add_setting net.ipv4.tcp_ecn_fallback 1 "ECN 路径异常时自动回退，兼顾公网兼容性"
    add_setting net.ipv4.tcp_rmem "4096 $TCP_RMEM_DEF $BUFFER_BYTES" "TCP 自动接收缓冲区"
    add_setting net.ipv4.tcp_wmem "4096 $TCP_WMEM_DEF $BUFFER_BYTES" "TCP 自动发送缓冲区"
    add_setting net.ipv4.tcp_max_syn_backlog "$SYN_BACKLOG" "SYN 队列上限"
    add_setting net.ipv4.tcp_fastopen 3 "允许支持 TFO 的代理应用使用客户端/服务端 TFO"
    add_setting net.ipv4.tcp_fastopen_blackhole_timeout_sec 3600 "TFO 黑洞路径自动退避"
    add_setting net.ipv4.tcp_mtu_probing 1 "仅在发现 PMTU 黑洞时探测 MSS"
    add_setting net.ipv4.tcp_slow_start_after_idle 0 "持久代理连接空闲后保留爬升结果"
    add_setting net.ipv4.tcp_notsent_lowat "$NOTSENT_LOWAT" "限制应用在拥塞窗口外堆积的未发送数据（小内存机器压得更低）"
    add_setting net.ipv4.tcp_moderate_rcvbuf 1 "启用 TCP 接收缓冲区自动调节"
    add_setting net.ipv4.tcp_window_scaling 1 "允许高 BDP 路径扩大 TCP 窗口"
    add_setting net.ipv4.tcp_timestamps 1 "RTT 测量和 PAWS"
    add_setting net.ipv4.tcp_sack 1 "选择确认以改善丢包恢复"
    add_setting net.ipv4.tcp_syncookies 1 "SYN 队列溢出保护"
    add_setting net.ipv4.tcp_tw_reuse 1 "允许出站复用 TIME-WAIT 端口，缓解代理出站高并发时的端口紧张"
    add_setting net.ipv4.tcp_fin_timeout 25 "缩短 FIN_WAIT_2 停留时间，加快连接回收"
    add_setting net.ipv4.tcp_no_metrics_save 1 "不缓存上次连接的拥塞记录，避免偶发丢包拖累后续连接起步"
    add_setting net.ipv4.tcp_keepalive_time "$KEEPALIVE_TIME" "空闲多久后开始 TCP 保活探测"
    add_setting net.ipv4.tcp_keepalive_intvl "$KEEPALIVE_INTVL" "保活探测间隔"
    add_setting net.ipv4.tcp_keepalive_probes "$KEEPALIVE_PROBES" "保活探测次数，超过即判定连接失效"
    add_setting net.ipv4.ip_local_port_range "10240 65535" "扩大代理出站临时端口范围"
    if [[ -n $HYSTERIA_RESERVED_PORTS ]]; then
        existing_reserved=$(get_sysctl net.ipv4.ip_local_reserved_ports)
        merged_reserved=$(merge_port_ranges "$existing_reserved" "$HYSTERIA_RESERVED_PORTS") \
            || die "现有 ip_local_reserved_ports 格式异常，拒绝覆盖"
        add_setting net.ipv4.ip_local_reserved_ports "$merged_reserved" \
            "保留 Hysteria 端口跳跃范围，同时合并系统已有保留端口"
    fi

    # Hysteria/QUIC uses application-level congestion control, not TCP BBR.
    # These values guarantee a reasonable minimum while core rmem/wmem_max
    # lets quic-go request a larger SO_RCVBUF/SO_SNDBUF when needed.
    add_setting net.ipv4.udp_rmem_min 16384 "UDP/QUIC 最小接收缓冲区"
    add_setting net.ipv4.udp_wmem_min 16384 "UDP/QUIC 最小发送缓冲区"

    local current_min_free
    if ((MIN_FREE_KB > 0)); then
        current_min_free=$(get_sysctl vm.min_free_kbytes)
        if [[ -n $current_min_free ]] && ! decimal_ge "$current_min_free" "$MIN_FREE_KB"; then
            add_setting vm.min_free_kbytes "$MIN_FREE_KB" \
                "小内存机器保留的空闲页，避免网络软中断里分配失败丢包（只增不减）"
        fi
    fi

    if [[ $PROTOCOL == "hysteria" ]]; then
        local udp_pages udp_min_pages udp_pressure_pages current_udp_mem current_udp_max
        udp_pages=$(clamp $((MEM_MB * 48)) 12288 262144)
        udp_min_pages=$((udp_pages / 2))
        udp_pressure_pages=$((udp_pages * 3 / 4))
        current_udp_mem=$(get_sysctl net.ipv4.udp_mem)
        current_udp_max=${current_udp_mem##* }
        if ! is_uint "$current_udp_max" || ! decimal_ge "$current_udp_max" "$udp_pages"; then
            add_setting net.ipv4.udp_mem "$udp_min_pages $udp_pressure_pages $udp_pages" \
                "UDP 全局内存页上限，防止 Hysteria 大流量时整体丢包（只增不减）"
        fi
        add_setting net.core.netdev_budget 600 "软中断每轮多处理一些 UDP 包"
        add_setting net.core.netdev_budget_usecs 4000 "软中断单轮时间预算"
    fi

    # Port hopping (nft/iptables DNAT) and relay outbound both push every flow
    # through conntrack; raise the table cap only when conntrack is loaded.
    if [[ $PROTOCOL == "hysteria" || $PROTOCOL == "ss2022-relay" ]]; then
        local conntrack_max current_conntrack
        current_conntrack=$(get_sysctl net.netfilter.nf_conntrack_max)
        conntrack_max=$(clamp $((MEM_MB * 48)) 16384 262144)
        if [[ -n $current_conntrack ]] && ! decimal_ge "$current_conntrack" "$conntrack_max"; then
            add_setting net.netfilter.nf_conntrack_max "$conntrack_max" \
                "连接跟踪表上限，按内存估算（只增不减，每条约 300 字节）"
        fi
    fi
}

filter_supported_settings() {
    local -a keys=() values=() notes=()
    local i key current
    SKIPPED_SETTINGS=()
    for ((i = 0; i < ${#SYSCTL_KEYS[@]}; i++)); do
        key=${SYSCTL_KEYS[$i]}
        if ! sysctl_exists "$key"; then
            if ((DRY_RUN == 0)); then
                SKIPPED_SETTINGS+=("$key（当前内核不存在）")
                continue
            fi
        fi
        if ((DRY_RUN == 0)); then
            current=$(normalize_sysctl_value "$(get_sysctl "$key")")
            if [[ -z $current ]] || ! set_sysctl "$key" "$current"; then
                SKIPPED_SETTINGS+=("$key（当前环境禁止写入）")
                continue
            fi
        fi
        keys+=("$key")
        values+=("${SYSCTL_VALUES[$i]}")
        notes+=("${SYSCTL_NOTES[$i]}")
    done
    SYSCTL_KEYS=("${keys[@]}")
    SYSCTL_VALUES=("${values[@]}")
    SYSCTL_NOTES=("${notes[@]}")
}

render_sysctl_config() {
    local destination=$1 i
    {
        printf '# Generated by %s v%s (port of %s)\n' "$PROGRAM_NAME" "$SCRIPT_VERSION" "$BASED_ON"
        printf '# Workload: AnyTLS, VLESS/WS/TLS/CDN, Xray/sing-box, Hysteria/QUIC, SS2022 relay\n'
        printf '# Primary protocol profile: %s\n' "$PROTOCOL"
        printf '# Host: Alpine %s / %s / %s MiB RAM / %s vCPU\n' \
            "${ALPINE_VERSION:-unknown}" "$KERNEL_RELEASE" "$MEM_MB" "$CPU_CORES"
        printf '# Inputs: local=%s Mbps, server=%s Mbps, effective=%s Mbps\n' \
            "$LOCAL_MBPS" "$SERVER_MBPS" "$EFFECTIVE_MBPS"
        printf '# RTT input: %s ms (%s); BDP=%s bytes; buffer=%s MiB (cap %s MiB)\n' \
            "$RTT_MS" "$RTT_SOURCE" "$BDP_BYTES" "$BUFFER_MIB" "$BUFFER_CAP_MIB"
        if [[ $PROTOCOL == "ss2022-relay" ]]; then
            printf '# Relay leg: +%s ms to landing VPS, %s Mbps, share %s%%, path BDP=%s bytes\n' \
                "$RELAY_RTT_MS" "$RELAY_MBPS" "$RELAY_SHARE" "$RELAY_BDP_BYTES"
        fi
        printf '# Loaded by OpenRC service "sysctl" (boot runlevel) via: sysctl -p %s\n' "$SYSCTL_CONF"
        printf '# This file may be removed safely, then run: rc-service sysctl restart\n\n'
        for ((i = 0; i < ${#SYSCTL_KEYS[@]}; i++)); do
            [[ -n ${SYSCTL_NOTES[$i]} ]] && printf '# %s\n' "${SYSCTL_NOTES[$i]}"
            printf '%s = %s\n\n' "${SYSCTL_KEYS[$i]}" "${SYSCTL_VALUES[$i]}"
        done
    } >"$destination"
}

print_plan() {
    local bdp_mib relay_bdp_mib active_qdisc="" worst_case_mib
    bdp_mib=$(awk -v bytes="$BDP_BYTES" 'BEGIN {printf "%.2f", bytes / 1048576}')
    heading "Alpine 代理网络调优计划"
    printf '系统             : Alpine %s / %s / %s / %s vCPU / %s MiB RAM / %s MiB Swap\n' \
        "${ALPINE_VERSION:-未知}" "$ARCH" "$KERNEL_RELEASE" "$CPU_CORES" "$MEM_MB" "$SWAP_MB"
    printf '虚拟化           : %s\n' "$VIRT_TYPE"
    printf '初始化系统       : %s\n' "$( ((HAVE_OPENRC == 1)) && echo "OpenRC" || echo "未检测到 OpenRC（rc.conf/conf.d 仍会写入）" )"
    printf '工具链           : iproute2=%s tc=%s prlimit=%s\n' \
        "$( ((HAVE_IPROUTE2 == 1)) && echo 有 || echo 无 )" \
        "$( ((HAVE_TC == 1)) && echo 有 || echo 无 )" \
        "$( ((HAVE_PRLIMIT == 1)) && echo 有 || echo 无 )"
    printf '主网卡           : %s\n' "${PRIMARY_IFACE:-未检测到}"
    printf 'IP 模式          : %s\n' "$IP_MODE"
    printf '主力协议         : %s\n' "$PROTOCOL_LABEL"
    printf '本地/VPS 带宽    : %s / %s Mbps（有效 %s Mbps）\n' "$LOCAL_MBPS" "$SERVER_MBPS" "$EFFECTIVE_MBPS"
    printf '实测 RTT         : %s ms（%s）\n' "$RTT_MS" "$RTT_SOURCE"
    printf 'BDP              : %s MiB\n' "$bdp_mib"
    if [[ $PROTOCOL == "ss2022-relay" ]]; then
        relay_bdp_mib=$(awk -v bytes="$RELAY_BDP_BYTES" 'BEGIN {printf "%.2f", bytes / 1048576}')
        printf '落地 VPS 带宽    : %s Mbps（三段有效 %s Mbps）\n' "$RELAY_MBPS" "$RELAY_EFFECTIVE_MBPS"
        printf '中转段 RTT       : %s ms（端到端 %s ms = %s + %s）\n' \
            "$RELAY_RTT_MS" "$RELAY_PATH_RTT" "$RTT_MS" "$RELAY_RTT_MS"
        printf '中转路径 BDP     : %s MiB（与直连 BDP 取较大值参与计算）\n' "$relay_bdp_mib"
        printf '分流比例         : %s%%（用于内存/FD 估算，非流量整形）\n' "$RELAY_SHARE"
    fi
    printf 'TCP/UDP 最大缓冲 : %s MiB（内存安全上限 %s MiB）\n' "$BUFFER_MIB" "$BUFFER_CAP_MIB"
    printf 'socket 初始缓冲  : rmem/wmem_default %s，tcp_rmem 中值 %s，tcp_wmem 中值 %s\n' \
        "$SOCK_DEFAULT" "$TCP_RMEM_DEF" "$TCP_WMEM_DEF"
    printf '队列/连接上限    : netdev_backlog %s / somaxconn %s / syn_backlog %s\n' \
        "$NETDEV_BACKLOG" "$SOMAXCONN" "$SYN_BACKLOG"
    printf '拥塞控制 / 队列  : %s + %s\n' "$SELECTED_CC" "$SELECTED_QDISC"
    if ((INITCWND > 0)); then
        printf '初始拥塞窗口     : initcwnd/initrwnd %s（即时修改默认路由并写入 OpenRC 服务持久化）\n' "$INITCWND"
    else
        printf '初始拥塞窗口     : 保持内核默认（10）\n'
    fi
    printf '当前 BBR 识别    : %s\n' "$CURRENT_BBR_GENERATION"
    printf 'FD 上限          : %s（/etc/rc.conf、%s、登录 shell 与运行中进程）\n' "$NOFILE_LIMIT" "$CONFD_DIR/<服务>"
    if ((MIN_FREE_KB > 0)); then
        printf 'vm.min_free_kbytes: %s KiB（小内存保护，只增不减）\n' "$MIN_FREE_KB"
    fi
    if ((${#PROXY_SERVICES[@]})); then
        printf '检测到代理服务   : %s\n' "${PROXY_SERVICES[*]}"
        printf '需写 conf.d 限制 : %s 个\n' "${#CONFD_SERVICES[@]}"
    else
        printf '检测到代理服务   : 无（若之后安装代理，请再次运行脚本补做服务级检查）\n'
    fi
    if ((${#PROXY_PIDS[@]})); then
        printf '运行中代理进程   : %s 个\n' "${#PROXY_PIDS[@]}"
    fi
    if [[ -n $HYSTERIA_RESERVED_PORTS ]]; then
        printf 'Hysteria 跳跃端口: %s（%s，写入 reserved_ports）\n' \
            "$HYSTERIA_RESERVED_PORTS" "$HYSTERIA_RANGE_SOURCE"
    elif ((HYSTERIA_DETECTED == 1)); then
        printf 'Hysteria 跳跃端口: 未保留（%s）\n' "$HYSTERIA_RANGE_SOURCE"
    else
        printf 'Hysteria 跳跃端口: 未检测到；以后安装可重跑或使用 --hysteria-range\n'
    fi
    if [[ -n $TCP_MEM_HIGH_MIB ]]; then
        printf 'TCP 全局内存 high: 约 %s MiB（保持内核自动值）\n' "$TCP_MEM_HIGH_MIB"
        if ((TCP_MEM_HIGH_MIB * MIB < BUFFER_BYTES * 2)); then
            warn "当前 tcp_mem high 低于两倍单连接缓冲上限；仅提示，不会用激进公式强行扩大。"
        fi
    fi
    printf '主动带宽限制     : 无\n'
    if [[ -n $PRIMARY_IFACE ]] && ((HAVE_TC == 1)); then
        active_qdisc=$(tc qdisc show dev "$PRIMARY_IFACE" 2>/dev/null || true)
        if [[ $active_qdisc == *"qdisc mq "* && $active_qdisc == *"qdisc cake "* \
            && $active_qdisc == *"bandwidth unlimited"* && $SELECTED_QDISC == fq ]]; then
            warn "检测到 mq 下的无限带宽 CAKE；应用时会把这些叶子队列切换为 fq，并记录回滚信息。"
        fi
    fi
    ((BUFFER_WAS_CAPPED == 1)) && warn "所需窗口超过内存安全上限，已自动裁剪；极端高 BDP 单流可能受内存限制。"

    worst_case_mib=$((BUFFER_MIB * 2))
    if ((MEM_MB <= 1024)); then
        printf '\n小内存提示       : 单条连接理论上最多能吃到约 %s MiB（收+发），是上限不是预分配，\n' "$worst_case_mib"
        printf '                   内核会按 tcp_moderate_rcvbuf 自动伸缩，只有真高 BDP 时才会涨上去。\n'
        if ((SWAP_MB == 0)); then
            warn "本机没有 swap。<1 GiB 的 Alpine VPS 跑 TLS/QUIC 代理时建议加一点 swap 或 zram（apk add zram-init），否则突发流量可能触发 OOM。"
        fi
    fi
    if ((${#MISSING_PKGS[@]})); then
        local entry
        printf '\n仍缺少的可选包   :\n'
        for entry in "${MISSING_PKGS[@]}"; do
            printf '  - %-18s %s\n' "${entry%%:*}" "${entry#*:}"
        done
    fi
    if ((${#PROFILE_NOTES[@]})); then
        local profile_note
        printf '\n'
        for profile_note in "${PROFILE_NOTES[@]}"; do
            printf '协议要点         : %s\n' "$profile_note"
        done
    fi
    printf '\n内核建议         : %s\n' "$KERNEL_ADVICE"
    [[ -n $KERNEL_ADVICE_DETAIL ]] && printf '建议说明         : %s\n' "$KERNEL_ADVICE_DETAIL"
    if ((OFFER_KERNEL_INSTALL == 1)); then
        printf '可选内核操作     : apk add %s（独立确认，不自动重启，不删除现有内核）\n' "$KERNEL_PACKAGE"
    fi
    if ((${#SKIPPED_SETTINGS[@]})); then
        printf '\n跳过的参数:\n'
        printf '  - %s\n' "${SKIPPED_SETTINGS[@]}"
    fi
}

print_config_preview() {
    local title=${1:-"将生成的 sysctl 配置"} temp
    temp=$(make_temp) || die "无法创建临时文件"
    if ! render_sysctl_config "$temp"; then
        rm -f -- "$temp"
        die "无法生成 sysctl 配置预览"
    fi
    heading "$title"
    sed 's/^/  /' "$temp"
    rm -f -- "$temp"
}

# --- backup / restore ---

backup_path() {
    local backup_dir=$1 path=$2 relative=${2#/}
    if [[ -e $path || -L $path ]]; then
        mkdir -p -- "$backup_dir/files/$(dirname "$relative")" || return 1
        cp -a -- "$path" "$backup_dir/files/$relative" || return 1
        printf 'present\t%s\n' "$path" >>"$backup_dir/files.manifest" || return 1
    else
        printf 'absent\t%s\n' "$path" >>"$backup_dir/files.manifest" || return 1
    fi
}

create_backup() {
    local timestamp backup_dir i key value root_qdisc="" path
    timestamp=$(date +%Y%m%d_%H%M%S)
    backup_dir="$BACKUP_ROOT/$timestamp"
    [[ -e $backup_dir ]] && backup_dir="${backup_dir}_$$"
    mkdir -p -- "$backup_dir" || return 1
    : >"$backup_dir/files.manifest" || return 1
    : >"$backup_dir/sysctl.runtime" || return 1
    : >"$backup_dir/qdisc.touched" || return 1

    backup_path "$backup_dir" "$SYSCTL_CONF" || return 1
    backup_path "$backup_dir" "$MODULES_CONF" || return 1
    backup_path "$backup_dir" "$PROFILE_LIMITS" || return 1
    backup_path "$backup_dir" "$RC_CONF" || return 1
    backup_path "$backup_dir" "$INITCWND_INITD" || return 1
    backup_path "$backup_dir" "$INITCWND_RUNLEVEL" || return 1
    [[ -d /etc/security/limits.d ]] && { backup_path "$backup_dir" "$PAM_LIMITS_CONF" || return 1; }
    for path in "${CONFD_PATHS[@]}"; do
        backup_path "$backup_dir" "$path" || return 1
    done

    for ((i = 0; i < ${#SYSCTL_KEYS[@]}; i++)); do
        key=${SYSCTL_KEYS[$i]}
        value=$(get_sysctl "$key")
        if [[ -n $value ]]; then
            printf '%s\t%s\n' "$key" "$value" >>"$backup_dir/sysctl.runtime" || return 1
        fi
    done

    if [[ -n $PRIMARY_IFACE ]] && ((HAVE_TC == 1)); then
        root_qdisc=$(tc qdisc show dev "$PRIMARY_IFACE" 2>/dev/null | awk '/ root / {print $2; exit}')
        tc qdisc show dev "$PRIMARY_IFACE" >"$backup_dir/qdisc.txt" 2>/dev/null || true
    fi
    {
        printf 'IFACE=%s\n' "$PRIMARY_IFACE"
        printf 'ROOT_QDISC=%s\n' "$root_qdisc"
        printf 'QDISC_TOUCHED=0\n'
        printf 'QDISC_LEAVES_TOUCHED=0\n'
        printf 'ROUTE4_TOUCHED=0\n'
        printf 'ROUTE6_TOUCHED=0\n'
        printf 'ROUTE4_ORIG=%s\n' "$(current_default_route 4 || true)"
        printf 'ROUTE6_ORIG=%s\n' "$(current_default_route 6 || true)"
    } >"$backup_dir/runtime.state" || return 1

    mkdir -p -- "$STATE_DIR" || return 1
    printf '%s\n' "$backup_dir" | write_atomic_file "$STATE_DIR/latest-backup" 0600 || return 1
    ACTIVE_BACKUP=$backup_dir
    info "已备份到 $backup_dir"
}

allowed_managed_path() {
    case $1 in
        "$SYSCTL_CONF" | "$MODULES_CONF" | "$PROFILE_LIMITS" | "$PAM_LIMITS_CONF" \
            | "$RC_CONF" | "$INITCWND_INITD" | "$INITCWND_RUNLEVEL") return 0 ;;
        "$CONFD_DIR"/*)
            local service=${1#$CONFD_DIR/}
            [[ $service == */* ]] && return 1
            valid_service_name "$service"
            return
            ;;
        *) return 1 ;;
    esac
}

restore_qdisc_leaf_from_backup() {
    local iface=$1 parent=$2 backup_file=$3 line kind full_parent index i
    local -a fields=() options=()
    while IFS= read -r line; do
        read -r -a fields <<<"$line"
        ((${#fields[@]} >= 5)) || continue
        [[ ${fields[0]} == qdisc ]] || continue
        for ((index = 3; index + 1 < ${#fields[@]}; index++)); do
            if [[ ${fields[$index]} == parent && ${fields[$((index + 1))]} == "$parent" ]]; then
                kind=${fields[1]}
                case $kind in cake | fq | fq_codel | pfifo_fast) ;; *) return 1 ;; esac
                options=()
                for ((i = index + 2; i < ${#fields[@]}; i++)); do
                    if [[ ${fields[$i]} == refcnt ]]; then
                        i=$((i + 1))
                        continue
                    fi
                    options+=("${fields[$i]}")
                done
                full_parent=$parent
                [[ $full_parent == :* ]] && full_parent="0$full_parent"
                tc qdisc replace dev "$iface" parent "$parent" "$kind" "${options[@]}" >/dev/null 2>&1 \
                    || tc qdisc replace dev "$iface" parent "$full_parent" "$kind" "${options[@]}" >/dev/null 2>&1 \
                    || tc qdisc replace dev "$iface" parent "$full_parent" "$kind" >/dev/null 2>&1
                return
            fi
        done
    done <"$backup_file"
    return 1
}

restore_backup_internal() {
    local backup_dir=$1 status path relative value key failures=0
    local iface="" root_qdisc="" qdisc_touched=0 qdisc_leaves_touched=0 parent
    local route4_touched=0 route6_touched=0 route4_orig="" route6_orig=""
    [[ $backup_dir == "$BACKUP_ROOT"/* && -f $backup_dir/files.manifest ]] || {
        error "备份目录无效: $backup_dir"
        return 1
    }

    while IFS=$'\t' read -r status path; do
        [[ -n $status && -n $path ]] || continue
        allowed_managed_path "$path" || {
            warn "忽略备份中的未知路径: $path"
            continue
        }
        relative=${path#/}
        case $status in
            present)
                if [[ ! -e $backup_dir/files/$relative && ! -L $backup_dir/files/$relative ]]; then
                    warn "备份内容缺失: $path"
                    failures=$((failures + 1))
                    continue
                fi
                mkdir -p -- "$(dirname "$path")" || { failures=$((failures + 1)); continue; }
                rm -f -- "$path" || { failures=$((failures + 1)); continue; }
                cp -a -- "$backup_dir/files/$relative" "$path" || failures=$((failures + 1))
                ;;
            absent) rm -f -- "$path" || failures=$((failures + 1)) ;;
        esac
    done <"$backup_dir/files.manifest"

    if [[ -f $backup_dir/sysctl.runtime ]]; then
        while IFS=$'\t' read -r key value; do
            [[ -n $key ]] || continue
            if ! set_sysctl "$key" "$value"; then
                warn "未能恢复运行时参数 $key"
                failures=$((failures + 1))
            fi
        done <"$backup_dir/sysctl.runtime"
    fi

    if [[ -f $backup_dir/runtime.state ]]; then
        while IFS='=' read -r key value; do
            case $key in
                IFACE) iface=$value ;;
                ROOT_QDISC) root_qdisc=$value ;;
                QDISC_TOUCHED) qdisc_touched=$value ;;
                QDISC_LEAVES_TOUCHED) qdisc_leaves_touched=$value ;;
                ROUTE4_TOUCHED) route4_touched=$value ;;
                ROUTE6_TOUCHED) route6_touched=$value ;;
                ROUTE4_ORIG) route4_orig=$value ;;
                ROUTE6_ORIG) route6_orig=$value ;;
            esac
        done <"$backup_dir/runtime.state"
    fi
    if [[ $qdisc_touched == 1 && $iface =~ ^[[:alnum:]_.:-]+$ && -d /sys/class/net/$iface ]] \
        && have_cmd tc; then
        case $root_qdisc in
            fq | fq_codel | pfifo_fast | cake)
                tc qdisc replace dev "$iface" root "$root_qdisc" >/dev/null 2>&1 \
                    || { warn "未能恢复 $iface 的 $root_qdisc 队列"; failures=$((failures + 1)); }
                ;;
            noqueue | "")
                tc qdisc del dev "$iface" root >/dev/null 2>&1 || true
                ;;
            *) warn "原队列 $root_qdisc 属于复杂配置，脚本此前未应触碰；请检查 tc qdisc show。" ;;
        esac
    fi
    if [[ $qdisc_leaves_touched == 1 && $iface =~ ^[[:alnum:]_.:-]+$ \
        && -d /sys/class/net/$iface && -f $backup_dir/qdisc.txt && -f $backup_dir/qdisc.touched ]] \
        && have_cmd tc; then
        while IFS= read -r parent; do
            [[ $parent =~ ^[0-9A-Fa-f]*:[0-9A-Fa-f]+$ ]] || continue
            restore_qdisc_leaf_from_backup "$iface" "$parent" "$backup_dir/qdisc.txt" \
                || { warn "未能恢复 $iface 的叶子队列 $parent"; failures=$((failures + 1)); }
        done <"$backup_dir/qdisc.touched"
    fi

    if [[ $route4_touched == 1 && $route4_orig == default* ]]; then
        # shellcheck disable=SC2086
        ip -4 route change $route4_orig >/dev/null 2>&1 \
            || { warn "未能恢复 IPv4 默认路由的 initcwnd 参数"; failures=$((failures + 1)); }
    fi
    if [[ $route6_touched == 1 && $route6_orig == default* ]]; then
        # shellcheck disable=SC2086
        ip -6 route change $route6_orig >/dev/null 2>&1 \
            || { warn "未能恢复 IPv6 默认路由的 initcwnd 参数"; failures=$((failures + 1)); }
    fi
    if [[ ! -e $INITCWND_INITD ]] && have_cmd rc-update; then
        rc-update del "$INITCWND_SERVICE" default >/dev/null 2>&1 || true
        rm -f -- "$INITCWND_RUNLEVEL"
    fi
    ((failures == 0))
}

rollback_on_failure() {
    local reason=$1
    error "$reason"
    if [[ -n $ACTIVE_BACKUP ]]; then
        warn "正在自动恢复应用前配置……"
        restore_backup_internal "$ACTIVE_BACKUP" || warn "自动恢复不完整，请手动运行 --restore。"
    fi
    APPLYING=0
}

restore_latest() {
    require_root
    local backup_dir=""
    [[ -r $STATE_DIR/latest-backup ]] && read -r backup_dir <"$STATE_DIR/latest-backup"
    [[ $backup_dir == "$BACKUP_ROOT"/* && -d $backup_dir ]] || die "没有找到可恢复的最近备份。"
    if ((ASSUME_YES == 0)); then
        printf '将恢复备份: %s\n' "$backup_dir"
        local answer
        read -r -p "输入 RESTORE 继续: " answer
        answer=$(normalize_user_input "$answer")
        [[ $answer == "RESTORE" ]] || die "已取消恢复"
    fi
    restore_backup_internal "$backup_dir" || die "恢复失败"
    info "已恢复应用前的配置。运行中的服务会在下次 rc-service <名字> restart 后继承恢复后的 FD 默认值。"
    warn "恢复操作不会卸载脚本装过的软件包（iproute2 等），也不会卸载你单独确认安装的内核包。"
}

# --- optional kernel package operation (independently confirmed) ---

kernel_install_preflight() {
    local free_kb="" root_free_kb=""
    apk_available || { error "没有 apk，无法安装 Alpine 内核包。"; return 1; }
    is_container_guest && { error "容器不能自行更换宿主机内核。"; return 1; }
    case $ARCH in
        x86_64 | aarch64) ;;
        *) error "脚本只对 x86_64 / aarch64 提供内核自动安装。"; return 1 ;;
    esac
    # BusyBox df has no -m; -Pk is always available.
    free_kb=$(df -Pk /boot 2>/dev/null | awk 'NR == 2 {print $4}')
    if is_uint "$free_kb" && ((free_kb < 60 * 1024)); then
        error "/boot 可用空间仅 $((free_kb / 1024)) MiB；至少预留 60 MiB 后再安装内核。"
        return 1
    fi
    root_free_kb=$(df -Pk / 2>/dev/null | awk 'NR == 2 {print $4}')
    if is_uint "$root_free_kb" && ((root_free_kb < 300 * 1024)); then
        error "根分区可用空间仅 $((root_free_kb / 1024)) MiB；至少预留 300 MiB 后再安装内核。"
        return 1
    fi
    if [[ ! -e /boot/extlinux.conf && ! -e /etc/update-extlinux.conf \
        && ! -e /boot/grub/grub.cfg && ! -d /boot/loader/entries ]]; then
        warn "未识别到常见本地引导器配置；内核包可能安装成功但 VPS 未必会从它启动。"
    fi
    return 0
}

install_alpine_kernel() {
    local status=""
    kernel_install_preflight || return 1
    heading "安装 Alpine 官方内核: $KERNEL_PACKAGE"
    info "只使用发行版官方源，不加第三方仓库；不自动重启，也不删除当前内核。"
    if ! apk add --no-cache "$KERNEL_PACKAGE"; then
        error "$KERNEL_PACKAGE 安装失败；网络调优仍可使用当前内核继续。"
        return 1
    fi
    status=$(apk info -e "$KERNEL_PACKAGE" 2>/dev/null || true)
    if [[ -z $status ]]; then
        error "apk 返回成功，但未能确认 $KERNEL_PACKAGE 已安装。"
        return 1
    fi
    KERNEL_INSTALLED=1
    INSTALLED_KERNEL_SOURCE="Alpine 官方 $KERNEL_PACKAGE"
    compgen -G '/boot/vmlinuz*' >/dev/null \
        || warn "没有在 /boot 发现 vmlinuz；请在重启前检查 VPS 的引导方式。"
    info "$KERNEL_PACKAGE 已安装；必须稍后重启才会切换过去。"
    return 0
}

maybe_install_recommended_kernel() {
    local answer available
    ((RECOMMEND_KERNEL == 1 && OFFER_KERNEL_INSTALL == 1)) || return 0
    if [[ ! -t 0 ]]; then
        warn "非交互运行不会安装内核；请交互运行并明确确认。"
        return 0
    fi

    heading "可选内核操作（独立确认）"
    printf '建议包           : %s（Alpine 官方仓库）\n' "$KERNEL_PACKAGE"
    printf '影响             : apk 会重建 initramfs 并更新引导配置；不自动重启，不删除旧内核。\n'
    printf '风险             : 换内核后若引导配置有问题可能开不了机，请确认服务商提供 VNC/救援模式。\n'
    read -r -p "确认立即安装请输入 INSTALL KERNEL；其他输入跳过: " answer
    answer=$(normalize_user_input "$answer")
    if [[ $answer != "INSTALL KERNEL" ]]; then
        info "已跳过内核安装，继续使用当前内核。"
        return 0
    fi
    if ! install_alpine_kernel; then
        warn "没有安装新内核，继续按当前内核应用网络配置。"
        return 0
    fi

    SELECTED_CC="bbr"
    available=$(get_sysctl net.ipv4.tcp_available_congestion_control)
    if ! word_in_list bbr "$available"; then
        FUTURE_BBR_ONLY=1
        warn "当前运行内核尚无 BBR；配置会在重启进入新内核后使用 BBR，当前暂时保留原拥塞控制。"
    fi
    prepare_settings
    filter_supported_settings
}

# --- configuration writers ---

write_service_confd_blocks() {
    local i service path
    for ((i = 0; i < ${#CONFD_SERVICES[@]}; i++)); do
        service=${CONFD_SERVICES[$i]}
        path=${CONFD_PATHS[$i]}
        write_managed_block "$path" 0644 <<EOF || return 1
# 提高 $service 的文件描述符上限；OpenRC 在启动服务前会执行 ulimit -n
rc_ulimit="-n $NOFILE_LIMIT"
EOF
    done
    return 0
}

write_rc_conf_block() {
    write_managed_block "$RC_CONF" 0644 <<EOF || return 1
# 所有 OpenRC 服务的默认 FD 上限（/etc/conf.d/<服务> 里的同名设置优先级更高）
rc_ulimit="-n $NOFILE_LIMIT"
EOF
    return 0
}

write_login_limits() {
    # Alpine has no PAM by default, so login shells get their limit from
    # /etc/profile.d instead of /etc/security/limits.conf.
    write_atomic_file "$PROFILE_LIMITS" 0644 <<EOF || return 1
# Generated by $PROGRAM_NAME v$SCRIPT_VERSION
# 登录 shell 的 FD 上限；OpenRC 服务的上限由 /etc/rc.conf 与 /etc/conf.d 控制。
ulimit -n $NOFILE_LIMIT 2>/dev/null || ulimit -n "\$(ulimit -H -n)" 2>/dev/null || true
EOF
    if [[ -d /etc/security/limits.d ]]; then
        write_atomic_file "$PAM_LIMITS_CONF" 0644 <<EOF || return 1
# Generated by $PROGRAM_NAME v$SCRIPT_VERSION（检测到 linux-pam 才写入）
*    soft nofile $NOFILE_LIMIT
*    hard nofile $NOFILE_LIMIT
root soft nofile $NOFILE_LIMIT
root hard nofile $NOFILE_LIMIT
EOF
    fi
    return 0
}

write_supporting_configs() {
    write_rc_conf_block || return 1
    write_service_confd_blocks || return 1
    write_login_limits || return 1

    local module_lines=""
    [[ $SELECTED_CC == "bbr" ]] && ! module_builtin tcp_bbr && module_lines+=$'tcp_bbr\n'
    [[ $SELECTED_QDISC == "fq" ]] && ! module_builtin sch_fq && module_lines+=$'sch_fq\n'
    [[ $SELECTED_QDISC == "fq_codel" ]] && ! module_builtin sch_fq_codel && module_lines+=$'sch_fq_codel\n'
    if [[ -n $module_lines ]] && ! is_container_guest; then
        printf '# Generated by %s v%s（由 OpenRC 的 modules 服务在 sysctl 之前加载）\n%s' \
            "$PROGRAM_NAME" "$SCRIPT_VERSION" "$module_lines" \
            | write_atomic_file "$MODULES_CONF" 0644 || return 1
    else
        rm -f -- "$MODULES_CONF"
    fi
    return 0
}

write_initcwnd_service() {
    local fams
    case $IP_MODE in
        4) fams="-4" ;;
        6) fams="-6" ;;
        *) fams="-4 -6" ;;
    esac
    # The route spec is re-read on every boot, so a gateway that changed since
    # this file was written is never clobbered with stale data.
    write_atomic_file "$INITCWND_INITD" 0755 <<EOF || return 1
#!/sbin/openrc-run
# Generated by $PROGRAM_NAME v$SCRIPT_VERSION
description="$PROGRAM_NAME: raise initcwnd/initrwnd on default routes"

depend() {
	after net
}

start() {
	ebegin "Raising initcwnd/initrwnd to $INITCWND on default routes"
	for _fam in $fams; do
		[ "\$(ip \$_fam route show default 2>/dev/null | grep -c .)" = 1 ] || continue
		_route=\$(ip \$_fam route show default | head -n1 | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ \$//; s/ (initcwnd|initrwnd) [0-9]+//g; s/ expires [0-9]+sec//g; s/ linkdown//g')
		[ -n "\$_route" ] || continue
		ip \$_fam route change \$_route initcwnd $INITCWND initrwnd $INITCWND || true
	done
	eend 0
}

stop() {
	return 0
}
EOF
    if have_cmd rc-update; then
        rc-update add "$INITCWND_SERVICE" default >/dev/null 2>&1 || return 1
    else
        warn "没有 rc-update，initcwnd 服务已写入但未加入 default 运行级别。"
    fi
    return 0
}

apply_mq_leaf_qdiscs() {
    local iface=$1 state_file=$2 touched_file="$ACTIVE_BACKUP/qdisc.touched"
    local output line kind parent="" full_parent handle replace_error="" i
    local changed=0 failed=0 recorded=0 preserved=0
    local -a fields=() parents=() kinds=()
    output=$(tc qdisc show dev "$iface" 2>/dev/null || true)
    while IFS= read -r line; do
        read -r -a fields <<<"$line"
        ((${#fields[@]} >= 5)) || continue
        [[ ${fields[0]} == qdisc ]] || continue
        kind=${fields[1]}
        parent=""
        for ((i = 3; i + 1 < ${#fields[@]}; i++)); do
            if [[ ${fields[$i]} == parent ]]; then
                parent=${fields[$((i + 1))]}
                break
            fi
        done
        [[ $parent =~ ^[0-9A-Fa-f]*:[0-9A-Fa-f]+$ ]] || continue
        [[ $kind == "$SELECTED_QDISC" ]] && continue
        case $kind in
            cake)
                if [[ " $line " == *" bandwidth unlimited "* ]]; then
                    parents+=("$parent"); kinds+=("$kind")
                else
                    warn "$iface 叶子 $parent 使用有限速的 CAKE，视为自定义 QoS，保持不变。"
                    preserved=$((preserved + 1))
                fi
                ;;
            fq_codel | pfifo_fast)
                parents+=("$parent"); kinds+=("$kind")
                ;;
            *)
                warn "$iface 叶子 $parent 使用自定义队列 $kind，保持不变。"
                preserved=$((preserved + 1))
                ;;
        esac
    done <<<"$output"

    if ((${#parents[@]} == 0)); then
        ((preserved == 0)) && info "$iface 的 mq 叶子队列已全部是 $SELECTED_QDISC"
        return 0
    fi
    if ! sed -i 's/^QDISC_LEAVES_TOUCHED=.*/QDISC_LEAVES_TOUCHED=1/' "$state_file"; then
        error "无法记录 mq 叶子队列回滚状态，已取消即时替换。"
        return 1
    fi
    for ((i = 0; i < ${#parents[@]}; i++)); do
        parent=${parents[$i]}
        kind=${kinds[$i]}
        if ! printf '%s\n' "$parent" >>"$touched_file"; then
            error "无法记录 $iface 叶子 $parent 的回滚信息。"
            return 1
        fi
        recorded=$((recorded + 1))
        replace_error=$(tc qdisc replace dev "$iface" parent "$parent" "$SELECTED_QDISC" 2>&1) && {
            changed=$((changed + 1))
            continue
        }

        # Some mq drivers print the abbreviated parent ":N" but only accept
        # the full "0:N" classid, or require a non-zero child handle when the
        # old leaf was installed with the implicit handle 0:.
        full_parent=$parent
        [[ $full_parent == :* ]] && full_parent="0$full_parent"
        if replace_error=$(tc qdisc replace dev "$iface" parent "$full_parent" \
            "$SELECTED_QDISC" 2>&1); then
            changed=$((changed + 1))
        else
            printf -v handle '%x:' $((0xF000 + i + 1))
            if replace_error=$(tc qdisc replace dev "$iface" parent "$full_parent" \
                handle "$handle" "$SELECTED_QDISC" 2>&1); then
                changed=$((changed + 1))
            else
                replace_error=$(normalize_user_input "$replace_error")
                warn "无法把 $iface 叶子 $parent 从 $kind 替换为 $SELECTED_QDISC：${replace_error:-tc 未返回原因}。"
                failed=$((failed + 1))
            fi
        fi
    done
    ((changed > 0)) && info "已把 $iface 的 $changed 个 mq 叶子队列即时切换为 $SELECTED_QDISC"
    ((failed == 0)) || warn "$failed 个 mq 叶子队列未能切换；持久默认值仍为 $SELECTED_QDISC。"
    ((recorded == ${#parents[@]}))
}

apply_live_qdisc() {
    local iface=$PRIMARY_IFACE old_root="" state_file="$ACTIVE_BACKUP/runtime.state"
    if ((HAVE_TC == 0)); then
        warn "没有 tc 命令（apk add iproute2-tc），跳过即时切换队列；默认 qdisc 已写入 sysctl，重启后生效。"
        return 0
    fi
    [[ -n $iface && -d /sys/class/net/$iface ]] || {
        warn "未检测到可用主网卡，默认 qdisc 将在网卡下次创建或重启后生效。"
        return 0
    }
    old_root=$(tc qdisc show dev "$iface" 2>/dev/null | awk '/ root / {print $2; exit}')
    case $old_root in
        "$SELECTED_QDISC") return 0 ;;
        "" | noqueue | pfifo_fast | fq | fq_codel)
            if ! sed -i 's/^QDISC_TOUCHED=.*/QDISC_TOUCHED=1/' "$state_file"; then
                error "无法记录 qdisc 回滚状态，已取消即时替换。"
                return 1
            fi
            if tc qdisc replace dev "$iface" root "$SELECTED_QDISC" >/dev/null 2>&1; then
                info "已在 $iface 即时应用 $SELECTED_QDISC"
            else
                sed -i 's/^QDISC_TOUCHED=.*/QDISC_TOUCHED=0/' "$state_file" || true
                warn "无法在 $iface 即时替换 qdisc；持久配置仍已写入。"
            fi
            ;;
        mq)
            apply_mq_leaf_qdiscs "$iface" "$state_file"
            ;;
        *)
            warn "$iface 已有自定义队列 $old_root，为避免破坏现有限速/QoS，未即时替换。"
            ;;
    esac
}

apply_initcwnd() {
    ((INITCWND > 0)) || return 0
    local state_file="$ACTIVE_BACKUP/runtime.state" fam base applied=0 skipped=0
    for fam in 4 6; do
        case $IP_MODE in
            4) [[ $fam == 4 ]] || continue ;;
            6) [[ $fam == 6 ]] || continue ;;
        esac
        if ! base=$(current_default_route "$fam"); then
            skipped=$((skipped + 1))
            continue
        fi
        [[ -n $base ]] || { skipped=$((skipped + 1)); continue; }
        if ! sed -i "s/^ROUTE${fam}_TOUCHED=.*/ROUTE${fam}_TOUCHED=1/" "$state_file"; then
            warn "无法记录 IPv$fam 路由回滚状态，跳过该协议族的 initcwnd。"
            continue
        fi
        # shellcheck disable=SC2086
        if ip "-$fam" route change $base initcwnd "$INITCWND" initrwnd "$INITCWND" >/dev/null 2>&1; then
            applied=$((applied + 1))
        else
            sed -i "s/^ROUTE${fam}_TOUCHED=.*/ROUTE${fam}_TOUCHED=0/" "$state_file" || true
            warn "IPv$fam 默认路由不接受 initcwnd 修改，已保持原样。"
        fi
    done
    if ((applied > 0)); then
        info "已把 $applied 个默认路由的 initcwnd/initrwnd 提升到 $INITCWND"
        write_initcwnd_service \
            || warn "initcwnd 已即时生效，但持久化 OpenRC 服务写入/启用失败；重启后需重跑脚本。"
    elif ((skipped > 0)); then
        warn "没有找到可安全修改的默认路由（不存在或为多路径），initcwnd 未生效。"
    fi
    return 0
}

raise_live_proxy_limits() {
    if ((HAVE_PRLIMIT == 0)); then
        warn "未找到 prlimit（apk add util-linux-misc）；FD 新上限将在代理服务下次重启时生效。"
        return 0
    fi
    local pid raised=0
    for pid in "${PROXY_PIDS[@]}"; do
        [[ $pid =~ ^[0-9]+$ ]] || continue
        ((pid == $$ || pid == PPID)) && continue
        [[ -d /proc/$pid ]] || continue
        if prlimit --pid "$pid" --nofile="$NOFILE_LIMIT:$NOFILE_LIMIT" >/dev/null 2>&1; then
            raised=$((raised + 1))
        fi
    done
    if ((raised > 0)); then
        info "已即时提升 $raised 个运行中代理进程的 FD 上限"
    else
        info "未发现可即时调整的代理进程；FD 配置将在服务下次启动时生效"
    fi
}

apply_runtime_sysctls() {
    local i key value failures=0
    for ((i = 0; i < ${#SYSCTL_KEYS[@]}; i++)); do
        key=${SYSCTL_KEYS[$i]}
        value=${SYSCTL_VALUES[$i]}
        if ((FUTURE_BBR_ONLY == 1)) && [[ $key == "net.ipv4.tcp_congestion_control" ]]; then
            continue
        fi
        if ! set_sysctl "$key" "$value"; then
            error "无法应用 $key = $value"
            failures=$((failures + 1))
        fi
    done
    ((failures == 0))
}

ensure_sysctl_service_enabled() {
    have_cmd rc-update || return 0
    if rc-update show boot 2>/dev/null | grep -q '^ *sysctl'; then
        return 0
    fi
    if rc-update show 2>/dev/null | grep -q '^ *sysctl'; then
        return 0
    fi
    if rc-update add sysctl boot >/dev/null 2>&1; then
        info "已把 OpenRC 的 sysctl 服务加入 boot 运行级别（否则重启后 /etc/sysctl.d 不会被加载）。"
    else
        warn "无法把 sysctl 服务加入 boot 运行级别；请手动执行 rc-update add sysctl boot。"
    fi
    return 0
}

apply_configuration() {
    local temp
    [[ -n $ACTIVE_BACKUP ]] || create_backup || die "无法创建备份"
    APPLYING=1

    temp=$(make_temp) || {
        rollback_on_failure "无法创建临时文件"
        return 1
    }
    if ! render_sysctl_config "$temp"; then
        rm -f -- "$temp"
        rollback_on_failure "无法生成 sysctl 配置"
        return 1
    fi
    mkdir -p -- "$(dirname "$SYSCTL_CONF")"
    if ! install -m 0644 "$temp" "$SYSCTL_CONF"; then
        rm -f -- "$temp"
        rollback_on_failure "无法写入 $SYSCTL_CONF"
        return 1
    fi
    rm -f -- "$temp"

    if ! apply_runtime_sysctls; then
        rollback_on_failure "sysctl 应用失败"
        return 1
    fi

    if ! write_supporting_configs; then
        rollback_on_failure "写入 FD/OpenRC 配置失败"
        return 1
    fi
    ensure_sysctl_service_enabled

    if ! apply_live_qdisc; then
        rollback_on_failure "qdisc 应用前的回滚状态记录失败"
        return 1
    fi
    apply_initcwnd
    raise_live_proxy_limits
    APPLYING=0
    return 0
}

# --- verification / status ---

validate_result() {
    local failures=0 actual key expected actual_normalized expected_normalized i pid soft name
    heading "本机生效检查"
    for key in net.ipv4.tcp_congestion_control net.core.default_qdisc net.core.rmem_max \
        net.core.wmem_max net.ipv4.tcp_fastopen fs.nr_open; do
        if sysctl_exists "$key"; then
            actual=$(get_sysctl "$key")
            printf '  %-42s %s\n' "$key" "$actual"
        fi
    done

    for ((i = 0; i < ${#SYSCTL_KEYS[@]}; i++)); do
        key=${SYSCTL_KEYS[$i]}
        expected=${SYSCTL_VALUES[$i]}
        if ((FUTURE_BBR_ONLY == 1)) && [[ $key == "net.ipv4.tcp_congestion_control" ]]; then
            continue
        fi
        actual=$(get_sysctl "$key")
        actual_normalized=$(normalize_sysctl_value "$actual")
        expected_normalized=$(normalize_sysctl_value "$expected")
        if [[ $actual_normalized != "$expected_normalized" ]]; then
            warn "$key 未达到目标：实际 '${actual_normalized:-空}'，目标 '$expected_normalized'"
            failures=$((failures + 1))
        fi
    done
    if [[ -n $PRIMARY_IFACE ]] && ((HAVE_TC == 1)); then
        printf '  tc qdisc (%s)：\n' "$PRIMARY_IFACE"
        tc qdisc show dev "$PRIMARY_IFACE" 2>/dev/null | sed 's/^/    /'
    fi
    if ((INITCWND > 0)); then
        printf '  默认路由（应含 initcwnd %s）：\n' "$INITCWND"
        { ip -4 route show default 2>/dev/null; ip -6 route show default 2>/dev/null; } \
            | sed 's/^/    /'
    fi
    detect_bbr_generation
    printf '  %-42s %s\n' "BBR generation" "$CURRENT_BBR_GENERATION"

    if has_managed_block "$RC_CONF"; then
        printf '  %-42s %s\n' "/etc/rc.conf 托管块" "已写入 rc_ulimit=\"-n $NOFILE_LIMIT\""
    else
        warn "/etc/rc.conf 没有检测到托管块，OpenRC 服务可能拿不到新的 FD 上限。"
        failures=$((failures + 1))
    fi
    if ((${#CONFD_SERVICES[@]})); then
        printf '\n  代理服务 conf.d：\n'
        for i in "${!CONFD_SERVICES[@]}"; do
            if has_managed_block "${CONFD_PATHS[$i]}"; then
                printf '  %-42s %s\n' "${CONFD_SERVICES[$i]}" "已写入 ${CONFD_PATHS[$i]}"
            else
                warn "${CONFD_PATHS[$i]} 写入失败"
                failures=$((failures + 1))
            fi
        done
        printf '  提示：conf.d 里的 rc_ulimit 需要 rc-service <服务> restart 才会对已运行进程生效。\n'
    fi
    if ((${#PROXY_PIDS[@]})); then
        printf '\n  运行中代理进程 FD：\n'
        for pid in "${PROXY_PIDS[@]}"; do
            [[ -d /proc/$pid ]] || continue
            name=$(proc_name "$pid")
            soft=$(proc_nofile_soft "$pid")
            printf '  %-42s %s\n' "${name:-pid} (pid $pid)" "${soft:-无法读取}"
            if [[ -n $soft && $soft != unlimited ]] && ! decimal_ge "$soft" "$NOFILE_LIMIT"; then
                warn "$name (pid $pid) 的 FD 软上限仍低于 $NOFILE_LIMIT；重启该服务即可生效。"
            fi
        done
    elif ((${#PROXY_SERVICES[@]} == 0)); then
        warn "应用时没有检测到代理服务；以后安装代理后请重新运行脚本。"
    fi
    ((FUTURE_BBR_ONLY == 1)) && info "BBR 项已写入持久配置，待重启进入新内核后生效。"
    if ((failures == 0)); then
        info "配置值已全部通过本机检查（未执行带宽测速）。"
    else
        warn "$failures 个参数与目标值不同，可能被宿主机或其他配置覆盖。"
    fi
}

show_status() {
    require_commands
    IP_MODE=${IP_MODE:-dual}
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        ALPINE_VERSION=${VERSION_ID:-}
    fi
    [[ -z $ALPINE_VERSION && -r /etc/alpine-release ]] && read -r ALPINE_VERSION </etc/alpine-release
    detect_system
    discover_proxy_services
    detect_bbr_generation
    heading "当前 Alpine 代理网络状态"
    printf '脚本版本         : %s（移植自 %s）\n' "$SCRIPT_VERSION" "$BASED_ON"
    printf '系统             : Alpine %s / %s / %s / %s vCPU / %s MiB RAM / %s MiB Swap\n' \
        "${ALPINE_VERSION:-未知}" "$ARCH" "$KERNEL_RELEASE" "$CPU_CORES" "$MEM_MB" "$SWAP_MB"
    printf '虚拟化           : %s\n' "$VIRT_TYPE"
    printf '主网卡           : %s\n' "${PRIMARY_IFACE:-未检测到}"
    printf 'BBR 识别         : %s\n' "$CURRENT_BBR_GENERATION"
    printf '工具链           : OpenRC=%s iproute2=%s tc=%s prlimit=%s\n' \
        "$( ((HAVE_OPENRC == 1)) && echo 有 || echo 无 )" \
        "$( ((HAVE_IPROUTE2 == 1)) && echo 有 || echo 无 )" \
        "$( ((HAVE_TC == 1)) && echo 有 || echo 无 )" \
        "$( ((HAVE_PRLIMIT == 1)) && echo 有 || echo 无 )"
    printf '\n'
    local key path service pid name soft
    for key in net.ipv4.tcp_available_congestion_control net.ipv4.tcp_congestion_control \
        net.core.default_qdisc net.core.rmem_max net.core.wmem_max net.core.rmem_default \
        net.ipv4.tcp_rmem net.ipv4.tcp_wmem net.ipv4.tcp_fastopen net.ipv4.tcp_ecn \
        net.ipv4.tcp_ecn_fallback net.ipv4.tcp_notsent_lowat net.ipv4.tcp_mem \
        net.ipv4.tcp_tw_reuse net.ipv4.tcp_fin_timeout net.ipv4.tcp_no_metrics_save \
        net.ipv4.tcp_keepalive_time net.core.somaxconn net.core.netdev_max_backlog \
        net.core.optmem_max net.ipv4.udp_mem net.netfilter.nf_conntrack_max vm.min_free_kbytes \
        net.ipv4.ip_local_port_range net.ipv4.ip_local_reserved_ports fs.file-max fs.nr_open; do
        sysctl_exists "$key" && printf '%-43s %s\n' "$key" "$(get_sysctl "$key")"
    done
    printf '\n默认路由（可检查 initcwnd 是否生效）：\n'
    { ip -4 route show default 2>/dev/null; ip -6 route show default 2>/dev/null; } \
        | sed 's/^/  /'
    [[ -f $SYSCTL_CONF ]] && printf '\nsysctl 配置文件  : %s\n' "$SYSCTL_CONF"
    [[ -f $MODULES_CONF ]] && printf '模块自动加载     : %s\n' "$MODULES_CONF"
    [[ -f $PROFILE_LIMITS ]] && printf '登录 shell 限制  : %s\n' "$PROFILE_LIMITS"
    [[ -f $INITCWND_INITD ]] && printf 'initcwnd 服务    : %s（runlevel: %s）\n' \
        "$INITCWND_INITD" "$( [[ -e $INITCWND_RUNLEVEL ]] && echo default || echo 未启用 )"
    if has_managed_block "$RC_CONF"; then
        printf '\n/etc/rc.conf 托管块：\n'
        managed_block_body "$RC_CONF" | sed 's/^/  /'
    else
        warn "/etc/rc.conf 里没有本脚本的托管块；OpenRC 服务使用系统默认 FD 上限。"
    fi
    if ((${#PROXY_SERVICES[@]})); then
        printf '\n代理服务 conf.d：\n'
        for service in "${PROXY_SERVICES[@]}"; do
            path="$CONFD_DIR/$service"
            if has_managed_block "$path"; then
                printf '  %-30s %s\n' "$service" "$(managed_block_body "$path" | grep -E 'rc_ulimit' || echo '已托管')"
            elif soft=$(confd_nofile_value "$path"); then
                printf '  %-30s 自定义 rc_ulimit -n %s\n' "$service" "$soft"
            else
                printf '  %-30s 未设置 rc_ulimit（将使用 /etc/rc.conf 的默认值）\n' "$service"
            fi
        done
    else
        warn "没有检测到代理服务；若代理尚未安装，安装后请再次运行脚本。"
    fi
    if ((${#PROXY_PIDS[@]})); then
        printf '\n运行中代理进程 FD：\n'
        for pid in "${PROXY_PIDS[@]}"; do
            [[ -d /proc/$pid ]] || continue
            name=$(proc_name "$pid")
            soft=$(proc_nofile_soft "$pid")
            printf '  %-30s pid %-8s soft nofile %s\n' "${name:-未知}" "$pid" "${soft:-无法读取}"
        done
    fi
    if ((HAVE_TC == 1)) && [[ -n $PRIMARY_IFACE ]]; then
        printf '\ntc qdisc (%s)：\n' "$PRIMARY_IFACE"
        tc qdisc show dev "$PRIMARY_IFACE" 2>/dev/null | sed 's/^/  /'
    fi
    return 0
}

# --- self test ---

reset_self_test_state() {
    PROTOCOL="general"
    RELAY_MBPS=0
    RELAY_RTT_MS=0
    RELAY_SHARE=50
}

run_self_test() {
    local failures=0 result="" temp=""
    heading "内置计算测试"
    reset_self_test_state

    MEM_MB=512 CPU_CORES=1 LOCAL_MBPS=1000 SERVER_MBPS=200 RTT_MS=60
    calculate_tuning
    if ((BDP_BYTES == 1500000 && BUFFER_MIB == 4 && BUFFER_CAP_MIB == 20 \
        && NOFILE_LIMIT == 131072 && SOMAXCONN == 2048 && NETDEV_BACKLOG == 2048)); then
        printf '  PASS  200 Mbps / 60 ms / 512 MiB -> 4 MiB，FD 131072\n'
    else
        printf '  FAIL  场景 1: BDP=%s buffer=%s cap=%s nofile=%s somaxconn=%s backlog=%s\n' \
            "$BDP_BYTES" "$BUFFER_MIB" "$BUFFER_CAP_MIB" "$NOFILE_LIMIT" "$SOMAXCONN" "$NETDEV_BACKLOG"
        failures=$((failures + 1))
    fi

    MEM_MB=1024 CPU_CORES=1 LOCAL_MBPS=1000 SERVER_MBPS=1000 RTT_MS=100
    calculate_tuning
    if ((BDP_BYTES == 12500000 && BUFFER_MIB == 32 && BUFFER_CAP_MIB == 42 \
        && NETDEV_BACKLOG == 8192 && NOFILE_LIMIT == 262144 && NOTSENT_LOWAT == 65536)); then
        printf '  PASS  1 Gbps / 100 ms / 1 GiB -> 32 MiB，notsent_lowat 压到 64 KiB\n'
    else
        printf '  FAIL  场景 2: BDP=%s buffer=%s cap=%s backlog=%s nofile=%s lowat=%s\n' \
            "$BDP_BYTES" "$BUFFER_MIB" "$BUFFER_CAP_MIB" "$NETDEV_BACKLOG" "$NOFILE_LIMIT" "$NOTSENT_LOWAT"
        failures=$((failures + 1))
    fi

    MEM_MB=512 CPU_CORES=1 LOCAL_MBPS=1000 SERVER_MBPS=1000 RTT_MS=250
    calculate_tuning
    if ((BUFFER_MIB == 20 && BUFFER_WAS_CAPPED == 1)); then
        printf '  PASS  1 Gbps / 250 ms / 512 MiB -> 内存上限裁剪到 20 MiB\n'
    else
        printf '  FAIL  场景 3: buffer=%s capped=%s\n' "$BUFFER_MIB" "$BUFFER_WAS_CAPPED"
        failures=$((failures + 1))
    fi

    MEM_MB=256 CPU_CORES=1 LOCAL_MBPS=500 SERVER_MBPS=500 RTT_MS=40
    calculate_tuning
    if ((BUFFER_CAP_MIB == 10 && NOFILE_LIMIT == 65536 && SOMAXCONN == 1024 \
        && NETDEV_BACKLOG == 2048 && MIN_FREE_KB == 4096)); then
        printf '  PASS  256 MiB 微型机降档：cap 10 MiB / FD 65536 / min_free 4096 KiB\n'
    else
        printf '  FAIL  场景 4: cap=%s nofile=%s somaxconn=%s backlog=%s minfree=%s\n' \
            "$BUFFER_CAP_MIB" "$NOFILE_LIMIT" "$SOMAXCONN" "$NETDEV_BACKLOG" "$MIN_FREE_KB"
        failures=$((failures + 1))
    fi

    PROTOCOL="ss2022-relay"
    MEM_MB=1024 CPU_CORES=1 LOCAL_MBPS=1000 SERVER_MBPS=500 RTT_MS=40
    RELAY_MBPS=300 RELAY_RTT_MS=120 RELAY_SHARE=50
    calculate_tuning
    apply_protocol_profile
    if ((RELAY_PATH_RTT == 160 && RELAY_EFFECTIVE_MBPS == 300 && RELAY_BDP_BYTES == 6000000 \
        && DESIGN_BDP_BYTES == 6000000 && BUFFER_CAP_MIB == 28 && BUFFER_MIB == 14 \
        && NOFILE_LIMIT == 524288 && KEEPALIVE_TIME == 600 && KEEPALIVE_PROBES == 3)); then
        printf '  PASS  中转档：端到端 160 ms / 300 Mbps -> 14 MiB，cap 按 50%% 分流收紧到 28 MiB，FD 翻倍\n'
    else
        printf '  FAIL  中转档: pathrtt=%s eff=%s relaybdp=%s design=%s cap=%s buffer=%s nofile=%s keep=%s/%s\n' \
            "$RELAY_PATH_RTT" "$RELAY_EFFECTIVE_MBPS" "$RELAY_BDP_BYTES" "$DESIGN_BDP_BYTES" \
            "$BUFFER_CAP_MIB" "$BUFFER_MIB" "$NOFILE_LIMIT" "$KEEPALIVE_TIME" "$KEEPALIVE_PROBES"
        failures=$((failures + 1))
    fi

    reset_self_test_state
    PROTOCOL="hysteria"
    MEM_MB=512 CPU_CORES=1 LOCAL_MBPS=500 SERVER_MBPS=500 RTT_MS=20
    calculate_tuning
    apply_protocol_profile
    if ((BUFFER_MIB == 16 && HYSTERIA_BELOW_RECOMMENDED == 0)); then
        printf '  PASS  Hysteria 档把过小的 UDP 缓冲抬到 16 MiB\n'
    else
        printf '  FAIL  Hysteria 缓冲下限: buffer=%s below=%s\n' "$BUFFER_MIB" "$HYSTERIA_BELOW_RECOMMENDED"
        failures=$((failures + 1))
    fi

    PROTOCOL="hysteria"
    MEM_MB=256 CPU_CORES=1 LOCAL_MBPS=500 SERVER_MBPS=500 RTT_MS=20
    calculate_tuning
    apply_protocol_profile
    if ((BUFFER_MIB == 10 && HYSTERIA_BELOW_RECOMMENDED == 1)); then
        printf '  PASS  256 MiB 上 Hysteria 缓冲被压到 10 MiB 并给出低于建议值的告警\n'
    else
        printf '  FAIL  Hysteria 微型机: buffer=%s below=%s\n' "$BUFFER_MIB" "$HYSTERIA_BELOW_RECOMMENDED"
        failures=$((failures + 1))
    fi

    reset_self_test_state
    PROTOCOL="vless-cdn"
    MEM_MB=2048 CPU_CORES=2 LOCAL_MBPS=1000 SERVER_MBPS=1000 RTT_MS=10
    calculate_tuning
    apply_protocol_profile
    if ((SOMAXCONN == 8192 && SYN_BACKLOG == 16384 && KEEPALIVE_TIME == 600)); then
        printf '  PASS  CDN 档加倍 accept/SYN 队列并缩短保活\n'
    else
        printf '  FAIL  CDN 档: somaxconn=%s syn=%s keepalive=%s\n' \
            "$SOMAXCONN" "$SYN_BACKLOG" "$KEEPALIVE_TIME"
        failures=$((failures + 1))
    fi

    result=$(merge_port_ranges "80,40000-50010" "50000:51000" "443") || result="ERROR"
    if [[ $result == "80,443,40000-51000" ]]; then
        printf '  PASS  Hysteria 保留端口与现有范围正确合并\n'
    else
        printf '  FAIL  端口范围合并: %s\n' "$result"
        failures=$((failures + 1))
    fi

    if ! normalize_port_ranges "51000:50000" >/dev/null 2>&1; then
        printf '  PASS  拒绝倒置的端口范围\n'
    else
        printf '  FAIL  未拒绝倒置的端口范围\n'
        failures=$((failures + 1))
    fi

    if [[ $(normalize_sysctl_value $'4096\t262144\t25165824') == "4096 262144 25165824" ]]; then
        printf '  PASS  sysctl 空格/制表符归一化\n'
    else
        printf '  FAIL  sysctl 多值格式归一化\n'
        failures=$((failures + 1))
    fi

    if [[ $(normalize_user_input $'  INSTALL   KERNEL \t') == "INSTALL KERNEL" ]]; then
        printf '  PASS  粘贴确认词的首尾/重复空格归一化\n'
    else
        printf '  FAIL  确认词空格归一化\n'
        failures=$((failures + 1))
    fi

    # BusyBox sort has no -V; version_ge must not depend on it.
    if version_ge "6.18.9" "5.10" && version_ge "6.6" "6.6" && version_ge "6.12.1-lts" "6.12" \
        && ! version_ge "5.4.0" "5.10" && ! version_ge "6.1" "6.12"; then
        printf '  PASS  纯 bash 版本比较（不依赖 sort -V）\n'
    else
        printf '  FAIL  version_ge 版本比较\n'
        failures=$((failures + 1))
    fi

    if decimal_ge "1048576" "65536" && ! decimal_ge "1024" "65536" \
        && ! decimal_ge "unlimited" "1024"; then
        printf '  PASS  大整数比较与非数字输入处理\n'
    else
        printf '  FAIL  decimal_ge 比较\n'
        failures=$((failures + 1))
    fi

    if normalize_protocol "HY2" && [[ $PROTOCOL == "hysteria" ]] \
        && normalize_protocol "4" && [[ $PROTOCOL == "vless-cdn" ]] \
        && normalize_protocol "5" && [[ $PROTOCOL == "ss2022-relay" ]] \
        && normalize_protocol "ss2022-relay" && [[ $PROTOCOL == "ss2022-relay" ]] \
        && normalize_protocol "0" && [[ $PROTOCOL == "general" ]] \
        && ! normalize_protocol "quic-madness"; then
        printf '  PASS  协议名/编号归一化（含新增 5 号中转档）与非法值拒绝\n'
    else
        printf '  FAIL  协议名归一化\n'
        failures=$((failures + 1))
    fi

    temp=$(make_temp) || { printf '  FAIL  无法创建临时文件\n'; failures=$((failures + 1)); }
    if [[ -n $temp ]]; then
        printf 'rc_parallel="NO"\n# existing comment\n' >"$temp"
        printf 'rc_ulimit="-n 111"\n' | write_managed_block "$temp" 0644
        printf 'rc_ulimit="-n 222"\n' | write_managed_block "$temp" 0644
        if [[ $(grep -c 'rc_ulimit' "$temp") == 1 ]] \
            && grep -q 'rc_ulimit="-n 222"' "$temp" \
            && grep -q 'rc_parallel="NO"' "$temp" \
            && [[ $(grep -c "$MARK_BEGIN" "$temp") == 1 ]] \
            && [[ $(confd_nofile_value "$temp") == 222 ]]; then
            printf '  PASS  rc.conf/conf.d 托管块可重复覆盖且不动用户原有内容\n'
        else
            printf '  FAIL  托管块写入\n'
            failures=$((failures + 1))
        fi
        rm -f -- "$temp"
    fi

    reset_self_test_state
    apply_protocol_profile
    ((failures == 0)) || return 1
    info "全部计算测试通过。"
}

on_signal() {
    printf '\n' >&2
    if ((APPLYING == 1)) && [[ -n $ACTIVE_BACKUP ]]; then
        rollback_on_failure "收到中断信号"
    fi
    exit 130
}

main_apply() {
    require_commands
    require_alpine
    ((DRY_RUN == 1)) || require_root

    if [[ -z $LOCAL_MBPS ]]; then
        if [[ -t 0 ]]; then LOCAL_MBPS=$(prompt_uint "本地宽带 Mbps" 1000 10 100000); else LOCAL_MBPS=1000; fi
    fi
    if [[ -z $SERVER_MBPS ]]; then
        if [[ -t 0 ]]; then SERVER_MBPS=$(prompt_uint "本机 VPS 标称带宽 Mbps" 1000 10 100000); else SERVER_MBPS=1000; fi
    fi
    is_uint "$LOCAL_MBPS" && ((LOCAL_MBPS >= 10 && LOCAL_MBPS <= 100000)) || die "本地带宽必须是 10-100000 Mbps"
    is_uint "$SERVER_MBPS" && ((SERVER_MBPS >= 10 && SERVER_MBPS <= 100000)) || die "VPS 带宽必须是 10-100000 Mbps"

    if [[ -z $IP_MODE ]]; then
        if [[ -t 0 ]]; then IP_MODE=$(prompt_ip_mode); else IP_MODE=dual; fi
    fi
    case $IP_MODE in
        4 | ipv4 | IPv4) IP_MODE=4 ;;
        6 | ipv6 | IPv6) IP_MODE=6 ;;
        dual | Dual | both | 46 | 64) IP_MODE=dual ;;
        *) die "IP 模式必须是 4、6 或 dual" ;;
    esac

    select_protocol
    detect_system
    collect_missing_packages
    maybe_install_packages
    discover_proxy_services
    configure_hysteria_port_hopping
    set_rtt_input
    set_relay_inputs
    calculate_tuning
    apply_protocol_profile
    plan_service_confd
    configure_initcwnd
    select_algorithms
    detect_bbr_generation
    build_kernel_advice
    prepare_settings
    filter_supported_settings
    print_plan
    print_config_preview

    if ((DRY_RUN == 1)); then
        info "试运行完成，未修改任何系统文件。"
        return 0
    fi
    confirm_apply || die "已取消应用"
    maybe_install_recommended_kernel
    if ((KERNEL_INSTALLED == 1)); then
        print_config_preview "安装内核后重新计算的最终 sysctl 配置"
    fi
    apply_configuration || return 1
    validate_result
    printf '\n%s完成。%s 恢复命令: bash %s --restore\n' "$C_GREEN" "$C_RESET" "$0"
    if ((${#CONFD_SERVICES[@]})); then
        printf '让代理服务用上新的 FD 上限: rc-service %s restart\n' "${CONFD_SERVICES[0]}"
    fi
    if ((KERNEL_INSTALLED == 1)); then
        printf '%s%s%s 已安装但尚未启用。请在方便时执行 reboot。\n' \
            "$C_YELLOW" "${INSTALLED_KERNEL_SOURCE:-新内核}" "$C_RESET"
        printf '重连后运行: uname -r; sysctl net.ipv4.tcp_congestion_control\n'
        printf '恢复命令只恢复本脚本的网络/FD 配置，不卸载已确认安装的内核或软件包。\n'
    fi
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    trap on_signal INT TERM
    parse_args "$@"

    case $ACTION in
        apply) main_apply ;;
        status) show_status ;;
        restore) require_commands; restore_latest ;;
        self-test) run_self_test ;;
        help) usage ;;
    esac
fi
