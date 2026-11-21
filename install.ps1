# wx-cli Windows installer (source build)
# Run with: irm https://raw.githubusercontent.com/rinh/wx-cli-again/main/install.ps1 | iex
#
# 本 fork 不发布预编译二进制（上游 botiverse/wx-cli 为 private），
# 因此改为从源码构建：clone → cargo build --release → 安装并加入用户 PATH。

$ErrorActionPreference = "Stop"

$Repo    = "rinh/wx-cli-again"
$RepoUrl = "https://github.com/$Repo.git"
$BinName = "wx.exe"
$InstallDir = "$env:LOCALAPPDATA\wx-cli"
$SrcDir = "$env:LOCALAPPDATA\wx-cli-src"

# ── 前置依赖 ──────────────────────────────────────────────────
if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
    Write-Error "缺少 cargo，请先安装 Rust: https://rustup.rs"
    exit 1
}
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Error "缺少 git，请先安装 Git for Windows"
    exit 1
}

# ── 取源码 ────────────────────────────────────────────────────
if (Test-Path (Join-Path $SrcDir ".git")) {
    Write-Host "==> 更新已有 clone: $SrcDir"
    git -C $SrcDir pull --ff-only
} else {
    Write-Host "==> 克隆源码到 $SrcDir"
    git clone --depth 1 $RepoUrl $SrcDir
}

# ── 构建 ──────────────────────────────────────────────────────
Write-Host "==> 编译中（首次构建需现场编译 OpenSSL + SQLCipher，约 2-5 分钟）..."
Push-Location $SrcDir
try {
    cargo build --release
} finally {
    Pop-Location
}

$Built = Join-Path $SrcDir "target\release\$BinName"
if (-not (Test-Path $Built)) {
    Write-Error "构建产物不存在: $Built"
    exit 1
}

# ── 安装 ──────────────────────────────────────────────────────
if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir | Out-Null
}
Copy-Item -Force $Built (Join-Path $InstallDir $BinName)

# ── 加入 PATH（当前用户） ────────────────────────────────────
$UserPath = [Environment]::GetEnvironmentVariable("PATH", "User")
if ($UserPath -notlike "*$InstallDir*") {
    [Environment]::SetEnvironmentVariable("PATH", "$UserPath;$InstallDir", "User")
    Write-Host "已将 $InstallDir 加入用户 PATH（重新打开终端生效）"
}

Write-Host ""
Write-Host "✓ wx 已安装到 $InstallDir\$BinName"
Write-Host ""
Write-Host "快速开始（以管理员身份运行）："
Write-Host "  wx init       # 首次初始化（需要微信正在运行）"
Write-Host "  wx sessions   # 查看最近会话"
Write-Host "  wx --help     # 查看所有命令"
