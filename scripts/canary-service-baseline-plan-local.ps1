param(
  [ValidateSet("ObserveOnly", "StabilizeCanary", "RollbackReady")]
  [string]$Mode = "StabilizeCanary",
  [string]$EvidenceRoot = ".smoke",
  [string]$OutputDir = ".smoke\canary-service-baseline-plan",
  [string]$HubServiceName = "jerry-telemetry-hub-canary.service",
  [string]$TunnelServiceName = "jerry-telemetry-hub-canary-reverse-tunnel.service",
  [string]$AgentContainerName = "",
  [bool]$PreserveArchivedSpool = $true
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$evidenceRootPath = if ([IO.Path]::IsPathRooted($EvidenceRoot)) { $EvidenceRoot } else { Join-Path $repoRoot $EvidenceRoot }
$outputRoot = if ([IO.Path]::IsPathRooted($OutputDir)) { $OutputDir } else { Join-Path $repoRoot $OutputDir }

function Get-LatestEvidenceDirectory {
  param([string]$Pattern)
  if (-not (Test-Path -LiteralPath $evidenceRootPath -PathType Container)) {
    return $null
  }
  return Get-ChildItem -LiteralPath $evidenceRootPath -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like $Pattern } |
    Sort-Object LastWriteTimeUtc, Name -Descending |
    Select-Object -First 1
}

function Read-JsonSafe {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return $null
  }
  return Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
}

function Get-NestedValue {
  param([object]$Object, [string[]]$Path)
  $current = $Object
  foreach ($segment in $Path) {
    if ($null -eq $current) { return $null }
    $property = $current.PSObject.Properties[$segment]
    if ($null -eq $property) { return $null }
    $current = $property.Value
  }
  return $current
}

function New-ChecklistItem {
  param([string]$Name, [string]$Status, [string]$Evidence)
  return [pscustomobject][ordered]@{
    name = $Name
    status = $Status
    evidence = $Evidence
  }
}

$stabilizeDir = Get-LatestEvidenceDirectory "canary-stabilize-*"
$observeDir = Get-LatestEvidenceDirectory "http-canary-observe-03-*"
$promoteDir = Get-LatestEvidenceDirectory "canary-promote-plan-*"
if ($null -eq $stabilizeDir -or $null -eq $observeDir -or $null -eq $promoteDir) {
  Write-Error "Required canary evidence is missing under $evidenceRootPath"
}

$stabilize = Read-JsonSafe (Join-Path $stabilizeDir.FullName "canary-stabilize-summary.json")
$observe = Read-JsonSafe (Join-Path $observeDir.FullName "http-canary-observe-03-summary.json")
$promote = Read-JsonSafe (Join-Path $promoteDir.FullName "canary-promote-plan-summary.json")
if ($null -eq $stabilize -or $null -eq $observe -or $null -eq $promote) {
  Write-Error "Required canary summary JSON is missing"
}

$effectiveAgentContainerName = if ([string]::IsNullOrWhiteSpace($AgentContainerName)) {
  [string](Get-NestedValue $observe @("agent", "container"))
} else {
  $AgentContainerName
}

$activeSpool = Get-NestedValue $stabilize @("storage", "active_spool")
$oldArchive = Get-NestedValue $stabilize @("storage", "old_archive")
$failedArchive = Get-NestedValue $stabilize @("storage", "failed_archive")
$recentSend = [string](Get-NestedValue $observe @("agent", "successful_send_evidence"))
$recentHub = [string](Get-NestedValue $observe @("hub", "recent_latest_timestamp"))

$plan = [pscustomobject][ordered]@{
  generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
  mode = $Mode
  plan_only = $true
  commands_executed = $false
  live_ssh_used = $false
  production_mutation = $false
  evidence = [ordered]@{
    root = [IO.Path]::GetRelativePath($repoRoot, $evidenceRootPath)
    canary_stabilize = $stabilizeDir.Name
    http_canary_observe_03 = $observeDir.Name
    canary_promote_plan = $promoteDir.Name
  }
  services = [ordered]@{
    hub = [ordered]@{
      service_name = $HubServiceName
      baseline_role = "private receiver and read model canary"
      health_check_cadence = "daily and after each authorized canary change"
      sqlite_integrity_cadence = "daily during canary, then weekly after operator review"
      backup_cadence = "before any authorized mutation and on the approved maintenance schedule"
    }
    reverse_tunnel = [ordered]@{
      service_name = $TunnelServiceName
      baseline_role = "private localhost upload path from Agent host to Hub canary"
      reachability_check_cadence = "daily and during each canary observation"
      restart_policy_recommendation = "keep observable; any restart count increase requires review"
    }
    agent = [ordered]@{
      container_name = $effectiveAgentContainerName
      baseline_role = "HTTP upload canary producer"
      current_restart_policy_concern = "reported as no"
      supervision_recommendation = "do not mutate live runtime in this plan; review supervised service wrapper or compose-managed canary next"
      health_check_cadence = "daily and during each canary observation"
      status_check_cadence = "daily and during each canary observation"
    }
  }
  recommendations = [ordered]@{
    runtime_baseline = switch ($Mode) {
      "ObserveOnly" { "Keep the retained canary running and increase observation discipline only." }
      "RollbackReady" { "Keep rollback evidence fresh and verify file-only rollback plan before any live change." }
      default { "Stabilize as a long-running canary baseline without production rename." }
    }
    agent_supervision = "Prefer a reviewed systemd wrapper or compose-managed canary in a later authorized goal; do not change current container now."
    restart_policy = "Treat current no restart policy as a known operational issue, not a reason to mutate without approval."
    read_model_smoke = "Verify nodes, summary, services, custom, and recent event progression."
    tunnel_health = "Verify localhost tunnel reachability and non-local listener count stays zero."
    log_summary = "Summarize counts only; do not collect raw logs into reports."
  }
  thresholds = [ordered]@{
    pending_active_spool = "0 expected; greater than 0 for more than the approved interval requires review"
    last_successful_send_age = "older than 10 minutes requires diagnosis"
    restart_count = "any increase requires review"
    sqlite_integrity = "must be ok before any promotion decision"
    marker_scan = "must pass before treating evidence as usable"
  }
  evidence_summary = [ordered]@{
    active_spool = $activeSpool
    archived_old_spool = $oldArchive
    archived_failed_check_spool = $failedArchive
    preserve_archived_spool = $PreserveArchivedSpool
    latest_successful_send = $recentSend
    latest_hub_recent = $recentHub
    stale_error_timestamp_policy = "current error flag and latest successful send supersede stale prior timestamp"
  }
  boundaries = [ordered]@{
    production_rename = "forbidden without separate authorization"
    live_service_mutation = "forbidden in this plan"
    docker_runtime_mutation = "forbidden in this plan"
    ssh = "not used"
    lax_codex_runtime = "untouched"
    raw_hub_public_exposure = "forbidden"
    dashboard_mobile_watch_notify = "out of scope"
    archived_spool = "preserve; do not flush, restore, or delete automatically"
  }
}

$operationChecklist = @(
  (New-ChecklistItem "Hub canary service baseline documented" "PASS" $HubServiceName),
  (New-ChecklistItem "Reverse tunnel service baseline documented" "PASS" $TunnelServiceName),
  (New-ChecklistItem "Agent HTTP canary runtime baseline documented" "PASS" $effectiveAgentContainerName),
  (New-ChecklistItem "Agent restart policy concern tracked" "PASS" "current concern: no restart policy"),
  (New-ChecklistItem "Health/read-model/tunnel cadence documented" "PASS" "daily and after authorized changes"),
  (New-ChecklistItem "Active spool threshold documented" "PASS" "expected zero"),
  (New-ChecklistItem "Archived spool preservation documented" "PASS" "preserve by default"),
  (New-ChecklistItem "Raw Hub exposure boundary documented" "PASS" "public exposure forbidden"),
  (New-ChecklistItem "LAX Codex boundary documented" "PASS" "untouched")
)

$rollbackChecklist = @(
  (New-ChecklistItem "Preserve diagnostics before rollback" "PASS" "safe status summaries only"),
  (New-ChecklistItem "Preserve archived spool" "PASS" "no automatic flush, restore, or delete"),
  (New-ChecklistItem "File-only rollback remains available" "PASS" "separate authorization required"),
  (New-ChecklistItem "Stop conditions documented" "PASS" "non-canary impact, ambiguous spool, or secret exposure risk")
)

New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null
$planJsonPath = Join-Path $outputRoot "service-baseline-plan.json"
$planMdPath = Join-Path $outputRoot "service-baseline-plan.md"
$operationChecklistPath = Join-Path $outputRoot "operation-checklist.md"
$rollbackChecklistPath = Join-Path $outputRoot "rollback-checklist.md"

$plan | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $planJsonPath -Encoding UTF8

$md = @(
  "# Canary Service Baseline Plan",
  "",
  "- Mode: $Mode",
  "- Plan only: true",
  "- Commands executed: false",
  "- Live SSH used: false",
  "- Production mutation: false",
  "- Hub service: $HubServiceName",
  "- Tunnel service: $TunnelServiceName",
  "- Agent container: $effectiveAgentContainerName",
  "",
  "## Recommendation",
  "",
  $plan.recommendations.runtime_baseline,
  "",
  "## Cadence",
  "",
  "- Hub health: $($plan.services.hub.health_check_cadence)",
  "- Hub SQLite integrity: $($plan.services.hub.sqlite_integrity_cadence)",
  "- Read model smoke: $($plan.recommendations.read_model_smoke)",
  "- Tunnel reachability: $($plan.services.reverse_tunnel.reachability_check_cadence)",
  "- Agent health/status: $($plan.services.agent.health_check_cadence)",
  "",
  "## Boundaries",
  "",
  "- No production rename.",
  "- No live service, Docker, tunnel, config, credential, or spool mutation.",
  "- Existing LAX Codex runtime remains untouched.",
  "- Raw Hub public exposure remains forbidden.",
  "- Archived spool is preserved and not flushed automatically."
)
$md | Set-Content -LiteralPath $planMdPath -Encoding UTF8

$operationChecklistMd = @("# Operation Checklist", "")
foreach ($item in $operationChecklist) {
  $operationChecklistMd += "- $($item.status): $($item.name) - $($item.evidence)"
}
$operationChecklistMd | Set-Content -LiteralPath $operationChecklistPath -Encoding UTF8

$rollbackChecklistMd = @("# Rollback Checklist", "")
foreach ($item in $rollbackChecklist) {
  $rollbackChecklistMd += "- $($item.status): $($item.name) - $($item.evidence)"
}
$rollbackChecklistMd | Set-Content -LiteralPath $rollbackChecklistPath -Encoding UTF8

Write-Host "canary_service_baseline_plan=PASS"
Write-Host "mode=$Mode"
Write-Host "plan_only=true"
Write-Host "commands_executed=false"
Write-Host "live_ssh_used=false"
Write-Host "production_mutation=false"
Write-Host "output_dir=$outputRoot"
