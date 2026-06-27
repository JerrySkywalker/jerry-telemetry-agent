param(
  [string]$Config = ".\deploy\examples\general-linux-agent.node.json",
  [string]$SmokeRoot = ".smoke\server-daemon"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Assert-SafeText {
  param([Parameter(Mandatory = $true)][string]$Text)

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
    if ($Text.Contains($marker)) {
      throw "daemon output contains a forbidden marker"
    }
  }
}

function Read-SafeJsonFile {
  param([Parameter(Mandatory = $true)][string]$Path)

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "required daemon output missing"
  }
  $text = Get-Content -Raw -LiteralPath $Path
  Assert-SafeText -Text $text
  return ($text | ConvertFrom-Json)
}

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$runId = Get-Date -Format "yyyyMMdd-HHmmss-ffff"
$runRoot = Join-Path (Join-Path $repoRoot $SmokeRoot) $runId
$outFile = Join-Path $runRoot "server.batch.safe.json"
$latestFile = Join-Path $runRoot "server.batch.latest.safe.json"
$statePath = Join-Path $runRoot "agent-state.json"
$spoolDir = Join-Path $runRoot "spool"
New-Item -ItemType Directory -Force -Path $runRoot | Out-Null

Push-Location $repoRoot
try {
  $runOutput = & "$PSScriptRoot\server-agent-daemon.ps1" `
    -Config $Config `
    -Output FileOnly `
    -OutFile $outFile `
    -LatestFile $latestFile `
    -StatePath $statePath `
    -SpoolDir $spoolDir `
    -IntervalSeconds 1 `
    -MaxIterations 2 2>&1
  if ($LASTEXITCODE -ne 0) { throw "server daemon smoke failed" }
  Assert-SafeText -Text ($runOutput -join "`n")

  $batch = Read-SafeJsonFile -Path $latestFile
  $state = Read-SafeJsonFile -Path $statePath
  if ($batch.schema_version -ne "v1") { throw "daemon batch schema mismatch" }
  if ($batch.events.Count -le 0) { throw "daemon batch emitted no events" }
  $types = @($batch.events | ForEach-Object { $_.event_type })
  foreach ($required in @("node.snapshot", "node.resources.snapshot", "service.health.snapshot", "docker.containers.snapshot", "systemd.units.snapshot", "custom.snapshot", "telemetry.agent.health")) {
    if (-not ($types -contains $required)) {
      throw "daemon batch missing event type $required"
    }
  }
  if ($state.lastServerBatchEventsCount -le 0) { throw "daemon state was not updated" }
  if ($state.pendingBatchSpoolCount -ne 0) { throw "daemon file-only smoke should not create batch spool" }
  if (-not (Test-Path -LiteralPath $outFile -PathType Leaf)) { throw "daemon file output missing" }

  Write-Host "PASS server_daemon_file_only iterations=2"
  Write-Host "PASS server_daemon_events_count=$($batch.events.Count)"
  Write-Host "PASS server_daemon_state_updated=true"
  Write-Host "PASS forbidden_markers_found=false"
} finally {
  Pop-Location
}
