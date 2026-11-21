#!/bin/bash
# hook-attach.sh — 在「运行中」的微信进程上挂 LLDB hook，捕捉新打开数据库的密钥。
#
# 与 capture-keys.sh 的区别：不重启微信，直接 attach 到当前进程。
# 因为调用方已具备开发者工具授权，attach 无需 sudo。
#
# 用法：bash ~/.local/share/wx-hook/hook-attach.sh [窗口秒数]
#
# 窗口期内请在微信里依次触发：
#   1) 往回翻某个老会话的历史消息   → message_0/1/2.db
#   2) 打开「订阅号 / 公众号」会话  → biz_message_*.db
#   3) 用微信顶部搜索框搜一个词     → message_fts.db
#   4) 点开聊天里的一张图片          → media_0.db
#   5) 随便点开几个会话              → session.db / contact.db 等

set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PID="$(pgrep -x WeChat | head -1)"
WINDOW="${1:-${WX_HOOK_SECONDS:-300}}"
KEYS="${WX_HOOK_KEYS:-$HOME/.wx-cli/hook_keys.txt}"
LOG="${WX_HOOK_LOG:-$HOME/.wx-cli/hook_attach.log}"

if [ -z "$PID" ] || ! ps -p "$PID" >/dev/null 2>&1; then
  echo "找不到微信进程" >&2
  exit 1
fi

mkdir -p "$(dirname "$KEYS")"
: > "$KEYS"

echo "==> attach 微信 PID=${PID}，hook 窗口 ${WINDOW}s"
echo "==> 请在窗口内触发：翻历史消息 / 打开公众号 / 搜索 / 打开图片"

WX_HOOK_SECONDS="$WINDOW" WX_HOOK_KEYS="$KEYS" \
lldb --batch -p "$PID" \
  -o "command script import ${HOOK_DIR}/wxhook.py" \
  -o "script wxhook.setup()" \
  -o "process continue" \
  -o "quit" >"$LOG" 2>&1 &
LLDB_PID=$!

( sleep $((WINDOW + 90)); kill -9 "$LLDB_PID" 2>/dev/null ) &
WATCH_PID=$!

wait "$LLDB_PID" 2>/dev/null
kill "$WATCH_PID" 2>/dev/null
for p in $(pgrep -x WeChat); do kill -CONT "$p" 2>/dev/null || true; done

echo
echo "==> hook 日志:"
grep -E "wx-hook" "$LOG" 2>/dev/null | grep -v "pending" | head -40
echo
echo "==> 捕获 $(sort -u "$KEYS" 2>/dev/null | grep -c . ) 个 key"
sort -u "$KEYS" 2>/dev/null | sed 's/^/    /'
echo
echo "下一步: bash ${HOOK_DIR}/map-keys.sh"
