param(
  [string]$HubRepoPath = (Join-Path (Resolve-Path (Join-Path $PSScriptRoot "..\..")) "jerry-telemetry-hub"),
  [string]$OutputDir = ".smoke\canary-baseline-gate",
  [switch]$SkipStackRc
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$outputRoot = if ([IO.Path]::IsPathRooted($OutputDir)) { $OutputDir } else { Join-Path $repoRoot $OutputDir }
$runId = "canary-baseline-gate-" + (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
$runRoot = Join-Path $outputRoot $runId
$results = New-Object System.Collections.Generic.List[object]

function Add-Result {
  param(
    [string]$Name,
    [string]$Status,
    [string]$Reason = ""
  )

  $script:results.Add([pscustomobject][ordered]@{
    name = $Name
    status = $Status
    reason = $Reason
  })
}

function Run-Step {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][scriptblock]$Command
  )

  Write-Host "START $Name"
  $global:LASTEXITCODE = 0
  & $Command
  if ($LASTEXITCODE -ne 0) {
    Add-Result -Name $Name -Status "FAIL" -Reason "exit_code=$LASTEXITCODE"
    throw "$Name failed"
  }
  Add-Result -Name $Name -Status "PASS"
  Write-Host "PASS $Name"
}

Push-Location $repoRoot
try {
  New-Item -ItemType Directory -Force -Path $runRoot | Out-Null

  Run-Step "npm run typecheck" { npm run typecheck }
  Run-Step "npm test" { npm test }
  Run-Step "npm run build" { npm run build }
  Run-Step "docker compose config" { docker compose config }
  Run-Step "scan-secrets-light" { & "$PSScriptRoot\scan-secrets-light.ps1" }
  Run-Step "git diff --check" { git diff --check }
  Run-Step "validate-local.ps1" { & "$PSScriptRoot\validate-local.ps1" }
  Run-Step "release-gate-local.ps1" { & "$PSScriptRoot\release-gate-local.ps1" -HubRepoPath $HubRepoPath }
  Run-Step "canary-baseline-audit.ps1" { & "$PSScriptRoot\canary-baseline-audit.ps1" -EvidenceRoot ".smoke" -OutputDir (Join-Path $runRoot "audit") }

  $agentBranch = (git branch --show-current).Trim()
  if ($SkipStackRc) {
    Add-Result -Name "stack-release-candidate-local.ps1" -Status "SKIP" -Reason "SkipStackRc requested"
    Write-Host "SKIP stack-release-candidate-local.ps1 reason=SkipStackRc"
  } elseif (Test-Path -LiteralPath (Join-Path $HubRepoPath "package.json") -PathType Leaf) {
    if ($agentBranch -eq "main" -or $agentBranch -like "mg-tel-stack-rc-*") {
      Run-Step "stack-release-candidate-local.ps1" { & "$PSScriptRoot\stack-release-candidate-local.ps1" -HubRepoPath $HubRepoPath -OutputDir (Join-Path $runRoot "stack-rc") }
    } else {
      Add-Result -Name "stack-release-candidate-local.ps1" -Status "SKIP" -Reason "agent branch is not main or stack RC"
      Write-Host "SKIP stack-release-candidate-local.ps1 reason=agent_branch_not_main_or_stack_rc"
    }
  } else {
    Add-Result -Name "stack-release-candidate-local.ps1" -Status "SKIP" -Reason "sibling Hub repo missing"
    Write-Host "SKIP stack-release-candidate-local.ps1 reason=sibling_hub_repo_missing"
  }

  $summary = [pscustomobject][ordered]@{
    run_id = $runId
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    result = "PASS"
    production_mutation = $false
    live_ssh_used = $false
    results = $results
  }
  $summary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $runRoot "canary-baseline-gate-summary.json") -Encoding UTF8
  Write-Host "canary_baseline_gate=PASS"
  Write-Host "production_mutation=false"
  Write-Host "live_ssh_used=false"
} finally {
  Pop-Location
}
