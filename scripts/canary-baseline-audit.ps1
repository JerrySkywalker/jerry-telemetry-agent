param(
  [string]$EvidenceRoot = ".smoke",
  [string]$OutputDir = "",
  [switch]$Live,
  [string]$HubTarget = "beijing",
  [string]$AgentTarget = "lax"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$runId = "canary-baseline-audit-" + (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
$evidenceRootPath = if ([IO.Path]::IsPathRooted($EvidenceRoot)) { $EvidenceRoot } else { Join-Path $repoRoot $EvidenceRoot }
$outputRoot = if ([string]::IsNullOrWhiteSpace($OutputDir)) {
  Join-Path $repoRoot (Join-Path ".smoke" $runId)
} elseif ([IO.Path]::IsPathRooted($OutputDir)) {
  $OutputDir
} else {
  Join-Path $repoRoot $OutputDir
}

function New-ChecklistItem {
  param(
    [string]$Name,
    [bool]$Pass,
    [string]$Evidence,
    [string]$Reason = ""
  )

  return [pscustomobject][ordered]@{
    name = $Name
    status = if ($Pass) { "PASS" } else { "FAIL" }
    evidence = $Evidence
    reason = $Reason
  }
}

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
  param(
    [object]$Object,
    [string[]]$Path
  )

  $current = $Object
  foreach ($segment in $Path) {
    if ($null -eq $current) {
      return $null
    }
    $property = $current.PSObject.Properties[$segment]
    if ($null -eq $property) {
      return $null
    }
    $current = $property.Value
  }
  return $current
}

function Test-PassValue {
  param([object]$Value)

  if ($Value -is [bool]) {
    return [bool]$Value
  }
  if ($Value -is [int] -or $Value -is [long]) {
    return [int64]$Value -eq 0
  }
  if ($null -eq $Value) {
    return $false
  }
  $text = ([string]$Value).Trim().ToLowerInvariant()
  return @("pass", "ok", "true", "active", "none", "no") -contains $text
}

function Test-StatusCode {
  param([object]$Value, [int]$Expected)

  if ($null -eq $Value) {
    return $false
  }
  try {
    return [int]$Value -eq $Expected
  } catch {
    return $false
  }
}

function Get-ForbiddenMarkers {
  $parts = New-Object System.Collections.Generic.List[string]
  $parts.Add("TELEMETRY_NODE_" + "SECRET=")
  $parts.Add("TELEMETRY_READ_" + "TOKEN=")
  $parts.Add("Author" + "ization: Bearer ")
  $parts.Add("Author" + "ization:")
  $parts.Add("Cookie:")
  $parts.Add("Set-Cookie:")
  $parts.Add("access_" + "token")
  $parts.Add("refresh_" + "token")
  $parts.Add("id_" + "token")
  $parts.Add("auth" + ".json")
  $parts.Add("account_" + "id")
  $parts.Add("user_" + "id")
  $parts.Add("email")
  $parts.Add("raw_" + "response")
  $parts.Add("BEGIN OPENSSH PRIVATE KEY")
  return $parts.ToArray()
}

function Invoke-ForbiddenMarkerScan {
  param([System.IO.DirectoryInfo[]]$Directories)

  $markers = Get-ForbiddenMarkers
  $scan = [ordered]@{
    scanned_file_count = 0
    hit_count = 0
    files_with_hits = @()
  }

  foreach ($dir in $Directories) {
    if ($null -eq $dir -or -not (Test-Path -LiteralPath $dir.FullName -PathType Container)) {
      continue
    }

    $files = Get-ChildItem -LiteralPath $dir.FullName -File -Recurse -ErrorAction SilentlyContinue |
      Where-Object { $_.Extension -in @(".json", ".md", ".txt") -and $_.Length -lt 2MB }
    foreach ($file in $files) {
      $scan.scanned_file_count++
      $text = Get-Content -Raw -LiteralPath $file.FullName
      $fileHits = 0
      foreach ($marker in $markers) {
        if ($text.ToLowerInvariant().Contains($marker.ToLowerInvariant())) {
          $fileHits++
        }
      }
      if ($fileHits -gt 0) {
        $scan.hit_count += $fileHits
        $scan.files_with_hits += [IO.Path]::GetRelativePath($repoRoot, $file.FullName)
      }
    }
  }

  return [pscustomobject]$scan
}

if ($Live) {
  Write-Error "Live canary audit mode is refused by default. This goal has no read-only SSH authorization; run evidence mode or use a separately authorized live wrapper."
}

New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null

$stabilizeDir = Get-LatestEvidenceDirectory -Pattern "canary-stabilize-*"
$observeDir = Get-LatestEvidenceDirectory -Pattern "http-canary-observe-03-*"
$promoteDir = Get-LatestEvidenceDirectory -Pattern "canary-promote-plan-*"
$evidenceDirs = @($stabilizeDir, $observeDir, $promoteDir)

$stabilizeSummaryPath = if ($stabilizeDir) { Join-Path $stabilizeDir.FullName "canary-stabilize-summary.json" } else { "" }
$observeSummaryPath = if ($observeDir) { Join-Path $observeDir.FullName "http-canary-observe-03-summary.json" } else { "" }
$promoteSummaryPath = if ($promoteDir) { Join-Path $promoteDir.FullName "canary-promote-plan-summary.json" } else { "" }
$stabilizeMarkerPath = if ($stabilizeDir) { Join-Path $stabilizeDir.FullName "marker-scan.json" } else { "" }
$observeMarkerPath = if ($observeDir) { Join-Path $observeDir.FullName "marker-scan.json" } else { "" }
$promoteMarkerPath = if ($promoteDir) { Join-Path $promoteDir.FullName "marker-scan.json" } else { "" }

$stabilize = Read-JsonSafe -Path $stabilizeSummaryPath
$observe = Read-JsonSafe -Path $observeSummaryPath
$promote = Read-JsonSafe -Path $promoteSummaryPath
$stabilizeMarker = Read-JsonSafe -Path $stabilizeMarkerPath
$observeMarker = Read-JsonSafe -Path $observeMarkerPath
$promoteMarker = Read-JsonSafe -Path $promoteMarkerPath
$localMarkerScan = Invoke-ForbiddenMarkerScan -Directories $evidenceDirs

$markerEvidencePass =
  (Test-PassValue (Get-NestedValue $stabilizeMarker @("marker_scan_pass"))) -and
  (Test-PassValue (Get-NestedValue $observeMarker @("marker_scan_pass"))) -and
  (Test-PassValue (Get-NestedValue $promoteMarker @("marker_scan_pass"))) -and
  ([int]$localMarkerScan.hit_count -eq 0)

$hubEvidencePass =
  (Test-PassValue (Get-NestedValue $stabilize @("pass", "hub_active"))) -and
  (Test-PassValue (Get-NestedValue $stabilize @("pass", "hub_health"))) -and
  (Test-StatusCode (Get-NestedValue $observe @("hub", "health")) 200)

$tunnelEvidencePass =
  (Test-PassValue (Get-NestedValue $stabilize @("pass", "tunnel_active"))) -and
  (Test-PassValue (Get-NestedValue $stabilize @("pass", "tunnel_reachable"))) -and
  (Test-StatusCode (Get-NestedValue $observe @("tunnel", "reachability")) 200)

$agentEvidencePass =
  (Test-PassValue (Get-NestedValue $stabilize @("pass", "agent_running"))) -and
  (Test-PassValue (Get-NestedValue $stabilize @("pass", "agent_health"))) -and
  (Test-StatusCode (Get-NestedValue $observe @("agent", "health")) 200) -and
  (Test-PassValue (Get-NestedValue $stabilize @("pass", "agent_http_mode")))

$extendedSoakPass =
  (Test-PassValue (Get-NestedValue $observe @("observation_result"))) -and
  (Test-PassValue (Get-NestedValue $promote @("baseline", "extended_observation")))

$activeSpoolPass =
  ((Get-NestedValue $stabilize @("storage", "active_spool")) -eq 0) -and
  ((Get-NestedValue $observe @("agent", "pending_active_spool")) -eq 0)

$archivedSpoolPass =
  ((Get-NestedValue $stabilize @("storage", "old_archive")) -eq 100) -and
  ((Get-NestedValue $stabilize @("storage", "failed_archive")) -eq 1) -and
  ((Get-NestedValue $observe @("agent", "archived_old_spool")) -eq 100) -and
  ((Get-NestedValue $observe @("agent", "archived_failed_check_spool")) -eq 1)

$readModelPass =
  (Test-PassValue (Get-NestedValue $stabilize @("pass", "hub_read_model"))) -and
  (Test-PassValue (Get-NestedValue $observe @("hub", "read_model")))

$rawExposurePolicyText = [string](Get-NestedValue $promote @("recommendation", "raw_hub_exposure"))
$rawExposurePass =
  (Test-PassValue (Get-NestedValue $stabilize @("pass", "hub_public_exposure_none"))) -and
  ((Get-NestedValue $observe @("hub", "public_exposure")) -eq $false) -and
  $rawExposurePolicyText.ToLowerInvariant().Contains("forbidden")

$laxBoundaryText = [string](Get-NestedValue $observe @("agent", "lax_codex_runtime"))
$laxRecommendationText = [string](Get-NestedValue $promote @("recommendation", "lax_codex_runtime"))
$laxBoundaryPass =
  $laxBoundaryText.ToLowerInvariant().Contains("untouched") -and
  $laxRecommendationText.ToLowerInvariant().Contains("do not touch")

$checklist = @(
  (New-ChecklistItem "Hub canary health evidence" $hubEvidencePass "stabilize and observe summaries"),
  (New-ChecklistItem "Reverse tunnel evidence" $tunnelEvidencePass "stabilize and observe summaries"),
  (New-ChecklistItem "Agent HTTP canary evidence" $agentEvidencePass "stabilize and observe summaries"),
  (New-ChecklistItem "Extended soak evidence" $extendedSoakPass "HTTP observe 03 and promotion plan"),
  (New-ChecklistItem "Marker scan evidence" $markerEvidencePass "marker-scan summaries and local evidence scan"),
  (New-ChecklistItem "Active spool evidence" $activeSpoolPass "active spool count remains zero"),
  (New-ChecklistItem "Archived spool preservation" $archivedSpoolPass "old archive 100 and failed-check archive 1"),
  (New-ChecklistItem "Read model evidence" $readModelPass "Hub read model pass evidence"),
  (New-ChecklistItem "No raw Hub exposure evidence" $rawExposurePass "localhost/private exposure evidence"),
  (New-ChecklistItem "LAX Codex untouched evidence" $laxBoundaryPass "observe and promotion summaries")
)

$overallPass = @(
  $stabilizeDir -ne $null,
  $observeDir -ne $null,
  $promoteDir -ne $null,
  $stabilize -ne $null,
  $observe -ne $null,
  $promote -ne $null,
  @($checklist | Where-Object { $_.status -eq "FAIL" }).Count -eq 0
) -notcontains $false

$risks = @(
  "Agent state may retain a stale prior HTTP error timestamp; treat current error-present flags and latest successful send timestamp as the live signal.",
  "Agent restart policy was observed as not hardened enough for a final production baseline; keep it as a tracked stabilization item.",
  "Archived HTTP spool retention remains an operator decision; do not flush or delete archives automatically."
)

$summary = [pscustomobject][ordered]@{
  run_id = $runId
  generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
  mode = "evidence"
  result = if ($overallPass) { "PASS" } else { "FAIL" }
  evidence = [ordered]@{
    root = [IO.Path]::GetRelativePath($repoRoot, $evidenceRootPath)
    canary_stabilize = if ($stabilizeDir) { $stabilizeDir.Name } else { $null }
    http_canary_observe_03 = if ($observeDir) { $observeDir.Name } else { $null }
    canary_promote_plan = if ($promoteDir) { $promoteDir.Name } else { $null }
  }
  checks = [ordered]@{
    hub_canary = if ($hubEvidencePass) { "PASS" } else { "FAIL" }
    reverse_tunnel = if ($tunnelEvidencePass) { "PASS" } else { "FAIL" }
    agent_http_canary = if ($agentEvidencePass) { "PASS" } else { "FAIL" }
    extended_soak = if ($extendedSoakPass) { "PASS" } else { "FAIL" }
    marker_scan = if ($markerEvidencePass) { "PASS" } else { "FAIL" }
    active_spool = if ($activeSpoolPass) { "PASS" } else { "FAIL" }
    archived_spool = if ($archivedSpoolPass) { "PASS" } else { "FAIL" }
    read_model = if ($readModelPass) { "PASS" } else { "FAIL" }
    raw_hub_exposure = if ($rawExposurePass) { "PASS" } else { "FAIL" }
    lax_codex_boundary = if ($laxBoundaryPass) { "PASS" } else { "FAIL" }
  }
  marker_scan = [ordered]@{
    scanned_file_count = $localMarkerScan.scanned_file_count
    hit_count = $localMarkerScan.hit_count
    evidence_marker_summaries_pass = $markerEvidencePass
  }
  safety = [ordered]@{
    live_ssh_used = $false
    production_mutation = $false
    secrets_printed = $false
    raw_logs_printed = $false
    docker_runtime_mutation = $false
    service_timer_mutation = $false
  }
  outstanding_risks = $risks
}

$summaryJsonPath = Join-Path $outputRoot "canary-baseline-audit-summary.json"
$summaryMdPath = Join-Path $outputRoot "canary-baseline-audit-summary.md"
$checklistPath = Join-Path $outputRoot "canary-baseline-checklist.md"

$summary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $summaryJsonPath -Encoding UTF8

$md = @(
  "# Canary Baseline Audit",
  "",
  "- Result: $($summary.result)",
  "- Mode: evidence",
  "- Live SSH used: false",
  "- Production mutation: false",
  "- Evidence root: $($summary.evidence.root)",
  "- Stabilize evidence: $($summary.evidence.canary_stabilize)",
  "- HTTP observe 03 evidence: $($summary.evidence.http_canary_observe_03)",
  "- Promotion plan evidence: $($summary.evidence.canary_promote_plan)",
  "- Marker scan hits: $($summary.marker_scan.hit_count)",
  "",
  "## Checks"
)
foreach ($property in $summary.checks.GetEnumerator()) {
  $md += "- $($property.Key): $($property.Value)"
}
$md += ""
$md += "## Outstanding Risks"
foreach ($risk in $risks) {
  $md += "- $risk"
}
$md | Set-Content -LiteralPath $summaryMdPath -Encoding UTF8

$checklistMd = @("# Canary Baseline Checklist", "")
foreach ($item in $checklist) {
  $line = "- $($item.status): $($item.name) - $($item.evidence)"
  if (-not [string]::IsNullOrWhiteSpace($item.reason)) {
    $line += " ($($item.reason))"
  }
  $checklistMd += $line
}
$checklistMd | Set-Content -LiteralPath $checklistPath -Encoding UTF8

Write-Host "canary_baseline_audit=$($summary.result)"
Write-Host "mode=evidence"
Write-Host "output_dir=$outputRoot"
Write-Host "marker_scan_hits=$($summary.marker_scan.hit_count)"
Write-Host "production_mutation=false"
Write-Host "live_ssh_used=false"

if (-not $overallPass) {
  exit 1
}
