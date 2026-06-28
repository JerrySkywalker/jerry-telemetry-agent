param(
  [string]$OutputDir = ".smoke\canary-agent-supervision-plan",
  [string]$AgentContainerName = "jerry-telemetry-agent-http-canary-readback-align-20260628T140444Z"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$outputRoot = if ([IO.Path]::IsPathRooted($OutputDir)) { $OutputDir } else { Join-Path $repoRoot $OutputDir }

function New-Option {
  param(
    [string]$Id,
    [string]$Name,
    [string]$Summary,
    [string[]]$Pros,
    [string[]]$Cons,
    [string]$Risk,
    [string]$Rollback
  )
  return [pscustomobject][ordered]@{
    id = $Id
    name = $Name
    summary = $Summary
    pros = $Pros
    cons = $Cons
    risk = $Risk
    rollback = $Rollback
  }
}

$options = @(
  (New-Option "A" "Keep current container-only canary" "Lowest-change path; current restart policy concern remains." @("No live mutation", "Preserves current passing canary") @("Requires external observation", "Manual recovery if container exits") "Operational drift if observation is missed" "No rollback needed because no change is applied"),
  (New-Option "B" "Docker restart policy for canary container" "Simple runtime hardening in a later authorized goal." @("Small operational change", "Keeps current container shape") @("Mutates Docker runtime later", "Less explicit than a service wrapper") "Unexpected restart behavior if container config is wrong" "Return container policy to prior value under authorization"),
  (New-Option "C" "Systemd wrapper managing canary container" "Explicit service baseline with preflight, logs, and restart policy." @("Clear service ownership", "Observable restart count", "Works with existing host operations") @("More moving parts", "Requires careful unit design") "Wrapper could conflict with manual container handling if poorly scoped" "Disable wrapper and leave container evidence preserved under authorization"),
  (New-Option "D" "Compose-managed canary stack" "Cleaner long-term service shape but broader change." @("Declarative runtime", "Easier future package updates") @("Broader migration", "Needs compose file and path governance") "Higher blast radius than wrapper-only hardening" "Return to current canary container or file-only canary under authorization")
)

$recommendation = [pscustomobject][ordered]@{
  recommended_path = "Review Option C systemd wrapper or Option D compose-managed canary before live change"
  default_now = "Do not change the live canary in this development goal"
  keep_running = "Keep current HTTP canary running while design is reviewed"
  production_rename = "not recommended"
  lax_codex_runtime = "do not touch"
  raw_hub_public_exposure = "forbidden"
  requires_authorization = $true
}

$summary = [pscustomobject][ordered]@{
  generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
  plan_only = $true
  commands_executed = $false
  live_ssh_used = $false
  production_mutation = $false
  agent_container = $AgentContainerName
  current_restart_policy_concern = "no"
  options = $options
  recommendation = $recommendation
  safety = [ordered]@{
    secrets_rendered = $false
    raw_logs_rendered = $false
    docker_runtime_mutation = $false
    service_timer_mutation = $false
    source_only_change = $true
  }
}

New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null
$optionsJsonPath = Join-Path $outputRoot "agent-supervision-options.json"
$optionsMdPath = Join-Path $outputRoot "agent-supervision-options.md"
$recommendedJsonPath = Join-Path $outputRoot "recommended-supervision-path.json"
$recommendedMdPath = Join-Path $outputRoot "recommended-supervision-path.md"

$summary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $optionsJsonPath -Encoding UTF8
$recommendation | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $recommendedJsonPath -Encoding UTF8

$optionsMd = @(
  "# Agent Canary Supervision Options",
  "",
  "- Plan only: true",
  "- Commands executed: false",
  "- Agent container: $AgentContainerName",
  "- Current restart policy concern: no",
  ""
)
foreach ($option in $options) {
  $optionsMd += "## Option $($option.id): $($option.name)"
  $optionsMd += ""
  $optionsMd += $option.summary
  $optionsMd += ""
  $optionsMd += "- Risk: $($option.risk)"
  $optionsMd += "- Rollback: $($option.rollback)"
  $optionsMd += ""
}
$optionsMd | Set-Content -LiteralPath $optionsMdPath -Encoding UTF8

$recommendedMd = @(
  "# Recommended Supervision Path",
  "",
  "- Recommended path: $($recommendation.recommended_path)",
  "- Default now: $($recommendation.default_now)",
  "- Keep running: $($recommendation.keep_running)",
  "- Production rename: $($recommendation.production_rename)",
  "- Existing LAX Codex runtime: $($recommendation.lax_codex_runtime)",
  "- Raw Hub public exposure: $($recommendation.raw_hub_public_exposure)",
  "- Separate authorization required: true"
)
$recommendedMd | Set-Content -LiteralPath $recommendedMdPath -Encoding UTF8

Write-Host "canary_agent_supervision_plan=PASS"
Write-Host "plan_only=true"
Write-Host "commands_executed=false"
Write-Host "live_ssh_used=false"
Write-Host "production_mutation=false"
Write-Host "output_dir=$outputRoot"
