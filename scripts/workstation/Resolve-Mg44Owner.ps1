param(
  [ValidateSet("Inspect", "Plan", "Apply", "Status", "Repair")]
  [string]$Action = "Status",
  [string]$OwnerLabel = "workstation-mg44-01",
  [string]$BaseRoot,
  [string]$OwnerAuthorizationId = "MG44_P1X_OWNER_BOOTSTRAP_01",
  [string]$TransactionId,
  [ValidateSet("None", "AfterTempWrite", "AfterTempAcl")]
  [string]$FailurePoint = "None",
  [switch]$FixtureMode
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$schema = "jerry.mg44.owner-resolution.v1"
$receiptPrefix = "MG44-P1X-OWNER-RESOLVER-"
$gatewayServiceName = "JerryMessageGateway"
$agentServiceName = "JerryTelemetryAgent"
$gatewayPort = 3094
$agentHealthPort = 8081
$allServicesSid = "S-1-5-80-0"
$systemSid = "S-1-5-18"
$administratorsSid = "S-1-5-32-544"
$usersSid = "S-1-5-32-545"
$authenticatedUsersSid = "S-1-5-11"
$everyoneSid = "S-1-1-0"

function Assert-True {
  param([bool]$Condition, [string]$Code)
  if (-not $Condition) { throw $Code }
}

function Get-CanonicalPath {
  param([string]$Path)
  return [IO.Path]::GetFullPath($Path).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
}

function Assert-SafeBaseRoot {
  param([string]$Path)
  $full = Get-CanonicalPath $Path
  Assert-True ([IO.Path]::IsPathRooted($full)) "owner_base_root_must_be_absolute"
  Assert-True (-not ($full -match "^(?i)\\\\|\\\\\?\\|\\\\\.\\|[a-z][a-z0-9+.-]*://")) "owner_base_root_remote_or_device_forbidden"
  Assert-True (-not (@($full -split "[\\/]" | Where-Object { $_ -eq ".." }).Count)) "owner_base_root_traversal_forbidden"
  if ($FixtureMode) {
    $temp = Get-CanonicalPath ([IO.Path]::GetTempPath())
    Assert-True ($full.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase)) "owner_fixture_root_must_be_under_temp"
  } else {
    $programData = Get-CanonicalPath $env:ProgramData
    $requiredPrefix = Join-Path $programData "Jerry\MG44"
    Assert-True ($full.StartsWith((Get-CanonicalPath $requiredPrefix), [StringComparison]::OrdinalIgnoreCase)) "owner_base_root_must_be_canonical_programdata"
    Assert-True (-not $full.StartsWith((Get-CanonicalPath (Join-Path (Get-Location) ".")), [StringComparison]::OrdinalIgnoreCase)) "owner_base_root_must_not_be_repository"
  }
  return $full
}

function Get-ServiceSid {
  param([string]$ServiceName)
  $sha1 = [Security.Cryptography.SHA1]::Create()
  try { $hash = $sha1.ComputeHash([Text.Encoding]::Unicode.GetBytes($ServiceName.ToUpperInvariant())) }
  finally { $sha1.Dispose() }
  $parts = for ($offset = 0; $offset -lt 20; $offset += 4) { [BitConverter]::ToUInt32($hash, $offset) }
  return "S-1-5-80-" + ($parts -join "-")
}

function Get-IdentitySid {
  param([string]$Identity)
  try { return ([Security.Principal.NTAccount]$Identity).Translate([Security.Principal.SecurityIdentifier]).Value }
  catch { return $Identity.ToUpperInvariant() }
}

function Get-Paths {
  $resolvedBase = if ($BaseRoot) { Assert-SafeBaseRoot $BaseRoot | Out-Null; Get-CanonicalPath $BaseRoot } else {
    Assert-True (-not $FixtureMode) "fixture_base_root_required"
    Get-CanonicalPath (Join-Path $env:ProgramData "Jerry\MG44")
  }
  Assert-True ($OwnerLabel -match "^[A-Za-z0-9][A-Za-z0-9._-]{2,127}$") "owner_label_invalid"
  if (-not $FixtureMode) { Assert-True (-not ($OwnerLabel -match "(?i)lax|fixture|placeholder|example|replace")) "owner_label_not_production_identity" }
  Assert-True ($OwnerAuthorizationId -match "^MG44_P1X_[A-Za-z0-9._-]+$") "owner_authorization_id_invalid"
  $parent = Get-CanonicalPath (Join-Path $resolvedBase $OwnerLabel)
  $gateway = Get-CanonicalPath (Join-Path $parent "gateway")
  $agent = Get-CanonicalPath (Join-Path $parent "agent")
  $identity = Get-CanonicalPath (Join-Path $agent "identity")
  $secret = Get-CanonicalPath (Join-Path $identity "secrets")
  $resolver = Get-CanonicalPath (Join-Path $resolvedBase "owner-resolution.v1.json")
  $lock = "$resolver.lock"
  [ordered]@{
    base = $resolvedBase
    parent = $parent
    gateway = $gateway
    agent = $agent
    identity = $identity
    secret = $secret
    resolver = $resolver
    lock = $lock
  }
}

function Get-Bindings {
  param([hashtable]$Paths)
  [ordered]@{
    workstation_parent = $Paths.parent
    gateway_runtime_root = $Paths.gateway
    agent_runtime_root = $Paths.agent
    agent_identity_root = $Paths.identity
    agent_secret_directory = $Paths.secret
    gateway_service_name = $gatewayServiceName
    agent_service_name = $agentServiceName
    gateway_loopback_port = $gatewayPort
    agent_health_loopback_port = $agentHealthPort
  }
}

function Get-SafeIds {
  [ordered]@{
    workstation_parent = "MG44_WORKSTATION_PARENT_01"
    gateway_runtime_root = "MG44_GATEWAY_RUNTIME_ROOT_01"
    agent_runtime_root = "MG44_AGENT_RUNTIME_ROOT_01"
    agent_identity_root = "MG44_AGENT_IDENTITY_ROOT_01"
    agent_secret_directory = "MG44_AGENT_SECRET_DIRECTORY_01"
    gateway_service_account = "MG44_GATEWAY_SERVICE_ACCOUNT_01"
    agent_service_account = "MG44_AGENT_SERVICE_ACCOUNT_01"
    gateway_loopback_slot = "MG44_GATEWAY_LOOPBACK_SLOT_01"
    agent_health_loopback_slot = "MG44_AGENT_HEALTH_LOOPBACK_SLOT_01"
  }
}

function Get-FileSystemRightsMask {
  param([Security.AccessControl.FileSystemRights]$Rights)
  return [int64]$Rights
}

function Add-ProtectedRule {
  param(
    [Security.AccessControl.CommonObjectSecurity]$Acl,
    [string]$Sid,
    [Security.AccessControl.FileSystemRights]$Rights,
    [bool]$Directory,
    [bool]$InheritToChildren
  )
  $inheritance = [Security.AccessControl.InheritanceFlags]::None
  if ($Directory -and $InheritToChildren) {
    $inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit
  }
  $rule = New-Object Security.AccessControl.FileSystemAccessRule(
    (New-Object Security.Principal.SecurityIdentifier($Sid)),
    $Rights,
    $inheritance,
    [Security.AccessControl.PropagationFlags]::None,
    [Security.AccessControl.AccessControlType]::Allow
  )
  $Acl.AddAccessRule($rule)
}

function Set-ProtectedAcl {
  param([string]$Path, [ValidateSet("File", "Directory")][string]$Kind, [switch]$AllowAgentRead)
  Assert-True (Test-Path -LiteralPath $Path -PathType $(if ($Kind -eq "File") { "Leaf" } else { "Container" })) "acl_target_missing"
  $isDirectory = $Kind -eq "Directory"
  $acl = if ($isDirectory) { New-Object System.Security.AccessControl.DirectorySecurity } else { New-Object System.Security.AccessControl.FileSecurity }
  $acl.SetAccessRuleProtection($true, $false)
  $fullControl = [Security.AccessControl.FileSystemRights]::FullControl
  Add-ProtectedRule $acl $systemSid $fullControl $isDirectory $true
  Add-ProtectedRule $acl $administratorsSid $fullControl $isDirectory $true
  if ($AllowAgentRead) {
    $read = [Security.AccessControl.FileSystemRights]::ReadAndExecute
    Add-ProtectedRule $acl (Get-ServiceSid $agentServiceName) $read $isDirectory $true
  }
  Set-Acl -LiteralPath $Path -AclObject $acl
}

function Get-AccessRecords {
  param([string]$Path)
  return @(Get-Acl -LiteralPath $Path | ForEach-Object { $_.Access } | ForEach-Object {
    [pscustomobject]@{
      sid = Get-IdentitySid ([string]$_.IdentityReference.Value)
      type = [string]$_.AccessControlType
      rights = [int64]$_.FileSystemRights
      inherited = [bool]$_.IsInherited
    }
  })
}

function Test-ProtectedAcl {
  param([string]$Path, [ValidateSet("File", "Directory")][string]$Kind, [switch]$AllowAgentRead)
  if (-not (Test-Path -LiteralPath $Path -PathType $(if ($Kind -eq "File") { "Leaf" } else { "Container" }))) { return $false }
  try {
    $acl = Get-Acl -LiteralPath $Path
    if (-not $acl.AreAccessRulesProtected) { return $false }
    $records = Get-AccessRecords $Path
    $full = Get-FileSystemRightsMask ([Security.AccessControl.FileSystemRights]::FullControl)
    $write = Get-FileSystemRightsMask ([Security.AccessControl.FileSystemRights]::Write -bor [Security.AccessControl.FileSystemRights]::Delete -bor [Security.AccessControl.FileSystemRights]::ChangePermissions -bor [Security.AccessControl.FileSystemRights]::TakeOwnership)
    foreach ($record in $records) {
      if ($record.inherited -or $record.type -ne "Allow") { return $false }
      if ($record.sid -in @($usersSid, $authenticatedUsersSid, $everyoneSid, $allServicesSid)) {
        if (($record.rights -band $write) -ne 0) { return $false }
        return $false
      }
      if ($record.sid -notin @($systemSid, $administratorsSid, (Get-ServiceSid $agentServiceName))) { return $false }
      if ($record.sid -eq (Get-ServiceSid $agentServiceName) -and (-not $AllowAgentRead -or ($record.rights -band $write) -ne 0)) { return $false }
    }
    $required = @($systemSid, $administratorsSid)
    foreach ($sid in $required) {
      $match = @($records | Where-Object { $_.sid -eq $sid -and ($_.rights -band $full) -eq $full })
      if ($match.Count -ne 1) { return $false }
    }
    if ($AllowAgentRead) {
      $agent = @($records | Where-Object { $_.sid -eq (Get-ServiceSid $agentServiceName) -and ($_.rights -band (Get-FileSystemRightsMask ([Security.AccessControl.FileSystemRights]::ReadAndExecute))) -ne 0 })
      if ($agent.Count -ne 1) { return $false }
    }
    return $true
  } catch { return $false }
}

function Test-SafeObject {
  param([string]$Path, [ValidateSet("File", "Directory")][string]$Kind)
  if (-not (Test-Path -LiteralPath $Path -PathType $(if ($Kind -eq "File") { "Leaf" } else { "Container" }))) { return $false }
  try {
    $item = Get-Item -LiteralPath $Path -Force
    if (([IO.FileAttributes]$item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
    return $true
  } catch { return $false }
}

function Test-PortFree {
  param([int]$Port)
  if ($FixtureMode) { return $true }
  try {
    $listeners = @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue)
    return $listeners.Count -eq 0
  } catch {
    try {
      $tcp = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $Port)
      $tcp.Start(); $tcp.Stop(); return $true
    } catch { return $false }
  }
}

function Test-PathModel {
  param([hashtable]$Paths)
  $items = @($Paths.parent, $Paths.gateway, $Paths.agent, $Paths.identity, $Paths.secret)
  foreach ($path in $items) { if (Test-Path -LiteralPath $path) { if (-not (Test-SafeObject $path "Directory")) { return $false } } }
  return $true
}

function New-Receipt {
  return ($receiptPrefix + [guid]::NewGuid().ToString("N"))
}

function Get-TransactionIdSafe {
  if ($TransactionId) {
    Assert-True ($TransactionId -match "^[A-Za-z0-9][A-Za-z0-9._-]{2,127}$") "transaction_id_invalid"
    return $TransactionId
  }
  return ("MG44-P1X-OWNER-" + [guid]::NewGuid().ToString("N"))
}

function Get-TempFiles {
  param([hashtable]$Paths)
  $directory = Split-Path -Parent $Paths.resolver
  $leaf = Split-Path -Leaf $Paths.resolver
  if (-not (Test-Path -LiteralPath $directory -PathType Container)) { return @() }
  return @(Get-ChildItem -LiteralPath $directory -Force -File -Filter "$leaf.*.tmp" -ErrorAction SilentlyContinue)
}

function Read-Resolver {
  param([hashtable]$Paths)
  if (-not (Test-Path -LiteralPath $Paths.resolver -PathType Leaf)) { return $null }
  try { return (Get-Content -Raw -LiteralPath $Paths.resolver | ConvertFrom-Json) }
  catch { return [pscustomobject]@{ __invalid = $true } }
}

function Test-InvalidResolver {
  param($Resolver)
  return ($null -ne $Resolver -and $Resolver.PSObject.Properties.Name -contains "__invalid" -and [bool]$Resolver.__invalid)
}

function Test-MappingMatches {
  param($Resolver, [hashtable]$Expected)
  if ($null -eq $Resolver -or (Test-InvalidResolver $Resolver)) { return $false }
  if ([string]$Resolver.schema_version -ne $schema -or [string]$Resolver.owner_label -ne $OwnerLabel) { return $false }
  foreach ($property in $Expected.Keys) {
    if ($null -eq $Resolver.bindings.$property -or [string]$Resolver.bindings.$property -cne [string]$Expected[$property]) { return $false }
  }
  return $true
}

function Get-ResolverAclPassed {
  param([hashtable]$Paths)
  return (Test-ProtectedAcl $Paths.resolver "File")
}

function Get-ScaffoldState {
  param([hashtable]$Paths)
  [ordered]@{
    workstation_parent = Test-SafeObject $Paths.parent "Directory"
    gateway_runtime_root = Test-SafeObject $Paths.gateway "Directory"
    agent_runtime_root = Test-SafeObject $Paths.agent "Directory"
    agent_identity_root = Test-SafeObject $Paths.identity "Directory"
    agent_secret_directory = (Test-SafeObject $Paths.secret "Directory" -and (Test-ProtectedAcl $Paths.secret "Directory" -AllowAgentRead))
  }
}

function Get-Status {
  param([hashtable]$Paths, [hashtable]$Expected, [hashtable]$SafeIds)
  $resolver = Read-Resolver $Paths
  $present = Test-Path -LiteralPath $Paths.resolver -PathType Leaf
  $invalid = $present -and ($null -eq $resolver -or (Test-InvalidResolver $resolver) -or [string]$resolver.schema_version -ne $schema)
  $mappingMatches = Test-MappingMatches $resolver $Expected
  $aclPassed = if ($present) { Get-ResolverAclPassed $Paths } else { $false }
  $scaffold = Get-ScaffoldState $Paths
  $tempFiles = @(Get-TempFiles $Paths)
  $lockPresent = Test-Path -LiteralPath $Paths.lock -PathType Leaf
  $lockBusy = $false
  if ($lockPresent) {
    try { $stream = [IO.File]::Open($Paths.lock, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None); $stream.Dispose() }
    catch { $lockBusy = $true }
  }
  $safeIdsResolved = $mappingMatches -and ($Expected.Keys.Count -eq $SafeIds.Keys.Count)
  [ordered]@{
    ok = (-not $invalid -and $mappingMatches -and $aclPassed -and $safeIdsResolved)
    action = $Action
    schema_version = $schema
    owner_label = $OwnerLabel
    resolver_present = $present
    resolver_valid = (-not $invalid -and $mappingMatches)
    resolver_acl_passed = $aclPassed
    owner_mapping_drift = ($present -and -not $invalid -and -not $mappingMatches)
    repair_required = ($invalid -or ($present -and -not $mappingMatches) -or ($present -and -not $aclPassed) -or $tempFiles.Count -gt 0)
    safe_ids_resolved = $safeIdsResolved
    non_secret_identity_scaffolding_created = ($scaffold.agent_identity_root -and $scaffold.agent_secret_directory)
    bootstrap_idempotent = ($mappingMatches -and $aclPassed -and $scaffold.agent_secret_directory)
    path_model_passed = Test-PathModel $Paths
    gateway_loopback_port_free = Test-PortFree $gatewayPort
    agent_health_loopback_port_free = Test-PortFree $agentHealthPort
    stale_temporary_count = $tempFiles.Count
    lock_present = $lockPresent
    lock_busy = $lockBusy
    generation_receipt = if ($resolver -and -not $invalid) { [string]$resolver.generation_receipt } else { $null }
    owner_authorization_id = if ($resolver -and -not $invalid) { [string]$resolver.owner_authorization_id } else { $OwnerAuthorizationId }
    transaction_id = if ($resolver -and -not $invalid) { [string]$resolver.transaction_id } else { $null }
    secret_value_present = $false
    secret_derivative_present = $false
    private_values_printed = $false
  }
}

function Acquire-ResolverLock {
  param([hashtable]$Paths, [string]$CurrentTransactionId)
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Paths.lock) | Out-Null
  try {
    $stream = [IO.File]::Open($Paths.lock, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $stream.SetLength(0)
    $bytes = [Text.Encoding]::UTF8.GetBytes(("transaction_id=" + $CurrentTransactionId))
    $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true)
    return $stream
  } catch { throw "resolver_lock_busy" }
}

function Write-ResolverAtomic {
  param([hashtable]$Paths, [hashtable]$Data, [string]$CurrentTransactionId)
  $temporary = "$($Paths.resolver).$([guid]::NewGuid().ToString('N')).tmp"
  try {
    $json = $Data | ConvertTo-Json -Depth 16
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json + "`n")
    $stream = [IO.FileStream]::new($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None, 4096, [IO.FileOptions]::WriteThrough)
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
    if ($FailurePoint -eq "AfterTempWrite") { throw "fixture_interrupted_after_temp_write" }
    Set-ProtectedAcl $temporary "File"
    if ($FailurePoint -eq "AfterTempAcl") { throw "fixture_interrupted_after_temp_acl" }
    if (Test-Path -LiteralPath $Paths.resolver -PathType Leaf) {
      [IO.File]::Replace($temporary, $Paths.resolver, $null, $true)
    } else {
      [IO.File]::Move($temporary, $Paths.resolver)
    }
    Assert-True (Test-MappingMatches (Read-Resolver $Paths) (Get-Bindings $Paths)) "resolver_post_replace_verification_failed"
    Assert-True (Get-ResolverAclPassed $Paths) "resolver_post_replace_acl_failed"
  } catch {
    if ($_.Exception.Message -notmatch "fixture_interrupted_after_temp") {
      throw "resolver_atomic_replace_failed"
    }
    throw $_
  } finally {
    if ((Test-Path -LiteralPath $temporary -PathType Leaf) -and $FailurePoint -eq "None") { Remove-Item -LiteralPath $temporary -Force }
  }
}

function New-ResolverData {
  param([hashtable]$Paths, [string]$CurrentTransactionId)
  [ordered]@{
    schema_version = $schema
    owner_label = $OwnerLabel
    owner_authorization_id = $OwnerAuthorizationId
    transaction_id = $CurrentTransactionId
    generation_receipt = New-Receipt
    generated_at = [DateTime]::UtcNow.ToString("o")
    safe_ids = Get-SafeIds
    bindings = Get-Bindings $Paths
    service_sids = [ordered]@{
      gateway = Get-ServiceSid $gatewayServiceName
      agent = Get-ServiceSid $agentServiceName
    }
    secret_value_present = $false
    secret_derivative_present = $false
  }
}

function Ensure-Scaffolding {
  param([hashtable]$Paths)
  foreach ($path in @($Paths.parent, $Paths.gateway, $Paths.agent, $Paths.identity, $Paths.secret)) {
    if (-not (Test-Path -LiteralPath $path)) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
    Assert-True (Test-SafeObject $path "Directory") "scaffold_reparse_or_type_invalid"
  }
  Set-ProtectedAcl $Paths.parent "Directory"
  Set-ProtectedAcl $Paths.gateway "Directory"
  Set-ProtectedAcl $Paths.agent "Directory"
  Set-ProtectedAcl $Paths.identity "Directory"
  Set-ProtectedAcl $Paths.secret "Directory" -AllowAgentRead
  Assert-True ((Get-ScaffoldState $Paths).agent_secret_directory) "scaffold_acl_verification_failed"
}

function Assert-CanCreateBoundary {
  param([hashtable]$Paths)
  if (Test-Path -LiteralPath $Paths.parent -PathType Container) {
    $unexpected = @(Get-ChildItem -LiteralPath $Paths.parent -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -notin @("gateway", "agent") })
    Assert-True ($unexpected.Count -eq 0) "owner_boundary_contains_unexpected_entries"
  }
  foreach ($path in @($Paths.gateway, $Paths.agent, $Paths.identity, $Paths.secret)) {
    if (Test-Path -LiteralPath $path) { Assert-True (Test-SafeObject $path "Directory") "owner_boundary_existing_object_unsafe" }
  }
}

function Invoke-Apply {
  param([hashtable]$Paths, [hashtable]$Expected, [hashtable]$SafeIds, [bool]$RepairMode)
  Assert-True ($FailurePoint -eq "None" -or $FixtureMode) "failure_injection_requires_fixture"
  $current = Get-TransactionIdSafe
  $status = Get-Status $Paths $Expected $SafeIds
  if ($status.owner_mapping_drift) { throw "owner_mapping_drift_rejected" }
  if ($status.resolver_present -and $status.resolver_valid -and $status.resolver_acl_passed -and $status.non_secret_identity_scaffolding_created) {
    $status.action = if ($RepairMode) { "Repair" } else { "Apply" }
    $status.bootstrap_idempotent = $true
    return $status
  }
  if ($status.stale_temporary_count -gt 0 -and -not $RepairMode) { throw "resolver_temporary_recovery_required" }
  if ($status.resolver_present -and (-not $status.resolver_valid) -and -not $RepairMode) { throw "resolver_invalid_repair_required" }
  if ($status.resolver_present -and $RepairMode) {
    $existing = Read-Resolver $Paths
    if (Test-InvalidResolver $existing) { $existing = $null }
    if ($null -ne $existing -and [string]$existing.schema_version -eq $schema) {
      if ([string]$existing.owner_label -ne $OwnerLabel -or -not (Test-MappingMatches $existing $Expected)) { throw "owner_mapping_drift_rejected" }
    }
    Remove-Item -LiteralPath $Paths.resolver -Force -ErrorAction SilentlyContinue
  }
  if ($RepairMode) {
    foreach ($temporary in @(Get-TempFiles $Paths)) { Remove-Item -LiteralPath $temporary.FullName -Force }
  }
  Assert-CanCreateBoundary $Paths
  Ensure-Scaffolding $Paths
  $lock = Acquire-ResolverLock $Paths $current
  try {
    $data = New-ResolverData $Paths $current
    Write-ResolverAtomic $Paths $data $current
  } finally {
    $lock.Dispose()
    Remove-Item -LiteralPath $Paths.lock -Force -ErrorAction SilentlyContinue
  }
  $result = Get-Status $Paths $Expected $SafeIds
  $result.action = if ($RepairMode) { "Repair" } else { "Apply" }
  $result.owner_authorization_id = $OwnerAuthorizationId
  Assert-True $result.ok "resolver_apply_postcondition_failed"
  return $result
}

function Invoke-Inspect {
  param([hashtable]$Paths, [hashtable]$Expected, [hashtable]$SafeIds)
  $result = Get-Status $Paths $Expected $SafeIds
  $result.action = "Inspect"
  return $result
}

function Invoke-Plan {
  param([hashtable]$Paths, [hashtable]$Expected, [hashtable]$SafeIds)
  $status = Get-Status $Paths $Expected $SafeIds
  [ordered]@{
    ok = (-not $status.owner_mapping_drift -and $status.path_model_passed)
    action = "Plan"
    schema_version = $schema
    owner_label = $OwnerLabel
    plan_id = ("MG44-P1X-OWNER-PLAN-" + [guid]::NewGuid().ToString("N"))
    owner_authorization_id = $OwnerAuthorizationId
    safe_ids = $SafeIds
    resolver_present = $status.resolver_present
    resolver_acl_passed = $status.resolver_acl_passed
    safe_ids_resolved = $status.safe_ids_resolved
    non_secret_identity_scaffolding_created = $status.non_secret_identity_scaffolding_created
    gateway_loopback_port_free = $status.gateway_loopback_port_free
    agent_health_loopback_port_free = $status.agent_health_loopback_port_free
    secret_generation_allowed = $false
    secret_value_present = $false
    secret_derivative_present = $false
    private_values_printed = $false
  }
}

try {
  if ($FailurePoint -ne "None") { Assert-True $FixtureMode "failure_injection_requires_fixture" }
  $paths = Get-Paths
  $expected = Get-Bindings $paths
  $safeIds = Get-SafeIds
  $result = switch ($Action) {
    "Inspect" { Invoke-Inspect $paths $expected $safeIds }
    "Status" { Get-Status $paths $expected $safeIds }
    "Plan" { Invoke-Plan $paths $expected $safeIds }
    "Apply" { Invoke-Apply $paths $expected $safeIds $false }
    "Repair" { Invoke-Apply $paths $expected $safeIds $true }
  }
  $result | ConvertTo-Json -Depth 16 -Compress
} catch {
  throw $_
}
