"""诊断：统计每个 DB 的 salt 在微信内存中出现多少次。

区分两种失败模式：
  (a) salt 出现 0 次  → salt 不驻留内存，邻接法从原理上就不适用
  (b) salt 出现 N 次但没命中 key → key 不在 salt 邻域，需要别的定位方式

对照组：contact/contact.db 是已知有 key 的库。
"""

import os
import json

try:
    import lldb
except ImportError:
    lldb = None

CHUNK = 8 * 1024 * 1024
OVERLAP = 64

CONFIG = os.path.expanduser("~/.wx-cli/config.json")


def _db_dir():
    with open(CONFIG) as f:
        return json.load(f)["db_dir"]


def run():
    target = lldb.debugger.GetSelectedTarget()
    process = target.GetProcess()
    db_dir = _db_dir()

    names = []
    out = os.popen("wx key list --json 2>/dev/null").read()
    try:
        d = json.loads(out)
        names = [m["db"] for m in d.get("missing", []) if m.get("db")]
        names.append("contact/contact.db")  # 对照组
    except Exception:
        pass

    salts = {}
    for db in names:
        try:
            with open(os.path.join(db_dir, db), "rb") as f:
                salts[db] = f.read(16)
        except Exception:
            pass

    print("[diag] 统计 %d 个 salt 在内存中的出现次数" % len(salts), flush=True)
    counts = {db: 0 for db in salts}
    err = lldb.SBError()

    for mem in process.GetMemoryRegions():
        base = mem.GetRegionBase()
        end = mem.GetRegionEnd()
        size = end - base
        if not mem.IsReadable() or size <= 0 or size > 512 * 1024 * 1024:
            continue
        pos = 0
        while pos < size:
            n = min(CHUNK, size - pos)
            read_len = min(n + OVERLAP, size - pos)
            data = process.ReadMemory(base + pos, read_len, err)
            if not err.Success() or not data:
                err.Clear()
                break
            data = bytes(data)
            for db, salt in salts.items():
                start = 0
                while True:
                    i = data.find(salt, start)
                    if i < 0 or i >= n:
                        break
                    counts[db] += 1
                    start = i + 1
            pos += n

    print("[diag] 结果（对照组 contact/contact.db 已知有 key）:", flush=True)
    for db in names:
        if db in counts:
            print("[diag]   %-32s salt 出现 %d 次" % (db, counts[db]), flush=True)
