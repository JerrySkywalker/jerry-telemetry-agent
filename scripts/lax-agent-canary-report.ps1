param(
  [string]$SshHost = "lax",
  [string]$ProjectDir = "~/jerry-telemetry-agent",
  [string]$HubBaseUrl = "https://telemetry.jerryskywalker.space",
  [string]$ComposeProject = "jerry-telemetry-agent"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$statusScript = Join-Path $PSScriptRoot "lax-agent-status.ps1"
if (-not (Test-Path -LiteralPath $statusScript)) {
  throw "Missing status script: $statusScript"
}

$raw = & $statusScript -SshHost $SshHost -ProjectDir $ProjectDir -HubBaseUrl $HubBaseUrl -ComposeProject $ComposeProject
if ($LASTEXITCODE -ne 0) {
  throw "Status script failed with exit code $LASTEXITCODE"
}

$status = @{}
foreach ($line in $raw) {
  if ($line -notmatch "^([^=]+)=(.*)$") {
    continue
  }
  $status[$Matches[1]] = $Matches[2]
}

function Get-StatusValue {
  param(
    [Parameter(Mandatory = $true)][hashtable]$Status,
    [Parameter(Mandatory = $true)][string]$Name
  )
  if ($Status.ContainsKey($Name)) {
    return $Status[$Name]
  }
  return ""
}

$requiredChecks = [ordered]@{
  ssh_ok = "true"
  project_dir_exists = "true"
  env_file_exists = "true"
  env_secret_nonempty = "true"
  env_backups_mode_safe = "true"
  container_running = "true"
  container_secret_nonempty = "true"
  compose_config_with_env = "ok"
  healthz_ok = "true"
  pending_spool_count = "0"
  latest_snapshot_status_ok = "true"
  latest_snapshot_limits_count = "2"
  old_timer_active = "inactive"
  old_timer_enabled = "disabled"
}

$failedChecks = New-Object System.Collections.Generic.List[string]
foreach ($item in $requiredChecks.GetEnumerator()) {
  $actual = Get-StatusValue $status $item.Key
  if ($actual -ne $item.Value) {
    $failedChecks.Add("$($item.Key):$actual")
  }
}
$healthy = $failedChecks.Count -eq 0

Write-Host "observation_time_utc=$((Get-Date).ToUniversalTime().ToString("o"))"
Write-Host "primary_candidate=Docker backend usage daemon"
Write-Host "canary_healthy=$($healthy.ToString().ToLowerInvariant())"
Write-Host "failed_checks=$($failedChecks -join ",")"
Write-Host "node_id=$(Get-StatusValue $status "node_id")"
Write-Host "hostname=$(Get-StatusValue $status "hostname")"
Write-Host "collector=$(Get-StatusValue $status "collector")"
Write-Host "container_running=$(Get-StatusValue $status "container_running")"
Write-Host "healthz_ok=$(Get-StatusValue $status "healthz_ok")"
Write-Host "pending_spool_count=$(Get-StatusValue $status "pending_spool_count")"
Write-Host "latest_snapshot_status_ok=$(Get-StatusValue $status "latest_snapshot_status_ok")"
Write-Host "latest_snapshot_limits_count=$(Get-StatusValue $status "latest_snapshot_limits_count")"
Write-Host "hub_latest_event_id=$(Get-StatusValue $status "hub_latest_event_id")"
Write-Host "hub_latest_received_at=$(Get-StatusValue $status "hub_latest_received_at")"
Write-Host "hub_latest_observed_at=$(Get-StatusValue $status "hub_latest_observed_at")"
Write-Host "env_file_mode=$(Get-StatusValue $status "env_file_mode")"
Write-Host "env_backup_count=$(Get-StatusValue $status "env_backup_count")"
Write-Host "env_backups_mode_safe=$(Get-StatusValue $status "env_backups_mode_safe")"
Write-Host "old_timer_active=$(Get-StatusValue $status "old_timer_active")"
Write-Host "old_timer_enabled=$(Get-StatusValue $status "old_timer_enabled")"
Write-Host "recommendation=Treat as current primary Codex usage telemetry runtime if latest observation remains healthy; keep old chain as manual fallback."
