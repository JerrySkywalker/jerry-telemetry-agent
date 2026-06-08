param(
  [Parameter(Mandatory = $true)]
  [ValidatePattern("^(feat|fix|docs|chore|test|refactor)/[a-z0-9][a-z0-9-]*$")]
  [string]$BranchName,

  [Parameter(Mandatory = $true)]
  [string]$CommitMessage,

  [Parameter(Mandatory = $true)]
  [string]$PrTitle,

  [Parameter(Mandatory = $true)]
  [string]$PrBody,

  [switch]$AutoMergeSafe,
  [switch]$SkipPush,
  [switch]$SkipPr,
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

function Get-GitBranch {
  return (git branch --show-current).Trim()
}

function Get-GitChanges {
  return @(git status --porcelain)
}

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Push-Location $repoRoot
try {
  Assert-Command "git"
  git rev-parse --is-inside-work-tree *> $null
  if ($LASTEXITCODE -ne 0) {
    throw "Current directory is not inside a Git repository."
  }

  Assert-Command "npm"
  Assert-Command "docker"
  if (-not $SkipPr) {
    Assert-Command "gh"
  }

  $branch = Get-GitBranch
  if (-not $branch) {
    throw "Could not determine current branch."
  }

  if ($branch -ne "main" -and $branch -ne $BranchName) {
    Invoke-Step "switch_to_main" { git switch main }
    $branch = Get-GitBranch
  }

  if ($branch -eq "main") {
    $dirtyMain = Get-GitChanges
    if ($dirtyMain.Count -gt 0) {
      git status --short
      throw "Local main is dirty. Commit, stash, or clean changes before starting an autonomous PR."
    }

    Invoke-Step "fetch_origin" { git fetch origin }
    Invoke-Step "pull_main_ff_only" { git pull --ff-only origin main }

    $existingBranch = git branch --list $BranchName
    if ($existingBranch) {
      Invoke-Step "switch_existing_branch" { git switch $BranchName }
    } else {
      Invoke-Step "create_feature_branch" { git switch -c $BranchName }
    }
  } elseif ($branch -eq $BranchName) {
    Write-Host "step=already_on_feature_branch"
  }

  $changes = Get-GitChanges
  if ($changes.Count -eq 0) {
    Write-Host "status=no_changes"
    Write-Host "message=Implement the goal, then rerun this script from $BranchName."
    exit 2
  }

  Invoke-Step "npm_install" { npm install }
  Invoke-Step "npm_typecheck" { npm run typecheck }
  Invoke-Step "npm_test" { npm test }
  Invoke-Step "npm_build" { npm run build }
  Invoke-Step "docker_compose_config" { docker compose config }

  $validateScript = Join-Path $PSScriptRoot "validate-local.ps1"
  if (Test-Path $validateScript) {
    Invoke-Step "validate_local" { & $validateScript }
  }

  $scanScript = Join-Path $PSScriptRoot "scan-secrets-light.ps1"
  if (Test-Path $scanScript) {
    Invoke-Step "scan_secrets_light" { & $scanScript }
  }

  Invoke-Step "git_add" { git add --all }

  if ($DryRun) {
    Write-Host "status=dry_run_ready_to_commit"
  } else {
    $staged = @(git diff --cached --name-only)
    if ($staged.Count -eq 0) {
      Write-Host "status=no_staged_changes"
      exit 2
    }
  }

  Invoke-Step "git_commit" { git commit -m $CommitMessage }

  if (-not $SkipPush) {
    Invoke-Step "git_push" { git push -u origin $BranchName }
  } else {
    Write-Host "skip=push"
  }

  if (-not $SkipPr) {
    $prUrl = ""
    Invoke-Step "create_pr" {
      gh pr create --base main --head $BranchName --title $PrTitle --body $PrBody
    }
    $prUrl = ($prUrl | Out-String).Trim()
    Write-Host "pr_url=$prUrl"

    if ($AutoMergeSafe) {
      $prNumber = Invoke-Step "read_pr_number" {
        gh pr view $BranchName --json number --jq ".number"
      }
      $prNumber = ($prNumber | Out-String).Trim()

      $mergeScript = Join-Path $PSScriptRoot "merge-pr-if-green.ps1"
      Invoke-Step "auto_merge_if_green" {
        & $mergeScript -PrNumber ([int]$prNumber) -DeleteBranch -Squash
      }
    }
  } else {
    Write-Host "skip=pr"
  }
} finally {
  Pop-Location
}
