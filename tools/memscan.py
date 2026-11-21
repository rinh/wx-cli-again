"""LLDB 内存扫描器：在微信进程内存中定位缺失分片的 SQLCipher 4 密钥。

为什么需要它：
  wx-cli 自带的内存扫描只在 salt 邻接的几个固定偏移（前后 32/40/48 字节）
  上取 32 字节当候选 key，实测对微信 4.x 的分片命中率很低（26 个库一个没中）。
  这里改成：找到 salt 出现位置后，把该位置 ±256 字节范围内所有 32 字节窗口
  都当候选，逐个用 SQLCipher 4 的 page-1 HMAC 校验，只有能真正解密该库
  的 key 才会被接受。

用法（无需 sudo，需要调用方具备 Developer Tools 授权）：
  lldb --batch -p <PID> \
      -o "command script import /Users/rinh/.local/share/wx-hook/memscan.py" \
      -o "script memscan.run()" \
      -o "process detach" -o "quit"
"""

try:
    import lldb
except ImportError:  # 允许在 lldb 之外导入本模块做算法自测
    lldb = None

import os
import json
import hmac
import hashlib
import struct

PAGE_SZ = 4096
SALT_SZ = 16
RESERVE_SZ = 80
IV_SZ = 16
HMAC_SZ = 64

CHUNK = 8 * 1024 * 1024
OVERLAP = 1024
WINDOW = int(os.environ.get("WX_SCAN_WINDOW", "256"))

CONFIG = os.path.expanduser("~/.wx-cli/config.json")
OUT = os.environ.get("WX_SCAN_OUT", os.path.expanduser("~/.wx-cli/scan_matches.json"))


def _db_dir():
    with open(CONFIG) as f:
        return json.load(f)["db_dir"]


def verify_page1(page, key):
    """SQLCipher 4 page-1 HMAC-SHA512 校验（与 wx-cli 的 Rust 实现一致）。"""
    salt = page[:SALT_SZ]
    mac_salt = bytes(b ^ 0x3A for b in salt)
    mac_key = hashlib.pbkdf2_hmac("sha512", key, mac_salt, 2, 32)
    content_end = PAGE_SZ - RESERVE_SZ
    content = page[SALT_SZ:content_end]
    iv = page[content_end:content_end + IV_SZ]
    stored = page[content_end + IV_SZ:content_end + IV_SZ + HMAC_SZ]
    mac = hmac.new(mac_key, content + iv + struct.pack("<I", 1), hashlib.sha512)
    return mac.digest() == stored


def load_targets():
    """读取待补齐数据库的 page-1，返回 [(db_name, page1_bytes)]。"""
    db_dir = _db_dir()
    targets = []
    listing = os.environ.get("WX_MISSING_DBS")
    names = []
    if listing and os.path.exists(listing):
        names = [l.strip() for l in open(listing) if l.strip()]
    else:
        # 回退：用 wx key list --json 推断
        out = os.popen("wx key list --json 2>/dev/null").read()
        try:
            d = json.loads(out)
            names = [m["db"] for m in d.get("missing", []) if m.get("db")]
        except Exception:
            names = []

    for db in names:
        path = os.path.join(db_dir, db)
        try:
            with open(path, "rb") as f:
                page = f.read(PAGE_SZ)
        except Exception as e:
            print("[memscan] skip %s (%s)" % (db, e), flush=True)
            continue
        if len(page) < PAGE_SZ:
            continue
        targets.append((db, page))
    return targets


def run():
    try:
        _run()
    except Exception:
        import traceback
        print("[memscan] 异常:", flush=True)
        traceback.print_exc()


def _run():
    target = lldb.debugger.GetSelectedTarget()
    process = target.GetProcess()
    pid = process.GetProcessID()
    print("[memscan] target pid=%d" % pid, flush=True)

    targets = load_targets()
    if not targets:
        print("[memscan] 没有待查的数据库", flush=True)
        return
    print("[memscan] 待查 %d 个库，窗口 ±%d 字节" % (len(targets), WINDOW), flush=True)

    err = lldb.SBError()
    found = {}
    seen_cand = set()
    scanned = 0
    region_count = 0

    for mem in process.GetMemoryRegions():
        base = mem.GetRegionBase()
        end = mem.GetRegionEnd()
        size = end - base
        if not mem.IsReadable():
            continue
        if size <= 0 or size > 512 * 1024 * 1024:
            continue
        region_count += 1

        pos = 0
        while pos < size:
            n = min(CHUNK, size - pos)
            read_len = min(n + OVERLAP, size - pos)
            data = process.ReadMemory(base + pos, read_len, err)
            if not err.Success() or not data:
                err.Clear()
                break
            data = bytes(data)
            scanned += len(data)

            for db, page in targets:
                salt = page[:SALT_SZ]
                start = 0
                while True:
                    i = data.find(salt, start)
                    if i < 0 or i >= n:
                        break
                    start = i + 1
                    lo = max(0, i - WINDOW)
                    hi = min(len(data) - 32, i + SALT_SZ + WINDOW)
                    for s in range(lo, hi + 1):
                        cand = data[s:s + 32]
                        ck = cand.hex()
                        if ck in seen_cand:
                            continue
                        seen_cand.add(ck)
                        if verify_page1(page, cand):
                            found[db] = ck
                            print("[memscan] HIT %s <- %s" % (db, ck), flush=True)
                            break

            pos += n
        if region_count % 25 == 0:
            print("[memscan] 进度: %d 个区域, %.0f MB, 命中 %d"
                  % (region_count, scanned / 1024.0 / 1024.0, len(found)), flush=True)

    print("[memscan] 扫描了 %d 个内存区域，约 %.1f MB" %
          (region_count, scanned / 1024.0 / 1024.0), flush=True)
    print("[memscan] 命中 %d / %d" % (len(found), len(targets)), flush=True)

    with open(OUT, "w") as f:
        json.dump(found, f, indent=2)
    print("[memscan] 结果写入 %s" % OUT, flush=True)
