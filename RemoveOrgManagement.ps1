﻿[CmdletBinding()]
param()

$ErrorActionPreference = "Continue"
$OutputEncoding = [System.Text.Encoding]::UTF8

$ScriptDir = if ($MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path } else { $PWD.Path }
$BackupDir = Join-Path $ScriptDir "OrgManageFix_Backup_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
$LogFile = Join-Path $ScriptDir "OrgManageFix_Log_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$ts] [$Level] $message"
    Write-Host $entry
    Add-Content -Path $LogFile -Value $entry -Encoding UTF8
}

function Backup-RegistryKey {
    param([string]$RegPath, [string]$BackupFile)
    try {
        reg export "$RegPath" "$BackupFile" /y 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Log "  已备份: $RegPath" "OK"; return $true }
        else { return $false }
    } catch { return $false }
}

function Remove-RegistryKeySafe {
    param([string]$RegPath)
    try {
        reg delete "$RegPath" /f 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Log "  已删除: $RegPath" "OK"; return $true }
        else { Write-Log "  跳过(不存在): $RegPath" "WARN"; return $false }
    } catch { Write-Log "  删除失败: $RegPath" "ERROR"; return $false }
}

function Show-Banner {
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "  Windows '由你的组织管理' 彻底清除工具 v3.0" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  本脚本将彻底清除所有'由组织管理'的来源:" -ForegroundColor Yellow
    Write-Host "" 
    Write-Host "  [系统设置] 组策略注册表、CloudDomainInfo、WindowsSelfHost" -ForegroundColor White
    Write-Host "  [防火墙]   防火墙组织策略 + 重置防火墙规则" -ForegroundColor White
    Write-Host "  [浏览器]   Edge/Chrome 组织策略" -ForegroundColor White
    Write-Host "  [Defender] 禁用杀毒策略值" -ForegroundColor White
    Write-Host "  [隐私]     数据收集策略、定位服务限制" -ForegroundColor White
    Write-Host "  [更新]     Windows Update 限制策略" -ForegroundColor White
    Write-Host "  [账户]     MDM注册信息、工作/学校账户残留" -ForegroundColor White
    Write-Host "  [组策略]   本地GPO缓存文件清理+重置" -ForegroundColor White
    Write-Host ""
    Write-Host "  !!! 警告 !!!" -ForegroundColor Red
    Write-Host "  如果电脑是公司/学校资产，请先咨询IT管理员！" -ForegroundColor Red
    Write-Host ""
    Write-Host "  安全保障: 自动创建还原点 + 全量注册表备份 + 一键回滚脚本" -ForegroundColor Green
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host ""
}

function Test-Administrator {
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Step-RestorePoint {
    Write-Host ""
    Write-Host "====== 步骤 1: 创建系统还原点 ======" -ForegroundColor Cyan
    $c = Read-Host "是否创建还原点? (Y/n)"
    if ($c -match '^[nN]') {
        Write-Log "跳过还原点" "WARN"
        if ((Read-Host "确定继续? (y/N)") -ne 'y') { exit 0 }
        return
    }
    try {
        Enable-ComputerRestore -Drive "C:\" -ErrorAction SilentlyContinue
        Checkpoint-Computer -Description "OrgManage_v3_$(Get-Date -Format 'yyyyMMdd_HHmmss')" -RestorePointType MODIFY_SETTINGS
        Write-Log "还原点创建成功!" "OK"
        Write-Host "  还原点已创建!" -ForegroundColor Green
    } catch {
        Write-Log "还原点失败: $($_.Exception.Message)" "ERROR"
        if ((Read-Host "继续? (y/N)") -ne 'y') { exit 0 }
    }
}

function Step-Diagnose {
    Write-Host ""
    Write-Host "====== 步骤 2: 全面诊断 ======" -ForegroundColor Cyan
    Write-Host ""

    Write-Log "--- 诊断开始 ---"

    Write-Host "  [1] Azure AD / MDM / 域状态..." -ForegroundColor White
    try {
        $out = dsregcmd /status 2>&1
        foreach ($item in @(
            @{Name="AzureAdJoined"; Pattern="AzureAdJoined\s*:\s*YES"},
            @{Name="MDM Enrolled"; Pattern="MdmEnrolled\s*:\s*YES"},
            @{Name="Workplace Joined"; Pattern="WorkplaceJoined\s*:\s*YES"},
            @{Name="Domain Joined"; Pattern="DomainJoined\s*:\s*YES"}
        )) {
            $found = $out | Select-String $item.Pattern -ErrorAction SilentlyContinue
            if ($found) { Write-Host "    $($item.Name): YES" -ForegroundColor Red; Write-Log "  $($item.Name): YES" "WARN" }
            else { Write-Host "    $($item.Name): NO" -ForegroundColor Green }
        }
    } catch { Write-Host "    dsregcmd 执行失败" -ForegroundColor Yellow }

    Write-Host ""
    Write-Host "  [2] 策略注册表项扫描..." -ForegroundColor White
    $allPolicyPaths = @{
        "HKLM:\SOFTWARE\Policies" = "全局策略(含Edge/Chrome等)"
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies" = "Windows系统策略"
        "HKLM:\SOFTWARE\Policies\Microsoft\WindowsFirewall" = "防火墙策略"
        "HKLM:\SOFTWARE\Policies\Microsoft\Edge" = "Edge浏览器策略"
        "HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate" = "Edge更新策略"
        "HKLM:\SOFTWARE\Policies\Google\Chrome" = "Chrome浏览器策略"
        "HKCU:\SOFTWARE\Policies" = "用户级策略"
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies" = "用户级Windows策略"
        "HKCU:\SOFTWARE\Policies\Microsoft\Edge" = "用户级Edge策略"
        "HKCU:\SOFTWARE\Policies\Google\Chrome" = "用户级Chrome策略"
    }
    $foundCount = 0
    foreach ($path in $allPolicyPaths.Keys) {
        if (Test-Path $path) {
            $subs = Get-ChildItem -Path $path -ErrorAction SilentlyContinue
            if ($subs) {
                Write-Host "    发现: $($allPolicyPaths[$path]) ($($subs.Count)子项)" -ForegroundColor Yellow
                Write-Log "  发现: $path ($($subs.Count))" "WARN"
                $foundCount++
            }
        }
    }
    if ($foundCount -eq 0) { Write-Host "    未发现策略注册表项" -ForegroundColor Green }

    Write-Host ""
    Write-Host "  [3] WindowsSelfHost / CloudDomainInfo..." -ForegroundColor White
    foreach ($sh in @("HKLM:\SOFTWARE\Microsoft\WindowsSelfHost","HKCU:\SOFTWARE\Microsoft\WindowsSelfHost")) {
        if (Test-Path $sh) { Write-Host "    发现: $sh" -ForegroundColor Yellow; Write-Log "  WindowsSelfHost: $sh" "WARN" }
    }
    $cd = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "CloudDomainInfo" -ErrorAction SilentlyContinue
    if ($cd) { Write-Host "    CloudDomainInfo 存在" -ForegroundColor Yellow } else { Write-Host "    CloudDomainInfo 不存在" -ForegroundColor Green }

    Write-Host ""
    Write-Host "  [4] 防火墙服务状态..." -ForegroundColor White
    $svc = Get-Service mpssvc -ErrorAction SilentlyContinue
    if ($svc) { Write-Host "    mpssvc: $($svc.Status) (启动: $($svc.StartType))" -ForegroundColor $(if($svc.Status -eq 'Running'){'Green'}else{'Yellow'}) }
    
    Write-Host ""
    Write-Host "  [5] Defender DisableAntiSpyware..." -ForegroundColor White
    $das = Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender" -Name "DisableAntiSpyware" -ErrorAction SilentlyContinue
    if ($das) { Write-Host "    DisableAntiSpyware 存在" -ForegroundColor Yellow } else { Write-Host "    不存在" -ForegroundColor Green }

    Write-Host ""
    Write-Host "  [6] Explorer限制策略..." -ForegroundColor White
    $explorerPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"
    foreach ($prop in @("NoControlPanel","DisableSettingsPage","DisableNotificationCenter")) {
        $val = Get-ItemProperty $explorerPath -Name $prop -ErrorAction SilentlyContinue
        if ($val) { Write-Host "    $prop 存在" -ForegroundColor Yellow }
    }

    Write-Host ""
    Write-Log "--- 诊断结束 ---"
}

function Step-BackupAll {
    Write-Host ""
    Write-Host "====== 步骤 3: 全量备份注册表 ======" -ForegroundColor Cyan
    $c = Read-Host "是否全量备份? (Y/n)"
    if ($c -match '^[nN]') { Write-Log "跳过备份" "WARN"; return }

    New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null

    $paths = @(
        @{R="HKCU\Software\Microsoft\Windows\CurrentVersion\Policies"; F="01_HKCU_Policies.reg"},
        @{R="HKCU\Software\Microsoft\WindowsSelfHost"; F="02_HKCU_WindowsSelfHost.reg"},
        @{R="HKCU\Software\Policies"; F="03_HKCU_SoftwarePolicies.reg"},
        @{R="HKCU\Software\Policies\Microsoft\Edge"; F="04_HKCU_Edge.reg"},
        @{R="HKCU\Software\Policies\Google\Chrome"; F="05_HKCU_Chrome.reg"},
        @{R="HKLM\Software\Microsoft\Policies"; F="06_HKLM_MicrosoftPolicies.reg"},
        @{R="HKLM\Software\Microsoft\Windows\CurrentVersion\Policies"; F="07_HKLM_Policies.reg"},
        @{R="HKLM\Software\Microsoft\Windows\CurrentVersion\WindowsStore\WindowsUpdate"; F="08_HKLM_WU.reg"},
        @{R="HKLM\Software\Microsoft\WindowsSelfHost"; F="09_HKLM_WindowsSelfHost.reg"},
        @{R="HKLM\Software\Policies"; F="10_HKLM_SoftwarePolicies.reg"},
        @{R="HKLM\Software\Policies\Microsoft\WindowsFirewall"; F="11_HKLM_Firewall.reg"},
        @{R="HKLM\Software\Policies\Microsoft\Edge"; F="12_HKLM_Edge.reg"},
        @{R="HKLM\Software\Policies\Microsoft\EdgeUpdate"; F="13_HKLM_EdgeUpdate.reg"},
        @{R="HKLM\Software\Policies\Google\Chrome"; F="14_HKLM_Chrome.reg"},
        @{R="HKLM\Software\WOW6432Node\Microsoft\Policies"; F="15_HKLM_WOW_Policies.reg"},
        @{R="HKLM\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Policies"; F="16_HKLM_WOW_Policies2.reg"},
        @{R="HKLM\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\WindowsStore\WindowsUpdate"; F="17_HKLM_WOW_WU.reg"}
    )
    $count = 0
    foreach ($p in $paths) {
        if (Backup-RegistryKey -RegPath $p.R -BackupFile (Join-Path $BackupDir $p.F)) { $count++ }
    }
    Write-Host ""
    Write-Host "  备份完成! 共 $count 项 -> $BackupDir" -ForegroundColor Green

    $rb = Join-Path $BackupDir "一键回滚.bat"
    $bat = @"
@echo off
chcp 65001 >nul
echo ============================================================
echo   注册表一键回滚 - 双击运行即可恢复所有备份
echo ============================================================
echo.
pause
set BACKUP_DIR=%~dp0
for %%f in ("%BACKUP_DIR%*.reg") do (
    echo 正在导入: %%~nxf
    reg import "%%f" 2>nul
)
echo.
echo 所有备份已恢复! 请重启计算机。
pause
"@
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($rb, $bat, $utf8)
    Write-Host "  回滚脚本已生成" -ForegroundColor Green
}

function Step-MDMCleanup {
    Write-Host ""
    Write-Host "====== 步骤 4: 清理 MDM / 工作账户 ======" -ForegroundColor Cyan
    if ((Read-Host "是否清理? (y/N)") -ne 'y') { return }
    try {
        $ep = "HKLM:\SOFTWARE\Microsoft\Enrollments"
        if (Test-Path $ep) {
            Get-ChildItem $ep -ErrorAction SilentlyContinue | ForEach-Object {
                Remove-Item $_.PSPath -Recurse -Force -ErrorAction SilentlyContinue
                Write-Host "  已移除: $($_.PSChildName)" -ForegroundColor Green
            }
        }
        $dmw = Get-Service dmwappushservice -ErrorAction SilentlyContinue
        if ($dmw) {
            Stop-Service dmwappushservice -Force -ErrorAction SilentlyContinue
            Set-Service dmwappushservice -StartupType Disabled -ErrorAction SilentlyContinue
            Write-Host "  已禁用 dmwappushservice" -ForegroundColor Green
        }
    } catch { Write-Host "  出错: $($_.Exception.Message)" -ForegroundColor Red }
}

function Step-CleanAllPolicies {
    Write-Host ""
    Write-Host "====== 步骤 5: 清理全部策略注册表 ======" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  将删除以下所有位置的组织策略:" -ForegroundColor Yellow
    Write-Host "  - HKLM/HKCU \Policies (含Edge/Chrome/防火墙/Defender)" -ForegroundColor White
    Write-Host "  - WindowsSelfHost (Insider计划)" -ForegroundColor White
    Write-Host "  - Windows Update 限制" -ForegroundColor White
    Write-Host "  - CloudDomainInfo" -ForegroundColor White
    Write-Host "  - Explorer 限制策略" -ForegroundColor White
    Write-Host ""
    if ((Read-Host "确认全部清除? (y/N)") -ne 'y') { return }

    $allPaths = @(
        "HKCU\Software\Microsoft\Windows\CurrentVersion\Policies",
        "HKCU\Software\Microsoft\WindowsSelfHost",
        "HKCU\Software\Policies",
        "HKCU\Software\Policies\Microsoft\Edge",
        "HKCU\Software\Policies\Google\Chrome",
        "HKLM\Software\Microsoft\Policies",
        "HKLM\Software\Microsoft\Windows\CurrentVersion\Policies",
        "HKLM\Software\Microsoft\Windows\CurrentVersion\WindowsStore\WindowsUpdate",
        "HKLM\Software\Microsoft\WindowsSelfHost",
        "HKLM\Software\Policies",
        "HKLM\Software\Policies\Microsoft\WindowsFirewall",
        "HKLM\Software\Policies\Microsoft\Edge",
        "HKLM\Software\Policies\Microsoft\EdgeUpdate",
        "HKLM\Software\Policies\Google\Chrome",
        "HKLM\Software\WOW6432Node\Microsoft\Policies",
        "HKLM\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Policies",
        "HKLM\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\WindowsStore\WindowsUpdate"
    )
    foreach ($p in $allPaths) { Remove-RegistryKeySafe -RegPath $p | Out-Null }

    $cloudPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
    $ci = Get-ItemProperty $cloudPath -Name "CloudDomainInfo" -ErrorAction SilentlyContinue
    if ($ci) {
        Remove-ItemProperty $cloudPath -Name "CloudDomainInfo" -Force -ErrorAction SilentlyContinue
        Write-Host "  CloudDomainInfo 已删除" -ForegroundColor Green
    }

    $explorerPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"
    foreach ($prop in @("NoControlPanel","DisableSettingsPage","DisableNotificationCenter")) {
        $v = Get-ItemProperty $explorerPath -Name $prop -ErrorAction SilentlyContinue
        if ($v) { Remove-ItemProperty $explorerPath -Name $prop -Force -ErrorAction SilentlyContinue; Write-Host "  Explorer.$prop 已删除" -ForegroundColor Green }
    }

    $daPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender"
    $daVal = Get-ItemProperty $daPath -Name "DisableAntiSpyware" -ErrorAction SilentlyContinue
    if ($daVal) { Remove-ItemProperty $daPath -Name "DisableAntiSpyware" -Force -ErrorAction SilentlyContinue; Write-Host "  DisableAntiSpyware 已删除" -ForegroundColor Green }

    Write-Host ""
    Write-Host "  全部策略注册表清理完成!" -ForegroundColor Green
}

function Step-FixFirewall {
    Write-Host ""
    Write-Host "====== 步骤 6: 修复防火墙 ======" -ForegroundColor Cyan
    if ((Read-Host "是否修复? (y/N)") -ne 'y') { return }
    try {
        foreach ($fw in @(
            "HKLM\Software\Policies\Microsoft\WindowsFirewall",
            "HKLM\Software\Policies\Microsoft\WindowsFirewall\DomainProfile",
            "HKLM\Software\Policies\Microsoft\WindowsFirewall\StandardProfile",
            "HKLM\Software\Policies\Microsoft\WindowsFirewall\PublicProfile"
        )) { Remove-RegistryKeySafe -RegPath $fw | Out-Null }
        netsh advfirewall reset 2>&1 | Out-Null
        sc.exe config mpssvc start= auto 2>&1 | Out-Null
        Start-Service mpssvc -ErrorAction SilentlyContinue
        Write-Host "  防火墙已重置，服务已恢复" -ForegroundColor Green
    } catch { Write-Host "  出错: $($_.Exception.Message)" -ForegroundColor Red }
}

function Step-ResetGP {
    Write-Host ""
    Write-Host "====== 步骤 7: 重置组策略 ======" -ForegroundColor Cyan
    if ((Read-Host "是否重置? (y/N)") -ne 'y') { return }
    try {
        if (-not (Test-Path $BackupDir)) { New-Item -ItemType Directory $BackupDir -Force | Out-Null }
        foreach ($gp in @("$env:windir\System32\GroupPolicy","$env:windir\System32\GroupPolicyUsers")) {
            if (Test-Path $gp) {
                Copy-Item $gp (Join-Path $BackupDir (Split-Path $gp -Leaf)) -Recurse -Force -ErrorAction SilentlyContinue
                Get-ChildItem $gp -Recurse -ErrorAction SilentlyContinue | Where-Object { -not $_.PSIsContainer } | Remove-Item -Force -ErrorAction SilentlyContinue
                Write-Host "  已清理: $gp" -ForegroundColor Green
            }
        }
        secedit /configure /cfg "$env:windir\inf\defltbase.inf" /db (Join-Path $env:TEMP "defltbase.sdb") /verbose 2>&1 | Out-Null
        gpupdate /force 2>&1 | Out-Null
        Write-Host "  组策略已重置并刷新" -ForegroundColor Green
    } catch { Write-Host "  出错: $($_.Exception.Message)" -ForegroundColor Red }
}

function Step-FinalVerify {
    Write-Host ""
    Write-Host "====== 步骤 8: 最终验证 ======" -ForegroundColor Cyan
    Write-Host ""

    $ok = $true
    $checkList = @(
        @{P="HKLM:\SOFTWARE\Policies"; N="全局策略"},
        @{P="HKLM:\SOFTWARE\Policies\Microsoft\Edge"; N="Edge策略"},
        @{P="HKLM:\SOFTWARE\Policies\Google\Chrome"; N="Chrome策略"},
        @{P="HKLM:\SOFTWARE\Policies\Microsoft\WindowsFirewall"; N="防火墙策略"}
    )
    foreach ($c in $checkList) {
        if (Test-Path $c.P) {
            $subs = Get-ChildItem $c.P -ErrorAction SilentlyContinue
            if ($subs -and $subs.Count -gt 0) {
                Write-Host "  X $($c.N): 仍有 $($subs.Count) 个子项" -ForegroundColor Red; $ok=$false
            }
        } else { Write-Host "  OK $($c.N): 已清除" -ForegroundColor Green }
    }
    $cdVal = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "CloudDomainInfo" -ErrorAction SilentlyContinue
    if ($cdVal) { Write-Host "  X CloudDomainInfo: 仍存在" -ForegroundColor Red; $ok=$false }
    else { Write-Host "  OK CloudDomainInfo: 已清除" -ForegroundColor Green }

    Write-Host ""
    if ($ok) {
        Write-Host "  全部检查通过! 请重启计算机。" -ForegroundColor Green
    } else {
        Write-Host "  部分项目仍有残留。重启后再次运行可彻底清除。" -ForegroundColor Yellow
    }
    Write-Log "--- 最终验证结束 ---"
}

function Main {
    Show-Banner
    if (-not (Test-Administrator)) {
        Write-Host "  错误: 需要管理员权限!" -ForegroundColor Red
        Write-Host "  右键 PowerShell -> 以管理员身份运行" -ForegroundColor Red
        Read-Host "按回车退出"
        exit 1
    }
    Write-Host "  管理员权限通过!" -ForegroundColor Green
    if ((Read-Host "是否继续? (y/N)") -ne 'y') { exit 0 }

    Step-RestorePoint
    Step-Diagnose
    Step-BackupAll
    Step-MDMCleanup
    Step-CleanAllPolicies
    Step-FixFirewall
    Step-ResetGP
    Step-FinalVerify

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "  v3.0 彻底清除完成!" -ForegroundColor Green
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  必须重启计算机使所有更改生效!" -ForegroundColor Yellow
    Write-Host "  回滚: 运行备份目录中的 [一键回滚.bat]" -ForegroundColor White
    Write-Host "  或: rstrui.exe (系统还原)" -ForegroundColor White
    Write-Host ""
    Write-Host "  备份: $BackupDir" -ForegroundColor Green
    Write-Host "  日志: $LogFile" -ForegroundColor Green
    Write-Host ""

    if ((Read-Host "立即重启? (y/N)") -match '^y$') { Restart-Computer -Force }
    else { Write-Host "  请手动重启!" -ForegroundColor Yellow }
}

Main
