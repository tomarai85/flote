# Flote Sprint 6 生成物
# 用途: Windows 向けリリースビルドを行い、成果物を Zip にまとめる

param(
  [string]$Version,
  [switch]$Help
)

$ErrorActionPreference = 'Stop'

# 使い方を表示する
function Show-Usage {
  Write-Host "Usage:"
  Write-Host "  ./scripts/dist-win.ps1 [-Version x.y.z]"
  Write-Host "  ./scripts/dist-win.ps1 -Help"
  Write-Host ""
  Write-Host "Options:"
  Write-Host "  -Version <x.y.z>  Zip 名に埋め込むバージョンを指定します"
  Write-Host "  -Help             このヘルプを表示します"
}

# pubspec.yaml から既定バージョンを取得する
function Get-ResolvedVersion {
  $resolved = Get-Content pubspec.yaml |
    Select-String '^version:' |
    ForEach-Object { ($_ -split '\s+')[1] -split '\+' | Select-Object -First 1 } |
    Select-Object -First 1

  if ([string]::IsNullOrWhiteSpace($resolved)) {
    throw "pubspec.yaml からバージョンを取得できませんでした。"
  }

  return $resolved
}

if ($Help) {
  Show-Usage
  exit 0
}

# スクリプトの親ディレクトリである apps/flutter を作業場所にする
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$appDir = Split-Path -Parent $scriptDir
Set-Location $appDir

if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
  throw "flutter コマンドが見つかりません。PATH を確認してください。"
}

if ([string]::IsNullOrWhiteSpace($Version)) {
  $Version = Get-ResolvedVersion
}

if ([string]::IsNullOrWhiteSpace($Version)) {
  throw "バージョンが空です。-Version か pubspec.yaml を確認してください。"
}

$releasePath = Join-Path $appDir 'build/windows/x64/runner/Release'
$distDir = Join-Path $appDir 'dist'
$packageDir = Join-Path $distDir "flote-windows-v$Version"
$zipPath = Join-Path $distDir "flote-windows-v$Version.zip"

# Flutter の依存解決と Windows リリースビルドを実行する
Write-Host "==> flutter clean"
& flutter clean

Write-Host "==> flutter pub get"
& flutter pub get

Write-Host "==> flutter build windows --release"
& flutter build windows --release

if (-not (Test-Path $releasePath)) {
  throw "ビルド成果物が見つかりません: $releasePath"
}

# 配布用ディレクトリを作り直し、Release 一式をそのまま複製する
Write-Host "==> 配布用ディレクトリを準備"
if (Test-Path $packageDir) {
  Remove-Item -Recurse -Force $packageDir
}
New-Item -ItemType Directory -Force -Path $packageDir | Out-Null
Get-ChildItem -Path $releasePath -Force | Copy-Item -Destination $packageDir -Recurse -Force

# 既存 Zip を削除し、新しい配布物を圧縮する
Write-Host "==> Zip を作成"
if (Test-Path $zipPath) {
  Remove-Item -Force $zipPath
}
Compress-Archive -Path (Join-Path $packageDir '*') -DestinationPath $zipPath

if (-not (Test-Path $zipPath)) {
  throw "Zip が生成されませんでした: $zipPath"
}

# 配布確認のためにパス、サイズ、ハッシュを表示する
$zipItem = Get-Item $zipPath
$zipHash = Get-FileHash -Path $zipPath -Algorithm SHA256

Write-Host "==> 出力結果"
Write-Host ("Zip: {0}" -f $zipItem.FullName)
Write-Host ("サイズ: {0} bytes" -f $zipItem.Length)
Write-Host ("SHA-256: {0}" -f $zipHash.Hash)
