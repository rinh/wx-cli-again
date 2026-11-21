#!/bin/bash
# memscan.sh — 在运行中的微信进程内存里定位缺失分片的密钥（只读，不重启微信）。
#
# 前置：调用方需具备「开发者工具」授权（可免 sudo attach 微信）。

set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PID="${1:-$(pgrep -x WeChat | head -1)}"
MISSING="$HOME/.wx-cli/missing_dbs.txt"
OUT="$HOME/.wx-cli/scan_matches.json"

if [ -z "$PID" ] || ! ps -p "$PID" >/dev/null 2>&1; then
  echo "找不到微信进程" >&2
  exit 1
fi

mkdir -p "$HOME/.wx-cli"

wx key list --json 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
for m in d.get('missing',[]):
    if m.get('db'): print(m['db'])
" > "$MISSING"

n=$(wc -l < "$MISSING" | tr -d ' ')
echo "==> 微信 PID=${PID}，待查 ${n} 个数据库"

WX_MISSING_DBS="$MISSING" WX_SCAN_OUT="$OUT" \
lldb --batch -p "$PID" \
  -o "command script import ${HOOK_DIR}/memscan.py" \
  -o "script memscan.run()" \
  -o "process detach" \
  -o "quit" 2>&1 | grep -E "^\[memscan\]"

echo
if [ -s "$OUT" ]; then
  echo "==> 命中结果写入 all_keys.json"
  python3 - "$OUT" <<'PY'
import json, subprocess, sys
found = json.load(open(sys.argv[1]))
ok = 0
for db, key in found.items():
    r = subprocess.run(["wx", "key", "set", db, key],
                       capture_output=True, text=True)
    if r.returncode == 0:
        print("  ✓ %s" % db)
        ok += 1
    else:
        print("  ✗ %s  %s" % (db, (r.stderr or r.stdout).strip()[:120]))
print("写入 %d / %d" % (ok, len(found)))
PY
fi

echo
echo "=== wx doctor ==="
wx doctor 2>&1 | tail -10
