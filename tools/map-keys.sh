#!/bin/bash
# map-keys.sh — 把 capture-keys.sh 抓到的裸 key 匹配回具体数据库并写入 all_keys.json。
#
# 匹配靠 wx key set 自带的校验：它会用候选 key 实际尝试解密该数据库，
# 解不开就报错且不写盘。所以可以放心遍历尝试，命中即写入。
#
# 注意：兼容 macOS 自带的 bash 3.2（无 mapfile）。

set -uo pipefail

KEYS="${WX_HOOK_KEYS:-$HOME/.wx-cli/hook_keys.txt}"

if [ ! -s "$KEYS" ]; then
  echo "没有可用的 key 文件: $KEYS" >&2
  echo "先运行 capture-keys.sh" >&2
  exit 1
fi

CANDIDATES="$HOME/.wx-cli/.cand_keys"
MISSING="$HOME/.wx-cli/.missing_dbs"

sort -u "$KEYS" | grep -E '^[0-9a-f]{64}$' > "$CANDIDATES"
n_cand=$(wc -l < "$CANDIDATES" | tr -d ' ')
echo "候选 key: $n_cand 个"

wx key list --json 2>/dev/null | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    sys.exit(0)
for m in d.get('missing',[]):
    db=m.get('db','')
    if db: print(db)
" > "$MISSING"

n_missing=$(wc -l < "$MISSING" | tr -d ' ')
if [ "$n_missing" -eq 0 ]; then
  echo "没有缺失的数据库，无需匹配"
  exit 0
fi
echo "待匹配数据库: $n_missing 个"
echo

matched=0
while IFS= read -r db; do
  [ -z "$db" ] && continue
  hit=""
  while IFS= read -r k; do
    [ -z "$k" ] && continue
    if wx key set "$db" "$k" >/dev/null 2>&1; then
      hit="$k"
      break
    fi
  done < "$CANDIDATES"

  if [ -n "$hit" ]; then
    echo "  ✓ $db  <-  ${hit:0:12}…"
    matched=$((matched + 1))
  else
    echo "  ✗ $db  (未命中)"
  fi
done < "$MISSING"

echo
echo "新增匹配: $matched / $n_missing"
echo
echo "=== wx doctor ==="
wx doctor 2>&1
