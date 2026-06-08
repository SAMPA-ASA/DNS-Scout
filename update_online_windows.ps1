Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$AppName = "dns-scout"
$InstallDir = Join-Path $env:ProgramData $AppName
$MetaFile = Join-Path $InstallDir ".online_release.json"
$DefaultRepoUrl = "https://github.com/sampa-asa/dns-scout.git"
$RepoUrl = if ($env:REPO_URL) { $env:REPO_URL } else { $DefaultRepoUrl }

. (Join-Path $PSScriptRoot "git_mirror_helpers.ps1")

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

Ensure-Elevated

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw "git is required but not installed."
}

if (-not (Test-Path $InstallDir)) {
    throw "Install directory not found: $InstallDir`nRun install.ps1 or install_online.ps1 first."
}

$knownRepoUrl = $null
$knownBranch = $null
$knownCommit = $null
if (Test-Path $MetaFile) {
    try {
        $meta = Get-Content -Raw $MetaFile | ConvertFrom-Json
        $knownRepoUrl = $meta.repo_url
        $knownBranch = $meta.branch
        $knownCommit = $meta.commit
    } catch {}
}

if ($knownRepoUrl) { $RepoUrl = $knownRepoUrl }
$branch = if ($env:REPO_BRANCH) { $env:REPO_BRANCH } elseif ($knownBranch) { $knownBranch } else { Resolve-DefaultBranchWithFallback -RepositoryUrl $RepoUrl }

$remoteCommit = Resolve-RemoteCommitWithFallback -RepositoryUrl $RepoUrl -Branch $branch
if (-not $remoteCommit) {
    throw "Unable to resolve remote commit for $RepoUrl ($branch)."
}

$localCommit = $knownCommit
if (-not $localCommit -and (Test-Path (Join-Path $InstallDir ".git"))) {
    try { $localCommit = (git -C $InstallDir rev-parse HEAD).Trim() } catch {}
}

if ($localCommit -and $localCommit -eq $remoteCommit) {
    Write-Host "Already up to date. Commit: $localCommit"
    return
}

$tmpSeed = New-TemporaryFile
Remove-Item $tmpSeed -Force
$tmpDir = New-Item -ItemType Directory -Path $tmpSeed.FullName -Force

try {
    Write-Host "==> Repository: $RepoUrl"
    Write-Host "==> Branch: $branch"
    $currentCommitDisplay = if ($localCommit) { $localCommit } else { "unknown" }
    Write-Host "==> Current commit: $currentCommitDisplay"
    Write-Host "==> Remote commit: $remoteCommit"
    Write-Host "==> Downloading update"
    if (-not (Invoke-GitCloneWithFallback -RepositoryUrl $RepoUrl -Branch $branch -Destination (Join-Path $tmpDir.FullName "repo"))) {
        throw "Unable to clone repository from the primary source or fallback mirrors."
    }

    $repoDir = Join-Path $tmpDir.FullName "repo"
    $updater = Join-Path $repoDir "update.ps1"
    if (-not (Test-Path $updater)) {
        throw "update.ps1 not found in cloned repository."
    }

    Write-Host "==> Running project updater"
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $updater

    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    $meta = [ordered]@{
        repo_url = $RepoUrl
        branch = $branch
        commit = $remoteCommit
        updated_at = $timestamp
    }
    $meta | ConvertTo-Json -Depth 10 | Set-Content -Path $MetaFile -Encoding UTF8

    Write-Host ""
    Write-Host "Update completed successfully."
    Write-Host "Installed commit: $remoteCommit"
}
finally {
    if (Test-Path $tmpDir.FullName) {
        Remove-Item -Path $tmpDir.FullName -Recurse -Force
    }
}
