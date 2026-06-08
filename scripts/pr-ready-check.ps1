$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Push-Location $repoRoot
try {
  Write-Host "check=branch status=running"
  $branch = (git branch --show-current).Trim()
  if (-not $branch) {
    throw "Could not determine current branch."
  }
  if ($branch -eq "main") {
    throw "PRs must be opened from a feature branch, not main."
  }
  Write-Host "check=branch status=ok branch=$branch"

  Write-Host "check=working_tree status=running"
  $status = git status --porcelain
  if ($status) {
    git status --short
    throw "Working tree is dirty. Commit or stash changes before marking PR ready."
  }
  Write-Host "check=working_tree status=ok"

  Write-Host "check=validate_local status=running"
  & (Join-Path $PSScriptRoot "validate-local.ps1")
  Write-Host "check=validate_local status=ok"

  $scanScript = Join-Path $PSScriptRoot "scan-secrets-light.ps1"
  if (Test-Path $scanScript) {
    Write-Host "check=scan_secrets_light status=running"
    & $scanScript
    Write-Host "check=scan_secrets_light status=ok"
  }

  Write-Host ""
  Write-Host "status=ready branch=$branch"
  Write-Host "suggested_pr_command=gh pr create --base main --head $branch --fill --draft"
} finally {
  Pop-Location
}
