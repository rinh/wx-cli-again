#!/usr/bin/env bash
# wx-cli 安装器（源码构建版）
#
# 本 fork 不发布预编译二进制（上游 botiverse/wx-cli 为 private），因此改为
# 从源码构建：clone → 交叉编译 → 安装到用户 PATH。
#
# 关键点：Apple Silicon 上若 rustup 的默认 toolchain host 是 x86_64
# （装在 Rosetta 下的常见状态），直接 cargo build --release 会产出 x86_64
# 二进制 —— 命令成功但取钥阶段不可用。本脚本会显式指定目标架构。
#
# 用法：
#   curl -fsSL https://raw.githubusercontent.com/rinh/wx-cli-again/main/install.sh | bash
#   INSTALL_DIR=/usr/local/bin bash install.sh      # 指定安装目录
set -euo pipefail

REPO="rinh/wx-cli-again"
REPO_URL="https://github.com/${REPO}.git"
BIN_NAME="wx"
INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"
SRC_DIR="${SRC_DIR:-$HOME/.local/src/wx-cli-again}"

# ── 检测平台与目标架构 ────────────────────────────────────────
OS=$(uname -s)
ARCH=$(uname -m)

case "${OS}-${ARCH}" in
  Darwin-arm64)  TARGET="aarch64-apple-darwin" ;;
  Darwin-x86_64) TARGET="x86_64-apple-darwin" ;;
  Linux-x86_64)  TARGET="x86_64-unknown-linux-gnu" ;;
  Linux-aarch64) TARGET="aarch64-unknown-linux-gnu" ;;
  *)
    echo "不支持的平台: ${OS}-${ARCH}"
    echo "请手动 clone ${REPO_URL} 并执行 cargo build --release"
    exit 1
    ;;
esac

echo "==> 平台: ${OS}-${ARCH}   目标架构: ${TARGET}"
echo "==> 安装目录: ${INSTALL_DIR}"

# ── 前置依赖 ──────────────────────────────────────────────────
need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "缺少依赖: $1"
    case "$1" in
      cargo) echo "  安装 Rust: https://rustup.rs" ;;
      git)   echo "  安装 Git: https://git-scm.com/downloads" ;;
    esac
    exit 1
  }
}
need git
need cargo

# ── 取源码 ────────────────────────────────────────────────────
if [ -d "${SRC_DIR}/.git" ]; then
  echo "==> 更新已有 clone: ${SRC_DIR}"
  git -C "$SRC_DIR" pull --ff-only
else
  echo "==> 克隆源码到 ${SRC_DIR}"
  mkdir -p "$(dirname "$SRC_DIR")"
  git clone --depth 1 "$REPO_URL" "$SRC_DIR"
fi

# ── 确认目标架构可用 ──────────────────────────────────────────
# rustc 的 host 决定默认产物架构。若 host 与目标不一致（Rosetta 场景），
# 必须显式安装对应 target，否则 cargo 会悄悄回退到 host 架构。
RUST_HOST=$(rustc -vV | awk '/^host:/ {print $2}')
echo "==> rustc host: ${RUST_HOST}"

BUILD_ARGS=()
if [ "${RUST_HOST}" != "${TARGET}" ]; then
  echo "==> host 与目标架构不一致，安装 ${TARGET} target"
  rustup target add "$TARGET"
  BUILD_ARGS=(--target "$TARGET")
else
  BUILD_ARGS=(--target "$TARGET")
fi

# ── 构建 ──────────────────────────────────────────────────────
echo "==> 编译中（首次构建需现场编译 OpenSSL + SQLCipher，约 2-5 分钟）..."
( cd "$SRC_DIR" && cargo build --release "${BUILD_ARGS[@]}" )

BUILT="${SRC_DIR}/target/${TARGET}/release/${BIN_NAME}"
if [ ! -f "$BUILT" ]; then
  echo "构建产物不存在: ${BUILT}" >&2
  exit 1
fi

# ── 安装 ──────────────────────────────────────────────────────
mkdir -p "$INSTALL_DIR"
cp "$BUILT" "${INSTALL_DIR}/${BIN_NAME}"
chmod +x "${INSTALL_DIR}/${BIN_NAME}"

echo ""
echo "✓ wx 已安装到 ${INSTALL_DIR}/${BIN_NAME}"
file "${INSTALL_DIR}/${BIN_NAME}" 2>/dev/null || true
echo ""
echo "快速开始："
echo "  sudo wx init                              # 首次初始化（微信须登录运行）"
echo "  sudo wx key extract --hook-seconds 90     # 缺分片密钥时补齐"
echo "  wx doctor                                 # 环境 / 密钥健康检查"
echo "  wx sessions                               # 查看最近会话"
echo "  wx --help"
echo ""
echo "Apple Silicon 上若只想抓取分片密钥，可用本仓库 tools/ 下的免 sudo 方案："
echo "  bash ${SRC_DIR}/tools/hook-attach.sh 300 && bash ${SRC_DIR}/tools/map-keys.sh"
