param(
  [string]$Config = ".\deploy\examples\general-linux-agent.node.json",
  [string]$OutFile = ".smoke\server-agent\server.batch.safe.json"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Assert-SafeFile {
  param([Parameter(Mandatory = $true)][string]$Path)

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "server batch output missing"
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
      throw "server batch contains a forbidden marker"
    }
  }
  return ($text | ConvertFrom-Json)
}

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$outputPath = Join-Path $repoRoot $OutFile
New-Item -ItemType Directory -Force -Path ([IO.Path]::GetDirectoryName($outputPath)) | Out-Null

Push-Location $repoRoot
try {
  $runOutput = & "$PSScriptRoot\server-agent-once.ps1" -Config $Config -Output FileOnly -OutFile $outputPath 2>&1
  if ($LASTEXITCODE -ne 0) { throw "server one-shot failed" }

  $batch = Assert-SafeFile -Path $outputPath
  if ($batch.schema_version -ne "v1") { throw "server batch schema mismatch" }
  $types = @($batch.events | ForEach-Object { $_.event_type })
  foreach ($required in @("node.snapshot", "node.resources.snapshot", "service.health.snapshot", "docker.containers.snapshot", "systemd.units.snapshot", "custom.snapshot", "telemetry.agent.health")) {
    if (-not ($types -contains $required)) {
      throw "server batch missing event type $required"
    }
  }

  Write-Host "PASS server_file_only events_count=$($batch.events.Count)"
  Write-Host "PASS forbidden_markers_found=false"
} finally {
  Pop-Location
}
