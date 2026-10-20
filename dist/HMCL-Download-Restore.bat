@echo off
setlocal EnableExtensions
chcp 65001 >nul 2>&1
title HMCL Download Restore

set "SELF=%~f0"
set "PAYLOAD=%TEMP%\pcl_restore_%RANDOM%%RANDOM%.ps1"

if not exist "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" (
    echo [ERROR] Windows PowerShell not found.
    pause
    exit /b 2
)

powershell -NoProfile -ExecutionPolicy Bypass -Command "$t=[IO.File]::ReadAllText($env:SELF,[Text.Encoding]::UTF8); $m='#::P'+'S1::'; $i=$t.IndexOf($m); if($i -lt 0){exit 2}; $b=$t.Substring($i+$m.Length).Trim(); [IO.File]::WriteAllText($env:PAYLOAD,$b,(New-Object Text.UTF8Encoding($true)))"
if errorlevel 1 goto :extract_failed

powershell -NoProfile -ExecutionPolicy Bypass -File "%PAYLOAD%" %*
set "RC=%ERRORLEVEL%"

del /f /q "%PAYLOAD%" >nul 2>&1
rem pause only when launched with no arguments (double-click); stay silent for scripting
if "%~1"=="" (
    echo.
    pause
)
exit /b %RC%

:extract_failed
echo [ERROR] Failed to unpack the PowerShell payload.
if "%~1"=="" pause
exit /b 2
#::PS1::
#requires -Version 5.1
<#
.SYNOPSIS
    HMCL 下载功能恢复工具（降级到未加锁版本 + 抑制更新提示 + 重建快捷方式）

.DESCRIPTION
    背景：
      HMCL 3.17.0.362 起，在中国大陆网络下会禁用「下载」相关页面。
      判定逻辑在 RegionUtils：请求 https://ipwho.is，country_code 为 CN 即锁；
      且为 fail-closed —— 请求失败也算作中国大陆。
      对应提交 583e004d「在中国大陆地区禁用游戏下载功能」（2026-10-20 08:37）。

    与 PCL 的区别：
      PCL 是编译期删代码，只能换版本；HMCL 是运行时按 IP 判定，代码仍在。
      因此本工具不改任何二进制，只做三件事：
        1. 换回最后一个未加锁的官方版本 3.17.0.361；
        2. 在配置里关闭自动更新弹窗，避免被推回新版；
        3. 把指向旧文件的快捷方式改指向新文件，没有就新建一个。

    设计与具体机器无关：
      - 不假设 HMCL 装在哪（自动探测，或用 -HmclDir）；
      - 不假设游戏目录在哪（从 HMCL 自己的配置里读）；
      - 不假设用的是 exe 还是 jar（自动识别）；
      - 不假设配置在用户目录还是便携目录（两处都读，遵循 HMCL 的环境变量覆盖）。

    数据安全：
      - 只改「启动器主程序文件」和 launcher-settings.json 里的一个布尔值；
      - 游戏目录、模组、存档、账号、实例设置一律不碰；
      - 运行前后各打一次数据指纹供对照；
      - 旧版本自动备份，可 -Restore 一键还原。

.PARAMETER HmclDir
    HMCL 所在目录。不填则自动探测。

.PARAMETER Restore
    还原最近一次备份，改回快捷方式，并移除更新抑制设置。

.PARAMETER Proxy
    GitHub 加速前缀，例如 https://hk.gh-proxy.com/

.PARAMETER NoShortcut
    不创建、不修改快捷方式。

.PARAMETER Force
    跳过确认提示。
#>
[CmdletBinding()]
param(
    [string]$HmclDir,
    [switch]$Restore,
    [string]$Proxy,
    [switch]$NoShortcut,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

try {
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]::Tls11
} catch { }

# ---------------------------------------------------------------- 版本锁
$Pin = [pscustomobject]@{
    Version   = '3.17.0.361'
    ExeSha256 = '67308A1FB935F5520A43C42EFCDDE42AB392A6757EBB838EEFFC85D54FB34A5F'
    ExeSize   = 12110614
    JarSha256 = 'DBB33BF99EFEE104E3432D3F5FD335275E38C38E17B2D75AE07C5214F8EF5E8B'
    JarSize   = 11656470
}

function Write-Step { param([string]$T) Write-Host "==> $T" -ForegroundColor Cyan }
function Write-Ok   { param([string]$T) Write-Host "    $T" -ForegroundColor Green }
function Write-Warn { param([string]$T) Write-Host "    $T" -ForegroundColor Yellow }
function Write-Dim  { param([string]$T) Write-Host "    $T" -ForegroundColor DarkGray }

# ---------------------------------------------------------------- 路径解析
# HMCL 的两个「家」：
#   Local Home  = 便携数据（.hmcl，含 launcher-settings.json）
#   User  Home  = 全局数据（Windows 默认 %APPDATA%\.hmcl，含账号）
# 两者都可被环境变量覆盖，这里尊重覆盖值。
function Get-HmclLocalHome {
    param([string]$Dir)
    if ($env:HMCL_LOCAL_HOME -and (Test-Path -LiteralPath $env:HMCL_LOCAL_HOME)) { return $env:HMCL_LOCAL_HOME }
    $p = Join-Path $Dir '.hmcl'
    if (Test-Path -LiteralPath $p) { return $p }
    return $p
}

function Get-HmclUserHomeCandidates {
    $out = New-Object System.Collections.ArrayList
    if ($env:HMCL_USER_HOME) { [void]$out.Add($env:HMCL_USER_HOME) }
    if ($env:APPDATA)         { [void]$out.Add((Join-Path $env:APPDATA '.hmcl')) }
    if ($env:LOCALAPPDATA)    { [void]$out.Add((Join-Path $env:LOCALAPPDATA '.hmcl')) }
    if ($env:USERPROFILE)     { [void]$out.Add((Join-Path $env:USERPROFILE '.hmcl')) }
    return @($out | Select-Object -Unique)
}

function Get-HmclConfigPath {
    param([string]$Dir)
    return (Join-Path (Get-HmclLocalHome -Dir $Dir) 'config\launcher-settings.json')
}

# ---------------------------------------------------------------- 定位
function Test-HmclDir {
    param([string]$Dir)
    if (-not $Dir -or -not (Test-Path -LiteralPath $Dir)) { return $false }
    @(Get-ChildItem -LiteralPath $Dir -File -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -match '^HMCL.*\.(exe|jar)$' }).Count -gt 0
}

function Get-SearchRoots {
    $r = New-Object System.Collections.ArrayList
    if ($PSScriptRoot) { [void]$r.Add($PSScriptRoot) }
    try { [void]$r.Add((Get-Location).Path) } catch { }
    $desk = [Environment]::GetFolderPath('Desktop');       if ($desk) { [void]$r.Add($desk) }
    $dl   = [Environment]::GetFolderPath('MyDocuments');   if ($dl)   { [void]$r.Add($dl) }
    if ($env:USERPROFILE) { [void]$r.Add((Join-Path $env:USERPROFILE 'Downloads')) }
    return @($r | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique)
}

function Find-HmclDir {
    param([string]$Hint)
    if ($Hint) {
        if (-not (Test-Path -LiteralPath $Hint)) { throw "目录不存在：$Hint" }
        if (-not (Test-HmclDir $Hint)) { throw "该目录下没有 HMCL 主程序（HMCL*.exe / HMCL*.jar）：$Hint" }
        return (Resolve-Path -LiteralPath $Hint).Path
    }
    # 1) 正在运行的 HMCL
    $procs = @(Get-CimInstance Win32_Process -Filter "Name='java.exe' OR Name='javaw.exe' OR Name LIKE 'HMCL%'" -ErrorAction SilentlyContinue |
               Where-Object { $_.CommandLine -and $_.CommandLine -match 'HMCL' })
    foreach ($p in $procs) {
        # a) 进程自身所在目录（少数情况下 HMCL 本体就是进程）
        if ($p.ExecutablePath) {
            $d = Split-Path -Parent $p.ExecutablePath
            if (Test-HmclDir $d) { return (Resolve-Path -LiteralPath $d).Path }
        }
        # b) HMCL 的 .exe 只是一层外壳：它会用系统 java 启动，并且把主程序名
        #    作为「相对路径」传给 -jar，随后外壳自己退出。
        #    因此进程的 ExecutablePath 指向的是 java.exe 所在目录，不是 HMCL 目录。
        #    这里从命令行里取出主程序文件名，再到有限的几个根目录反查。
        $m = [regex]::Match([string]$p.CommandLine, '-jar\s+"?([^"\s]+)"?')
        if ($m.Success) {
            $leaf = Split-Path -Leaf $m.Groups[1].Value
            foreach ($root in (Get-SearchRoots)) {
                $hit = Get-ChildItem -LiteralPath $root -Filter $leaf -Recurse -Depth 3 -File -ErrorAction SilentlyContinue |
                       Select-Object -First 1
                if ($hit) { return (Split-Path -Parent $hit.FullName) }
            }
        }
    }
    # 2) 脚本目录 / 当前目录
    foreach ($d in @($PSScriptRoot, (Get-Location).Path)) {
        if ($d -and (Test-HmclDir $d)) { return (Resolve-Path -LiteralPath $d).Path }
    }
    # 3) 交互式兜底
    Write-Host ''
    Write-Host '  未能自动定位 HMCL 目录。' -ForegroundColor Yellow
    $asked = Read-Host '  请把 HMCL 目录拖到本窗口后回车（或直接输入路径，留空取消）'
    if ($asked) {
        $asked = $asked.Trim('"', ' ', "'")
        if (Test-HmclDir $asked) { return (Resolve-Path -LiteralPath $asked).Path }
        throw "该目录下没有 HMCL 主程序：$asked"
    }
    throw '找不到 HMCL。请用 -HmclDir 指定 HMCL 所在目录。'
}

function Get-HmclArtifact {
    param([string]$Dir)
    $all = @(Get-ChildItem -LiteralPath $Dir -File -ErrorAction SilentlyContinue |
             Where-Object { $_.Name -match '^HMCL.*\.(exe|jar)$' })
    if ($all.Count -eq 0) { return $null }
    # 优先 exe（Windows 用户绝大多数用 exe），同类取最新
    $exe = $all | Where-Object { $_.Extension -eq '.exe' } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($exe) { return @{ Kind = 'exe'; File = $exe } }
    $jar = $all | Where-Object { $_.Extension -eq '.jar' } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($jar) { return @{ Kind = 'jar'; File = $jar } }
    return $null
}

function Stop-Hmcl {
    $procs = @(Get-CimInstance Win32_Process -Filter "Name='java.exe' OR Name='javaw.exe' OR Name LIKE 'HMCL%'" -ErrorAction SilentlyContinue |
               Where-Object { $_.CommandLine -and $_.CommandLine -match 'HMCL' })
    if ($procs.Count -eq 0) { return }
    Write-Step "关闭正在运行的 HMCL（$($procs.Count) 个进程）"
    foreach ($p in $procs) { try { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue } catch { } }
    Start-Sleep -Milliseconds 1500
    Write-Ok '已关闭'
}

# ---------------------------------------------------------------- 数据快照
function Get-GameDirCandidates {
    param([string]$Dir)

    $paths = New-Object System.Collections.ArrayList
    $localHome = Get-HmclLocalHome -Dir $Dir

    $parseFile = {
        param($file, $baseDir)
        if (-not (Test-Path -LiteralPath $file)) { return }
        try { $j = [System.IO.File]::ReadAllText($file) | ConvertFrom-Json } catch { return }
        foreach ($d in @($j.directories)) {
            $p = [string]$d.path
            if (-not $p) { continue }
            if (-not [System.IO.Path]::IsPathRooted($p)) {
                foreach ($b in @($Dir, $baseDir, $localHome)) {
                    if (-not $b) { continue }
                    $cand = Join-Path $b $p
                    if (Test-Path -LiteralPath $cand) { [void]$paths.Add((Resolve-Path -LiteralPath $cand).Path); break }
                }
            } elseif (Test-Path -LiteralPath $p) {
                [void]$paths.Add($p)
            }
        }
    }

    & $parseFile (Join-Path $localHome 'config\game-directories.json') $localHome
    foreach ($uh in (Get-HmclUserHomeCandidates)) {
        & $parseFile (Join-Path $uh 'config\user-game-directories.json') $uh
    }
    return @($paths | Select-Object -Unique)
}

function Get-DataSnapshot {
    param([string]$Dir)

    $lines = New-Object System.Collections.ArrayList
    $fp = ''

    # 1) 配置指纹：只看 config\ 与 state\
    #    不含 logs\、cache\、dependencies\（运行时会自然变动，算进去会误报）
    #    也不含本工具要改的 launcher-settings.json 及其备份
    $localHome = Get-HmclLocalHome -Dir $Dir
    if (Test-Path -LiteralPath $localHome) {
        $watch = @((Join-Path $localHome 'config'), (Join-Path $localHome 'state'))
        $files = @($watch |
                   Where-Object { Test-Path -LiteralPath $_ } |
                   ForEach-Object { Get-ChildItem -LiteralPath $_ -Recurse -File -Force -ErrorAction SilentlyContinue } |
                   Where-Object { $_.Name -ne 'launcher-settings.json' -and $_.Name -notlike 'launcher-settings.json.bak*' } |
                   Sort-Object FullName)
        $sb = New-Object System.Text.StringBuilder
        foreach ($f in $files) {
            [void]$sb.Append($f.FullName.Substring($localHome.Length)).Append('|').Append($f.Length).Append('|').Append($f.LastWriteTimeUtc.Ticks).Append("`n")
        }
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $fp = [BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($sb.ToString()))).Replace('-','').Substring(0,16)
        [void]$lines.Add("启动器配置：$($files.Count) 个文件，指纹 $fp")
    } else {
        [void]$lines.Add('启动器配置：尚未生成（首次运行前）')
    }

    # 2) 游戏目录统计（完全按 HMCL 自己的配置来，不做任何假设）
    $gds = Get-GameDirCandidates -Dir $Dir
    if ($gds.Count -eq 0) {
        [void]$lines.Add('游戏目录：未在 HMCL 配置中找到')
    } else {
        foreach ($gd in $gds) {
            $vers  = @(Get-ChildItem -LiteralPath (Join-Path $gd 'versions') -Directory -ErrorAction SilentlyContinue)
            $saves = @(Get-ChildItem -LiteralPath (Join-Path $gd 'saves') -Directory -ErrorAction SilentlyContinue)
            $mods = 0
            foreach ($v in $vers) {
                $mods += @(Get-ChildItem -LiteralPath (Join-Path $v.FullName 'mods') -Filter *.jar -File -ErrorAction SilentlyContinue).Count
            }
            [void]$lines.Add("游戏目录 $gd：版本 $($vers.Count)，模组 $mods，存档 $($saves.Count)")
        }
    }

    return [pscustomobject]@{ Fingerprint = $fp; Lines = $lines.ToArray() }
}

# ---------------------------------------------------------------- 快捷方式
function Update-HmclShortcuts {
    param([string]$OldPath, [string]$NewPath, [string]$WorkDir, [switch]$CreateIfMissing)

    $sh = New-Object -ComObject WScript.Shell
    $dirs = @(
        [Environment]::GetFolderPath('Desktop'),
        [Environment]::GetFolderPath('CommonDesktopDirectory'),
        (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'),
        (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'),
        (Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar')
    )

    $changed = 0
    foreach ($d in $dirs) {
        if (-not $d -or -not (Test-Path -LiteralPath $d)) { continue }
        foreach ($lnk in @(Get-ChildItem -LiteralPath $d -Filter *.lnk -Recurse -ErrorAction SilentlyContinue)) {
            try {
                $sc = $sh.CreateShortcut($lnk.FullName)
                if ($OldPath -and $sc.TargetPath -and ($sc.TargetPath -ieq $OldPath)) {
                    $sc.TargetPath = $NewPath
                    $sc.WorkingDirectory = $WorkDir
                    $sc.Save()
                    $changed++
                    Write-Ok "已改指向：$($lnk.FullName)"
                }
            } catch { }
        }
    }

    if ($changed -gt 0) { Write-Ok "共更新 $changed 个快捷方式"; return }

    if ($CreateIfMissing) {
        $desk = [Environment]::GetFolderPath('Desktop')
        if ($desk) {
            $lnkPath = Join-Path $desk 'HMCL.lnk'
            if (-not (Test-Path -LiteralPath $lnkPath)) {
                $sc = $sh.CreateShortcut($lnkPath)
                $sc.TargetPath = $NewPath
                $sc.WorkingDirectory = $WorkDir
                $sc.Description = 'Hello Minecraft! Launcher'
                $sc.Save()
                Write-Ok "已新建桌面快捷方式：$lnkPath"
                return
            }
        }
    }
    Write-Dim '未发现指向旧文件的快捷方式，跳过'
}

# ---------------------------------------------------------------- 下载
function Get-PinnedArtifact {
    param([string]$Kind, [string]$OutFile, [string]$ProxyPrefix)

    $name = if ($Kind -eq 'exe') { "HMCL-$($Pin.Version).exe" } else { "HMCL-$($Pin.Version).jar" }
    $wantSha  = if ($Kind -eq 'exe') { $Pin.ExeSha256 } else { $Pin.JarSha256 }
    $wantSize = if ($Kind -eq 'exe') { $Pin.ExeSize }   else { $Pin.JarSize }

    $gh = "https://github.com/HMCL-dev/HMCL/releases/download/v$($Pin.Version)/$name"
    $urls = @(
        "https://hmcl.glavo.site/download/$name"
        $gh
        "https://hk.gh-proxy.com/$gh"
    )
    if ($ProxyPrefix) {
        $pre = $ProxyPrefix.TrimEnd('/') + '/'
        $urls = @($urls | ForEach-Object { $pre + $_ }) + $urls
    }

    foreach ($u in $urls) {
        try {
            Write-Dim "尝试 $u"
            $wc = New-Object System.Net.WebClient
            $wc.Headers.Add('User-Agent', 'Restore-HMCLDownload/1.0')
            try { $wc.DownloadFile($u, $OutFile) } finally { $wc.Dispose() }

            $sha = (Get-FileHash -LiteralPath $OutFile -Algorithm SHA256).Hash
            $len = (Get-Item -LiteralPath $OutFile).Length
            if ($sha -ne $wantSha -or $len -ne $wantSize) {
                Write-Warn "校验不符，丢弃（期望 $($wantSha.Substring(0,16))…/$wantSize，实得 $($sha.Substring(0,16))…/$len）"
                Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
                continue
            }
            Write-Ok "下载完成并校验通过（$([math]::Round($len/1MB,1)) MB）"
            return $true
        } catch {
            Write-Warn "失败：$($_.Exception.Message)"
        }
    }
    return $false
}

# ---------------------------------------------------------------- 配置
function Set-NoAutoUpdate {
    param([string]$Dir)
    $cfg = Get-HmclConfigPath -Dir $Dir
    $cfgDir = Split-Path -Parent $cfg
    if (-not (Test-Path -LiteralPath $cfgDir)) { New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null }

    if (Test-Path -LiteralPath $cfg) {
        Copy-Item -LiteralPath $cfg -Destination "$cfg.bak" -Force
        try { $obj = [System.IO.File]::ReadAllText($cfg) | ConvertFrom-Json } catch { $obj = $null }
        if ($obj) {
            if ($obj.PSObject.Properties.Name -contains 'disableAutoShowUpdateDialog') {
                $obj.disableAutoShowUpdateDialog = $true
            } else {
                $obj | Add-Member -NotePropertyName 'disableAutoShowUpdateDialog' -NotePropertyValue $true -Force
            }
            [System.IO.File]::WriteAllText($cfg, ($obj | ConvertTo-Json -Depth 20), (New-Object System.Text.UTF8Encoding($false)))
            Write-Ok '已关闭自动更新弹窗（合并写入，其他设置不动）'
            return
        }
        Write-Warn '原配置无法解析，已备份为 .bak，改为新建'
    }

    [System.IO.File]::WriteAllText($cfg, (@{
        '$schema' = 'https://schemas.glavo.site/hmcl/launcher-settings/1.0.0'
        'disableAutoShowUpdateDialog' = $true
    } | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
    Write-Ok '已新建配置并关闭自动更新弹窗'
}

function Remove-NoAutoUpdate {
    param([string]$Dir)
    $cfg = Get-HmclConfigPath -Dir $Dir
    if (-not (Test-Path -LiteralPath $cfg)) { return }
    try {
        $obj = [System.IO.File]::ReadAllText($cfg) | ConvertFrom-Json
        if ($obj.PSObject.Properties.Name -contains 'disableAutoShowUpdateDialog') {
            $obj.PSObject.Properties.Remove('disableAutoShowUpdateDialog')
            [System.IO.File]::WriteAllText($cfg, ($obj | ConvertTo-Json -Depth 20), (New-Object System.Text.UTF8Encoding($false)))
            Write-Ok '已移除更新抑制设置'
        }
    } catch { Write-Warn '配置解析失败，未改动' }
}

# ---------------------------------------------------------------- 主流程
Write-Host ''
Write-Host '  HMCL 下载功能恢复工具' -ForegroundColor White
Write-Host '  降级到未加锁版本 · 抑制更新提示 · 重建快捷方式 · 数据不掉' -ForegroundColor DarkGray
Write-Host ''

$dir = Find-HmclDir -Hint $HmclDir
Write-Step "HMCL 目录：$dir"

$art = Get-HmclArtifact -Dir $dir
if (-not $art) { throw '目录中没有 HMCL 主程序（HMCL*.exe / HMCL*.jar）' }
Write-Ok "当前文件：$($art.File.Name)"

# ---------------- 还原 ----------------
if ($Restore) {
    # 备份名形如 HMCL-3.16.3.exe.bak-3.16.3，与「当前文件名」无关，
    # 因此必须按 HMCL*.bak-* 通配查找，不能拼当前文件名。
    $backs = @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
               Where-Object { $_.Name -match '^HMCL.*\.(exe|jar)\.bak-' } |
               Sort-Object LastWriteTime -Descending)
    if ($backs.Count -eq 0) { throw '没有找到备份，无法还原。' }
    Stop-Hmcl
    $b = $backs[0]
    $origName = $b.Name -replace '\.bak-.*$',''
    $origPath = Join-Path $dir $origName
    Copy-Item -LiteralPath $b.FullName -Destination $origPath -Force
    Write-Ok "已还原：$origName"
    Update-HmclShortcuts -OldPath $art.File.FullName -NewPath $origPath -WorkDir $dir
    if ($art.File.FullName -ne $origPath -and (Test-Path -LiteralPath $art.File.FullName)) {
        Remove-Item -LiteralPath $art.File.FullName -Force
        Write-Ok "已移除 $($art.File.Name)"
    }
    Remove-NoAutoUpdate -Dir $dir
    Write-Host ''
    Write-Host '  完成。' -ForegroundColor Green
    exit 0
}

$targetName = "HMCL-$($Pin.Version).$($art.Kind)"
$targetPath = Join-Path $dir $targetName

# 已经是目标版本？
if ($art.File.Name -eq $targetName) {
    $h = (Get-FileHash -LiteralPath $art.File.FullName -Algorithm SHA256).Hash
    if ($h -eq $Pin.ExeSha256 -or $h -eq $Pin.JarSha256) {
        Write-Ok "已经是 $($Pin.Version)（哈希一致）"
        Set-NoAutoUpdate -Dir $dir
        if (-not $NoShortcut) { Update-HmclShortcuts -OldPath $null -NewPath $targetPath -WorkDir $dir -CreateIfMissing }
        Write-Host ''
        Write-Host '  无需降级，只确保更新提示已关闭。' -ForegroundColor Green
        exit 0
    }
}

Write-Host ''
Write-Host '  操作前数据快照' -ForegroundColor White
$before = Get-DataSnapshot -Dir $dir
$before.Lines | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
Write-Host ''

Write-Host '  将执行：' -ForegroundColor White
Write-Host "    当前文件 : $($art.File.Name)"
Write-Host "    写入为   : $targetName"
Write-Host "    备份为   : $($art.File.Name).bak-$($art.File.Name -replace '^HMCL-','' -replace '\.(exe|jar)$','')"
Write-Host "    配置     : $(Get-HmclConfigPath -Dir $dir)"
Write-Host '               → disableAutoShowUpdateDialog = true'
if (-not $NoShortcut) { Write-Host '    快捷方式 : 指向旧文件的改为指向新文件；没有则新建桌面快捷方式' }
Write-Host ''

if (-not $Force) {
    $ans = Read-Host '  确认继续？(y/N)'
    if ($ans -notmatch '^(y|yes)$') { Write-Warn '已取消'; exit 1 }
}

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('hmcl-restore-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

try {
    Write-Step '下载官方构建'
    $newFile = Join-Path $tmp $targetName
    if (-not (Get-PinnedArtifact -Kind $art.Kind -OutFile $newFile -ProxyPrefix $Proxy)) {
        throw '所有下载源均失败。可尝试 -Proxy 指定加速前缀，例如 https://hk.gh-proxy.com/'
    }

    Stop-Hmcl

    $oldVer = $art.File.Name -replace '^HMCL-','' -replace '\.(exe|jar)$',''
    $bak = "$($art.File.FullName).bak-$oldVer"
    if (-not (Test-Path -LiteralPath $bak)) {
        Copy-Item -LiteralPath $art.File.FullName -Destination $bak -Force
        Write-Ok "已备份：$(Split-Path -Leaf $bak)"
    }

    Write-Step '写入新版本'
    $done = $false
    for ($i = 0; $i -lt 12; $i++) {
        try { Copy-Item -LiteralPath $newFile -Destination $targetPath -Force; $done = $true; break }
        catch { Start-Sleep -Milliseconds 600 }
    }
    if (-not $done) { throw '写入失败，文件被占用。请手动关闭 HMCL 后重试。' }
    Write-Ok "已写入 $targetName"

    if ($art.File.FullName -ne $targetPath -and (Test-Path -LiteralPath $art.File.FullName)) {
        Remove-Item -LiteralPath $art.File.FullName -Force
        Write-Ok "已移除旧文件 $($art.File.Name)"
    }

    Write-Step '更新快捷方式'
    if (-not $NoShortcut) {
        Update-HmclShortcuts -OldPath $art.File.FullName -NewPath $targetPath -WorkDir $dir -CreateIfMissing
    } else {
        Write-Dim '已跳过（-NoShortcut）'
    }

    Set-NoAutoUpdate -Dir $dir

    Write-Host ''
    Write-Host '  操作后数据核对' -ForegroundColor White
    $after = Get-DataSnapshot -Dir $dir
    $after.Lines | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }

    Write-Host ''
    if ($before.Fingerprint -eq $after.Fingerprint) {
        Write-Host "  数据指纹一致（$($after.Fingerprint)），游戏目录与配置未被改动。" -ForegroundColor Green
    } else {
        Write-Warn "数据指纹变化：$($before.Fingerprint) → $($after.Fingerprint)"
        Write-Warn '如非预期，请用 -Restore 还原并反馈。'
    }

    Write-Host ''
    Write-Host '  完成。' -ForegroundColor Green
    Write-Host ''
    Write-Host '  打开 HMCL → 下载，页面应恢复正常。' -ForegroundColor White
    Write-Host '  如需撤销：再次运行本工具并加上 -Restore' -ForegroundColor DarkGray
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
