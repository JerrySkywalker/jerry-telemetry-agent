$ErrorActionPreference = "Stop"

Set-StrictMode -Version Latest

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Push-Location $repoRoot
try {
  if (Test-Path "package-lock.json") {
    npm ci
  } else {
    npm install
  }

  npm run typecheck
  npm test
  npm run build
  docker compose config --quiet

  Write-Host "Local validation completed."
} finally {
  Pop-Location
}
