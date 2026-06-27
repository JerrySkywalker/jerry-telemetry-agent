param(
  [string]$OutputDir = ".smoke\local-agent"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Assert-SafeFile {
  param([Parameter(Mandatory = $true)][string]$Path)

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "safe output file missing"
  }
  $text = Get-Content -Raw -LiteralPath $Path
  $forbidden = @(
    "TELEMETRY_NODE_SECRET=",
    "TELEMETRY_READ_TOKEN=",
    "Authorization: Bearer ",
    ("access" + "_token"),
    ("refresh" + "_token"),
    "id_token",
    "auth.json",
    "account_id",
    "user_id",
    "email",
    "raw_response",
    "BEGIN OPENSSH PRIVATE KEY"
  )
  foreach ($marker in $forbidden) {
    if ($text.Contains($marker)) {
      throw "safe output file contains a forbidden marker"
    }
  }
  return ($text | ConvertFrom-Json)
}

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$outputRoot = Join-Path $repoRoot $OutputDir
$fixtureFile = Join-Path $outputRoot "fixture.batch.safe.json"
$localFile = Join-Path $outputRoot "local.batch.safe.json"

Push-Location $repoRoot
try {
  New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null

  $fixtureOutput = & "$PSScriptRoot\agent-once.ps1" -Mode Fixture -Output FileOnly -NodeId "local-win-dev-01" -Region "local" -Role "dev-node" -Provider "local" -OutFile $fixtureFile 2>&1
  if ($LASTEXITCODE -ne 0) { throw "fixture one-shot failed" }
  $fixture = Assert-SafeFile -Path $fixtureFile
  if ($fixture.schema_version -ne "v1") { throw "fixture batch schema mismatch" }
  if ($fixture.events.Count -lt 5) { throw "fixture batch event count mismatch" }

  $localOutput = & "$PSScriptRoot\agent-once.ps1" -Mode LocalWindows -Output FileOnly -NodeId "local-win-dev-01" -Region "local" -Role "dev-node" -Provider "local" -OutFile $localFile 2>&1
  if ($LASTEXITCODE -ne 0) { throw "local one-shot failed" }
  $local = Assert-SafeFile -Path $localFile
  $localTypes = @($local.events | ForEach-Object { $_.event_type })
  if (-not ($localTypes -contains "node.snapshot")) { throw "local node snapshot missing" }
  if (-not ($localTypes -contains "node.resources.snapshot")) { throw "local resources snapshot missing" }

  Write-Host "PASS fixture_file_only events_count=$($fixture.events.Count)"
  Write-Host "PASS localwindows_file_only events_count=$($local.events.Count)"
  Write-Host "PASS forbidden_markers_found=false"
} finally {
  Pop-Location
}
