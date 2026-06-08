Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$AppName = "dns-scout"
$TaskName = $AppName
$InstallDir = Join-Path $env:ProgramData $AppName
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$VenvPython = Join-Path $InstallDir ".venv\Scripts\python.exe"
$PanelConfigFile = Join-Path $InstallDir "panel_config.json"
$RunnerScript = Join-Path $InstallDir "run_panel.ps1"
$LogsDir = Join-Path $InstallDir "logs"
$RunnerErrLog = Join-Path $LogsDir "runner.err.log"
$FirewallRuleNamePrefix = "DNSScoutPanel-TCP-"

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

function Test-PanelPortReady {
    param([int]$Port)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect("127.0.0.1", $Port, $null, $null)
        $connected = $iar.AsyncWaitHandle.WaitOne(700, $false)
        if (-not $connected) {
            return $false
        }
        $client.EndConnect($iar) | Out-Null
        return $true
    } catch {
        return $false
    } finally {
        try { $client.Close() } catch {}
    }
}

function Wait-PanelReady {
    param(
        [int]$Port,
        [int]$TimeoutSeconds = 20
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-PanelPortReady -Port $Port) {
            return $true
        }
        Start-Sleep -Seconds 1
    }
    return $false
}

function Ensure-PanelFirewallRule {
    param([int]$Port)

    if ($Port -lt 1 -or $Port -gt 65535) {
        throw "Invalid panel port for firewall rule: $Port"
    }
    if (-not (Get-Command New-NetFirewallRule -ErrorAction SilentlyContinue)) {
        Write-Warning "Windows Firewall cmdlets are not available. Skipping firewall rule setup."
        return
    }

    $ruleName = "${FirewallRuleNamePrefix}${Port}"
    $displayName = "DNS Scout Panel TCP $Port"

    try {
        $existingRule = Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue
        if ($existingRule) {
            Set-NetFirewallRule -Name $ruleName -Enabled True -Action Allow -Direction Inbound -Profile Any | Out-Null
        } else {
            New-NetFirewallRule `
                -Name $ruleName `
                -DisplayName $displayName `
                -Direction Inbound `
                -Action Allow `
                -Protocol TCP `
                -LocalPort $Port `
                -Profile Any | Out-Null
        }

        Get-NetFirewallRule -Name "${FirewallRuleNamePrefix}*" -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne $ruleName } |
            Remove-NetFirewallRule -ErrorAction SilentlyContinue

        Write-Host "==> Windows Firewall rule is ready for TCP port $Port"
    } catch {
        Write-Warning "Failed to configure Windows Firewall for panel port $Port. $($_.Exception.Message)"
    }
}

function Stop-DnsScoutProcesses {
    if (-not (Test-Path $InstallDir)) {
        return
    }

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

Ensure-Elevated

Write-Host "==> Script directory: $ScriptDir"

if (-not (Test-Path (Join-Path $ScriptDir "main.py")) -or -not (Test-Path (Join-Path $ScriptDir "panel_app.py"))) {
    throw "Required project files were not found next to update.ps1."
}

if (-not (Test-Path $InstallDir)) {
    throw "Install directory not found: $InstallDir`nRun install.ps1 first."
}

Write-Host "==> Syncing updated project files"
$excludeNames = @(".git", ".idea", "__pycache__", ".venv", "panel_config.json", "source", ".online_release.json")
$preserve = @("panel_config.json", "source", ".venv", ".online_release.json")

Stop-DnsScoutProcesses
Get-ChildItem -LiteralPath $InstallDir -Force -ErrorAction SilentlyContinue | ForEach-Object {
    if ($preserve -contains $_.Name) { return }
    Remove-Item -LiteralPath $_.FullName -Recurse -Force
}

Get-ChildItem -LiteralPath $ScriptDir -Force | ForEach-Object {
    if ($excludeNames -contains $_.Name) { return }
    Copy-Item -LiteralPath $_.FullName -Destination $InstallDir -Recurse -Force
}

if (-not (Test-Path $VenvPython)) {
    throw "Virtual environment not found in $InstallDir\.venv`nRun install.ps1 first."
}

Write-Host "==> Updating Python dependencies"
& $VenvPython -m pip install --upgrade pandas flask

$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($task) {
    Write-Host "==> Restarting scheduled task"
    try { Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue } catch {}
    Start-ScheduledTask -TaskName $TaskName

    $panelPort = $null
    if (Test-Path $PanelConfigFile) {
        try {
            $panelCfg = Get-Content -Raw $PanelConfigFile | ConvertFrom-Json
            $panelPort = [int]$panelCfg.port
        } catch {}
    }
    if ($panelPort) {
        Ensure-PanelFirewallRule -Port $panelPort
        if (-not (Wait-PanelReady -Port $panelPort -TimeoutSeconds 20)) {
            Write-Warning "Panel was not reachable after restarting the scheduled task. Trying direct fallback start."
            Start-Process -FilePath "powershell.exe" `
                -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File", "`"$RunnerScript`"") `
                -WindowStyle Hidden | Out-Null

            if (-not (Wait-PanelReady -Port $panelPort -TimeoutSeconds 20)) {
                Write-Warning "Panel is still not reachable on port $panelPort."
                Write-Host "Check runner error log: $RunnerErrLog"
                if (Test-Path $RunnerErrLog) {
                    Write-Host "Last runner error lines:"
                    Get-Content -Path $RunnerErrLog -Tail 40 | ForEach-Object { Write-Host "  $_" }
                }
            }
        }
    }
} else {
    Write-Host "==> Scheduled task not found. Skipping restart."
}

Write-Host ""
Write-Host "Update completed successfully."
