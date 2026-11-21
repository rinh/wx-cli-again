# macOS (Apple Silicon) 安装与密钥提取实战手册

> 实测环境：macOS 26.6.2 (darwin 25.6.0) · Apple M3 Max · arm64 · 微信 4.x (官方 Hardened Runtime 签名)
>
> 目标：从零安装 `wx-cli`，并让 `wx sessions / history / search / export` 真正能读到本地微信数据。
>
> 本文记录的是**实测过程**，包含失败的路线和被证伪的假设。结论先行：
>
> - Apple Silicon 上必须交叉编译出 **arm64 原生二进制**，x86_64 版本在取钥阶段会失效。
> - 官方 `sudo wx key extract` 在微信已经运行时**抓不全**分片密钥（实测 8/26）。
> - 微信 4.x 的数据库 salt **不驻留内存**，内存扫描路线（salt 邻接）原理上不成立。
> - 唯一可靠路径是 **LLDB hook `CCCryptorCreate`**，且必须 attach 到一个
>   **在 hook 挂载之后才打开数据库**的微信进程；配合「开发者工具」授权可以**免 sudo**。

---

## 目录

1. [环境基线](#1-环境基线)
2. [安装：为什么必须源码构建 + 为什么必须 arm64](#2-安装为什么必须源码构建--为什么必须-arm64)
3. [密钥提取：完整攻坚过程](#3-密钥提取完整攻坚过程)
4. [验证](#4-验证)
5. [工具脚本清单](#5-工具脚本清单)
6. [踩坑清单](#6-踩坑清单)
7. [结论与后续](#7-结论与后续)

---

## 1. 环境基线

```bash
uname -m                      # arm64
sysctl -n machdep.cpu.brand_string   # Apple M3 Max
rustc -vV | grep host         # x86_64-apple-darwin  ← 关键问题
xcode-select -p               # /Applications/Xcode.app/Contents/Developer
codesign -dvv /Applications/WeChat.app | grep flags
# CodeDirectory v=20500 size=513 flags=0x10000(runtime) hashes=5+7 location=embedded
```

微信数据目录（由工具自动探测）：

```
~/Library/Containers/com.tencent.xinWeChat/Data/Documents/
  xwechat_files/<wxid>/db_storage/
```

其中有 **26 个加密数据库**，分布在 `message/`、`session/`、`contact/`、`sns/`、
`favorite/`、`bizchat/` 等子目录。

---

## 2. 安装：为什么必须源码构建 + 为什么必须 arm64

### 2.1 为什么必须源码构建

`jackwener/wx-cli-again` 仓库**没有 release、也没有 tag**：

```bash
curl -sL https://api.github.com/repos/jackwener/wx-cli-again/releases/latest
# {"message":"Not Found", ... 404}

curl -sL https://api.github.com/repos/jackwener/wx-cli-again/tags
# []
```

仓库自带的 `install.sh` 指向的是**另一个私有仓库** `botiverse/wx-cli`：

```bash
REPO="botiverse/wx-cli"
TAG=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" | grep '"tag_name"' ...)
```

匿名执行必然拿不到二进制。所以只能从 `jackwener/wx-cli-again` 源码构建。

### 2.2 为什么必须 arm64 原生二进制

本机是 arm64，但 rustup 的默认 host 是 `x86_64-apple-darwin`（rustup 自身跑在
Rosetta 模拟下）：

```
$ rustc -vV
host: x86_64-apple-darwin
$ rustup toolchain list
stable-x86_64-apple-darwin (active, default)
```

直接 `cargo build --release` 产出的是 **x86_64** 二进制：

```
$ file target/release/wx
Mach-O 64-bit executable x86_64
```

**为什么这会导致取钥失败**：本机微信是官方 Hardened Runtime 包，取钥靠 LLDB
往微信进程注入代码并 hook `CCCryptorCreate`。x86_64 的调试器无法向 arm64
目标进程注入本架构的断点回调——跨架构注入会被内核拒绝，hook 静默失效。

> 旁证：`rustup toolchain install stable-aarch64-apple-darwin` 会被 rustup 拒绝
> （`Rustup is not running natively... error: toolchain 'stable-aarch64-apple-darwin'
> may not be able to run on this system`），只能改用 **target** 交叉编译。

### 2.3 构建与安装

```bash
mkdir -p ~/.local/src && cd ~/.local/src
git clone --depth 1 https://github.com/jackwener/wx-cli-again.git
cd wx-cli-again

rustup target add aarch64-apple-darwin      # 注意：是 target，不是 toolchain
cargo build --release --target aarch64-apple-darwin

cp target/aarch64-apple-darwin/release/wx ~/.local/bin/wx
chmod +x ~/.local/bin/wx
```

构建耗时约 **2 分 19 秒**（`bundled-sqlcipher-vendored-openssl` 需要现场编译
OpenSSL + SQLCipher）。

验证：

```bash
$ file ~/.local/bin/wx
Mach-O 64-bit executable arm64          # ← 必须是 arm64
$ wx --version
wx 0.6.3
```

PATH：`~/.zshrc` 第 156 行已有 `export PATH="$HOME/.local/bin:$PATH"`，新终端可直接用。

> **构建依赖**：`cc` / `clang`、`make`、`perl`（OpenSSL vendored 需要）、
> `pkg-config`。本次环境全部具备（Xcode.app 已安装）。

---

## 3. 密钥提取：完整攻坚过程

微信 4.x 使用 **SQLCipher 4** 加密本地库（AES-256-CBC + HMAC-SHA512，页级 raw key）。
每个 DB 有独立的 32-byte AES key，key 在微信打开该库时通过 `CCCryptorCreate` 传入。

### 3.1 官方路径与首次实测

官方文档给的是：

```bash
sudo wx key extract --hook-seconds 90
```

首次实测（官方 Hardened Runtime + sudo + 本机 GUI Terminal）：

```
WeChat PID: 84052
WeChat 签名: 官方 Hardened Runtime（内存扫描需要 sudo；hook 也建议 sudo）
找到 26 个加密数据库
内存扫描完成：x'hex' 候选 0 个，salt 邻接候选 293 个（读取约 2162.9 MB）
内存阶段匹配到 0/26 个数据库密钥（候选 key 293 个，含已有密钥）
仍有 26 个数据库未匹配密钥，启动 LLDB hook 90s…
LLDB hook 捕获到 8 个 32-byte key
最终匹配到 8/26 个数据库密钥
```

**结果：8/26**，缺失 18 个，其中 9 个是关键分片：

```
message/message_0.db (468.9MB)   message/message_1.db (421.8MB)
message/message_2.db (205.2MB)    message/biz_message_0.db (230.3MB)
message/message_fts.db (193.4MB)  message/biz_message_1.db (162.5MB)
message/biz_message_2.db (76.7MB) message/media_0.db (37.5MB)
session/session.db (7.8MB)
```

拿到 8 个 key 后，`wx doctor` 的状态：

```
✓  数据库密钥        8 个密钥
✗  关键分片密钥      9 个缺失（约 1804MB）
✗  message_fts 密钥  缺失（search 将回退全库扫描）
```

`wx sessions` 直接失败：

```
$ wx sessions
启动 wx-daemon...
错误: 无法解密 session.db
```

### 3.2 根因：hook 只在「打开数据库」那一刻生效

关键事实（后面所有结论都由它推出）：

1. `wx key extract` 第一步是 `find_wechat_pid()` —— `pgrep -x WeChat`，
   **要求微信已经在运行**，否则直接 `bail!("找不到 WeChat 进程")`。
2. LLDB hook 通过在 `CCCryptorCreate` 上打断点捕获 key。
   **只有微信调用 `CCCryptorCreate`（即打开某个加密库）时才会触发。**
3. 微信启动时就已经打开了 `session.db`、`message_N.db` 等分片。
   等 90 秒后 hook 才挂上，这些库的 open 事件**早已过去**，永远抓不到。

用 `lsof` 印证了这一点——微信把 26 个库全部持有为打开状态：

```bash
$ lsof -p 84052 | grep -o "$DB/.*\.db" | sed "s|$DB/||" | sort -u
bizchat/bizchat.db          message/biz_message_0.db   message/media_0.db
chatbot/chatbot_message.db  message/biz_message_1.db   message/media_1.db
contact/contact.db          message/biz_message_2.db   message/message_0.db
contact/contact_fts.db      message/media_1.db         message/message_1.db
emoticon/emoticon.db        message/message_2.db       message/message_2.db
favorite/favorite.db        message/message_3.db       message/message_fts.db
favorite/favorite_fts.db    message/message_resource.db
general/general.db          message/weclaw.db
hardlink/hardlink.db        session/session.db
head_image/head_image.db    sns/sns.db
solitaire/solitaire.db      third_app_icon/third_app_icon.db
```

而 hook 窗口内新打开的库（用户交互触发的那些，如头像 `head_image.db`、
表情 `emoticon.db`）却被成功捕获了 —— 8 个已捕获库正是这类"按需打开"的库。

### 3.3 排除路线 A：内存扫描（salt 邻接）

工具自带的 Phase 1 内存扫描做两件事：

- 搜 `x'<64hex_key><32hex_salt>'` 字符串（传统 WCDB 格式）
- 按每个 DB 的 16-byte salt 在堆里找**相邻**的 32-byte raw key

第二个的偏移候选写死在 `src/scanner/mod.rs`：

```rust
const BEFORE: [usize; 3] = [32, 40, 48];
const AFTER:  [usize; 3] = [0, 8, 16];
```

只试 6 个固定偏移。我写了一个增强版（`memscan.py`）：找到 salt 后，把
**±256 字节内所有 32 字节窗口**都当候选，逐个用 SQLCipher 4 的 page-1
HMAC 校验（与工具的 `validate_raw_key_for_db` 完全同源）：

```python
mac_salt = bytes(b ^ 0x3A for b in page[:16])
mac_key  = hashlib.pbkdf2_hmac("sha512", key, mac_salt, 2, 32)
mac      = hmac.new(mac_key, page[16:4016] + page[4016:4032]
                              + struct.pack("<I", 1), hashlib.sha512).digest()
valid    = mac == page[4032:4096]
```

先做**算法自测**（用已知有 key 的 `contact/contact.db`）：

```
[t] 正确 key 校验: True
[t] 错误 key 校验: False
```

算法无误后跑全量扫描：

```
[memscan] 待查 18 个库，窗口 ±256 字节
[memscan] 扫描了 602 个内存区域，约 3231.6 MB
[memscan] 命中 0 / 18
```

**0 命中**。为了区分「salt 不在内存里」和「salt 在但邻域没 key」，又做了一次
计数实验——把**已知有 key 的 `contact/contact.db` 作为对照组**一起统计
salt 出现次数：

```
[diag] 结果（对照组 contact/contact.db 已知有 key）:
[diag]   message/message_0.db             salt 出现 0 次
[diag]   message/message_1.db             salt 出现 0 次
[diag]   ...
[diag]   session/session.db               salt 出现 0 次
[diag]   contact/contact.db               salt 出现 0 次   ← 对照组也是 0
```

**对照组同样为 0**。结论明确：微信 4.x 的 salt **根本不驻留内存**，
因此「salt 邻接」这条路在原理上就不成立——不是偏移猜错了，是 salt 压根不在。
工具自带的内存扫描（以及任何基于 salt 邻接的改写）对 4.x 都无效。

> 这也解释了为什么即使成功挂上 hook、拿到了 key，`sudo wx key extract` 依然
> 报告「内存阶段匹配到 0/26」：它本来就只能靠 Phase 2 的 hook。

### 3.4 排除路线 B：lldb launch 模式

既然 attach 追不上启动期的 open，那就让微信**在 debugger 控制下启动**：
断点在进程启动前设好，启动期打开的库必然被捕获。

实现上用 `lldb -f <binary>` + `process launch --stop-at-entry`，
而不是 `-p <pid>` attach。**launch 模式不需要 `task_for_pid`，
因此不需要 root，也不需要 TCC 授权**。

先在测试程序上验证机制（用 hardened runtime 签名模拟微信的签名状态）：

```c
// hooktest.c
unsigned char key[32]; for (int i = 0; i < 32; i++) key[i] = 0xA0 + i;
CCCryptorCreate(kCCEncrypt, kCCAlgorithmAES, kCCOptionECBMode,
                 key, sizeof(key), iv, &cryptor);
```

```bash
codesign -s - --options runtime -f hooktest      # flags=0x10002(adhoc,runtime)
lldb --batch -f ./hooktest \
    -o "command script import wxhook.py" \
    -o "process launch --stop-at-entry" \
    -o "script wxhook.setup()" \
    -o "process continue"
```

```
[wx-hook] key a0a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebf
```

✅ 机制完全正确，hardened runtime 目标也能正常调试，key 精确命中。

**但落到真实微信上失败了**：lldb 确实把微信拉起来了（`Process 34904 launched`），
可微信**一个数据库都没打开**：

```bash
$ lsof -p 34904 | grep -c "\.db"
0
```

hook 窗口结束，捕获到 0 个 key。直接 exec 启动的微信拿不到正常的
launchservices 环境（沙箱容器注册、启动时序都变了），最终没有进入正常的
DB 访问流程。

> 这条路线**不成立**，但它逼出了关键认识：**问题不在「怎么抓到 key」，
> 而在「什么时候抓」**。

### 3.5 解法：免 sudo attach 到运行中的微信

回到 attach 路线。之前的障碍是：微信是 Hardened Runtime 包，attach 需要
`task_for_pid`，而 `task_for_pid` 对 Hardened Runtime 目标需要 root，
或者需要调用方具备 **TCC「开发者工具」授权**。

在 macOS「隐私与安全性 → 开发者工具」里给宿主 App（本次是 MCode）授权后，
**attach 就不再需要 sudo**：

```bash
$ lldb --batch -p 34904 -o "process status" -o "process detach" -o "quit"
Process 34904 stopped
* thread #1, queue = 'com.apple.main-thread', stop reason = signal SIGSTOP
       frame #0: ... mach_msg2_trap + 8
Target 0: (WeChat) stopped.          # ← 附加成功，未使用 sudo
```

这一下把 3.4 和 3.2 的矛盾解开了：

- **attach**：不需要重启微信，微信保持正常运行、保持登录态；
- **微信在 hook 挂载之后仍会按需打开数据库**（翻历史 → `message_N.db`、
  搜索 → `message_fts.db`、公众号 → `biz_message_N.db`、图片 → `media_0.db`），
  这些 open 事件发生在 hook 期间，能被捕获；
- **不重启**就意味着微信不会退出重进，登录态、正在进行的会话都不受影响。

### 3.6 关键实现：pending breakpoint

实现 hook 时踩到一个坑：在 `process launch --stop-at-entry` 停下时，
**只加载了主程序和 dyld，libSystem（CommonCrypto 所在）还没加载**：

```
$ target modules list
[ 0] ... /Users/rinh/.local/share/wx-hook/hooktest
[ 1] ... /usr/lib/dyld
$ image lookup -n CCCryptorCreate
(无输出)
```

所以 `BreakpointCreateByName()` 拿到的是 **0 locations**。第一版脚本误判成
「符号不存在」直接 skip，四个断点一个都没挂上。

正确做法：**不要跳过 0 locations 的断点**。
`BreakpointCreateByName` 此时创建的是 *pending breakpoint*，lldb 会在
对应模块加载时自动解析，而且 `SetScriptCallbackFunction` 设置的回调会
在解析后保留：

```python
for name in SYMBOLS:
    bp = target.BreakpointCreateByName(name)
    bp.SetScriptCallbackFunction(__name__ + ".on_cc")
    bp.SetAutoContinue(True)
    # 不要因为 GetNumLocations()==0 就 skip
```

arm64 ABI 下的寄存器取法（与工具内嵌脚本一致）：

```
CCCryptorCreate(op, alg, options, key, keyLength, iv, cryptorRef)
  -> x3 = key, x4 = keyLength
CCCryptorCreateWithMode(op, mode, alg, padding, iv, key, keyLength, ...)
  -> x5 = key, x6 = keyLength
```

hook 的四个符号：`CCCryptorCreate`、`CCCrypt`、`CCCryptorCreateWithMode`、
`CCCryptorCreateFromData`。

### 3.7 key ↔ DB 匹配与校验

hook 只给出裸 32-byte key，不知道它属于哪个库。匹配用工具自带的
`wx key set`：它会**先用候选 key 实际尝试解密该库**，解不开就报错且不写盘：

```rust
// src/cli/key_cmd.rs
if path.exists() {
    if let Some(raw) = scanner::decode_key_hex_pub(&key) {
        if !crate::crypto::validate_raw_key_for_db(&path, &raw) {
            bail!("密钥无法解密 {}，请确认 hex 正确", rel);
        }
    }
}
map.insert(rel.clone(), json!({ "enc_key": key }));
```

所以可以放心地遍历尝试，命中即写入：

```bash
while read -r db; do
  while read -r k; do
    wx key set "$db" "$k" >/dev/null 2>&1 && { echo "✓ $db <- ${k:0:12}…"; break; }
  done < <(sort -u hook_keys.txt)
done < <(wx key list --json | jq -r '.missing[].db')
```

实测结果 **18/18 全中**：

```
  ✓ message/message_0.db      <-  9bb4ac37fcb4…
  ✓ message/message_1.db      <-  d004e331f9f9…
  ✓ message/message_2.db      <-  d0ece4d2d960…
  ✓ message/biz_message_0.db  <-  6699dd419ebd…
  ✓ message/message_fts.db    <-  39ce62db3127…
  ✓ message/biz_message_1.db  <-  7e26ee7e438f…
  ✓ message/biz_message_2.db  <-  47e9297e246d…
  ✓ message/media_0.db        <-  b7799f920ca0…
  ✓ session/session.db        <-  73207e0ca2f3…
  ✓ message/media_1.db        <-  486823f4629a…
  ✓ message/weclaw.db         <-  84c98805acbb…
  ✓ sns/sns.db                <-  36bb1916f021…
  ✓ favorite/favorite.db      <-  e0cc06eff4ae…
  ✓ favorite/favorite_fts.db  <-  6197a1210cd5…
  ✓ solitaire/solitaire.db    <-  ad40b7e160d7…
  ✓ chatbot/chatbot_message.db<-  c137c50153f2…
  ✓ bizchat/bizchat.db        <-  5ac2fec2b303…
  ✓ third_app_icon/third_app_icon.db <- 8e524332091e…
```

hook 本身很高效：挂上后 **约 8 秒捕获 17 个 key**，最终共 35 个，
其中恰好包含全部 18 个缺失库的 key。

> **关于密钥的持久性**：中途重启过一次微信，清空解密缓存后重新解密
> `contact/contact.db` 仍然成功 —— 说明微信 4.x 的 DB 密钥是**持久的**，
> 不随微信重启失效。所以这 26 个 key 抓一次就长期有效。

---

## 4. 验证

### 4.1 `wx doctor` 全绿

```
✓  WeChat 进程                    PID 34904
✓  SIP                            System Integrity Protection status: disabled.
✓  WeChat 签名                    Hardened Runtime
✓  lldb                           可用
✓  config.json                    /Users/rinh/.../db_storage
✓  数据库密钥                      26 个密钥
✓  关键分片密钥                    聊天 / session / contact 齐全
✓  SQLCipher 在线打开               session.db OK
✓  message_fts 密钥                已配置（search 可走 FTS）
✓  daemon socket                  /Users/rinh/.wx-cli/daemon.sock

全部检查通过。
```

### 4.2 功能实测（不只是 doctor）

| 命令 | 结果 |
|---|---|
| `wx sessions -n 30` | 30 个会话，`meta.status=ok`，含 chat_type / unread |
| `wx history "<群名>" -n 5` | 消息正文、sender、附件标记（`[图片] local_id=...`）齐全 |
| `wx search "关键词" -n 5` | 跨会话全文命中，带 chat 来源与时间；FTS 索引生效 |
| `wx stats "<群名>"` | `by_hour` / `by_type` / `top_senders` / `meta` |
| `wx export "<群名>" -n 20 --format json` | 正常落盘 |
| `wx contacts --query "<关键字>"` | 23134 个联系人可检索 |

长会话验证（一条真实私聊）：

```
status = ok | unknown_shards = []
总条数 = 2000
时间范围 = 2025-09-08 11:24 → 2026-11-21 09:46
发送者分布: {'(对方)': 1441, 'rinh': 559}
```

---

## 5. 工具脚本清单

本仓库 `tools/` 目录收录了本次实战沉淀的脚本：

| 文件 | 作用 |
|---|---|
| `tools/wxhook.py` | LLDB hook 核心：断点、寄存器读取、key 落盘、定时 detach |
| `tools/hook-attach.sh` | **主力**：attach 到运行中的微信（免 sudo），抓 300s |
| `tools/map-keys.sh` | 把裸 key 匹配回数据库并写入 `all_keys.json` |
| `tools/memscan.py` | 增强版内存扫描（±256 字节窗口 + HMAC 校验） |
| `tools/memscan.sh` | 内存扫描封装 |
| `tools/saltdiag.py` | salt 出现次数统计（含对照组） |

日常使用（脚本会自行定位同目录下的 `wxhook.py` / `memscan.py`，可直接从仓库跑）：

```bash
# 微信升级 / 新增分片后，重新抓一次
bash tools/hook-attach.sh 300
# 期间在微信里：翻历史消息 / 打开公众号 / 搜索 / 打开图片
bash tools/map-keys.sh
```

### 已知限制

- `hook-attach.sh` 需要宿主 App 具备 TCC「开发者工具」授权，否则 attach
  会失败（非 sudo 情况下）。授权路径：
  「系统设置 → 隐私与安全性 → 开发者工具」勾选宿主 App。
- 内存扫描路线已被证伪（salt 不驻留内存，见 [3.3](#33-排除路线-a内存扫描salt-邻接)），
  `memscan.*` / `saltdiag.py` 仅作为诊断工具保留，**不要**指望它们能补齐密钥。
- 仓库里没有收录 launch 模式的脚本：直接 exec 启动的微信不会正常打开数据库，
  该路线在微信 4.x 上不可用（见 [3.4](#34-排除路线-blldb-launch-模式)）。

---

## 6. 踩坑清单

| # | 现象 | 根因 | 处理 |
|---|---|---|---|
| 1 | `rustup toolchain install stable-aarch64-apple-darwin` 被拒 | rustup 自身跑在 Rosetta 下 | 改用 `rustup target add aarch64-apple-darwin` + `--target` 交叉编译 |
| 2 | 直出二进制是 x86_64 | 默认 toolchain host 是 x86_64 | 同上，交叉编译出 arm64 |
| 3 | `sudo wx key extract` 只拿到 8/26 | hook 只在 DB open 时触发，attach 晚于启动期 | attach 到运行中的微信，让用户触发按需打开 |
| 4 | 内存扫描 293 个候选 0 命中 | 微信 4.x 的 salt 不驻留内存（对照组亦 0） | 放弃 salt 邻接路线，只用 hook |
| 5 | lldb launch 模式下微信不开数据库 | 直接 exec 启动拿不到正常 launchservices 环境 | 放弃 launch 模式，改 attach |
| 6 | 断点 0 locations 被误判为"符号不存在" | stop-at-entry 时 libSystem 尚未加载 | 保留为 pending breakpoint，不要 skip |
| 7 | `SBMemoryRegionInfo` 无 `GetRangeBase` | 本机 LLDB Python API 命名不同 | 用 `GetRegionBase()` / `GetRegionEnd()` / `IsReadable()` |
| 8 | `lldb.ePermissionsRead` 不存在 | 本版本常量名不同 | 用 `mem.IsReadable()` 判断 |
| 9 | `SBMemoryRegionInfoList` 不支持 `regs[0]` | 本版本未实现 `__getitem__` | 用 `for mem in regs:` 迭代 |
| 10 | `PID: unbound variable` | bash 3.2 多字节字符处的变量名解析 | 写成 `${PID}`（加花括号） |
| 11 | `wx contacts` 返回空 | 18 次连续热重载把 daemon 解密缓存写坏 | `wx daemon stop` 后重启 daemon |
| 12 | `wx history "<不存在的名字>"` 报"找不到联系人" | 会话名需与联系人/会话名一致 | 先用 `wx sessions` 拿到真实 chat 名 |

关于 #10 的细节：macOS 自带 bash 3.2，在 UTF-8 locale 下会把紧跟变量名的
多字节字符（如中文逗号 `，`）吞进变量名，报 `PID: unbound variable`。
脚本里所有变量引用一律加 `${}`。

---

## 7. 结论与后续

1. **安装**：Apple Silicon 上必须交叉编译 arm64 版本
   （`rustup target add aarch64-apple-darwin` + `cargo build --release --target ...`）。
   仓库无 release，只能源码构建。

2. **取钥**：
   - 官方 `sudo wx key extract` 在微信已运行的状态下只能覆盖"按需打开"的库；
   - 内存扫描路线对微信 4.x 原理上无效（salt 不驻留内存，有对照组实证）；
   - 可靠路径是 **attach 到运行中的微信 + hook `CCCryptorCreate`**，
     前提是调用方具备 TCC「开发者工具」授权，从而免 sudo。

3. **密钥持久**：微信 4.x 的 DB 密钥不随重启失效，抓一次长期有效。

4. **可改进的方向**（留给上游 / 后续 PR）：
   - 把「attach + hook」做成 `wx key extract --attach` 之类的子命令，
     省掉外部脚本；
   - 在 `wx doctor` 里加一条「微信进程已运行但关键分片缺密钥」的明确提示，
     避免用户反复重跑 `sudo wx key extract`；
   - `wx key set` 增加 `--try-all` 之类的批量匹配模式。

---

## 附：本文涉及的关键源码位置

| 关注点 | 位置 |
|---|---|
| 微信 PID 查找（`pgrep -x WeChat`，要求已运行） | `src/scanner/macos.rs` → `find_wechat_pid()` |
| 内存扫描的 salt 邻接固定偏移 | `src/scanner/mod.rs` → `collect_salt_adjacent_keys()` |
| LLDB hook 脚本与 arm64 寄存器取法 | `src/scanner/macos.rs` → `lldb_hook_script()` |
| LLDB 只允许 root 或 ad-hoc 才 attach | `src/scanner/macos.rs` → `hook_keys_via_lldb()` 的 `allow_user` |
| SQLCipher 4 page-1 HMAC 校验 | `src/crypto/mod.rs` → `verify_hmac_page1()` |
| key → DB 校验与写入 | `src/cli/key_cmd.rs` → `cmd_key_set()` |
| config.json 查找顺序（cwd → exe dir → `~/.wx-cli`） | `src/config.rs` → `find_existing_config_path()` |
