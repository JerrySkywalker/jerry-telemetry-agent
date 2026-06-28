param(
  [string]$EvidenceRoot = ".smoke",
  [string]$OutputDir = ".smoke\canary-report-summary"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$evidenceRootPath = if ([IO.Path]::IsPathRooted($EvidenceRoot)) {
  $EvidenceRoot
} else {
  Join-Path $repoRoot $EvidenceRoot
}
$outputRoot = if ([IO.Path]::IsPathRooted($OutputDir)) {
  $OutputDir
} else {
  Join-Path $repoRoot $OutputDir
}

function Get-LatestDir {
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
  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
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

New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null

$liveDir = Get-LatestDir "canary-live-audit*"
$soakDir = Get-LatestDir "canary-soak*"
$hardenDir = Get-LatestDir "canary-service-harden-apply*"
$baselineDir = Get-LatestDir "canary-baseline-audit*"
$promoteDir = Get-LatestDir "canary-promote-plan*"

$live = if ($liveDir) { Read-JsonSafe (Join-Path $liveDir.FullName "canary-live-audit-summary.json") } else { $null }
$soak = if ($soakDir) { Read-JsonSafe (Join-Path $soakDir.FullName "canary-soak-summary.json") } else { $null }
$harden = if ($hardenDir) { Read-JsonSafe (Join-Path $hardenDir.FullName "hardening-summary.json") } else { $null }
$baseline = if ($baselineDir) { Read-JsonSafe (Join-Path $baselineDir.FullName "canary-baseline-audit-summary.json") } else { $null }
$promote = if ($promoteDir) { Read-JsonSafe (Join-Path $promoteDir.FullName "canary-promote-plan-summary.json") } else { $null }

$latestLiveSample = $null
if ($live -and $live.samples) {
  $latestLiveSample = @($live.samples) | Select-Object -Last 1
}

$summary = [pscustomobject][ordered]@{
  generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
  evidence_root = [IO.Path]::GetRelativePath($repoRoot, $evidenceRootPath)
  evidence = [ordered]@{
    live_audit = if ($liveDir) { $liveDir.Name } else { $null }
    soak = if ($soakDir) { $soakDir.Name } else { $null }
    hardening = if ($hardenDir) { $hardenDir.Name } else { $null }
    baseline_audit = if ($baselineDir) { $baselineDir.Name } else { $null }
    promotion_plan = if ($promoteDir) { $promoteDir.Name } else { $null }
  }
  statuses = [ordered]@{
    live_audit = if ($live) { $live.result } else { "NOT_FOUND" }
    soak = if ($soak) { $soak.result } else { "NOT_FOUND" }
    hardening_restart_policy = if ($harden) { Get-NestedValue $harden @("hardening", "after_restart_policy") } else { $null }
    baseline_audit = if ($baseline) { $baseline.result } else { "NOT_FOUND" }
    promotion_recommendation = if ($promote) { Get-NestedValue $promote @("recommendation", "recommended_option") } else { $null }
  }
  latest_live_sample = [ordered]@{
    hub_health = if ($latestLiveSample) { $latestLiveSample.hub_health } else { $null }
    tunnel_active = if ($latestLiveSample) { $latestLiveSample.tunnel_active } else { $null }
    agent_health = if ($latestLiveSample) { $latestLiveSample.agent_health } else { $null }
    active_spool = if ($latestLiveSample) { $latestLiveSample.active_spool } else { $null }
    restart_policy = if ($latestLiveSample) { $latestLiveSample.agent_restart_policy } else { $null }
    last_successful_send = if ($latestLiveSample) { $latestLiveSample.last_successful_send } else { $null }
  }
  safety = [ordered]@{
    source = "local .smoke summaries only"
    production_mutation = $false
    live_ssh_used = $false
    secrets_printed = $false
    raw_logs_printed = $false
    raw_response_bodies_printed = $false
  }
}

$summary | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $outputRoot "canary-operator-summary.json") -Encoding UTF8

$md = @(
  "# Canary Operator Summary",
  "",
  "- evidence_root: $($summary.evidence_root)",
  "- live_audit: $($summary.evidence.live_audit)",
  "- live_audit_status: $($summary.statuses.live_audit)",
  "- soak: $($summary.evidence.soak)",
  "- soak_status: $($summary.statuses.soak)",
  "- hardening: $($summary.evidence.hardening)",
  "- hardening_restart_policy: $($summary.statuses.hardening_restart_policy)",
  "- baseline_audit: $($summary.evidence.baseline_audit)",
  "- baseline_audit_status: $($summary.statuses.baseline_audit)",
  "- promotion_plan: $($summary.evidence.promotion_plan)",
  "- latest_agent_restart_policy: $($summary.latest_live_sample.restart_policy)",
  "- latest_active_spool: $($summary.latest_live_sample.active_spool)",
  "- latest_successful_send: $($summary.latest_live_sample.last_successful_send)",
  "",
  "## Safety",
  "",
  "- production_mutation: false",
  "- live_ssh_used: false",
  "- secrets_printed: false",
  "- raw_logs_printed: false",
  "- raw_response_bodies_printed: false"
)
$md | Set-Content -LiteralPath (Join-Path $outputRoot "canary-operator-summary.md") -Encoding UTF8

Write-Host "canary_report_summary=PASS"
Write-Host "output_dir=$outputRoot"
Write-Host "production_mutation=false"
Write-Host "live_ssh_used=false"
Write-Host "raw_logs_printed=false"
Write-Host "secrets_printed=false"
