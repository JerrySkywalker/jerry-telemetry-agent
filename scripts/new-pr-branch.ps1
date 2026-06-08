param(
  [Parameter(Mandatory = $true, Position = 0)]
  [ValidatePattern("^(feat|fix|docs|chore|test|refactor)/[a-z0-9][a-z0-9-]*$")]
  [string]$BranchName,

  [switch]$Force
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Push-Location $repoRoot
try {
  $dirty = git status --porcelain
  if ($dirty -and -not $Force) {
    throw "Working tree is dirty. Commit, stash, or rerun with -Force."
  }

  git switch main

  $upstream = git rev-parse --abbrev-ref --symbolic-full-name "main@{u}" 2>$null
  if ($LASTEXITCODE -eq 0 -and $upstream) {
    git pull --ff-only
  }

  git switch -c $BranchName
  Write-Host "Created PR branch $BranchName from main."
} finally {
  Pop-Location
}
