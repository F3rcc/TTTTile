#Requires -Version 5.1
<#
.SYNOPSIS
    安装 TTTTile（自签名 sideload 包）。

.DESCRIPTION
    Windows 只认「manifest 里的 Publisher 字符串」与「签名证书 Subject」是否一致，
    所以必须先把 TTTTile.cer 导入「本地计算机\受信任人」，否则安装会报
    0x800B0109 / 0x80073CF0。

    本脚本会：
      1. 检查管理员权限（没有则自动提权）
      2. 导入 TTTTile.cer 到 Cert:\LocalMachine\TrustedPeople（已存在则跳过）
      3. 安装 Dependencies 目录下的框架包（VCLibs / .NET Native）
      4. 安装主包（.appxbundle 或 .appx）

.PARAMETER PackagePath
    主包路径。默认在脚本目录及子目录里自动找 *.appxbundle / *.appx。

.PARAMETER CertificatePath
    证书路径。默认找脚本目录下的 TTTTile.cer。

.PARAMETER Uninstall
    卸载应用（同时可选删除受信任的证书）。

.PARAMETER RemoveCertificate
    配合 -Uninstall 使用：卸载后一并从 TrustedPeople 移除证书。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Install.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Install.ps1 -Uninstall

.NOTES
    证书 SHA-256 指纹：CB:86:17:09:21:FA:62:FB:9C:1A:2E:3C:D0:AB:60:F5:65:59:D0:AB:9C:CB:EE:AD:4F:E4:3B:FF:B5:B3:4D:94
    安装前请核对指纹，不要信任来源不明的同名证书。
#>
[CmdletBinding()]
param(
    [string]$PackagePath,
    [string]$CertificatePath,
    [switch]$Uninstall,
    [switch]$RemoveCertificate
)

$ErrorActionPreference = 'Stop'

$PackageName      = '46e79dbd-6853-4213-a215-84f6e22fb6b0'
$ExpectedSubject  = 'CN=F3rcc'
$ExpectedSha256   = 'CB86170921FA62FB9C1A2E3CD0AB60F56559D0AB9CCBEEAD4FE43BFFB5B34D94'
$Root             = $PSScriptRoot

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdmin)) {
    Write-Host '需要管理员权限，正在提权...' -ForegroundColor Yellow
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', "-File `"$PSCommandPath`"")
    if ($PackagePath)     { $argList += @('-PackagePath', "`"$PackagePath`"") }
    if ($CertificatePath) { $argList += @('-CertificatePath', "`"$CertificatePath`"") }
    if ($Uninstall)       { $argList += '-Uninstall' }
    if ($RemoveCertificate) { $argList += '-RemoveCertificate' }
    Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs -Wait
    exit $LASTEXITCODE
}

function Find-FirstFile([string]$Pattern) {
    Get-ChildItem -Path $Root -Recurse -File -Filter $Pattern -ErrorAction SilentlyContinue |
        Sort-Object FullName | Select-Object -First 1 -ExpandProperty FullName
}

# ---------- 卸载 ----------
if ($Uninstall) {
    $pkg = Get-AppxPackage -Name $PackageName -ErrorAction SilentlyContinue
    if ($pkg) {
        Write-Host "卸载 $($pkg.PackageFullName) ..." -ForegroundColor Cyan
        Remove-AppxPackage -Package $pkg.PackageFullName
        Write-Host '已卸载。' -ForegroundColor Green
    } else {
        Write-Host '未安装，无需卸载。' -ForegroundColor Yellow
    }

    if ($RemoveCertificate) {
        $thumb = 'CDB3C7803C6ECD5E1FE511A03FA4DA6CDD2216EA'
        $store = 'Cert:\LocalMachine\TrustedPeople'
        $c = Get-ChildItem $store | Where-Object Thumbprint -eq $thumb
        if ($c) {
            Remove-Item -Path "$store\$thumb" -Force
            Write-Host '证书已从受信任人存储移除。' -ForegroundColor Green
        }
    }
    return
}

# ---------- 找包 ----------
if (-not $PackagePath) { $PackagePath = Find-FirstFile '*.appxbundle' }
if (-not $PackagePath) { $PackagePath = Find-FirstFile '*.appx' }
if (-not $PackagePath) { throw "在 $Root 下找不到 *.appxbundle / *.appx，请用 -PackagePath 指定。" }
if (-not (Test-Path $PackagePath)) { throw "包不存在：$PackagePath" }
$PackagePath = (Resolve-Path $PackagePath).Path

# ---------- 导入证书 ----------
if (-not $CertificatePath) {
    if (Test-Path (Join-Path $Root 'TTTTile.cer')) {
        $CertificatePath = Join-Path $Root 'TTTTile.cer'
    } else {
        $CertificatePath = Find-FirstFile '*.cer'
    }
}
if (-not $CertificatePath -or -not (Test-Path $CertificatePath)) {
    throw "找不到 .cer 证书文件，请用 -CertificatePath 指定。"
}
$CertificatePath = (Resolve-Path $CertificatePath).Path

$cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 $CertificatePath
$sha256 = $cert.GetCertHashString('SHA256')
if ($cert.Subject -ne $ExpectedSubject) {
    throw "证书 Subject 是 '$($cert.Subject)'，预期 '$ExpectedSubject'，拒绝安装。"
}
if ($sha256 -ne $ExpectedSha256) {
    $pretty = ($sha256 -replace '(.{2})(?!$)', '$1')
    throw "证书 SHA-256 指纹不匹配！`n  实际：$pretty`n  预期：$ExpectedSha256`n若你确认这是你自己重签的证书，请更新脚本里的 ExpectedSha256。"
}

$store = 'Cert:\LocalMachine\TrustedPeople'
if (Get-ChildItem $store | Where-Object Thumbprint -eq $cert.Thumbprint) {
    Write-Host '证书已在受信任人存储中，跳过导入。' -ForegroundColor DarkGray
} else {
    Write-Host "导入证书到 $store ..." -ForegroundColor Cyan
    Import-Certificate -FilePath $CertificatePath -CertStoreLocation $store | Out-Null
}

# ---------- 安装依赖 ----------
$deps = Get-ChildItem -Path (Split-Path $PackagePath) -Recurse -Directory -Filter 'Dependencies' -ErrorAction SilentlyContinue |
        Select-Object -First 1
if ($deps) {
    $arch = if ([Environment]::Is64BitOperatingSystem) { 'x64' } else { 'x86' }
    $depFiles = Get-ChildItem -Path $deps.FullName -Recurse -Filter '*.appx' |
                Where-Object { $_.FullName -match "\\$arch\\" -or $_.Directory.Name -eq $arch }
    foreach ($d in $depFiles) {
        Write-Host "安装依赖 $($d.Name) ..." -ForegroundColor DarkGray
        try { Add-AppxPackage -Path $d.FullName -ErrorAction Stop }
        catch { Write-Host "  跳过（$($_.Exception.Message.Split([Environment]::NewLine)[0])）" -ForegroundColor DarkYellow }
    }
}

# ---------- 安装主包 ----------
Write-Host "安装 $([IO.Path]::GetFileName($PackagePath)) ..." -ForegroundColor Cyan
try {
    Add-AppxPackage -Path $PackagePath -ForceApplicationShutdown -ErrorAction Stop
} catch {
    Write-Host ''
    Write-Host '安装失败。常见原因：' -ForegroundColor Red
    Write-Host '  1) 已安装上游 CN=Zhang 版本 → 先运行本脚本 -Uninstall 再装' -ForegroundColor Yellow
    Write-Host '  2) 系统禁止旁加载 → 设置 → 更新和安全 → 开发者选项 → 旁加载应用' -ForegroundColor Yellow
    throw
}

$installed = Get-AppxPackage -Name $PackageName
if ($installed) {
    Write-Host ''
    Write-Host "安装成功：$($installed.PackageFullName)" -ForegroundColor Green
    Write-Host "版本：$($installed.Version)   发布者：$($installed.Publisher)" -ForegroundColor Green
} else {
    throw 'Add-AppxPackage 未报错，但查询不到已安装的包，请检查事件查看器。'
}
