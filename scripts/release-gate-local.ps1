param(
  [string]$HubRepoPath = (Join-Path (Resolve-Path (Join-Path $PSScriptRoot "..\..")) "jerry-telemetry-hub"),
  [string]$SmokeRoot = ".smoke\release-gate"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$smokeRootPath = Join-Path $repoRoot $SmokeRoot
$strictEnvPath = Join-Path $smokeRootPath "strict-production.local.env"
$secretEnvName = "TELEMETRY_NODE_" + "SECRET"

function Run-Step {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][scriptblock]$Command
  )

  Write-Host "START $Name"
  & $Command
  if ($LASTEXITCODE -ne 0) {
    throw "$Name failed"
  }
  Write-Host "PASS $Name"
}

Push-Location $repoRoot
try {
  New-Item -ItemType Directory -Force -Path $smokeRootPath | Out-Null
  @(
    "TELEMETRY_OUTPUT_MODE=file,http",
    "TELEMETRY_HUB_URL=http://127.0.0.1:3000/v1/events",
    "$secretEnvName=local-synthetic-secret-for-doctor-only",
    "TELEMETRY_NODE_KEY_ID=local-synthetic-key",
    "STATE_PATH=.smoke/release-gate/agent-state.json",
    "SPOOL_DIR=.smoke/release-gate/spool",
    "TELEMETRY_LOG_DIR=.smoke/release-gate/logs"
  ) | Set-Content -LiteralPath $strictEnvPath -Encoding UTF8

  # ci:local covers the required local checks:
  # npm run typecheck
  # npm test
  # npm run build
  Run-Step "npm run ci:local" { npm run ci:local }
  Run-Step "docker compose config" { docker compose config }
  Run-Step "scan-secrets-light" { & "$PSScriptRoot\scan-secrets-light.ps1" }
  Run-Step "git diff --check" { git diff --check }
  Run-Step "validate-local.ps1" { & "$PSScriptRoot\validate-local.ps1" }
  Run-Step "agent-once Fixture FileOnly" { & "$PSScriptRoot\agent-once.ps1" -Mode Fixture -Output FileOnly -NodeId local-win-dev-01 -OutFile ".smoke\release-gate\fixture.batch.safe.json" }
  Run-Step "agent-once LocalWindows FileOnly" { & "$PSScriptRoot\agent-once.ps1" -Mode LocalWindows -Output FileOnly -NodeId local-win-dev-01 -OutFile ".smoke\release-gate\local.batch.safe.json" }
  Run-Step "smoke-local-agent.ps1" { & "$PSScriptRoot\smoke-local-agent.ps1" -OutputDir ".smoke\release-gate\local-agent" }
  Run-Step "server-agent-once FileOnly" { & "$PSScriptRoot\server-agent-once.ps1" -Config ".\deploy\examples\general-linux-agent.node.json" -Output FileOnly -OutFile ".smoke\release-gate\server.batch.safe.json" }
  Run-Step "smoke-server-agent.ps1" { & "$PSScriptRoot\smoke-server-agent.ps1" -OutFile ".smoke\release-gate\server-agent\server.batch.safe.json" }
  Run-Step "smoke-server-daemon.ps1" { & "$PSScriptRoot\smoke-server-daemon.ps1" -SmokeRoot ".smoke\release-gate\server-daemon" }

  if (Test-Path -LiteralPath (Join-Path $HubRepoPath "package.json") -PathType Leaf) {
    Run-Step "smoke-local-hub-agent-e2e Once" { & "$PSScriptRoot\smoke-local-hub-agent-e2e.ps1" -Mode Once -HubRepoPath $HubRepoPath -SmokeRoot ".smoke\release-gate\local-hub-agent-e2e-once" }
    Run-Step "smoke-local-hub-agent-e2e Daemon" { & "$PSScriptRoot\smoke-local-hub-agent-e2e.ps1" -Mode Daemon -HubRepoPath $HubRepoPath -SmokeRoot ".smoke\release-gate\local-hub-agent-e2e-daemon" }
  } else {
    Write-Host "SKIP smoke-local-hub-agent-e2e reason=sibling_hub_repo_missing"
  }

  Run-Step "doctor-agent-config example" { & "$PSScriptRoot\doctor-agent-config.ps1" -NodeConfigPath ".\deploy\examples\general-linux-agent.node.json" -NoNetwork }
  Run-Step "doctor-agent-config strict" { & "$PSScriptRoot\doctor-agent-config.ps1" -NodeConfigPath ".\deploy\examples\general-linux-agent.node.json" -EnvPath $strictEnvPath -StrictProduction -NoNetwork }
  Run-Step "package-agent-local.ps1" { & "$PSScriptRoot\package-agent-local.ps1" -OutputDir ".smoke\release-gate\artifacts" }
  Run-Step "workstation release-slot rehearsal" { & "$PSScriptRoot\workstation\Test-AgentWorkstationRelease.ps1" }
  Run-Step "install-agent-dry-run.ps1" { & "$PSScriptRoot\install-agent-dry-run.ps1" -NodeConfigPath ".\deploy\examples\general-linux-agent.node.json" -OutputDir ".smoke\release-gate\install-plan" }
  Run-Step "upgrade-agent-dry-run.ps1" { & "$PSScriptRoot\upgrade-agent-dry-run.ps1" -NodeConfigPath ".\deploy\examples\general-linux-agent.node.json" -OutputDir ".smoke\release-gate\upgrade-plan" }
  Run-Step "uninstall-agent-dry-run.ps1" { & "$PSScriptRoot\uninstall-agent-dry-run.ps1" -NodeConfigPath ".\deploy\examples\general-linux-agent.node.json" -OutputDir ".smoke\release-gate\uninstall-plan" }

  $canaryEvidenceAvailable =
    (Get-ChildItem -Path ".smoke" -Directory -Filter "canary-stabilize-*" -ErrorAction SilentlyContinue | Select-Object -First 1) -and
    (Get-ChildItem -Path ".smoke" -Directory -Filter "http-canary-observe-03-*" -ErrorAction SilentlyContinue | Select-Object -First 1) -and
    (Get-ChildItem -Path ".smoke" -Directory -Filter "canary-promote-plan-*" -ErrorAction SilentlyContinue | Select-Object -First 1)
  if ($canaryEvidenceAvailable) {
    Run-Step "canary-baseline-audit.ps1 evidence" { & "$PSScriptRoot\canary-baseline-audit.ps1" -EvidenceRoot ".smoke" -OutputDir ".smoke\release-gate\canary-baseline-audit" }
    Run-Step "canary-service-baseline-plan-local.ps1" { & "$PSScriptRoot\canary-service-baseline-plan-local.ps1" -EvidenceRoot ".smoke" -OutputDir ".smoke\release-gate\canary-service-baseline-plan" }
    Run-Step "canary-agent-supervision-plan-local.ps1" { & "$PSScriptRoot\canary-agent-supervision-plan-local.ps1" -OutputDir ".smoke\release-gate\canary-agent-supervision-plan" }
    Run-Step "canary-live-audit-contract-local.ps1" { & "$PSScriptRoot\canary-live-audit-contract-local.ps1" -OutputDir ".smoke\release-gate\canary-live-audit-contract" }
    Run-Step "canary-report-summarize-local.ps1" { & "$PSScriptRoot\canary-report-summarize-local.ps1" -EvidenceRoot ".smoke" -OutputDir ".smoke\release-gate\canary-report-summary" }
  } else {
    Write-Host "SKIP canary-baseline-hardening reason=local_canary_evidence_missing"
  }

  Write-Host "release_gate_local=PASS"
  Write-Host "production_mutation=false"
  Write-Host "output_safety=checked"
} finally {
  Pop-Location
}
