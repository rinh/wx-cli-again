"""LLDB hook: capture 32-byte AES keys passed to CommonCrypto CCCryptorCreate*.

Usage (launch mode — breakpoints are set BEFORE the process starts, so every
DB open is captured, including ones opened during app startup):

    lldb --batch \
        -f /Applications/WeChat.app/Contents/MacOS/WeChat \
        -o "command script import /Users/rinh/.local/share/wx-hook/wxhook.py" \
        -o "process launch --stop-at-entry" \
        -o "script wxhook.setup()" \
        -o "process continue" \
        -o "process detach" \
        -o "quit"

Launch mode needs no root: the task port is inherited from fork/exec, so
task_for_pid (and TCC "Developer Tools") are not involved.
"""

import lldb
import threading
import time
import os

OUT = os.environ.get("WX_HOOK_KEYS", "/Users/rinh/.wx-cli/hook_keys.txt")
DONE = os.environ.get("WX_HOOK_DONE", "/Users/rinh/.wx-cli/hook_done")
SECONDS = int(os.environ.get("WX_HOOK_SECONDS", "180"))

captured = set()
_debugger = None

# Symbols that receive an AES key. WeChat's SQLCipher layer goes through
# CommonCrypto, so a CCCryptorCreate with keyLength==32 is a DB key.
SYMBOLS = [
    "CCCryptorCreate",
    "CCCrypt",
    "CCCryptorCreateWithMode",
    "CCCryptorCreateFromData",
]


def _save(hx):
    try:
        with open(OUT, "a") as f:
            f.write(hx + "\n")
    except Exception:
        pass


def _try_read(process, key_ptr, key_len):
    if key_len != 32 or not key_ptr:
        return
    err = lldb.SBError()
    data = process.ReadMemory(key_ptr, 32, err)
    if not err.Success() or not data or len(data) != 32:
        return
    hx = bytes(data).hex()
    if hx in captured:
        return
    captured.add(hx)
    print("[wx-hook] key " + hx, flush=True)
    _save(hx)


def on_cc(frame, bp_loc, _dict):
    try:
        process = frame.GetThread().GetProcess()
        arch = process.GetTarget().GetTriple()
        if "arm64" in arch or "aarch64" in arch:
            # CCCryptorCreate(op, alg, options, key, keyLength, iv, cryptorRef)
            #   -> x3=key, x4=keyLength
            # CCCryptorCreateWithMode(op, mode, alg, padding, iv, key, keyLength, ...)
            #   -> x5=key, x6=keyLength
            _try_read(process,
                      frame.FindRegister("x3").GetValueAsUnsigned(),
                      frame.FindRegister("x4").GetValueAsUnsigned())
            _try_read(process,
                      frame.FindRegister("x5").GetValueAsUnsigned(),
                      frame.FindRegister("x6").GetValueAsUnsigned())
        else:
            _try_read(process,
                      frame.FindRegister("rcx").GetValueAsUnsigned(),
                      frame.FindRegister("r8").GetValueAsUnsigned())
            _try_read(process,
                      frame.FindRegister("r9").GetValueAsUnsigned(), 32)
    except Exception as e:
        print("[wx-hook] err " + str(e), flush=True)
    return False


def _finish():
    time.sleep(SECONDS)
    try:
        if _debugger is not None:
            _debugger.HandleCommand("process detach")
            _debugger.HandleCommand("quit")
    except Exception as e:
        print("[wx-hook] detach err " + str(e), flush=True)
    try:
        with open(DONE, "w") as f:
            f.write("ok\n")
    except Exception:
        pass


def setup():
    """Called after `process launch --stop-at-entry`: the main executable is
    loaded but libSystem (which holds CommonCrypto) is not yet.

    So we must NOT skip symbols that have 0 locations: `BreakpointCreateByName`
    returns a *pending* breakpoint that lldb resolves automatically once the
    module loads, and the script callback survives that resolution.
    """
    global _debugger
    _debugger = _debugger or lldb.debugger

    target = _debugger.GetSelectedTarget()
    armed = 0
    for name in SYMBOLS:
        bp = target.BreakpointCreateByName(name)
        bp.SetScriptCallbackFunction(__name__ + ".on_cc")
        bp.SetAutoContinue(True)
        armed += 1
        print("[wx-hook] pending " + name, flush=True)

    try:
        open(OUT, "w").close()
    except Exception:
        pass
    try:
        import os
        if os.path.exists(DONE):
            os.remove(DONE)
    except Exception:
        pass

    print("[wx-hook] armed=%d pending breakpoints, capturing for %ds"
          % (armed, SECONDS), flush=True)
    t = threading.Thread(target=_finish, daemon=True)
    t.start()
    return armed


def __lldb_init_module(debugger, _internal_dict):
    global _debugger
    _debugger = debugger
