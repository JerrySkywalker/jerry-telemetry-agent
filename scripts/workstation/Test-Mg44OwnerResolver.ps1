$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$scriptRoot = (Resolve-Path $PSScriptRoot).Path
$resolver = Join-Path $scriptRoot "Resolve-Mg44Owner.ps1"
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ("mg44-owner-resolver-" + [guid]::NewGuid().ToString("N"))
$ownerLabel = "fixture-workstation"

function Assert-True {
  param([bool]$Condition, [string]$Code)
  if (-not $Condition) { throw $Code }
}

function Invoke-ResolverJson {
  param(
    [string]$Action,
    [hashtable]$Extra = @{}
  )
  $arguments = @{ Action = $Action; OwnerLabel = $ownerLabel; BaseRoot = $fixtureRoot; FixtureMode = $true }
  foreach ($key in $Extra.Keys) {
    $arguments[$key] = $Extra[$key]
  }
  $raw = (& $resolver @arguments | Out-String).Trim()
  Assert-True (-not [string]::IsNullOrWhiteSpace($raw)) "resolver_fixture_empty_output"
  Assert-True (-not ($raw -match [regex]::Escape($fixtureRoot))) "resolver_private_path_printed"
  return ($raw | ConvertFrom-Json)
}

function Assert-ResolverFails {
  param([hashtable]$Extra, [string]$ExpectedCode)
  $failed = $false
  try {
    Invoke-ResolverJson "Apply" $Extra | Out-Null
  } catch {
    $failed = $_.Exception.Message -match [regex]::Escape($ExpectedCode)
  }
  Assert-True $failed ("resolver_fixture_expected_failure_missing_" + $ExpectedCode)
}

try {
  New-Item -ItemType Directory -Force -Path $fixtureRoot | Out-Null

  $absent = Invoke-ResolverJson "Inspect"
  Assert-True (-not $absent.resolver_present -and -not $absent.safe_ids_resolved) "resolver_fixture_absent_inspect_failed"

  $planned = Invoke-ResolverJson "Plan"
  Assert-True ($planned.ok -and -not $planned.secret_generation_allowed -and -not (Test-Path -LiteralPath (Join-Path $fixtureRoot $ownerLabel))) "resolver_fixture_plan_mutated"

  $applied = Invoke-ResolverJson "Apply"
  Assert-True ($applied.ok -and $applied.resolver_present -and $applied.resolver_acl_passed -and $applied.safe_ids_resolved) "resolver_fixture_apply_failed"
  Assert-True ($applied.non_secret_identity_scaffolding_created -and $applied.secret_value_present -eq $false -and $applied.secret_derivative_present -eq $false) "resolver_fixture_scaffold_or_secret_contract_failed"

  $parent = Join-Path $fixtureRoot $ownerLabel
  $secret = Join-Path $parent "agent\identity\secrets"
  Assert-True ((Test-Path -LiteralPath $secret -PathType Container) -and @(Get-ChildItem -LiteralPath $secret -Force).Count -eq 0) "resolver_fixture_secret_directory_not_empty"

  $status = Invoke-ResolverJson "Status"
  Assert-True ($status.ok -and $status.bootstrap_idempotent -and $status.path_model_passed) "resolver_fixture_status_failed"
  $receipt = [string]$status.generation_receipt
  $reapplied = Invoke-ResolverJson "Apply"
  Assert-True ($reapplied.ok -and $reapplied.bootstrap_idempotent -and [string]$reapplied.generation_receipt -eq $receipt) "resolver_fixture_apply_not_idempotent"
  $repairedValid = Invoke-ResolverJson "Repair"
  Assert-True ($repairedValid.ok -and $repairedValid.bootstrap_idempotent) "resolver_fixture_valid_repair_failed"

  $resolverPath = Join-Path $fixtureRoot "owner-resolution.v1.json"
  $originalText = Get-Content -Raw -LiteralPath $resolverPath
  $drifted = $originalText.Replace('"gateway_service_name": "JerryMessageGateway"', '"gateway_service_name": "DriftedService"')
  Set-Content -LiteralPath $resolverPath -Value $drifted -Encoding UTF8
  $driftRejected = $false
  try { Invoke-ResolverJson "Repair" | Out-Null } catch { $driftRejected = $_.Exception.Message -match "owner_mapping_drift_rejected" }
  Assert-True $driftRejected "resolver_fixture_owner_mapping_drift_not_rejected"
  Set-Content -LiteralPath $resolverPath -Value $originalText -Encoding UTF8
  Assert-True (Invoke-ResolverJson "Repair").ok "resolver_fixture_drift_restore_failed"

  Set-Content -LiteralPath $resolverPath -Value "not-json" -Encoding UTF8
  $corruptStatus = Invoke-ResolverJson "Status"
  Assert-True (-not $corruptStatus.resolver_valid -and $corruptStatus.repair_required) "resolver_fixture_invalid_json_not_detected"
  Assert-True (Invoke-ResolverJson "Repair").ok "resolver_fixture_invalid_json_repair_failed"

  $wrongSchema = (Get-Content -Raw -LiteralPath $resolverPath).Replace('jerry.mg44.owner-resolution.v1', 'wrong.owner-resolution.v0')
  Set-Content -LiteralPath $resolverPath -Value $wrongSchema -Encoding UTF8
  Assert-True (-not (Invoke-ResolverJson "Status").resolver_valid) "resolver_fixture_wrong_schema_not_detected"
  Assert-True (Invoke-ResolverJson "Repair").ok "resolver_fixture_wrong_schema_repair_failed"

  $acl = Get-Acl -LiteralPath $resolverPath
  $broadRule = New-Object Security.AccessControl.FileSystemAccessRule("BUILTIN\Users", "FullControl", "Allow")
  $acl.AddAccessRule($broadRule); Set-Acl -LiteralPath $resolverPath -AclObject $acl
  $unsafeAcl = Invoke-ResolverJson "Status"
  Assert-True (-not $unsafeAcl.resolver_acl_passed -and $unsafeAcl.repair_required) "resolver_fixture_broad_acl_not_detected"
  Assert-True (Invoke-ResolverJson "Repair").ok "resolver_fixture_broad_acl_repair_failed"

  Remove-Item -LiteralPath $resolverPath -Force
  Assert-ResolverFails @{FailurePoint = "AfterTempWrite"} "fixture_interrupted_after_temp_write"
  $crashState = Invoke-ResolverJson "Status"
  Assert-True ($crashState.stale_temporary_count -eq 1 -and $crashState.repair_required) "resolver_fixture_temp_crash_not_detected"
  Assert-True (Invoke-ResolverJson "Repair").ok "resolver_fixture_temp_crash_repair_failed"
  Assert-True (@(Get-ChildItem -LiteralPath $fixtureRoot -Force -File -Filter "owner-resolution.v1.json.*.tmp").Count -eq 0) "resolver_fixture_temp_crash_artifact_remaining"

  Remove-Item -LiteralPath $resolverPath -Force
  Assert-ResolverFails @{FailurePoint = "AfterTempAcl"} "fixture_interrupted_after_temp_acl"
  $aclCrashState = Invoke-ResolverJson "Status"
  Assert-True ($aclCrashState.stale_temporary_count -eq 1 -and $aclCrashState.repair_required) "resolver_fixture_acl_crash_not_detected"
  Assert-True (Invoke-ResolverJson "Repair").ok "resolver_fixture_acl_crash_repair_failed"

  $transactionRoot = Join-Path $parent "agent\identity\transaction"
  New-Item -ItemType Directory -Force -Path $transactionRoot | Out-Null
  $signingMarker = Join-Path $secret "transaction-owned-marker"
  $mapMarker = Join-Path $transactionRoot "hub-candidate-map.tmp"
  $plaintextMarker = Join-Path $transactionRoot "transaction-plaintext.tmp"
  Set-Content -LiteralPath $signingMarker -Value "fixture-marker" -NoNewline
  Set-Content -LiteralPath $mapMarker -Value "fixture-marker" -NoNewline
  Set-Content -LiteralPath $plaintextMarker -Value "fixture-marker" -NoNewline
  Remove-Item -LiteralPath $signingMarker, $mapMarker, $plaintextMarker -Force
  $retained = Invoke-ResolverJson "Status"
  Assert-True ($retained.ok -and (Test-Path -LiteralPath $secret -PathType Container) -and @(Get-ChildItem -LiteralPath $secret -Force).Count -eq 0) "resolver_fixture_secret_failure_retention_failed"

  [ordered]@{
    ok = $true
    resolver_fixture_create_passed = $true
    resolver_fixture_idempotency_passed = $true
    resolver_fixture_acl_passed = $true
    resolver_fixture_atomic_replace_passed = $true
    resolver_fixture_crash_recovery_passed = $true
    resolver_fixture_secret_failure_retention_passed = $true
    resolver_fixture_resources_remaining = 0
    secret_value_generated = $false
    secret_derivative_generated = $false
    private_values_printed = $false
  } | ConvertTo-Json -Compress
} finally {
  if (Test-Path -LiteralPath $fixtureRoot) {
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
  }
}
