Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$AppName = "dns-scout"
$TaskName = $AppName
$InstallDir = Join-Path $env:ProgramData $AppName
$PanelConfigFile = Join-Path $InstallDir "panel_config.json"
$RunnerScript = Join-Path $InstallDir "run_panel.ps1"
$LogsDir = Join-Path $InstallDir "logs"
$RunnerOutLog = Join-Path $LogsDir "runner.out.log"
$RunnerErrLog = Join-Path $LogsDir "runner.err.log"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$PythonBin = "python"
$FirewallRuleNamePrefix = "DNSScoutPanel-TCP-"
$MinPythonVersion = [Version]"3.10.0"
$BootstrapPythonVersion = "3.12.10"
$BootstrapPythonInstallerUrl = "https://www.python.org/ftp/python/$BootstrapPythonVersion/python-$BootstrapPythonVersion-amd64.exe"
$BootstrapPythonInstallerPath = Join-Path $env:TEMP "python-$BootstrapPythonVersion-amd64.exe"

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

function Require-Command {
    param([string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "$Name is not installed or not available in PATH."
    }
}

function Test-PortFree {
    param([int]$Port)
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Any, $Port)
    try {
        $listener.Start()
        return $true
    } catch {
        return $false
    } finally {
        try { $listener.Stop() } catch {}
    }
}

function Get-RandomFreePort {
    for ($i = 0; $i -lt 500; $i++) {
        $candidate = Get-Random -Minimum 12000 -Maximum 49001
        if (Test-PortFree -Port $candidate) {
            return $candidate
        }
    }
    return 18080
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

function Get-PythonVersion {
    param([string]$PythonExe)
    try {
        $raw = & $PythonExe -c "import sys; print('.'.join(map(str, sys.version_info[:3])))" 2>$null
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($raw)) {
            return $null
        }
        return [Version]$raw.Trim()
    } catch {
        return $null
    }
}

function Resolve-PythonExecutable {
    $pythonCmd = Get-Command python -ErrorAction SilentlyContinue
    if ($pythonCmd -and $pythonCmd.Source) {
        $candidate = $pythonCmd.Source
        $version = Get-PythonVersion -PythonExe $candidate
        if ($version) {
            return $candidate
        }
    }

    $pyLauncher = Get-Command py -ErrorAction SilentlyContinue
    if ($pyLauncher) {
        try {
            $exe = & py -3 -c "import sys; print(sys.executable)" 2>$null
            if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($exe)) {
                $candidate = $exe.Trim()
                if (Test-Path $candidate) {
                    $version = Get-PythonVersion -PythonExe $candidate
                    if ($version) {
                        return $candidate
                    }
                }
            }
        } catch {}
    }

    return $null
}

function Refresh-ProcessPath {
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if ($machinePath -and $userPath) {
        $env:Path = "$machinePath;$userPath"
    } elseif ($machinePath) {
        $env:Path = $machinePath
    } elseif ($userPath) {
        $env:Path = $userPath
    }
}

function Install-PythonFromPythonOrg {
    Write-Host "==> Downloading Python $BootstrapPythonVersion from python.org"
    Invoke-WebRequest -Uri $BootstrapPythonInstallerUrl -OutFile $BootstrapPythonInstallerPath

    Write-Host "==> Installing Python $BootstrapPythonVersion silently"
    $proc = Start-Process -FilePath $BootstrapPythonInstallerPath `
        -ArgumentList @("/quiet", "InstallAllUsers=1", "PrependPath=1", "Include_test=0") `
        -Wait `
        -PassThru
    if ($proc.ExitCode -ne 0) {
        throw "Python installer exited with code $($proc.ExitCode)."
    }
}

function Ensure-PythonRuntime {
    $pythonExe = Resolve-PythonExecutable
    if ($pythonExe) {
        $version = Get-PythonVersion -PythonExe $pythonExe
        if ($version -and $version -ge $MinPythonVersion) {
            Write-Host "==> Using detected Python $version at $pythonExe"
            return $pythonExe
        }
        if ($version) {
            Write-Host "Detected Python $version is lower than required $MinPythonVersion."
        }
    }

    Write-Host "==> Python 3.10+ was not found. Attempting automatic installation."
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if ($winget) {
        try {
            Write-Host "==> Trying winget install: Python.Python.3.12"
            & winget install `
                --id Python.Python.3.12 `
                --exact `
                --silent `
                --scope machine `
                --accept-package-agreements `
                --accept-source-agreements
        } catch {
            Write-Warning "winget install failed: $($_.Exception.Message)"
        }

        Refresh-ProcessPath
        $pythonExe = Resolve-PythonExecutable
        if ($pythonExe) {
            $version = Get-PythonVersion -PythonExe $pythonExe
            if ($version -and $version -ge $MinPythonVersion) {
                Write-Host "==> Python installation completed via winget: $version"
                return $pythonExe
            }
        }
    } else {
        Write-Host "==> winget not found. Falling back to python.org installer."
    }

    Install-PythonFromPythonOrg
    Refresh-ProcessPath

    $pythonExe = Resolve-PythonExecutable
    if (-not $pythonExe) {
        throw "Python installation finished but executable was not detected. Open a new terminal and run install again."
    }
    $version = Get-PythonVersion -PythonExe $pythonExe
    if (-not $version -or $version -lt $MinPythonVersion) {
        throw "Detected Python version is invalid or too old after install."
    }

    try {
        Remove-Item -Path $BootstrapPythonInstallerPath -Force -ErrorAction SilentlyContinue
    } catch {}

    Write-Host "==> Python installation completed: $version"
    return $pythonExe
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

function Remove-InstallDirectorySafe {
    if (-not (Test-Path $InstallDir)) {
        return
    }

    Write-Host "==> Removing existing install directory"
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        Stop-DnsScoutProcesses

        try {
            Remove-Item -LiteralPath $InstallDir -Recurse -Force -ErrorAction Stop
        } catch {
            if ($attempt -eq 3) {
                throw
            }

            Start-Sleep -Seconds 2
        }

        if (-not (Test-Path $InstallDir)) {
            return
        }
    }

    if (Test-Path $InstallDir) {
        throw "Failed to remove existing install directory: $InstallDir"
    }
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

Write-Host "==> Script directory: $ScriptDir"

if (-not (Test-Path (Join-Path $ScriptDir "main.py"))) {
    throw "main.py was not found next to install.ps1."
}
if (-not (Test-Path (Join-Path $ScriptDir "panel_app.py"))) {
    throw "panel_app.py was not found next to install.ps1."
}

Ensure-Elevated

$PythonBin = Ensure-PythonRuntime

$panelUsername = Read-Host "Enter panel username"
while ([string]::IsNullOrWhiteSpace($panelUsername)) {
    Write-Host "Username cannot be empty."
    $panelUsername = Read-Host "Enter panel username"
}

while ($true) {
    $p1 = Read-Host "Enter panel password" -AsSecureString
    $p2 = Read-Host "Confirm panel password" -AsSecureString
    $b1 = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($p1)
    $b2 = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($p2)
    try {
        $panelPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b1)
        $panelPasswordConfirm = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b2)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b1)
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b2)
    }

    if ([string]::IsNullOrWhiteSpace($panelPassword)) {
        Write-Host "Password cannot be empty."
        continue
    }
    if ($panelPassword -ne $panelPasswordConfirm) {
        Write-Host "Passwords do not match. Please try again."
        continue
    }
    break
}

$suggestedPort = Get-RandomFreePort
Write-Host ""
Write-Host "Suggested free port: $suggestedPort"

while ($true) {
    $selectedPortRaw = Read-Host "Press Enter to accept it or enter a custom port"
    if ([string]::IsNullOrWhiteSpace($selectedPortRaw)) {
        $selectedPortRaw = "$suggestedPort"
    }

    if ($selectedPortRaw -notmatch '^\d+$') {
        Write-Host "Invalid port. Please enter a number."
        continue
    }

    $selectedPort = [int]$selectedPortRaw
    if ($selectedPort -lt 1 -or $selectedPort -gt 65535) {
        Write-Host "Port must be between 1 and 65535."
        continue
    }

    if (-not (Test-PortFree -Port $selectedPort)) {
        Write-Host "Port $selectedPort is already in use. Please choose another port."
        continue
    }
    break
}

Write-Host "==> Preparing install directory"
if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
}
Remove-InstallDirectorySafe
New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
Copy-Item -Path (Join-Path $ScriptDir "*") -Destination $InstallDir -Recurse -Force

Write-Host "==> Creating virtual environment"
$venvDir = Join-Path $InstallDir ".venv"
if (-not (Test-Path $venvDir)) {
    & $PythonBin -m venv $venvDir
}
$venvPython = Join-Path $venvDir "Scripts\python.exe"

Write-Host "==> Installing dependencies"
& $venvPython -m pip install --upgrade pip
& $venvPython -m pip install --upgrade pandas flask

Write-Host "==> Generating panel configuration"
$env:PANEL_PASSWORD = $panelPassword
$panelPasswordHash = & $venvPython -c "import os; from werkzeug.security import generate_password_hash; print(generate_password_hash(os.environ['PANEL_PASSWORD']))"
Remove-Item Env:PANEL_PASSWORD -ErrorAction SilentlyContinue

$panelSecretKey = & $venvPython -c "import secrets; print(secrets.token_urlsafe(48))"

$panelConfig = [ordered]@{
    username = $panelUsername
    password_hash = $panelPasswordHash.Trim()
    port = $selectedPort
    secret_key = $panelSecretKey.Trim()
    source_dir = (Join-Path $InstallDir "source")
    csv_config_path = (Join-Path $InstallDir "csv_extractor_config.json")
    scanner_config_path = (Join-Path $InstallDir "scanner_config.json")
}
$panelConfigJson = $panelConfig | ConvertTo-Json -Depth 10
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($PanelConfigFile, $panelConfigJson, $utf8NoBom)

Write-Host "==> Creating startup runner script"
New-Item -ItemType Directory -Path $LogsDir -Force | Out-Null
$runnerContent = @"
Set-StrictMode -Version Latest
`$ErrorActionPreference = "Continue"
`$installDir = "$InstallDir"
`$venvPython = Join-Path `$installDir ".venv\Scripts\python.exe"
`$panelApp = Join-Path `$installDir "panel_app.py"
`$panelConfig = Join-Path `$installDir "panel_config.json"
`$logsDir = Join-Path `$installDir "logs"
`$outLog = Join-Path `$logsDir "runner.out.log"
`$errLog = Join-Path `$logsDir "runner.err.log"

New-Item -ItemType Directory -Path `$logsDir -Force | Out-Null

Set-Location `$installDir
while (`$true) {
  Add-Content -Path `$outLog -Value ("[" + (Get-Date -Format s) + "] starting panel process")
  try {
    & `$venvPython `$panelApp --config `$panelConfig 1>>`$outLog 2>>`$errLog
    Add-Content -Path `$outLog -Value ("[" + (Get-Date -Format s) + "] panel process exited with code " + `$LASTEXITCODE)
  } catch {
    Add-Content -Path `$errLog -Value ("[" + (Get-Date -Format s) + "] runner exception: " + (`$_ | Out-String))
  }
  Start-Sleep -Seconds 5
}
"@
$runnerContent | Set-Content -Path $RunnerScript -Encoding UTF8

Write-Host "==> Registering startup scheduled task"
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$RunnerScript`""
$trigger = New-ScheduledTaskTrigger -AtStartup
$settings = New-ScheduledTaskSettingsSet `
    -RestartCount 999 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit (New-TimeSpan -Days 3650) `
    -StartWhenAvailable `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description "DNS Scout startup task" | Out-Null

Start-ScheduledTask -TaskName $TaskName
Start-Sleep -Seconds 2

if (-not (Wait-PanelReady -Port $selectedPort -TimeoutSeconds 20)) {
    Write-Warning "Panel was not reachable after starting the scheduled task. Trying direct fallback start."
    Start-Process -FilePath "powershell.exe" `
        -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File", "`"$RunnerScript`"") `
        -WindowStyle Hidden | Out-Null

    if (-not (Wait-PanelReady -Port $selectedPort -TimeoutSeconds 20)) {
        Write-Warning "Panel is still not reachable on port $selectedPort."
        Write-Host ""
        Write-Host "Task diagnostics:"
        try {
            $taskInfo = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction Stop
            Write-Host "  LastTaskResult: $($taskInfo.LastTaskResult)"
            Write-Host "  LastRunTime:    $($taskInfo.LastRunTime)"
            Write-Host "  NextRunTime:    $($taskInfo.NextRunTime)"
        } catch {
            Write-Host "  Could not read scheduled task info: $($_.Exception.Message)"
        }

        Write-Host ""
        Write-Host "Runner logs:"
        Write-Host "  $RunnerOutLog"
        Write-Host "  $RunnerErrLog"
        if (Test-Path $RunnerErrLog) {
            Write-Host ""
            Write-Host "Last runner error lines:"
            Get-Content -Path $RunnerErrLog -Tail 40 | ForEach-Object { Write-Host "  $_" }
        }
    }
}

Ensure-PanelFirewallRule -Port $selectedPort

$hostIp = "127.0.0.1"
try {
    $ip = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop | Where-Object { $_.IPAddress -notlike "127.*" -and $_.PrefixOrigin -ne "WellKnown" } | Select-Object -First 1 -ExpandProperty IPAddress)
    if ($ip) { $hostIp = $ip }
} catch {}

Write-Host ""
Write-Host "Installation completed."
Write-Host "Open the panel and login to start scanning:"
Write-Host "  http://${hostIp}:$selectedPort"
Write-Host ""
Write-Host "To change panel username/password later via CLI:"
Write-Host "  $venvPython `"$InstallDir\manage_panel_auth.py`" --config `"$PanelConfigFile`""
Write-Host ""
Write-Host "To print panel login URLs later via CLI:"
Write-Host "  $venvPython `"$InstallDir\manage_panel_auth.py`" --config `"$PanelConfigFile`" --show-urls"
