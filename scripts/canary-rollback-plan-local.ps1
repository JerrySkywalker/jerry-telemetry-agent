param(
  [ValidateSet("StopHttpCanary", "FileOnlyRollback", "FullCanaryStop")]
  [string]$Mode = "FileOnlyRollback",
  [string]$OutputDir = ".smoke\canary-rollback-plan",
  [bool]$PreserveSpool = $true
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$outputRoot = if ([IO.Path]::IsPathRooted($OutputDir)) { $OutputDir } else { Join-Path $repoRoot $OutputDir }

function New-Step {
  param(
    [string]$Name,
    [string]$Scope,
    [string]$Plan,
    [string]$Safety
  )

  return [pscustomobject][ordered]@{
    name = $Name
    scope = $Scope
    plan_only = $true
    command_executed = $false
    plan = $Plan
    safety = $Safety
  }
}

New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null

$steps = New-Object System.Collections.Generic.List[object]
$steps.Add((New-Step "Capture pre-rollback evidence" "Hub, reverse tunnel, Agent canary" "Record safe health, restart counts, read model status, active spool count, and archive counts before any future rollback." "No raw logs, config dumps, or secret values."))
$steps.Add((New-Step "Stop Agent HTTP canary plan" "Agent canary only" "In a separately authorized rollback, stop the HTTP-upload canary runtime and preserve its diagnostics." "Do not touch the existing LAX Codex runtime."))
$steps.Add((New-Step "Preserve state and spool" "Agent canary state" "Keep active state, active spool, archived old spool, and failed-check archive intact for diagnosis." "Do not flush, restore, or delete archived spool automatically."))

if ($Mode -eq "FileOnlyRollback") {
  $steps.Add((New-Step "Restore file-only canary plan" "Agent canary only" "In a separately authorized rollback, bring back a file-only canary using the last known canary config shape with upload disabled." "Do not send Agent telemetry to Hub during file-only rollback."))
  $steps.Add((New-Step "Keep Hub canary available" "Hub canary" "Keep the Hub canary available for read-only inspection unless a later goal authorizes stopping it." "Do not modify unrelated Beijing services."))
  $steps.Add((New-Step "Keep or stop reverse tunnel by decision" "Reverse tunnel canary" "Leave the tunnel running for diagnosis or stop it only under a separate rollback authorization." "Do not alter non-canary SSH or service configuration."))
} elseif ($Mode -eq "StopHttpCanary") {
  $steps.Add((New-Step "Leave file-only replacement out of scope" "Agent canary only" "Stop the HTTP canary in a later authorized goal and leave no replacement runtime unless separately requested." "Avoid accidental HTTP upload."))
  $steps.Add((New-Step "Keep Hub and tunnel evidence" "Hub and tunnel canaries" "Keep Hub and tunnel evidence available until the operator decides whether to stop them." "No public exposure changes."))
} else {
  $steps.Add((New-Step "Stop reverse tunnel plan" "Reverse tunnel canary" "In a separately authorized full stop, stop the reverse tunnel canary after Agent HTTP canary is already stopped." "Do not alter existing LAX Codex runtime or unrelated SSH services."))
  $steps.Add((New-Step "Stop Hub canary plan" "Hub canary" "In a separately authorized full stop, stop the Hub canary after preserving SQLite and smoke evidence." "Preserve database, backups, and logs for the approved retention window."))
}

$steps.Add((New-Step "Post-rollback smoke plan" "Local and target-safe checks" "Verify Agent mode, Hub health if retained, tunnel status if retained, active spool count, and read model state after rollback." "Summarize counts only; do not print raw logs or credentials."))

$plan = [pscustomobject][ordered]@{
  generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
  mode = $Mode
  plan_only = $true
  commands_executed = $false
  preserve_spool = $PreserveSpool
  production_mutation = $false
  touches_lax_codex_runtime = $false
  flushes_archived_spool = $false
  deletes_archived_spool = $false
  steps = $steps
  stop_conditions = @(
    "Stop and ask for operator review if the planned rollback would affect non-canary services.",
    "Stop and ask for operator review if state, spool, or archive counts are ambiguous.",
    "Stop and ask for operator review if a secret or raw log would need to be printed for diagnosis."
  )
}

$planJsonPath = Join-Path $outputRoot "rollback-plan.json"
$planMdPath = Join-Path $outputRoot "rollback-plan.md"
$checklistPath = Join-Path $outputRoot "rollback-checklist.md"

$plan | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $planJsonPath -Encoding UTF8

$md = @(
  "# Canary Rollback Plan",
  "",
  "- Mode: $Mode",
  "- Plan only: true",
  "- Commands executed: false",
  "- Preserve spool: $PreserveSpool",
  "- Production mutation: false",
  "",
  "## Steps"
)
foreach ($step in $steps) {
  $md += "- $($step.name): $($step.plan)"
}
$md += ""
$md += "## Stop Conditions"
foreach ($condition in $plan.stop_conditions) {
  $md += "- $condition"
}
$md | Set-Content -LiteralPath $planMdPath -Encoding UTF8

$checklist = @(
  "# Canary Rollback Checklist",
  "",
  "- PASS: rollback plan is plan-only",
  "- PASS: commands_executed=false",
  "- PASS: archived spool preserved by default",
  "- PASS: diagnostics preserved",
  "- PASS: existing LAX Codex runtime remains out of scope",
  "- PASS: production deployment is not performed",
  "- PASS: service and Docker runtime changes require a separate explicit authorization"
)
$checklist | Set-Content -LiteralPath $checklistPath -Encoding UTF8

Write-Host "canary_rollback_plan=PASS"
Write-Host "mode=$Mode"
Write-Host "plan_only=true"
Write-Host "commands_executed=false"
Write-Host "output_dir=$outputRoot"
