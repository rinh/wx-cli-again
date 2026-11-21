# wx-cli 使用说明（已安装用户）

> 面向**已经安装并完成初始化**的用户。
> 安装与取钥的完整过程见 [macos-arm64-install-and-key-extraction-playbook.md](macos-arm64-install-and-key-extraction-playbook.md)。
>
> 本文档假设 `wx doctor` 已全部通过（26 个密钥齐全、关键分片齐全）。

---

## 五分钟上手

```bash
wx doctor                 # 健康检查，全绿才继续
wx sessions               # 最近 20 个会话 —— 拿到会话名
wx history "会话名" -n 10 # 看某个会话最近 10 条
wx search "关键词"        # 全库搜
```

先跑 `wx sessions` 拿到**准确的会话名**，后面所有命令都靠它定位。

---

## 三个必须先搞懂的概念

### 1. 会话名要完全匹配

`wx history` / `export` / `stats` 传的是会话名，**必须和本地库里一致**，否则报「找不到联系人」。
名字从哪来：

```bash
wx sessions --json | jq -r '.sessions[].chat'    # 从会话列表拿
wx contacts -q "张三"                             # 从通讯录拿
wx members "群名"                                 # 群成员也带 display
```

群聊的 `chat` 可能是「折叠的群聊」「公众号」这类聚合入口，
真正的群名要靠 `wx sessions` 里 `chat_type: group` 的条目定位。

### 2. 每次查询都带 `meta`，先看它

```yaml
meta:
  status: ok                    # 数据新鲜度
  unknown_shards: []            # 非空 = 有分片缺密钥，结果可能不全
  chat_latest_db: message/message_3.db
  chat_latest_timestamp: 1795228449
  session_last_timestamp: 1795228449
```

| `status` | 含义 | 该做什么 |
|---|---|---|
| `ok` | 数据完整新鲜 | 直接用 |
| `windowed` | 只返回了部分时间窗内的数据 | 需要更多数据就调大 `-n` |
| `possibly_stale` | 数据可能不是最新的 | 看 `chat_latest_timestamp` 判断 |
| `possibly_stale_unknown_shards` | 既有陈旧又有缺分片 | 先补密钥（见「故障排查」） |

**`unknown_shards` 非空 = 有库没解密**，此时结果一定不完整，别当成"消息不存在"。

### 3. 默认输出是 YAML，`--json` 切 JSON

```bash
wx history "群名" -n 5                    # YAML，人看
wx history "群名" -n 5 --json             # JSON，程序消费
```

JSON 顶层结构（已实测）：

| 命令 | 顶层键 | 数组字段 |
|---|---|---|
| `sessions` | `meta`, `sessions` | — |
| `history` | `chat`, `chat_type`, `count`, `is_group`, `messages`, `meta`, `username` | `messages` |
| `search` | `count`, `keyword`, `meta`, `results` | `results` |
| `attachments` | `attachments`, `chat`, `chat_type`, `count`, `is_group`, `meta`, `username` | `attachments` |

---

## 按场景的命令清单

### 消息

```bash
wx sessions                        # 最近会话（默认 20 条）
wx unread                          # 有未读的会话
wx unread --filter private,group   # 只看真人未读，过滤公众号/折叠入口
wx new-messages                    # 上次检查之后的新消息（增量，默认 200 条）
wx history "会话名"                # 最近 50 条
wx history "会话名" -n 2000        # 拉更多
wx history "会话名" --since 2026-10-01 --until 2026-10-31
wx history "会话名" --type image   # 只看图片
wx timeline                        # 跨会话按时间合并
wx watch                           # 实时监听新消息（默认 1.5s 轮询）
```

### 搜索

```bash
wx search "关键词"                 # 全库，默认 20 条
wx search "关键词" -n 500          # 放宽条数
wx search "会议" --in "工作群"     # 限定某个会话（可重复指定多个）
wx search "会议" --since 2026-01-01
wx search "会议" --type link       # 只搜链接类消息
```

### 联系人与群

```bash
wx contacts                        # 默认 50 个
wx contacts -q "李"                # 按名字搜
wx members "群名"                  # 群成员
```

### 统计与收藏

```bash
wx stats "会话名"                  # by_hour / by_type / top_senders
wx stats "会话名" --since 2026-01-01
wx favorites                        # 收藏
wx favorites --type image           # 按类型过滤
wx favorites -q "关键词"            # 搜收藏内容
```

### 朋友圈与公众号

```bash
wx sns-feed                        # 近 20 条朋友圈时间线
wx sns-feed --user "张三" --since 2026-04-01
wx sns-search "婚礼" --user "李四"
wx sns-notifications               # 点赞/评论通知
wx sns-notifications --include-read -n 100
wx biz-articles                    # 公众号文章推送
wx biz-articles --account "返朴"   # 限定公众号
wx biz-articles --unread           # 每个公众号取最新 1 篇
```

### 导出

```bash
wx export "会话名" -o chat.md                        # 默认 markdown
wx export "会话名" -n 2000 --format json -o chat.json
wx export "会话名" --since 2026-10-01 --format txt -o chat.txt
```

格式可选 `markdown` / `txt` / `json` / `yaml`，默认 `markdown`。
不加 `-o` 则输出到 stdout。**默认最多 500 条**，要更多记得加 `-n`。

---

## 三个高频技巧

### 1. 翻页用游标，别用 `--offset`

深 offset 会越来越慢。优先用 `--after`：

```bash
# 第一页
wx history "群名" -n 50 --json | jq -r '.messages[-1].timestamp'
# → 1789...

# 拿更旧的（传上一页最旧那条的 timestamp）
wx history "群名" -n 50 --after 1789... --json
```

`--before` 则取更新的消息。`--offset` 仍然可用，只是慢。

### 2. 消息类型过滤

`--type` 支持：
`text` `image` `voice` `video` `card` `sticker` `location` `link` `file` `appmsg` `call` `system` `revoke`

`--type link` / `--type file` 会包含链接、文件、合并聊天记录和引用消息等变体。
`--type appmsg` 覆盖公众号推送类消息。

### 3. 给程序消费

```bash
# 取最近 10 条消息正文
wx history "群名" -n 10 --json | jq -r '.messages[].content'

# 全库搜关键词，只看谁发的
wx search "预算" -n 100 --json | jq -r '.results[] | "\(.time) \(.sender): \(.content)"'

# 统计某个群里各人发言数
wx stats "群名" --json | jq '.top_senders'

# 增量监控：只看新消息
watch -n 30 'wx new-messages --json | jq -r ".messages[] | \"\(.time) \(.sender)\""'
```

---

## 图片附件提取（两步）

聊天里的图片在库里只是一个 `local_id`，真正的原图存在 `xwechat_files/<wxid>/msg/attach/` 下，
是加密的 `.dat`，需要用 md5 + image key 解码才能还原。

```bash
# 1) 列出图片附件，拿到不透明的 attachment_id
wx attachments "会话名" --kind image -n 100

# 2) 解密写出去（扩展名建议保留）
wx extract <attachment_id> -o ~/Desktop/photo.jpg
wx extract <attachment_id> -o /tmp/x.jpg --overwrite
```

`extract` 的输出报告会给出 `md5` / `dat_path` / `format` / `decoder`
（`legacy_xor` / `v1_aes` / `v2`）。

批量导出某个会话的图片：

```bash
wx attachments "会话名" --kind image -n 100 --json \
  | jq -r '.attachments[].attachment_id' \
  | while read id; do
      wx extract "$id" -o "./imgs/$id.jpg" --overwrite
    done
```

---

## 后台 daemon

首次查询会自动拉起 daemon，把解密后的库缓存在 `~/.wx-cli/cache/`，
按 mtime 增量更新。日常查询很快（毫秒级）就是这个原因。

```bash
wx daemon status
wx daemon logs --follow      # 实时看日志
wx daemon stop               # 停止；下次查询会自动重启
```

数据目录与密钥都在这里：

```
~/.wx-cli/
├── config.json       # 配置（db_dir 等）
├── all_keys.json     # 26 个数据库密钥
├── daemon.sock       # Unix socket
├── daemon.pid / .log
└── cache/            # 解密后的库
```

---

## 故障排查

| 现象 | 原因 | 处理 |
|---|---|---|
| `错误: 找不到联系人: xxx` | 会话名不匹配 | `wx sessions --json` 找准确名字 |
| `错误: 无法解密 session.db` | 缺分片密钥 | 见下方「补密钥」 |
| `错误: wx-daemon 启动超时` | `config.json` 还没生成 | 跑 `wx init`；生成后会消失 |
| `错误: 读取 config.json 失败: <某个目录>/config.json` | 查找顺序是 cwd → 可执行文件目录 → `~/.wx-cli`，前两者没有 config 时会退化 | `wx init` 生成 `~/.wx-cli/config.json` 即解决 |
| `meta.unknown_shards` 非空 | 有库没密钥，结果不完整 | 见下方「补密钥」 |
| `wx contacts` 突然返回空 | daemon 缓存被连续热重载写坏 | `wx daemon stop` 后重试 |
| 图片消息只有 `[图片] local_id=xxx` | 正常，图片本体需单独提取 | `wx attachments` + `wx extract` |
| 语音消息只有 `[语音]` | 工具不做语音转写 | `wx media voice` 导出 silk 原始数据后自行转写 |

### 补密钥

```bash
# 先看缺哪些
wx key list

# macOS：attach 到运行中的微信（免 sudo，需「开发者工具」授权）
bash tools/hook-attach.sh 300
# 期间在微信里：翻历史消息 / 打开公众号 / 搜索 / 点开图片
bash tools/map-keys.sh

# 确认
wx doctor
```

> 微信升级后可能出现新分片，重跑上面两条即可。
> 微信 4.x 的数据库密钥是持久的，不随微信重启失效。

---

## 命令速查

```
诊断与密钥
  wx doctor [--json] [--fix]
  wx key list [--json] [--show-secrets]
  wx key set <db> <64hex>

消息
  wx sessions [-n N] [--json]
  wx unread [--filter private,group] [-n N] [--json]
  wx new-messages [-n N] [--json]
  wx history <CHAT> [-n N] [--since D] [--until D] [--after TS] [--before TS] [--type T] [--json]
  wx search <KEYWORD> [--in CHAT] [-n N] [--since D] [--until D] [--type T] [--json]
  wx timeline [-n N] [--since D] [--until D] [--after TS] [--type T] [--json]
  wx watch [--interval MS] [-n N] [--json]

联系人与群
  wx contacts [-q Q] [-n N] [--json]
  wx members <CHAT> [--json]

统计与收藏
  wx stats <CHAT> [--since D] [--until D] [--json]
  wx favorites [--type T] [-q Q] [-n N] [--json]

朋友圈与公众号
  wx sns-feed [--user U] [--since D] [-n N] [--json]
  wx sns-search <KEYWORD> [--user U] [--since D] [-n N] [--json]
  wx sns-notifications [--include-read] [-n N] [--json]
  wx biz-articles [--account A] [--since D] [--until D] [--unread] [-n N] [--json]

附件
  wx attachments <CHAT> [--kind image] [-n N] [--since D] [--until D] [--json]
  wx extract <ATTACHMENT_ID> -o <FILE> [--overwrite] [--json]
  wx media voice <svr_id> -o <FILE>

导出
  wx export <CHAT> [-n N] [-f markdown|txt|json|yaml] [-o FILE] [--since D] [--until D]

daemon
  wx daemon status | stop | logs --follow
```

---

## 数据边界

- 所有数据**只在本地**，工具不联网、不上传。
- 只覆盖**你自己**本机的微信数据；解密他人账号数据违法，仓库 README 也有免责声明。
- 朋友圈只覆盖你本地刷到过的帖子（微信按需下载）。
- 公众号文章只覆盖本地缓存的推送。
