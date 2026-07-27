#!/usr/bin/env bash
set -Eeuo pipefail

APP="/opt/aggregator"
REPO="https://github.com/wzdnzd/aggregator.git"

die() {
    echo "错误：$*" >&2
    exit 1
}

[ "$(id -u)" -eq 0 ] || die "请使用 root 运行"

read -rp "Gist 地址或 用户名/Gist-ID：" GIST_INPUT </dev/tty
GIST_INPUT="${GIST_INPUT%/}"

if [[ "$GIST_INPUT" =~ ^https://gist\.github\.com/([^/]+)/([0-9a-fA-F]+)$ ]]; then
    GIST_LINK="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
elif [[ "$GIST_INPUT" =~ ^([^/]+)/([0-9a-fA-F]+)$ ]]; then
    GIST_LINK="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
else
    die "Gist 格式错误"
fi

read -rsp "GitHub Token（输入不显示）：" GIST_PAT </dev/tty
echo >&2
[ -n "$GIST_PAT" ] || die "Token 不能为空"

GIST_OWNER="${GIST_LINK%%/*}"
GIST_ID="${GIST_LINK#*/}"

echo "[1/5] 安装必要组件……"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
    ca-certificates \
    cron \
    git \
    python3 \
    python3-venv \
    util-linux >/dev/null

[ ! -e "$APP" ] || die "$APP 已存在，请在全新机器运行"

echo "[2/5] 下载并安装 Aggregator……"
git clone --quiet --depth 1 "$REPO" "$APP"
python3 -m venv "$APP/venv"

PIP_DISABLE_PIP_VERSION_CHECK=1 \
"$APP/venv/bin/python" -m pip install \
    --quiet \
    --no-cache-dir \
    -r "$APP/requirements.txt"

umask 077
printf 'GIST_LINK=%q
GIST_PAT=%q
' \
    "$GIST_LINK" "$GIST_PAT" > "$APP/.env"
chmod 600 "$APP/.env"

echo "[3/5] 创建自动采集脚本……"

cat > "$APP/run.sh" <<'RUNNER'
#!/usr/bin/env bash
set -Eeuo pipefail

APP="/opt/aggregator"
MODE="${1:-refresh}"
RUN_LOG="$APP/last-run.log"

cd "$APP"

set -a
source "$APP/.env"
set +a

case "$MODE" in
    full)
        echo "$(date '+%F %T') 开始扫描最新15页"
        rm -f "$APP/data/domains.txt"
        ARGS=(-o -p 15)
        ;;
    refresh)
        echo "$(date '+%F %T') 开始刷新已有订阅"
        ARGS=(-r -p 5)
        ;;
    *)
        echo "模式只能是 full 或 refresh"
        exit 1
        ;;
esac

mkdir -p "$APP/data"
rm -f "$APP/data/quanx.conf"
: > "$RUN_LOG"

if ! "$APP/venv/bin/python" subscribe/collect.py \
    -g "$GIST_LINK" \
    -k "$GIST_PAT" \
    -t quanx \
    "${ARGS[@]}" \
    -n 16 \
    -i > "$RUN_LOG" 2>&1
then
    echo "采集失败，最后日志："
    tail -n 40 "$RUN_LOG"
    exit 1
fi

if [ ! -s "$APP/data/quanx.conf" ]; then
    echo "没有生成可用节点，Gist 保留原内容"
    tail -n 40 "$RUN_LOG"
    exit 1
fi

"$APP/venv/bin/python" <<'PY'
import os
from pathlib import Path
import requests

path = Path("/opt/aggregator/data/quanx.conf")
content = path.read_text(encoding="utf-8")
gist_id = os.environ["GIST_LINK"].split("/", 1)[1]

response = requests.patch(
    f"https://api.github.com/gists/{gist_id}",
    headers={
        "Authorization": f"Bearer {os.environ['GIST_PAT']}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2026-03-10",
    },
    json={"files": {"quanx.conf": {"content": content}}},
    timeout=30,
)

if response.status_code != 200:
    raise SystemExit(
        f"Gist 上传失败：HTTP {response.status_code} "
        f"{response.text[:200]}"
    )

count = sum(1 for line in content.splitlines() if line.strip())
print(f"上传成功，有效节点：{count}")
PY
RUNNER

chmod 700 "$APP/run.sh"

echo "[4/5] 首次扫描15页，可能需要几分钟……"

if ! "$APP/run.sh" full; then
    die "首次采集失败，请查看 $APP/last-run.log"
fi

echo "[5/5] 设置每6小时自动刷新……"

systemctl enable --now cron >/dev/null

{
    crontab -l 2>/dev/null |
        grep -v "$APP/run.sh" || true

    echo "17 0 * * * /usr/bin/flock -n /run/lock/aggregator-qx.lock $APP/run.sh full >> $APP/cron.log 2>&1"
    echo "17 6,12,18 * * * /usr/bin/flock -n /run/lock/aggregator-qx.lock $APP/run.sh refresh >> $APP/cron.log 2>&1"
} | crontab -

touch "$APP/cron.log"
chmod 600 "$APP/cron.log"

unset GIST_PAT

echo
echo "安装完成"
echo
echo "Quantumult X 订阅链接："
echo "https://gist.githubusercontent.com/$GIST_OWNER/$GIST_ID/raw/quanx.conf"
echo
echo "刷新计划："
echo "  00:17 扫描最新15页并刷新"
echo "  06:17、12:17、18:17 刷新已有订阅"
echo
echo "查看日志：tail -f $APP/cron.log"
