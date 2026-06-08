$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Push-Location $repoRoot
try {
  $branch = (git branch --show-current).Trim()
  if (-not $branch) {
    throw "Could not determine current branch."
  }
  if ($branch -eq "main") {
    throw "PRs must be opened from a feature branch, not main."
  }

  $status = git status --porcelain
  if ($status) {
    git status --short
    throw "Working tree is dirty. Commit or stash changes before marking PR ready."
  }

  & (Join-Path $PSScriptRoot "validate-local.ps1")

  Write-Host ""
  Write-Host "Suggested PR command:"
  Write-Host "gh pr create --base main --head $branch --fill --draft"
} finally {
  Pop-Location
}
