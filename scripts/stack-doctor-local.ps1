param(
  [string]$AgentRepoPath = (Resolve-Path (Join-Path $PSScriptRoot "..")),
  [string]$HubRepoPath = (Join-Path (Resolve-Path (Join-Path $PSScriptRoot "..\..")) "jerry-telemetry-hub"),
  [switch]$RequireClean,
  [switch]$AllowMissingHub,
  [switch]$Json
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$requiredHubCommit = "be540993f046ca66d90f44a255e29bb4f8b7c77e"
$checks = New-Object System.Collections.Generic.List[object]

function Add-Check {
  param(
    [string]$Area,
    [string]$Name,
    [bool]$Ok,
    [string]$Message,
    [hashtable]$Details = @{}
  )

  $checks.Add([pscustomobject][ordered]@{
    area = $Area
    name = $Name
    ok = $Ok
    message = $Message
    details = $Details
  })
}

function Invoke-Git {
  param(
    [Parameter(Mandatory = $true)][string]$Repo,
    [Parameter(Mandatory = $true)][string[]]$GitArgs
  )
  $output = & git -C $Repo @GitArgs 2>$null
  if ($LASTEXITCODE -ne 0) { return $null }
  return ($output -join "`n").Trim()
}

function Test-GitAncestor {
  param([string]$Repo, [string]$Ancestor, [string]$Commit = "HEAD")
  & git -C $Repo merge-base --is-ancestor $Ancestor $Commit 2>$null
  return $LASTEXITCODE -eq 0
}

function Get-PackageInfo {
  param([string]$Repo)
  $packagePath = Join-Path $Repo "package.json"
  if (-not (Test-Path -LiteralPath $packagePath -PathType Leaf)) {
    return @{ present = $false; name = ""; version = "" }
  }
  $package = Get-Content -Raw -LiteralPath $packagePath | ConvertFrom-Json
  return @{ present = $true; name = [string]$package.name; version = [string]$package.version }
}

function Get-RepoCleanSummary {
  param([string]$Repo)
  $entries = @(git -C $Repo status --porcelain=v1 --untracked-files=normal)
  $goalDocs = @($entries | Where-Object { $_ -match '^\?\? goals/.+\.md$' })
  $other = @($entries | Where-Object { $_ -notmatch '^\?\? goals/.+\.md$' })
  return @{
    clean_except_goal_docs = ($other.Count -eq 0)
    entries_count = $entries.Count
    untracked_goal_docs_count = $goalDocs.Count
    other_changes_count = $other.Count
  }
}

function Test-AnyFileContains {
  param([string]$Repo, [string[]]$RelativeRoots, [string[]]$Patterns)
  $files = @()
  foreach ($root in $RelativeRoots) {
    $path = Join-Path $Repo $root
    if (-not (Test-Path -LiteralPath $path)) { continue }
    $rootFiles = if (Test-Path -LiteralPath $path -PathType Leaf) {
      @(Get-Item -LiteralPath $path)
    } else {
      @(Get-ChildItem -LiteralPath $path -Recurse -File -Include *.ts,*.js,*.ps1,*.md,*.json)
    }
    $files += $rootFiles
  }

  if ($files.Count -eq 0) { return $false }

  foreach ($pattern in $Patterns) {
    $found = $false
    foreach ($file in $files) {
      if (Select-String -LiteralPath $file.FullName -Pattern $pattern -SimpleMatch -Quiet) {
        $found = $true
        break
      }
    }
    if (-not $found) { return $false }
  }
  return $true
}

$agentRepo = Resolve-Path -LiteralPath $AgentRepoPath
$agentPackage = Get-PackageInfo $agentRepo
$agentBranch = Invoke-Git -Repo $agentRepo -GitArgs @("branch", "--show-current")
$agentCommit = Invoke-Git -Repo $agentRepo -GitArgs @("rev-parse", "HEAD")
$agentClean = Get-RepoCleanSummary $agentRepo

Add-Check "agent" "repo_exists" (Test-Path -LiteralPath $agentRepo -PathType Container) "Agent repo path exists" @{ path = [string]$agentRepo }
Add-Check "agent" "git_available" ([bool](Invoke-Git -Repo $agentRepo -GitArgs @("rev-parse", "--is-inside-work-tree"))) "Agent git metadata is available" @{}
Add-Check "agent" "branch" ($agentBranch -eq "main" -or $agentBranch -like "mg-tel-stack-rc-*") "Agent branch is main or stack RC feature branch" @{ branch = $agentBranch }
Add-Check "agent" "package_json" ($agentPackage.present -and $agentPackage.name -eq "jerry-telemetry-agent") "Agent package name checked" @{ name = $agentPackage.name; version = $agentPackage.version }
foreach ($file in @(
  "scripts/release-gate-local.ps1",
  "scripts/smoke-local-hub-agent-e2e.ps1",
  "scripts/package-agent-local.ps1",
  "scripts/doctor-agent-config.ps1"
)) {
  Add-Check "agent" $file (Test-Path -LiteralPath (Join-Path $agentRepo $file) -PathType Leaf) "$file exists" @{}
}
Add-Check "agent" "working_tree" ($agentClean.clean_except_goal_docs -or -not $RequireClean) "Agent working tree checked" $agentClean

$hubExists = Test-Path -LiteralPath $HubRepoPath -PathType Container
if (-not $hubExists) {
  Add-Check "hub" "repo_exists" ([bool]$AllowMissingHub) "Hub repo missing" @{ path = $HubRepoPath; allowed_missing = [bool]$AllowMissingHub }
} else {
  $hubRepo = Resolve-Path -LiteralPath $HubRepoPath
  $hubPackage = Get-PackageInfo $hubRepo
  $hubBranch = Invoke-Git -Repo $hubRepo -GitArgs @("branch", "--show-current")
  $hubCommit = Invoke-Git -Repo $hubRepo -GitArgs @("rev-parse", "HEAD")
  $hubOriginMain = Invoke-Git -Repo $hubRepo -GitArgs @("rev-parse", "origin/main")
  $hubClean = Get-RepoCleanSummary $hubRepo

  Add-Check "hub" "repo_exists" $true "Hub repo path exists" @{ path = [string]$hubRepo }
  Add-Check "hub" "git_available" ([bool](Invoke-Git -Repo $hubRepo -GitArgs @("rev-parse", "--is-inside-work-tree"))) "Hub git metadata is available" @{}
  Add-Check "hub" "branch" ($hubBranch -eq "main") "Hub branch is main" @{ branch = $hubBranch }
  Add-Check "hub" "required_merge" (Test-GitAncestor $hubRepo $requiredHubCommit "HEAD") "Hub main contains required deployment-readiness merge" @{ commit = $hubCommit; required = $requiredHubCommit; origin_main = $hubOriginMain }
  Add-Check "hub" "package_json" ($hubPackage.present -and $hubPackage.name -eq "jerry-telemetry-hub") "Hub package name checked" @{ name = $hubPackage.name; version = $hubPackage.version }
  foreach ($file in @(
    "scripts/release-gate-local.ps1",
    "scripts/doctor-local-config.ps1",
    "scripts/smoke-production-like-local.ps1",
    "scripts/sqlite-integrity-local.ps1",
    "scripts/sqlite-backup-local.ps1",
    "scripts/sqlite-restore-dry-run-local.ps1",
    "scripts/prune-retention-local.ps1"
  )) {
    Add-Check "hub" $file (Test-Path -LiteralPath (Join-Path $hubRepo $file) -PathType Leaf) "$file exists" @{}
  }
  Add-Check "hub" "working_tree" ($hubClean.clean_except_goal_docs -or -not $RequireClean) "Hub working tree checked" $hubClean

  $hubEndpointPatterns = @("/v1/events/batch", "/v1/nodes", "/v1/summary", "/v1/services", "/v1/custom", "/v1/events/recent")
  Add-Check "compatibility" "hub_endpoints" (Test-AnyFileContains $hubRepo @("app", "tests", "scripts") $hubEndpointPatterns) "Hub endpoint references checked" @{ endpoints = $hubEndpointPatterns }
}

$agentEventPatterns = @("node.snapshot", "node.resources.snapshot", "service.health.snapshot", "custom.snapshot", "telemetry.agent.health", "docker.containers.snapshot", "systemd.units.snapshot", "/v1/events/batch")
Add-Check "compatibility" "agent_batch_and_events" (Test-AnyFileContains $agentRepo @("src", "tests", "scripts") $agentEventPatterns) "Agent batch/event references checked" @{ event_types = $agentEventPatterns }
Add-Check "compatibility" "expected_packages" ($agentPackage.name -eq "jerry-telemetry-agent" -and ($AllowMissingHub -or $hubExists)) "Expected package names checked" @{}

$failures = @($checks | Where-Object { -not $_.ok })
$result = [ordered]@{
  ok = ($failures.Count -eq 0)
  generated_at = (Get-Date).ToUniversalTime().ToString("o")
  require_clean = [bool]$RequireClean
  allow_missing_hub = [bool]$AllowMissingHub
  agent = [ordered]@{ path = [string]$agentRepo; branch = $agentBranch; commit = $agentCommit; package = $agentPackage.name; version = $agentPackage.version }
  hub = [ordered]@{ path = $HubRepoPath; present = [bool]$hubExists }
  checks = $checks
  summary = [ordered]@{ total = $checks.Count; passed = ($checks.Count - $failures.Count); failed = $failures.Count }
  safe = [ordered]@{ secret_values_printed = $false; raw_env_printed = $false; raw_logs_printed = $false }
}

if ($Json) {
  $result | ConvertTo-Json -Depth 10
} else {
  foreach ($check in $checks) {
    $status = if ($check.ok) { "PASS" } else { "FAIL" }
    Write-Host "$status $($check.area).$($check.name)"
  }
  Write-Host "stack_doctor_ok=$($result.ok.ToString().ToLowerInvariant())"
}

if (-not $result.ok) {
  exit 1
}
