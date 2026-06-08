Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$AppName = "dns-scout"
$TaskName = $AppName
$InstallDir = Join-Path $env:ProgramData $AppName
$FirewallRuleNamePrefix = "DNSScoutPanel-TCP-"
$RunnerScript = Join-Path $InstallDir "run_panel.ps1"

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Ensure-Elevated {
    if (Test-IsAdministrator) {
        return
    }

    $scriptPath = $PSCommandPath
    if (-not $scriptPath) {
        throw "Unable to determine script path for elevation."
    }

    $forwardArgs = @()
    if ($MyInvocation -and $MyInvocation.UnboundArguments) {
        $forwardArgs = @($MyInvocation.UnboundArguments)
    }
    $argLiterals = @()
    foreach ($arg in $forwardArgs) {
        $argText = [string]$arg
        $argLiterals += "'" + $argText.Replace("'", "''") + "'"
    }
    $argArrayExpression = if ($argLiterals.Count -gt 0) { $argLiterals -join ", " } else { "" }
    $scriptPathLiteral = $scriptPath.Replace("'", "''")

    $bootstrap = @"
`$scriptPath = '$scriptPathLiteral'
`$scriptArgs = @($argArrayExpression)
`$exitCode = 0
try {
    & `$scriptPath @scriptArgs
    if (`$null -ne `$LASTEXITCODE) {
        `$exitCode = [int]`$LASTEXITCODE
    }
} catch {
    Write-Host ""
    Write-Host "An error occurred:" -ForegroundColor Red
    Write-Host (`$_ | Out-String)
    `$exitCode = 1
} finally {
    Write-Host ""
    [void](Read-Host "Press Enter to close this window")
}
exit `$exitCode
"@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrap))

    Write-Host "==> Requesting Administrator permission (UAC)..."
    try {
        $proc = Start-Process -FilePath "powershell.exe" `
            -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-EncodedCommand", $encoded) `
            -Verb RunAs `
            -Wait `
            -PassThru
    } catch {
        throw "Administrator permission was not granted."
    }

    if ($null -eq $proc) {
        throw "Failed to launch elevated process."
    }

    exit $proc.ExitCode
}

function Stop-DnsScoutProcesses {
    if (-not (Test-Path $InstallDir)) {
        return
    }

    Write-Host "==> Stopping DNS Scout related processes"
    $needleInstallDir = $InstallDir.ToLowerInvariant()
    $needleRunner = $RunnerScript.ToLowerInvariant()

    try {
        $candidates = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -match '^(python|pythonw|powershell|pwsh)\.exe$'
        }
    } catch {
        $candidates = @()
    }

    foreach ($proc in $candidates) {
        $cmdLine = [string]$proc.CommandLine
        if ([string]::IsNullOrWhiteSpace($cmdLine)) {
            continue
        }
        $normalized = $cmdLine.ToLowerInvariant()
        if ($normalized.Contains($needleInstallDir) -or $normalized.Contains($needleRunner)) {
            try {
                Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
            } catch {}
        }
    }

    Start-Sleep -Seconds 1
}

function Remove-InstallDirectorySafe {
    if (-not (Test-Path $InstallDir)) {
        Write-Host "==> Install directory not found. Skipping."
        return
    }

    Write-Host "==> Removing installed directory"
    try {
        Remove-Item -Path $InstallDir -Recurse -Force -ErrorAction Stop
    } catch {
        Write-Warning "Direct removal failed. Trying ownership/ACL fallback."

        try { & takeown.exe /F $InstallDir /R /D Y /A | Out-Null } catch {}
        try { & icacls.exe $InstallDir /grant "*S-1-5-32-544:F" /T /C /Q | Out-Null } catch {}
        try { & attrib.exe -R "$InstallDir\*" /S /D | Out-Null } catch {}

        $removed = $false
        for ($i = 0; $i -lt 3; $i++) {
            Stop-DnsScoutProcesses
            try { & cmd.exe /c "rmdir /S /Q `"$InstallDir`"" | Out-Null } catch {}
            Start-Sleep -Seconds 1
            if (-not (Test-Path $InstallDir)) {
                $removed = $true
                break
            }
        }

        if (-not $removed -and (Test-Path $InstallDir)) {
            throw "Could not remove install directory: $InstallDir. Reboot Windows and run uninstall.ps1 again as Administrator."
        }
    }
}

Ensure-Elevated

Write-Host "==> Uninstalling $AppName"
Write-Host "This will remove:"
Write-Host "  - startup scheduled task: $TaskName"
Write-Host "  - installed directory: $InstallDir"
Write-Host "Project files in current repository will NOT be deleted."
Write-Host ""

$confirm = Read-Host "Continue? [Y/n]"
if ($null -eq $confirm) { $confirm = "" }
$confirm = $confirm.ToLowerInvariant()
if ($confirm -and $confirm -ne "y" -and $confirm -ne "yes") {
    Write-Host "Uninstall cancelled."
    return
}

$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($task) {
    Write-Host "==> Stopping and removing scheduled task"
    try { Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue } catch {}
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
} else {
    Write-Host "==> Scheduled task not found. Skipping."
}

Stop-DnsScoutProcesses
Remove-InstallDirectorySafe

if (Get-Command Get-NetFirewallRule -ErrorAction SilentlyContinue) {
    Write-Host "==> Removing Windows Firewall rules created by DNS Scout"
    Get-NetFirewallRule -Name "${FirewallRuleNamePrefix}*" -ErrorAction SilentlyContinue |
        Remove-NetFirewallRule -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "Uninstall completed."
Write-Host "You can run install again from your project folder:"
Write-Host "  powershell -ExecutionPolicy Bypass -File .\install.ps1"
