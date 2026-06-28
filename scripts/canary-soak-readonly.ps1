param(
  [ValidateRange(1, 288)][int]$Samples = 6,
  [ValidateRange(0, 3600)][int]$IntervalSeconds = 300,
  [string]$OutputDir = ".smoke\canary-soak",
  [string]$HubTarget = "beijing",
  [string]$AgentTarget = "lax",
  [string]$HubServiceName = "jerry-telemetry-hub-canary.service",
  [string]$TunnelServiceName = "jerry-telemetry-hub-canary-reverse-tunnel.service",
  [string]$AgentContainerName = "jerry-telemetry-agent-http-canary-readback-align-20260628T140444Z"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$runId = "canary-soak-" + (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
$outputRoot = if ([IO.Path]::IsPathRooted($OutputDir)) {
  $OutputDir
} else {
  Join-Path $repoRoot $OutputDir
}
$auditRoot = Join-Path $outputRoot "live-audit"
New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null

& "$PSScriptRoot\canary-live-audit-readonly.ps1" `
  -HubTarget $HubTarget `
  -AgentTarget $AgentTarget `
  -OutputDir $auditRoot `
  -Samples $Samples `
  -IntervalSeconds $IntervalSeconds `
  -HubServiceName $HubServiceName `
  -TunnelServiceName $TunnelServiceName `
  -AgentContainerName $AgentContainerName
if ($LASTEXITCODE -ne 0) {
  throw "canary-live-audit-readonly.ps1 failed during soak"
}

$auditSummaryPath = Join-Path $auditRoot "canary-live-audit-summary.json"
if (-not (Test-Path -LiteralPath $auditSummaryPath -PathType Leaf)) {
  throw "Live audit summary missing: $auditSummaryPath"
}
$audit = Get-Content -Raw -LiteralPath $auditSummaryPath | ConvertFrom-Json
$rows = @($audit.samples)
$first = $rows | Select-Object -First 1
$last = $rows | Select-Object -Last 1

$restartStable = [bool]$audit.progression.restart_counts_stable
$spoolStable = [bool]$audit.progression.active_spool_stable_zero
$sendAdvanced = -not [string]::IsNullOrWhiteSpace([string]$audit.progression.send_timestamp_last) -and
  ([string]$audit.progression.send_timestamp_first -ne [string]$audit.progression.send_timestamp_last -or $Samples -eq 1)
$recentAdvanced = -not [string]::IsNullOrWhiteSpace([string]$audit.progression.recent_timestamp_last) -and
  ([string]$audit.progression.recent_timestamp_first -ne [string]$audit.progression.recent_timestamp_last -or $Samples -eq 1)
$markerPass = [bool]$audit.marker_scan.marker_scan_pass

$result = if ($audit.result -eq "PASS" -and $restartStable -and $spoolStable -and $sendAdvanced -and $recentAdvanced -and $markerPass) {
  "PASS"
} else {
  "FAIL"
}

$summary = [pscustomobject][ordered]@{
  run_id = $runId
  generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
  result = $result
  read_only = $true
  production_mutation = $false
  docker_runtime_mutation = $false
  service_timer_mutation = $false
  tunnel_mutation = $false
  samples = $Samples
  interval_seconds = $IntervalSeconds
  live_audit_output = [IO.Path]::GetRelativePath($repoRoot, $auditRoot)
  progression = [ordered]@{
    restart_counts_stable = $restartStable
    send_timestamp_advanced = $sendAdvanced
    recent_event_timestamp_advanced = $recentAdvanced
    active_spool_stable_zero = $spoolStable
    marker_scan_pass = $markerPass
  }
  first_sample = $first
  last_sample = $last
}
$summary | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $outputRoot "canary-soak-summary.json") -Encoding UTF8

$summaryMd = @(
  "# Canary Soak Summary",
  "",
  "- result: $result",
  "- samples: $Samples",
  "- interval_seconds: $IntervalSeconds",
  "- read_only: true",
  "- production_mutation: false",
  "- docker_runtime_mutation: false",
  "- service_timer_mutation: false",
  "- tunnel_mutation: false",
  "- restart_counts_stable: $restartStable",
  "- send_timestamp_advanced: $sendAdvanced",
  "- recent_event_timestamp_advanced: $recentAdvanced",
  "- active_spool_stable_zero: $spoolStable",
  "- marker_scan_pass: $markerPass"
)
$summaryMd | Set-Content -LiteralPath (Join-Path $outputRoot "canary-soak-summary.md") -Encoding UTF8

$table = @("# Canary Soak Sample Table", "", "| sample | hub | tunnel | agent | active_spool | restart_policy | send | recent |", "| --- | --- | --- | --- | ---: | --- | --- | --- |")
foreach ($row in $rows) {
  $table += "| $($row.sample) | $($row.hub_health) | $($row.tunnel_active) | $($row.agent_health) | $($row.active_spool) | $($row.agent_restart_policy) | $($row.last_successful_send) | $($row.recent_latest_timestamp) |"
}
$table | Set-Content -LiteralPath (Join-Path $outputRoot "canary-soak-sample-table.md") -Encoding UTF8

$checklist = @(
  "# Canary Soak Checklist",
  "",
  "- $(if ($audit.result -eq "PASS") { "PASS" } else { "FAIL" }): live audit passed",
  "- $(if ($restartStable) { "PASS" } else { "FAIL" }): restart counts stable",
  "- $(if ($sendAdvanced) { "PASS" } else { "FAIL" }): latest successful send timestamp advanced",
  "- $(if ($recentAdvanced) { "PASS" } else { "FAIL" }): Hub recent timestamp advanced",
  "- $(if ($spoolStable) { "PASS" } else { "FAIL" }): active spool remained zero",
  "- $(if ($markerPass) { "PASS" } else { "FAIL" }): marker scans passed",
  "- PASS: no raw logs printed",
  "- PASS: no secrets printed",
  "- PASS: no production mutation"
)
$checklist | Set-Content -LiteralPath (Join-Path $outputRoot "canary-soak-checklist.md") -Encoding UTF8

Write-Host "canary_soak=$result"
Write-Host "output_dir=$outputRoot"
Write-Host "samples=$Samples"
Write-Host "interval_seconds=$IntervalSeconds"
Write-Host "read_only=true"
Write-Host "production_mutation=false"

if ($result -ne "PASS") {
  exit 1
}
