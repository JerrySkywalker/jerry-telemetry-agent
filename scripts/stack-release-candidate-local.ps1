param(
  [string]$HubRepoPath = (Join-Path (Resolve-Path (Join-Path $PSScriptRoot "..\..")) "jerry-telemetry-hub"),
  [string]$OutputDir = ".smoke\stack-rc",
  [switch]$SkipHubGate,
  [switch]$SkipAgentGate,
  [switch]$SkipE2E,
  [switch]$AllowMissingHub,
  [switch]$Json
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$runId = "stack-rc-" + (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
$outputRoot = if ([IO.Path]::IsPathRooted($OutputDir)) { $OutputDir } else { Join-Path $repoRoot $OutputDir }
$runRoot = Join-Path $outputRoot $runId
$artifactDir = Join-Path $runRoot "artifacts"
$artifactDirForPackage = [IO.Path]::GetRelativePath($repoRoot, $artifactDir)
$commands = @()
$startedAt = Get-Date

function Add-CommandResult {
  param(
    [string]$Name,
    [string]$Status,
    [int]$ExitCode,
    [double]$DurationSeconds,
    [int]$OutputLines,
    [string]$Reason = ""
  )
  $script:commands += [pscustomobject][ordered]@{
    name = $Name
    status = $Status
    exit_code = $ExitCode
    duration_seconds = [Math]::Round($DurationSeconds, 3)
    output_lines = $OutputLines
    reason = $Reason
  }
}

function Assert-SafeText {
  param([string]$Text, [string]$Label)
  $forbidden = @(
    "TELEMETRY_NODE_SECRET=",
    "TELEMETRY_READ_TOKEN=",
    "Authorization: Bearer ",
    "Authorization:",
    "Cookie:",
    "Set-Cookie:",
    "access_token",
    "refresh_token",
    "id_token",
    "account_id",
    "user_id",
    "raw_response",
    "BEGIN OPENSSH PRIVATE KEY"
  )
  foreach ($marker in $forbidden) {
    if ($Text.ToLowerInvariant().Contains($marker.ToLowerInvariant())) {
      throw "$Label contains forbidden marker"
    }
  }
}

function Invoke-CapturedStep {
  param(
    [string]$Name,
    [string]$WorkingDirectory,
    [scriptblock]$Script
  )

  Write-Host "START $Name"
  $stepStart = Get-Date
  Push-Location $WorkingDirectory
  try {
    $global:LASTEXITCODE = 0
    $output = @(& $Script *>&1)
    $exitCode = if ($LASTEXITCODE -ne $null) { [int]$LASTEXITCODE } else { 0 }
    $text = ($output | ForEach-Object { [string]$_ }) -join "`n"
    Assert-SafeText -Text $text -Label $Name
    if ($exitCode -ne 0) {
      Add-CommandResult -Name $Name -Status "fail" -ExitCode $exitCode -DurationSeconds ((Get-Date) - $stepStart).TotalSeconds -OutputLines $output.Count
      throw "$Name failed"
    }
    Add-CommandResult -Name $Name -Status "pass" -ExitCode 0 -DurationSeconds ((Get-Date) - $stepStart).TotalSeconds -OutputLines $output.Count
    Write-Host "PASS $Name"
  } catch {
    if (-not ($commands | Where-Object { $_.name -eq $Name })) {
      Add-CommandResult -Name $Name -Status "fail" -ExitCode 1 -DurationSeconds ((Get-Date) - $stepStart).TotalSeconds -OutputLines 0 -Reason "safe failure"
    }
    throw
  } finally {
    Pop-Location
  }
}

function Invoke-Git {
  param([string]$Repo, [string[]]$GitArgs)
  $output = & git -C $Repo @GitArgs 2>$null
  if ($LASTEXITCODE -ne 0) { return "" }
  return ($output -join "`n").Trim()
}

function Get-PackageInfo {
  param([string]$Repo)
  $package = Get-Content -Raw -LiteralPath (Join-Path $Repo "package.json") | ConvertFrom-Json
  return [ordered]@{ name = [string]$package.name; version = [string]$package.version }
}

function Read-AgentPackageManifest {
  param([string]$Dir)
  $manifestPath = Join-Path $Dir "agent-package-manifest.json"
  if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "agent package manifest missing"
  }
  $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
  return [ordered]@{
    path = $manifestPath
    artifact_path = [string]$manifest.artifact_path
    file_count = [int]$manifest.file_count
    forbidden_marker_scan = [string]$manifest.forbidden_marker_scan
  }
}

function Get-CommandStatus {
  param([string]$Name)
  foreach ($entry in $commands) {
    if ($entry.name -eq $Name) { return [string]$entry.status }
  }
  return "not_run"
}

function Get-CommandsByStatus {
  param([string]$Status)
  $items = @()
  foreach ($entry in $commands) {
    if ($entry.status -eq $Status) { $items += $entry }
  }
  return $items
}

function Write-Reports {
  param([hashtable]$State)

  $reportJson = [string]$State["report_path_json"]
  $manifestJson = [string]$State["manifest_path"]
  $reportMd = [string]$State["report_path_markdown"]

  $State | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $reportJson -Encoding UTF8
  $manifest = [ordered]@{
    generated_at = $State.generated_at
    status = $State.status
    agent = $State.agent
    hub = $State.hub
    package = $State.package
    contract = $State.contract
    skipped = $State.skipped
    production_mutation = $false
  }
  $manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $manifestJson -Encoding UTF8

  $md = @(
    "# Telemetry Stack Release Candidate",
    "",
    "- Status: $($State.status)",
    "- Generated at: $($State.generated_at)",
    "- Agent commit: $($State.agent.commit)",
    "- Hub commit: $($State.hub.commit)",
    "- Agent package: $($State.agent.package.name)@$($State.agent.package.version)",
    "- Hub package: $($State.hub.package.name)@$($State.hub.package.version)",
    "- Package artifact: $($State.package.artifact_path)",
    "- Production mutation: false",
    "",
    "## Commands",
    ($State.commands | ForEach-Object { "- $($_.status): $($_.name)" }),
    "",
    "## Contract",
    "- Event types: $($State.contract.event_types -join ', ')",
    "- Endpoints: $($State.contract.endpoints -join ', ')",
    "- Recent history: $($State.contract.recent_history)",
    "- Idempotency: $($State.contract.idempotency)",
    "- Read model: $($State.contract.read_model)"
  ) -join "`n"
  $md | Set-Content -LiteralPath $reportMd -Encoding UTF8

  Assert-SafeText -Text (Get-Content -Raw -LiteralPath $reportJson) -Label "stack rc report json"
  Assert-SafeText -Text (Get-Content -Raw -LiteralPath $manifestJson) -Label "stack rc manifest json"
  Assert-SafeText -Text (Get-Content -Raw -LiteralPath $reportMd) -Label "stack rc report markdown"
}

New-Item -ItemType Directory -Force -Path $runRoot, $artifactDir | Out-Null

$hubPresent = Test-Path -LiteralPath (Join-Path $HubRepoPath "package.json") -PathType Leaf
if (-not $hubPresent -and -not $AllowMissingHub) {
  throw "sibling Hub repo missing"
}

Invoke-CapturedStep "stack doctor" $repoRoot {
  if ($AllowMissingHub) {
    & "$PSScriptRoot\stack-doctor-local.ps1" -AgentRepoPath $repoRoot -HubRepoPath $HubRepoPath -Json -AllowMissingHub
  } else {
    & "$PSScriptRoot\stack-doctor-local.ps1" -AgentRepoPath $repoRoot -HubRepoPath $HubRepoPath -Json
  }
}

if ($SkipHubGate) {
  Add-CommandResult -Name "Hub release gate" -Status "skip" -ExitCode 0 -DurationSeconds 0 -OutputLines 0 -Reason "SkipHubGate"
} elseif ($hubPresent) {
  Invoke-CapturedStep "Hub release gate" $HubRepoPath { & ".\scripts\release-gate-local.ps1" }
} elseif ($AllowMissingHub) {
  Add-CommandResult -Name "Hub release gate" -Status "skip" -ExitCode 0 -DurationSeconds 0 -OutputLines 0 -Reason "sibling_hub_repo_missing"
}

if ($SkipAgentGate) {
  Add-CommandResult -Name "Agent release gate" -Status "skip" -ExitCode 0 -DurationSeconds 0 -OutputLines 0 -Reason "SkipAgentGate"
} else {
  Invoke-CapturedStep "Agent release gate" $repoRoot { & ".\scripts\release-gate-local.ps1" -HubRepoPath $HubRepoPath }
}

if ($SkipE2E) {
  Add-CommandResult -Name "Agent Hub E2E Once" -Status "skip" -ExitCode 0 -DurationSeconds 0 -OutputLines 0 -Reason "SkipE2E"
  Add-CommandResult -Name "Agent Hub E2E Daemon" -Status "skip" -ExitCode 0 -DurationSeconds 0 -OutputLines 0 -Reason "SkipE2E"
} elseif ($hubPresent) {
  Invoke-CapturedStep "Agent Hub E2E Once" $repoRoot { & ".\scripts\smoke-local-hub-agent-e2e.ps1" -Mode Once -HubRepoPath $HubRepoPath -SmokeRoot (Join-Path $runRoot "e2e-once") }
  Invoke-CapturedStep "Agent Hub E2E Daemon" $repoRoot { & ".\scripts\smoke-local-hub-agent-e2e.ps1" -Mode Daemon -HubRepoPath $HubRepoPath -SmokeRoot (Join-Path $runRoot "e2e-daemon") }
} elseif ($AllowMissingHub) {
  Add-CommandResult -Name "Agent Hub E2E Once" -Status "skip" -ExitCode 0 -DurationSeconds 0 -OutputLines 0 -Reason "sibling_hub_repo_missing"
  Add-CommandResult -Name "Agent Hub E2E Daemon" -Status "skip" -ExitCode 0 -DurationSeconds 0 -OutputLines 0 -Reason "sibling_hub_repo_missing"
}

Invoke-CapturedStep "Agent package check" $repoRoot { & ".\scripts\package-agent-local.ps1" -OutputDir $artifactDirForPackage }

$agentPackage = Get-PackageInfo $repoRoot
$hubPackage = if ($hubPresent) { Get-PackageInfo $HubRepoPath } else { [ordered]@{ name = ""; version = "" } }
$packageManifest = Read-AgentPackageManifest $artifactDir
$skipped = @(Get-CommandsByStatus "skip")
$failed = @(Get-CommandsByStatus "fail")
$status = if ($failed.Count -eq 0 -and ($skipped.Count -eq 0 -or $AllowMissingHub -or $SkipHubGate -or $SkipAgentGate -or $SkipE2E)) { "pass" } else { "fail" }

$state = [ordered]@{
  generated_at = (Get-Date).ToUniversalTime().ToString("o")
  status = $status
  platform = [ordered]@{ os = [System.Runtime.InteropServices.RuntimeInformation]::OSDescription; powershell = $PSVersionTable.PSVersion.ToString() }
  run_root = $runRoot
  agent = [ordered]@{
    path = [string]$repoRoot
    branch = Invoke-Git -Repo $repoRoot -GitArgs @("branch", "--show-current")
    commit = Invoke-Git -Repo $repoRoot -GitArgs @("rev-parse", "HEAD")
    package = $agentPackage
    release_gate_status = Get-CommandStatus "Agent release gate"
  }
  hub = [ordered]@{
    path = $HubRepoPath
    present = [bool]$hubPresent
    branch = if ($hubPresent) { Invoke-Git -Repo $HubRepoPath -GitArgs @("branch", "--show-current") } else { "" }
    commit = if ($hubPresent) { Invoke-Git -Repo $HubRepoPath -GitArgs @("rev-parse", "HEAD") } else { "" }
    package = $hubPackage
    release_gate_status = Get-CommandStatus "Hub release gate"
  }
  commands = @($commands)
  skipped = @($skipped)
  package = $packageManifest
  contract = [ordered]@{
    event_types = @("node.snapshot", "node.resources.snapshot", "service.health.snapshot", "custom.snapshot", "telemetry.agent.health", "docker.containers.snapshot", "systemd.units.snapshot")
    endpoints = @("POST /v1/events/batch", "GET /v1/nodes", "GET /v1/summary", "GET /v1/services", "GET /v1/custom", "GET /v1/events/recent")
    recent_history = if ($hubPresent -and -not $SkipHubGate) { "covered_by_hub_release_gate" } else { "not_run" }
    idempotency = if ($hubPresent -and -not $SkipHubGate) { "covered_by_hub_release_gate" } else { "not_run" }
    read_model = if (-not $SkipE2E -and $hubPresent) { "covered_by_agent_hub_e2e" } else { "not_run" }
    artifact_compatibility = if ($packageManifest.forbidden_marker_scan -eq "pass") { "pass" } else { "fail" }
  }
  safety = [ordered]@{ production_mutation = $false; secret_values_printed = $false; raw_env_printed = $false; raw_logs_included = $false }
  duration_seconds = [Math]::Round(((Get-Date) - $startedAt).TotalSeconds, 3)
  report_path_json = (Join-Path $runRoot "stack-rc-report.json")
  report_path_markdown = (Join-Path $runRoot "stack-rc-report.md")
  manifest_path = (Join-Path $runRoot "stack-rc-manifest.json")
}

Write-Reports -State $state

if ($Json) {
  $state | ConvertTo-Json -Depth 12
} else {
  Write-Host "stack_rc_status=$($state.status)"
  Write-Host "stack_rc_report_json=$($state["report_path_json"])"
  Write-Host "stack_rc_report_markdown=$($state["report_path_markdown"])"
  Write-Host "stack_rc_manifest=$($state["manifest_path"])"
  Write-Host "production_mutation=false"
  Write-Host "forbidden_marker_scan=pass"
}

if ($state.status -ne "pass") {
  exit 1
}
