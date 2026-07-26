#!/bin/sh
# route.sh — 233boy Xray / sing-box 分流管理（direct / WARP / Shadowsocks）
#
# v2：纯 POSIX sh，兼容 Alpine Linux（busybox ash + OpenRC）与
#     Debian / Ubuntu / CentOS 等（dash|bash + systemd）。
#
# 仅依赖 jq。不创建备份、不自动回滚；写入前先用核心自带的
# `sing-box check` / `xray run -test` 验证候选配置，通过才覆盖。
#
# 与旧版的差异：
#   * 不再依赖 bash，也不再硬性依赖 systemctl/journalctl。
#   * 只接管本脚本自己的 tag（warp / shadowsocks）与对应规则，
#     233boy 原有的 block 出站、ban_bt / ban_geoip_cn / geoip:private
#     等规则会被保留，重复执行是幂等的。

set -eu
umask 077

# ---------------------------------------------------------------- 常量
DIRECT_TAG='direct'
WARP_TAG='warp'
SS_TAG='shadowsocks'
SS_METHOD='aes-128-gcm'
RULESET_BASE='https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set'
HTTP_CLIENT_TAG='route-manager-direct'

# ---------------------------------------------------------------- 全局变量
CORE=''
CONFIG=''
SERVICE=''
CORE_BIN=''
CONF_DIR=''
LOG_DIR=''
WARP_PORT=40000
NO_RESTART=0
INIT_SYS=''
USE_CONFDIR=0

ACTION='configure'
USE_WARP=0
USE_SS=0
SS_ADDRESS=''
SS_PORT=1
ORDER_TAGS=''

WORKDIR=''
INSTALL_TMP=''
STTY_SAVED=''
SS_PASSWORD_FILE=''
RULES_WARP=''
RULES_SS=''
ORDER_FILE=''
SEEN_FILE=''

REPLY_VALUE=''
SECRET_VALUE=''
RULE_ERROR=''
NORMALIZED_RULE=''
LAST_TEST_LOG=''
FORMAT=''

# ---------------------------------------------------------------- 基础工具
have() { command -v "$1" >/dev/null 2>&1; }

die() { printf '错误：%s\n' "$*" >&2; exit 1; }

warn() { printf '警告：%s\n' "$*" >&2; }

# 域名与 geosite 名都是 ASCII，这里刻意只转 A-Z，避免受 locale 影响
# shellcheck disable=SC2018,SC2019
lower() { printf '%s' "$1" | tr 'A-Z' 'a-z'; }

trim() { printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }

jbool() { if [ "$1" -eq 1 ]; then printf 'true'; else printf 'false'; fi; }

restore_stty() {
    if [ -n "$STTY_SAVED" ]; then
        stty "$STTY_SAVED" 2>/dev/null || true
        STTY_SAVED=''
    fi
}

cleanup() {
    restore_stty
    if [ -n "$INSTALL_TMP" ] && [ -f "$INSTALL_TMP" ]; then rm -f -- "$INSTALL_TMP"; fi
    if [ -n "$WORKDIR" ] && [ -d "$WORKDIR" ]; then rm -rf -- "$WORKDIR"; fi
}
trap cleanup EXIT
trap 'printf "\n已中断。\n" >&2; exit 130' INT
trap 'printf "\n已终止。\n" >&2; exit 143' TERM

usage() {
    cat <<'EOF'
用法：route.sh [选项]

交互管理 233boy Xray / sing-box 的 direct、WARP、Shadowsocks 分流。
兼容 Alpine(OpenRC) 与 Debian/Ubuntu/CentOS(systemd)。

选项：
  --core xray|singbox   跳过核心选择
  --config PATH         自定义配置路径（默认 /etc/<core>/config.json）
  --service NAME        自定义服务名（systemd unit 或 OpenRC init 脚本名）
  --bin PATH            自定义核心可执行文件
  --conf-dir PATH       片段配置目录（默认 /etc/<core>/conf）
  --warp-port PORT      WARP SOCKS5 端口（默认 40000）
  --no-restart          只写配置，不重启服务
  -h, --help            显示帮助
EOF
}

valid_port() {
    case "$1" in
        '' | *[!0-9]*) return 1 ;;
    esac
    [ "${#1}" -le 5 ] || return 1
    [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

# 去掉前导零，避免 test / jq 把 "080" 当成怪值
strip_zeros() {
    _v=$(printf '%s' "$1" | sed 's/^0*//')
    [ -n "$_v" ] || _v=0
    printf '%s' "$_v"
}

read_line() {
    REPLY_VALUE=''
    printf '%s' "$1"
    if ! IFS= read -r REPLY_VALUE; then
        printf '\n'
        die '无法读取输入（stdin 已结束）'
    fi
}

read_secret() {
    SECRET_VALUE=''
    printf '%s' "$1"
    if [ -t 0 ] && have stty; then
        STTY_SAVED=$(stty -g 2>/dev/null || printf '')
        if [ -n "$STTY_SAVED" ]; then
            stty -echo 2>/dev/null || STTY_SAVED=''
        fi
    fi
    if IFS= read -r SECRET_VALUE; then
        _ret=0
    else
        _ret=1
    fi
    restore_stty
    printf '\n'
    [ "$_ret" -eq 0 ] || die '无法读取密码'
}

# ---------------------------------------------------------------- 参数解析
while [ $# -gt 0 ]; do
    case "$1" in
        --core)
            [ $# -ge 2 ] || die '--core 缺少参数'
            CORE=$(lower "$2"); shift 2 ;;
        --config)
            [ $# -ge 2 ] || die '--config 缺少参数'
            CONFIG="$2"; shift 2 ;;
        --service)
            [ $# -ge 2 ] || die '--service 缺少参数'
            SERVICE="$2"; shift 2 ;;
        --bin)
            [ $# -ge 2 ] || die '--bin 缺少参数'
            CORE_BIN="$2"; shift 2 ;;
        --conf-dir)
            [ $# -ge 2 ] || die '--conf-dir 缺少参数'
            CONF_DIR="$2"; shift 2 ;;
        --warp-port)
            [ $# -ge 2 ] || die '--warp-port 缺少参数'
            valid_port "$2" || die 'WARP 端口必须在 1-65535 之间'
            WARP_PORT=$(strip_zeros "$2"); shift 2 ;;
        --no-restart)
            NO_RESTART=1; shift ;;
        -h | --help)
            usage; exit 0 ;;
        *)
            die "未知选项：$1" ;;
    esac
done

# 允许 `curl ... | sh` 方式运行时仍能交互；无控制终端时保持原 stdin
if [ ! -t 0 ] && (exec </dev/tty) 2>/dev/null; then
    exec </dev/tty
fi

# ---------------------------------------------------------------- 核心与路径
choose_core() {
    [ -n "$CORE" ] && return 0
    printf '选择要修改的核心：\n  1) Xray\n  2) sing-box\n'
    while :; do
        read_line '请输入 1 或 2: '
        case "$REPLY_VALUE" in
            1) CORE='xray'; return 0 ;;
            2) CORE='singbox'; return 0 ;;
            *) printf '输入无效。\n' ;;
        esac
    done
}

choose_core
case "$CORE" in
    xray)
        CORE='xray'
        CORE_NAME='xray'
        CONFIG="${CONFIG:-/etc/xray/config.json}"
        CONF_DIR="${CONF_DIR:-/etc/xray/conf}"
        SERVICE="${SERVICE:-xray}"
        ;;
    singbox | sing-box)
        CORE='singbox'
        CORE_NAME='sing-box'
        CONFIG="${CONFIG:-/etc/sing-box/config.json}"
        CONF_DIR="${CONF_DIR:-/etc/sing-box/conf}"
        SERVICE="${SERVICE:-sing-box}"
        ;;
    *) die '--core 只能是 xray 或 singbox' ;;
esac
LOG_DIR="/var/log/$CORE_NAME"

[ "$(id -u)" -eq 0 ] || die '请使用 root 运行'
[ -f "$CONFIG" ] || die "配置不存在：$CONFIG"

# ---------------------------------------------------------------- 依赖
install_jq() {
    if have apk; then
        apk add --no-cache jq
    elif have apt-get; then
        apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y jq
    elif have dnf; then
        dnf install -y jq
    elif have yum; then
        yum install -y jq
    elif have zypper; then
        zypper --non-interactive install jq
    elif have pacman; then
        pacman -Sy --noconfirm jq
    else
        die '无法识别包管理器，请手动安装 jq'
    fi
}

ensure_jq() {
    have jq && return 0
    printf '未找到 jq，脚本需要 jq 修改 JSON。\n'
    read_line '是否自动安装 jq？[Y/n]: '
    case "$REPLY_VALUE" in
        y | Y | yes | YES | '') ;;
        *) die '已取消' ;;
    esac
    install_jq || die 'jq 安装失败'
    have jq || die 'jq 安装失败'
}

find_core_bin() {
    if [ -n "$CORE_BIN" ]; then
        [ -x "$CORE_BIN" ] || die "不可执行：$CORE_BIN"
        return 0
    fi
    if [ "$CORE" = 'xray' ]; then
        _cands="/etc/xray/bin/xray /usr/local/bin/xray /usr/bin/xray"
    else
        _cands="/etc/sing-box/bin/sing-box /usr/local/bin/sing-box /usr/bin/sing-box"
    fi
    for _p in $_cands; do
        if [ -x "$_p" ]; then CORE_BIN="$_p"; return 0; fi
    done
    _p=$(command -v "$CORE_NAME" 2>/dev/null || printf '')
    if [ -n "$_p" ] && [ -x "$_p" ]; then CORE_BIN="$_p"; return 0; fi
    die "找不到 $CORE_NAME 可执行文件，可用 --bin 指定"
}

# ---------------------------------------------------------------- init 系统
detect_init() {
    if [ -d /run/systemd/system ] && have systemctl; then INIT_SYS='systemd'; return 0; fi
    if [ -d /run/openrc ] && have rc-service; then INIT_SYS='openrc'; return 0; fi
    if have rc-service && [ -f "/etc/init.d/$SERVICE" ]; then INIT_SYS='openrc'; return 0; fi
    if have systemctl; then INIT_SYS='systemd'; return 0; fi
    if have rc-service; then INIT_SYS='openrc'; return 0; fi
    if have service; then INIT_SYS='sysv'; return 0; fi
    INIT_SYS='none'
}

check_service_unit() {
    case "$INIT_SYS" in
        systemd)
            if ! systemctl cat "$SERVICE" >/dev/null 2>&1; then
                warn "未找到 systemd 服务 $SERVICE，可用 --service 指定"
            fi ;;
        openrc)
            if [ ! -f "/etc/init.d/$SERVICE" ]; then
                warn "未找到 OpenRC 服务 /etc/init.d/$SERVICE，可用 --service 指定"
            fi ;;
    esac
}

svc_restart() {
    case "$INIT_SYS" in
        systemd) systemctl restart "$SERVICE" ;;
        openrc)  rc-service "$SERVICE" restart ;;
        sysv)    service "$SERVICE" restart ;;
        *)       return 1 ;;
    esac
}

svc_active() {
    case "$INIT_SYS" in
        systemd) systemctl is-active --quiet "$SERVICE" ;;
        openrc)  rc-service "$SERVICE" status >/dev/null 2>&1 ;;
        sysv)    service "$SERVICE" status >/dev/null 2>&1 ;;
        *)       return 1 ;;
    esac
}

# 直接扫 /proc 判断核心进程是否存活。
# 不用 pgrep：busybox 的 pgrep 比对 argv[0]，procps 的比对进程名，两者结果不一致；
# 也不能用 pgrep -f "$CORE_BIN"，那会匹配到本脚本自己的命令行（--bin 参数里就有该路径）。
proc_alive() {
    [ -d /proc/1 ] || return 0
    _want=$(basename -- "$CORE_BIN")
    _want=$(printf '%.15s' "$_want")   # /proc/PID/comm 最长 15 字符
    for _d in /proc/[0-9]*; do
        [ -r "$_d/comm" ] || continue
        _comm=''
        IFS= read -r _comm <"$_d/comm" || continue
        [ "$_comm" = "$_want" ] && return 0
    done
    return 1
}

svc_logs() {
    case "$INIT_SYS" in
        systemd)
            systemctl --no-pager --full status "$SERVICE" 2>&1 | head -n 40 || true
            if have journalctl; then
                journalctl -u "$SERVICE" -n 50 --no-pager 2>&1 | tail -n 50 || true
            fi ;;
        openrc)
            rc-service "$SERVICE" status 2>&1 | head -n 20 || true
            for _f in "$LOG_DIR/error.log" "$LOG_DIR/access.log" /var/log/rc.log /var/log/messages; do
                if [ -f "$_f" ]; then
                    printf -- '--- %s ---\n' "$_f"
                    tail -n 30 "$_f" 2>/dev/null || true
                fi
            done ;;
        *)
            for _f in "$LOG_DIR/error.log" "$LOG_DIR/access.log"; do
                if [ -f "$_f" ]; then
                    printf -- '--- %s ---\n' "$_f"
                    tail -n 30 "$_f" 2>/dev/null || true
                fi
            done ;;
    esac
}

ensure_jq
jq empty "$CONFIG" >/dev/null 2>&1 || die "配置不是有效 JSON：$CONFIG"
find_core_bin
detect_init
if [ "$NO_RESTART" -eq 0 ]; then
    if [ "$INIT_SYS" = 'none' ]; then
        warn '未检测到 systemd / OpenRC，将只写入配置，请稍后手动重启核心'
        NO_RESTART=1
    else
        check_service_unit
    fi
fi

WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/route-manager.XXXXXXXX") || die '无法创建临时目录'
SS_PASSWORD_FILE="$WORKDIR/ss-password"
RULES_WARP="$WORKDIR/warp.rules"
RULES_SS="$WORKDIR/ss.rules"
ORDER_FILE="$WORKDIR/order.txt"
SEEN_FILE="$WORKDIR/seen.rules"
: >"$SS_PASSWORD_FILE"
chmod 600 "$SS_PASSWORD_FILE"
: >"$RULES_WARP"
: >"$RULES_SS"
: >"$ORDER_FILE"
: >"$SEEN_FILE"

# ---------------------------------------------------------------- 交互
choose_action() {
    printf '\n选择操作：\n'
    printf '  1) 配置/重建分流\n'
    printf '  2) 删除本脚本添加的分流（保留 233boy 原有规则）\n'
    while :; do
        read_line '请输入 1 或 2 [1]: '
        case "${REPLY_VALUE:-1}" in
            1) ACTION='configure'; return 0 ;;
            2) ACTION='delete'; USE_WARP=0; USE_SS=0; return 0 ;;
            *) printf '输入无效。\n' ;;
        esac
    done
}

choose_mode() {
    printf '\n选择出站模式（未命中始终 direct）：\n'
    printf '  1) 仅直连\n'
    printf '  2) direct + WARP（127.0.0.1:%s）\n' "$WARP_PORT"
    printf '  3) direct + Shadowsocks\n'
    printf '  4) direct + WARP + Shadowsocks\n'
    while :; do
        read_line '请输入 1-4 [1]: '
        case "${REPLY_VALUE:-1}" in
            1) USE_WARP=0; USE_SS=0; return 0 ;;
            2) USE_WARP=1; USE_SS=0; return 0 ;;
            3) USE_WARP=0; USE_SS=1; return 0 ;;
            4) USE_WARP=1; USE_SS=1; return 0 ;;
            *) printf '输入无效。\n' ;;
        esac
    done
}

prompt_ss() {
    printf '\nShadowsocks 加密固定为 %s。\n' "$SS_METHOD"
    while :; do
        read_line '服务器 IP/域名: '
        _v=$(trim "$REPLY_VALUE")
        case "$_v" in
            '['*']') _v=$(printf '%s' "$_v" | sed 's/^\[//; s/\]$//') ;;
        esac
        case "$_v" in
            '' | *[[:space:]]* | *://* | */*) printf '地址格式无效。\n'; continue ;;
        esac
        SS_ADDRESS="$_v"; break
    done
    while :; do
        read_line '服务器端口: '
        _v=$(trim "$REPLY_VALUE")
        if valid_port "$_v"; then SS_PORT=$(strip_zeros "$_v"); break; fi
        printf '端口必须在 1-65535。\n'
    done
    while :; do
        read_secret '密码（不回显）: '
        [ -n "$SECRET_VALUE" ] && break
        printf '密码不能为空。\n'
    done
    printf '%s' "$SECRET_VALUE" >"$SS_PASSWORD_FILE"
    SECRET_VALUE=''
}

choose_priority() {
    printf '\n规则重叠时优先使用：\n  1) WARP\n  2) Shadowsocks\n'
    while :; do
        read_line '请输入 1 或 2 [1]: '
        case "${REPLY_VALUE:-1}" in
            1) ORDER_TAGS="$WARP_TAG $SS_TAG"; return 0 ;;
            2) ORDER_TAGS="$SS_TAG $WARP_TAG"; return 0 ;;
            *) printf '输入无效。\n' ;;
        esac
    done
}

# ORDER_TAGS 只会是 warp / shadowsocks 这两个固定词，可安全按空白分割
write_order_file() {
    : >"$ORDER_FILE"
    for _t in $ORDER_TAGS; do
        printf '%s\n' "$_t" >>"$ORDER_FILE"
    done
}

normalize_rule() {
    RULE_ERROR=''
    NORMALIZED_RULE=''
    _val=$(trim "$1")
    [ -n "$_val" ] || { RULE_ERROR='空规则'; return 1; }
    case "$_val" in
        *[[:cntrl:]]*) RULE_ERROR='含控制字符'; return 1 ;;
    esac
    _low=$(lower "$_val")

    case "$_low" in
        geosite:*)
            _body=$(trim "${_val#*:}")
            case "$_body" in
                '' | *..*) RULE_ERROR='geosite 名称格式无效'; return 1 ;;
            esac
            if ! printf '%s' "$_body" | grep -qE '^[A-Za-z0-9_@.!+-]+$'; then
                RULE_ERROR='geosite 名称格式无效'; return 1
            fi
            NORMALIZED_RULE="geosite:$(lower "$_body")"
            return 0 ;;
    esac

    case "$_low" in
        domain_suffix:* | domain-suffix:* | domain:*) _val=${_val#*:} ;;
    esac
    _val=$(trim "$_val")
    case "$_val" in
        '*.'*) _val=${_val#*.} ;;
    esac
    _val=${_val#.}
    case "$_val" in
        '' | *[[:space:]]* | *://* | */* | *:* | .* | *. | *..* | -* | *-)
            RULE_ERROR='域名后缀格式无效'; return 1 ;;
    esac
    if ! printf '%s' "$_val" | grep -qE '^[A-Za-z0-9_.-]+$'; then
        RULE_ERROR='域名后缀格式无效'; return 1
    fi
    NORMALIZED_RULE="domain_suffix:$(lower "$_val")"
}

collect_rules() {
    _label="$1"
    _out="$2"
    _count=0
    : >"$_out"
    printf '\n输入走 %s 的规则，空行结束。\n' "$_label"
    printf '支持：geosite:netflix、domain_suffix:example.com、example.com\n'
    printf '同一行可用英文或中文逗号分隔。\n'
    while :; do
        read_line "$_label 规则: "
        _line=$(trim "$REPLY_VALUE")
        if [ -z "$_line" ]; then
            [ "$_count" -gt 0 ] && break
            printf '至少输入一条；不需要该出口请重新运行。\n'
            continue
        fi
        _line=$(printf '%s' "$_line" | sed 's/，/,/g')
        _rest="$_line"
        while [ -n "$_rest" ]; do
            case "$_rest" in
                *,*) _raw=${_rest%%,*}; _rest=${_rest#*,} ;;
                *)   _raw="$_rest";     _rest='' ;;
            esac
            _raw=$(trim "$_raw")
            [ -n "$_raw" ] || continue
            if ! normalize_rule "$_raw"; then
                printf '  跳过 %s：%s\n' "$_raw" "$RULE_ERROR"
                continue
            fi
            _rule="$NORMALIZED_RULE"
            if grep -qxF -e "$_rule" "$SEEN_FILE" 2>/dev/null; then
                printf '  跳过 %s：已被更高优先级出口占用或重复\n' "$_rule"
                continue
            fi
            printf '%s\n' "$_rule" >>"$_out"
            printf '%s\n' "$_rule" >>"$SEEN_FILE"
            _count=$((_count + 1))
            printf '  已添加：%s\n' "$_rule"
        done
    done
}

port_listening() {
    _hex=$(printf '%04X' "$1")
    for _f in /proc/net/tcp /proc/net/tcp6; do
        if [ -r "$_f" ] && grep -qiE "^[[:space:]]*[0-9]+:[[:space:]]+[0-9A-F]+:${_hex}[[:space:]]+[0-9A-F]+:[0-9A-F]+[[:space:]]+0A" "$_f"; then
            return 0
        fi
    done
    return 1
}

check_warp() {
    [ -r /proc/net/tcp ] || return 0
    if ! port_listening "$WARP_PORT"; then
        printf '警告：127.0.0.1:%s 当前没有监听，仍可继续生成配置。\n' "$WARP_PORT"
    fi
}

choose_action
if [ "$ACTION" = 'configure' ]; then
    choose_mode
    [ "$USE_SS" -eq 1 ] && prompt_ss
    [ "$USE_WARP" -eq 1 ] && check_warp
    if [ "$USE_WARP" -eq 1 ] && [ "$USE_SS" -eq 1 ]; then
        choose_priority
    elif [ "$USE_WARP" -eq 1 ]; then
        ORDER_TAGS="$WARP_TAG"
    elif [ "$USE_SS" -eq 1 ]; then
        ORDER_TAGS="$SS_TAG"
    fi
    for _tag in $ORDER_TAGS; do
        if [ "$_tag" = "$WARP_TAG" ]; then
            collect_rules 'WARP' "$RULES_WARP"
        else
            collect_rules 'Shadowsocks' "$RULES_SS"
        fi
    done
fi
write_order_file

# ---------------------------------------------------------------- 预览
current_summary() {
    if [ "$CORE" = 'xray' ]; then
        jq -r '[.outbounds[]? | "\(.tag // "?")(\(.protocol // "?"))"] | if length==0 then "<无>" else join(", ") end' "$CONFIG"
    else
        jq -r '[.outbounds[]? | "\(.tag // "?")(\(.type // "?"))"] | if length==0 then "<无>" else join(", ") end' "$CONFIG"
    fi
}

print_rules_of() {
    while IFS= read -r _r; do
        [ -n "$_r" ] || continue
        printf '    - %s\n' "$_r"
    done <"$1"
}

printf '\n========== 预览 ==========\n'
printf '核心：%s\n配置：%s\n' "$CORE_NAME" "$CONFIG"
printf '可执行：%s\n' "$CORE_BIN"
printf 'init：%s（服务名 %s）\n' "$INIT_SYS" "$SERVICE"
printf '原出站：%s\n' "$(current_summary)"
if [ "$ACTION" = 'delete' ]; then
    printf '操作：移除 %s / %s 出站及其分流规则\n' "$WARP_TAG" "$SS_TAG"
else
    printf '新增出站：'
    _any=0
    if [ "$USE_WARP" -eq 1 ]; then printf 'warp(127.0.0.1:%s)' "$WARP_PORT"; _any=1; fi
    if [ "$USE_SS" -eq 1 ]; then
        [ "$_any" -eq 1 ] && printf ', '
        printf 'shadowsocks(%s:%s, %s, 密码隐藏)' "$SS_ADDRESS" "$SS_PORT" "$SS_METHOD"
        _any=1
    fi
    [ "$_any" -eq 0 ] && printf '<无>'
    printf '\n规则优先级（高于 233boy 原有规则）：\n'
    if [ -z "$ORDER_TAGS" ]; then
        printf '  <无，全部直连>\n'
    else
        for _tag in $ORDER_TAGS; do
            printf '  %s:\n' "$_tag"
            if [ "$_tag" = "$WARP_TAG" ]; then print_rules_of "$RULES_WARP"; else print_rules_of "$RULES_SS"; fi
        done
    fi
fi
printf '未命中：direct\n'
printf '保留：233boy 原有 block 出站与 ban_bt / geoip:cn / geoip:private 等规则\n'
printf '不会备份，也不会失败回滚。\n'
printf '==========================\n'
read_line '确认执行请输入 YES: '
[ "$REPLY_VALUE" = 'YES' ] || { printf '已取消。\n'; exit 0; }

# ---------------------------------------------------------------- JSON 构建
rules_json() { jq -Rs 'split("\n") | map(select(length > 0))' <"$1"; }

ORDER_JSON=$(rules_json "$ORDER_FILE")
WARP_JSON=$(rules_json "$RULES_WARP")
SS_JSON=$(rules_json "$RULES_SS")

XRAY_PROGRAM='
def xr: map(if startswith("domain_suffix:") then "domain:" + ltrimstr("domain_suffix:") else . end);
# 注意：$list | index(.foo) 会把 .foo 作用在 $list 上，必须先把值绑到变量
def drop_tags($managed; $field): map(select((.[$field] // "") as $t | ($managed | index($t)) == null));

. as $root
| [$warp_tag, $ss_tag] as $managed
| ((if ($root.outbounds | type) == "array" then $root.outbounds else [] end)
   | drop_tags($managed; "tag")) as $kept_out
| (if ($kept_out | map(.tag // "") | index($direct_tag)) == null
   then [{tag: $direct_tag, protocol: "freedom"}] + $kept_out
   else $kept_out end) as $out0
| ($out0
   + (if $use_warp then
        [{tag: $warp_tag, protocol: "socks",
          settings: (if $schema == "modern"
                     then {address: "127.0.0.1", port: $warp_port}
                     else {servers: [{address: "127.0.0.1", port: $warp_port}]} end)}]
      else [] end)
   + (if $use_ss then
        [{tag: $ss_tag, protocol: "shadowsocks",
          settings: (if $schema == "modern"
                     then {address: $addr, port: $ss_port, method: $method, password: $password}
                     else {servers: [{address: $addr, port: $ss_port, method: $method, password: $password}]} end)}]
      else [] end)) as $new_out

| (if ($root.routing | type) == "object" then $root.routing else {} end) as $old_routing
| ((if ($old_routing.rules | type) == "array" then $old_routing.rules else [] end)
   | drop_tags($managed; "outboundTag")) as $kept_rules
| (if (($root.api | type) == "object" and ($root.api.tag | type) == "string" and ($root.api.tag | length) > 0)
   then $root.api.tag else null end) as $api_tag
| ($kept_rules | map(select($api_tag != null and .outboundTag == $api_tag))) as $api_rules
| ($kept_rules | map(select($api_tag == null or .outboundTag != $api_tag))) as $other_rules
| (if $api_tag != null and ($api_rules | length) == 0
   then [{type: "field", inboundTag: [$api_tag], outboundTag: $api_tag}]
   else $api_rules end) as $api_rules2
| ([$order[] as $tag
    | {type: "field",
       domain: ((if $tag == $warp_tag then $warp_rules else $ss_rules end) | xr),
       outboundTag: $tag}]) as $proxy_rules

| $root
| .outbounds = $new_out
| .routing = (($old_routing | del(.rules))
              + {domainStrategy: ($old_routing.domainStrategy // "IPIfNonMatch"),
                 rules: ($api_rules2 + $proxy_rules + $other_rules)})
'

SING_PROGRAM='
def site: map(select(startswith("geosite:")) | "geosite-" + ltrimstr("geosite:"));
def suffix: map(select(startswith("domain_suffix:")) | ltrimstr("domain_suffix:"));
# 注意：$list | index(.foo) 会把 .foo 作用在 $list 上，必须先把值绑到变量
def drop_tags($managed; $field): map(select((.[$field] // "") as $t | ($managed | index($t)) == null));

. as $root
| [$warp_tag, $ss_tag] as $managed
| ((if ($root.outbounds | type) == "array" then $root.outbounds else [] end)
   | drop_tags($managed; "tag")) as $kept_out
| (if ($kept_out | map(.tag // "") | index($direct_tag)) == null
   then [{tag: $direct_tag, type: "direct"}] + $kept_out
   else $kept_out end) as $out0
| ($out0
   + (if $use_warp then
        [{tag: $warp_tag, type: "socks", server: "127.0.0.1", server_port: $warp_port, version: "5"}]
      else [] end)
   + (if $use_ss then
        [{tag: $ss_tag, type: "shadowsocks", server: $addr, server_port: $ss_port,
          method: $method, password: $password}]
      else [] end)) as $new_out

| (if ($root.route | type) == "object" then $root.route else {} end) as $old_route
| ((if ($old_route.rules | type) == "array" then $old_route.rules else [] end)
   | drop_tags($managed; "outbound")) as $kept_rules
| ($kept_rules | map(select(.action == "sniff"))) as $sniff_rules
| ($kept_rules | map(select(.action != "sniff"))) as $rest_rules
| (if ($sniff_rules | length) == 0 then [{action: "sniff"}] else $sniff_rules end) as $sniff2
| ([$order[] as $tag
    | ((if $tag == $warp_tag then $warp_rules else $ss_rules end)) as $r
    | ((if ($r | site | length) > 0
        then [{rule_set: ($r | site), action: "route", outbound: $tag}] else [] end)
       + (if ($r | suffix | length) > 0
          then [{domain_suffix: ($r | suffix), action: "route", outbound: $tag}] else [] end))]
   | add // []) as $proxy_rules

| (($warp_rules + $ss_rules)
   | map(select(startswith("geosite:")) | ltrimstr("geosite:")) | unique) as $names
| ($names | map({tag: ("geosite-" + .), type: "remote", format: "binary",
                 url: ($base + "/geosite-" + . + ".srs"), update_interval: "7d"})
          | map(if $style == "detour" then . + {download_detour: $direct_tag} else . end)) as $our_sets
| ($our_sets | map(.tag)) as $our_tags
| ((if ($old_route.rule_set | type) == "array" then $old_route.rule_set else [] end)
   | map(select((((.url // "") | type) == "string") and (((.url // "") | startswith($base)) | not)))
   | drop_tags($our_tags; "tag")) as $kept_sets
| ($kept_sets + $our_sets) as $rule_sets

| $root
| .outbounds = $new_out
| .route = (($old_route | del(.rules, .rule_set, .geoip, .geosite))
            + {rules: ($sniff2 + $proxy_rules + $rest_rules), final: $direct_tag}
            + (if ($rule_sets | length) > 0 then {rule_set: $rule_sets} else {} end))
| (if $style == "httpclient" and ($rule_sets | length) > 0 then
     .http_clients = (((if (.http_clients | type) == "array" then .http_clients else [] end)
                       | map(select(.tag != $client))) + [{tag: $client, detour: $direct_tag}])
     | .route.default_http_client = $client
   else
     (if (.http_clients | type) == "array"
      then .http_clients |= map(select(.tag != $client)) else . end)
     | (if (.route.default_http_client // "") == $client
        then .route |= del(.default_http_client) else . end)
   end)
| (if (.http_clients | type) == "array" and (.http_clients | length) == 0
   then del(.http_clients) else . end)
| (if ($rule_sets | length) > 0 then
     .experimental = (if (.experimental | type) == "object" then .experimental else {} end)
     | .experimental.cache_file = (if (.experimental.cache_file | type) == "object"
                                   then .experimental.cache_file else {} end)
     | .experimental.cache_file.enabled = true
   else . end)
'

make_xray_candidate() {
    jq --arg schema "$1" \
       --arg direct_tag "$DIRECT_TAG" --arg warp_tag "$WARP_TAG" --arg ss_tag "$SS_TAG" \
       --argjson use_warp "$(jbool "$USE_WARP")" --argjson warp_port "$WARP_PORT" \
       --argjson use_ss "$(jbool "$USE_SS")" --arg addr "$SS_ADDRESS" \
       --argjson ss_port "$SS_PORT" --arg method "$SS_METHOD" \
       --rawfile password "$SS_PASSWORD_FILE" \
       --argjson order "$ORDER_JSON" --argjson warp_rules "$WARP_JSON" --argjson ss_rules "$SS_JSON" \
       "$XRAY_PROGRAM" "$CONFIG" >"$2"
}

make_sing_candidate() {
    jq --arg style "$1" --arg base "$RULESET_BASE" --arg client "$HTTP_CLIENT_TAG" \
       --arg direct_tag "$DIRECT_TAG" --arg warp_tag "$WARP_TAG" --arg ss_tag "$SS_TAG" \
       --argjson use_warp "$(jbool "$USE_WARP")" --argjson warp_port "$WARP_PORT" \
       --argjson use_ss "$(jbool "$USE_SS")" --arg addr "$SS_ADDRESS" \
       --argjson ss_port "$SS_PORT" --arg method "$SS_METHOD" \
       --rawfile password "$SS_PASSWORD_FILE" \
       --argjson order "$ORDER_JSON" --argjson warp_rules "$WARP_JSON" --argjson ss_rules "$SS_JSON" \
       "$SING_PROGRAM" "$CONFIG" >"$2"
}

# ---------------------------------------------------------------- 配置校验
run_xray_test() {
    _file="$1"
    if [ "$USE_CONFDIR" -eq 1 ]; then
        if LAST_TEST_LOG=$("$CORE_BIN" run -test -c "$_file" -confdir "$CONF_DIR" 2>&1); then return 0; fi
        return 1
    fi
    if LAST_TEST_LOG=$("$CORE_BIN" run -test -c "$_file" 2>&1); then return 0; fi
    _first="$LAST_TEST_LOG"
    if LAST_TEST_LOG=$("$CORE_BIN" -test -config "$_file" 2>&1); then return 0; fi
    LAST_TEST_LOG="$_first
---
$LAST_TEST_LOG"
    return 1
}

run_sing_test() {
    _file="$1"
    if [ "$USE_CONFDIR" -eq 1 ]; then
        if LAST_TEST_LOG=$("$CORE_BIN" check -c "$_file" -C "$CONF_DIR" 2>&1); then return 0; fi
        return 1
    fi
    if LAST_TEST_LOG=$("$CORE_BIN" check -c "$_file" 2>&1); then return 0; fi
    return 1
}

# 先确认「当前配置 + conf 片段目录」本身能通过校验，
# 能通过才在候选校验时带上 conf 目录（与服务实际启动参数一致）。
probe_confdir() {
    [ -d "$CONF_DIR" ] || return 0
    USE_CONFDIR=1
    if [ "$CORE" = 'xray' ]; then
        run_xray_test "$CONFIG" >/dev/null 2>&1 || USE_CONFDIR=0
    else
        run_sing_test "$CONFIG" >/dev/null 2>&1 || USE_CONFDIR=0
    fi
    if [ "$USE_CONFDIR" -eq 0 ]; then
        warn "带 $CONF_DIR 校验当前配置未通过，候选配置将单独校验"
    fi
}
probe_confdir

# 没有 geosite 规则时不会生成远程 rule-set，两个 sing-box 候选完全相同；
# 没有代理出站时两个 Xray 候选也完全相同。此时格式标签只是噪音。
HAS_GEOSITE=0
if grep -q '^geosite:' "$RULES_WARP" "$RULES_SS" 2>/dev/null; then HAS_GEOSITE=1; fi
if [ "$HAS_GEOSITE" -eq 1 ]; then
    SB_FMT_A='http_clients 格式（sing-box 1.14+）'
    SB_FMT_B='rule_set download_detour 格式'
else
    SB_FMT_A='未使用远程 rule-set'
    SB_FMT_B="$SB_FMT_A"
fi
if [ "$USE_WARP" -eq 1 ] || [ "$USE_SS" -eq 1 ]; then
    XR_FMT_A='servers 数组格式'
    XR_FMT_B='扁平 settings 格式'
else
    XR_FMT_A='无代理出站'
    XR_FMT_B="$XR_FMT_A"
fi

SELECTED=''
if [ "$CORE" = 'xray' ]; then
    # servers 数组是 Xray 一直支持的写法，优先；扁平 settings 只作为兜底
    make_xray_candidate legacy "$WORKDIR/xray-legacy.json"
    make_xray_candidate modern "$WORKDIR/xray-modern.json"
    printf '正在检查 Xray 配置……\n'
    if run_xray_test "$WORKDIR/xray-legacy.json"; then
        SELECTED="$WORKDIR/xray-legacy.json"; FORMAT="$XR_FMT_A"
    else
        LEGACY_LOG="$LAST_TEST_LOG"
        if run_xray_test "$WORKDIR/xray-modern.json"; then
            SELECTED="$WORKDIR/xray-modern.json"; FORMAT="$XR_FMT_B"
        else
            printf '[servers]\n%s\n\n[flat]\n%s\n' "$LEGACY_LOG" "$LAST_TEST_LOG" >&2
            die '两种 Xray 格式都检查失败，原配置未修改'
        fi
    fi
else
    make_sing_candidate httpclient "$WORKDIR/sing-httpclient.json"
    make_sing_candidate detour "$WORKDIR/sing-detour.json"
    printf '正在检查 sing-box 配置……\n'
    if run_sing_test "$WORKDIR/sing-httpclient.json"; then
        SELECTED="$WORKDIR/sing-httpclient.json"; FORMAT="$SB_FMT_A"
    else
        HTTPCLIENT_LOG="$LAST_TEST_LOG"
        if run_sing_test "$WORKDIR/sing-detour.json"; then
            SELECTED="$WORKDIR/sing-detour.json"; FORMAT="$SB_FMT_B"
        else
            printf '[http_clients]\n%s\n\n[download_detour]\n%s\n' "$HTTPCLIENT_LOG" "$LAST_TEST_LOG" >&2
            die '两种 sing-box rule-set 格式都检查失败，原配置未修改'
        fi
    fi
fi
printf '配置检查通过：%s\n' "$FORMAT"

# ---------------------------------------------------------------- 写入
atomic_replace() {
    _dir=$(dirname -- "$CONFIG")
    _base=$(basename -- "$CONFIG")
    INSTALL_TMP=$(mktemp "$_dir/.$_base.route.XXXXXXXX") || die '无法创建临时配置'
    cp -p "$CONFIG" "$INSTALL_TMP" || die '无法复制原配置权限'
    cat "$SELECTED" >"$INSTALL_TMP" || die '无法写入配置'
    mv -f "$INSTALL_TMP" "$CONFIG" || die '无法替换配置'
    INSTALL_TMP=''
}
atomic_replace

if [ "$NO_RESTART" -eq 1 ]; then
    printf '写入完成（未重启）：%s\n' "$CONFIG"
    printf '请手动重启：'
    case "$INIT_SYS" in
        systemd) printf 'systemctl restart %s\n' "$SERVICE" ;;
        openrc)  printf 'rc-service %s restart\n' "$SERVICE" ;;
        sysv)    printf 'service %s restart\n' "$SERVICE" ;;
        *)       printf '%s\n' "$CORE_NAME" ;;
    esac
    exit 0
fi

if svc_restart; then
    sleep 2
    if svc_active && proc_alive; then
        printf '完成：%s 已重启，状态正常。\n配置：%s\n' "$SERVICE" "$CONFIG"
        exit 0
    fi
fi

printf '服务未正常运行；按要求未自动回滚。\n' >&2
svc_logs >&2 || true
exit 1
