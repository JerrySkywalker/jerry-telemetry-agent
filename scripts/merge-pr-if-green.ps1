param(
  [Parameter(Mandatory = $true)]
  [int]$PrNumber,

  [switch]$DeleteBranch,
  [switch]$Squash,
  [switch]$DryRun
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Invoke-Step {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Description,

    [Parameter(Mandatory = $true)]
    [scriptblock]$Action
  )

  Write-Host "step=$Description"
  if ($DryRun) {
    Write-Host "dry_run=true"
    return $null
  }

  return & $Action
}

function Assert-Command {
  param([Parameter(Mandatory = $true)][string]$Name)

  $command = Get-Command $Name -ErrorAction SilentlyContinue
  if (-not $command) {
    throw "Required command not found: $Name"
  }
}

function Test-HighRiskPath {
  param([Parameter(Mandatory = $true)][string]$Path)

  $normalized = $Path -replace "\\", "/"
  $fileName = [IO.Path]::GetFileName($normalized)
  return (
    $fileName -eq ".env" -or
    $normalized -like "*.local.env" -or
    $fileName -eq "auth.json" -or
    $normalized -like "systemd/*" -or
    $normalized -eq "docker-compose.prod.yml" -or
    $normalized -match "(?i)^docs/.*(live|production).*deploy" -or
    $normalized -match "(?i)^docs/.*deploy.*(live|production)" -or
    $normalized -match "(?i)(^|/)migrations?/" -or
    $normalized -match "(?i)(nginx|caddy|traefik|reverse-proxy|proxy)\.(conf|yml|yaml|toml)$"
  )
}

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Push-Location $repoRoot
try {
  Assert-Command "git"
  Assert-Command "gh"

  $prJson = Invoke-Step "check_pr_exists" {
    gh pr view $PrNumber --json number,state,headRefName,url
  }

  if (-not $DryRun) {
    $pr = ($prJson | Out-String) | ConvertFrom-Json
    if ($pr.state -ne "OPEN") {
      throw "PR #$PrNumber is not open. state=$($pr.state)"
    }
  }

  Invoke-Step "wait_for_checks" {
    gh pr checks $PrNumber --watch --fail-fast
  }

  $checksJson = Invoke-Step "read_checks" {
    gh pr checks $PrNumber --json name,state,bucket
  }

  if (-not $DryRun) {
    $checks = @(($checksJson | Out-String) | ConvertFrom-Json)
    if ($checks.Count -eq 0) {
      throw "Refusing merge because no PR checks were found."
    }

    $badChecks = @($checks | Where-Object {
      $bucket = $_.bucket
      $bucket -notin @("pass", "skipping")
    })
    if ($badChecks.Count -gt 0) {
      $names = ($badChecks | ForEach-Object { "$($_.name):$($_.bucket)" }) -join ", "
      throw "Refusing merge because checks are not green: $names"
    }
  }

  $changedFiles = @(Invoke-Step "read_changed_files" {
    gh pr diff $PrNumber --name-only
  }
  )

  if (-not $DryRun) {
    $highRiskFiles = @($changedFiles | Where-Object { Test-HighRiskPath $_ })
    if ($highRiskFiles.Count -gt 0) {
      throw "Refusing auto-merge due to high-risk changed files: $($highRiskFiles -join ', ')"
    }
  }

  $diffText = Invoke-Step "read_diff_for_secret_markers" {
    gh pr diff $PrNumber
  }
  $diffText = ($diffText | Out-String)

  if (-not $DryRun) {
    $secretMarkers = @(
      ("access" + "_token"),
      ("refresh" + "_token"),
      ("TELEMETRY_NODE" + "_SECRET="),
      ("CODEX" + "_AUTH")
    )
    $secretPattern = "(?i)(" + (($secretMarkers | ForEach-Object { [regex]::Escape($_) }) -join "|") + ")"
    if ($diffText -match $secretPattern) {
      throw "Refusing auto-merge because the PR diff contains an obvious secret marker."
    }
  }

  $mergeArgs = @("pr", "merge", "$PrNumber")
  if ($Squash) {
    $mergeArgs += "--squash"
  } else {
    $mergeArgs += "--merge"
  }
  if ($DeleteBranch) {
    $mergeArgs += "--delete-branch"
  }

  Invoke-Step "merge_pr" {
    gh @mergeArgs
  }

  Invoke-Step "checkout_main" { git switch main }
  Invoke-Step "pull_main_ff_only" { git pull --ff-only origin main }

  if (-not $DryRun) {
    $sha = (git rev-parse HEAD).Trim()
    Write-Host "main_sha=$sha"
  }
} finally {
  Pop-Location
}
