$script:GitHubGitMirrorBases = @(
    "https://scorpian.ir/repos"
)

function Get-GitCloneCandidates {
    param([string]$RepositoryUrl)

    $candidates = [System.Collections.Generic.List[string]]::new()
    $candidates.Add($RepositoryUrl)

    $match = [regex]::Match($RepositoryUrl, '^(https?://github\.com/|git@github\.com:)(?<owner>[^/]+)/(?<repo>[^/]+?)(?:\.git)?$')
    if ($match.Success) {
        $owner = $match.Groups['owner'].Value
        $repo = $match.Groups['repo'].Value
        foreach ($mirrorBase in $script:GitHubGitMirrorBases) {
            $candidates.Add("$mirrorBase/$owner/$repo.git")
        }
    }

    return $candidates
}

function Resolve-DefaultBranchWithFallback {
    param([string]$RepositoryUrl)

    foreach ($candidate in Get-GitCloneCandidates -RepositoryUrl $RepositoryUrl) {
        $branchLine = git ls-remote --symref $candidate HEAD 2>$null | Select-String '^ref:' | Select-Object -First 1
        if ($branchLine -and $branchLine.ToString() -match '^ref:\s+refs/heads/(?<branch>\S+)\s+HEAD$') {
            return $Matches.branch
        }
    }

    return "main"
}

function Resolve-RemoteCommitWithFallback {
    param(
        [string]$RepositoryUrl,
        [string]$Branch
    )

    foreach ($candidate in Get-GitCloneCandidates -RepositoryUrl $RepositoryUrl) {
        $remoteCommit = git ls-remote $candidate ("refs/heads/$Branch") | ForEach-Object { ($_ -split '\s+')[0] } | Select-Object -First 1
        if ($remoteCommit) {
            return $remoteCommit.Trim()
        }
    }

    return $null
}

function Invoke-GitCloneWithFallback {
    param(
        [string]$RepositoryUrl,
        [string]$Branch,
        [string]$Destination
    )

    foreach ($candidate in Get-GitCloneCandidates -RepositoryUrl $RepositoryUrl) {
        Write-Host "==> Trying clone source: $candidate"
        & git clone --depth 1 --branch $Branch $candidate $Destination | Out-Null
        if ($LASTEXITCODE -eq 0) {
            if ($candidate -ne $RepositoryUrl) {
                Write-Host "==> Cloned from fallback mirror: $candidate"
            }

            return $true
        }
    }

    return $false
}
