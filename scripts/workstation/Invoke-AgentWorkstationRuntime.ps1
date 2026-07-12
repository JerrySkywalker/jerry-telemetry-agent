param(
  [Parameter(Mandatory = $true)]
  [ValidateSet("Install", "Upgrade", "Rollback", "Uninstall", "Status")]
  [string]$Operation,
  [Parameter(Mandatory = $true)][string]$RuntimeRoot,
  [string]$ArtifactPath,
  [string]$ManifestPath,
  [string]$EnvPath,
  [string]$NodeConfigPath,
  [string]$ExpectedSourceCommit,
  [string]$ExpectedArtifactSha256,
  [string]$ExpectedServiceTemplateSha256,
  [string]$ExpectedServiceAccountBindingSha256,
  [string]$ExpectedSecretReferenceSchema,
  [string]$ExpectedAgentIdentityBindingSha256,
  [string]$ExpectedConfigBindingSha256,
  [string]$ExpectedSecretReferenceBindingSha256,
  [string]$ServiceWrapperPath,
  [string]$ServiceTemplatePath,
  [string]$ServiceAccountModel = "VirtualServiceAccount",
  [string]$ServiceAccountIdentity = "NT SERVICE\JerryTelemetryAgent",
  [string]$AuthorizationId,
  [switch]$DryRun,
  [switch]$ConfirmInstall,
  [switch]$ConfirmUpgrade,
  [switch]$ConfirmRollback,
  [switch]$ConfirmUninstall,
  [switch]$FixtureMode,
  [ValidateSet("Safe", "ReadDenied", "ReadOnlyGroupWrite", "ReadOnlyFullControl", "MutableWriteDenied", "MutableModify", "MutableRootDelete", "MutableOwnership", "MutableNonInheritable", "ChildDeny", "ChildExcessWrite", "ChildOwnership", "AllServicesInheritedWrite", "AncestorWrite", "AncestorDelete", "SiblingWrite", "NestedSiblingWrite", "RuntimeOwnerWrite", "RuntimeTransactionWrite", "UnknownRuntimeSubtreeWrite", "TraversalDenied")]
  [string]$FixtureAccessCase = "Safe",
  [string]$FixtureScmStartName = "NT SERVICE\JerryTelemetryAgent",
  [switch]$SimulateHealthFailure
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$component = "agent"
$serviceName = "JerryTelemetryAgent"
$ownerSchema = "jerry.workstation.runtime-owner.v1"
$transactionSchema = "jerry.workstation.activation.v1"
$serviceAccountSchema = "jerry.workstation.service-account.v1"
$secretReferenceSchema = "jerry.workstation.secret-reference.v1"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$verifier = Join-Path $repoRoot "scripts\workstation\Test-AgentReleaseManifest.ps1"
$defaultTemplate = Join-Path $repoRoot "deploy\workstation\jerry-telemetry-agent-service.xml.template"
$trust = Get-Content -Raw -LiteralPath (Join-Path $repoRoot "deploy\workstation\trusted-runtime.json") | ConvertFrom-Json

function Assert-True { param([bool]$Condition, [string]$Code); if (-not $Condition) { throw $Code } }
function Get-Sha256 {
  param([string]$Path)
  $stream = [IO.File]::OpenRead($Path); $sha = [Security.Cryptography.SHA256]::Create()
  try { return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace("-", "").ToLowerInvariant() }
  finally { $sha.Dispose(); $stream.Dispose() }
}
function Get-TextSha256 {
  param([string]$Text)
  $sha = [Security.Cryptography.SHA256]::Create()
  try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace("-", "").ToLowerInvariant() }
  finally { $sha.Dispose() }
}
function Get-ServiceAccountBindingSha256 {
  return Get-TextSha256 "$serviceAccountSchema|$serviceName|VirtualServiceAccount|service_name_derived"
}
function Assert-ServiceAccountContract {
  Assert-True ($ServiceAccountModel -ceq "VirtualServiceAccount") "service_account_model_forbidden"
  Assert-True ($ServiceAccountIdentity -ceq "NT SERVICE\$serviceName") "service_account_identity_must_be_service_name_derived"
  Assert-True ([string]$trust.service_account.schema_version -eq $serviceAccountSchema) "service_account_trust_schema_invalid"
  Assert-True ([string]$trust.service_account.model -eq "VirtualServiceAccount") "service_account_trust_model_invalid"
  Assert-True ([string]$trust.service_account.identity_kind -eq "service_name_derived") "service_account_trust_identity_invalid"
  Assert-True ($trust.service_account.password_required -eq $false) "service_account_password_contract_invalid"
  Assert-True ($trust.service_account.service_logon_right_mutation -eq $false) "service_account_right_mutation_forbidden"
  Assert-True ([string]$trust.service_account.binding_sha256 -eq (Get-ServiceAccountBindingSha256)) "service_account_binding_sha256_mismatch"
}
function Assert-CanonicalServiceTemplate {
  Assert-True ([string]$trust.service_template.byte_contract -eq "canonical_lf_bytes_raw_sha256") "service_template_byte_contract_invalid"
  $bytes = [IO.File]::ReadAllBytes($defaultTemplate)
  Assert-True (-not ([Text.Encoding]::UTF8.GetString($bytes).Contains("`r"))) "service_template_must_be_canonical_lf"
  Assert-True ((Get-Sha256 $defaultTemplate) -eq [string]$trust.service_template.sha256) "service_template_raw_sha256_mismatch"
  [xml]$template = [Text.Encoding]::UTF8.GetString($bytes)
  Assert-True ($template.service.serviceaccount.domain -ceq "NT SERVICE") "service_template_account_domain_invalid"
  Assert-True ($template.service.serviceaccount.user -ceq $serviceName) "service_template_account_user_invalid"
  Assert-True ($template.service.serviceaccount.allowservicelogon -ceq "false") "service_template_must_not_grant_logon_right"
  Assert-True ($null -eq $template.SelectSingleNode("/service/serviceaccount/password")) "service_template_password_forbidden"
}
function ConvertTo-XmlText { param([string]$Value); return [Security.SecurityElement]::Escape($Value) }
function Assert-SafeLocalPathObject {
  param([string]$Path, [ValidateSet("Leaf", "Container")][string]$Type)
  Assert-True (-not [string]::IsNullOrWhiteSpace($Path)) "access_path_required"
  Assert-True ([IO.Path]::IsPathRooted($Path)) "access_path_must_be_absolute"
  Assert-True (-not ($Path -match "^(?i)\\\\|\\\\\?\\|\\\\\.\\|[a-z][a-z0-9+.-]*://")) "access_path_remote_or_device_forbidden"
  Assert-True (-not (@($Path -split "[\\/]" | Where-Object { $_ -eq ".." }).Count)) "access_path_traversal_forbidden"
  $full = [IO.Path]::GetFullPath($Path)
  $rootPath = [IO.Path]::GetPathRoot($full)
  $relative = $full.Substring($rootPath.Length)
  $cursor = $rootPath
  foreach ($segment in @($relative -split "[\\/]" | Where-Object { $_ })) {
    $cursor = Join-Path $cursor $segment
    Assert-True (Test-Path -LiteralPath $cursor) "access_path_component_missing"
    $item = Get-Item -LiteralPath $cursor -Force
    Assert-True (-not [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) "access_path_reparse_forbidden"
    $linkType = if ($item.PSObject.Properties.Name -contains "LinkType") { [string]$item.LinkType } else { "" }
    Assert-True ($linkType -notin @("SymbolicLink", "Junction", "HardLink")) "access_path_link_forbidden"
    if ($item.PSObject.Properties.Name -contains "Target") { Assert-True (-not $item.Target) "access_path_target_alias_forbidden" }
  }
  Assert-True (Test-Path -LiteralPath $full -PathType $Type) "access_path_type_invalid"
  return $full
}
function Get-AccessRuleRecords {
  param([string]$Path, [string]$ResourceClass)
  if ($FixtureMode) {
    $read = [int64][Security.AccessControl.FileSystemRights]::ReadAndExecute
    $stateWrite = [int64]($read -bor [Security.AccessControl.FileSystemRights]::WriteData -bor [Security.AccessControl.FileSystemRights]::AppendData)
    $childLifecycleWrite = [int64]($stateWrite -bor [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles)
    $rights = switch ($ResourceClass) {
      "mutable_state" { $stateWrite }
      "mutable_spool" { $childLifecycleWrite }
      "mutable_log" { $childLifecycleWrite }
      "mutable_state_child" { $stateWrite }
      "mutable_spool_child" { $childLifecycleWrite }
      "mutable_log_child" { $childLifecycleWrite }
      "protected_sibling" { $read }
      default { $read }
    }
    $mutableRoot = $ResourceClass -in @("mutable_state", "mutable_spool", "mutable_log")
    $mutableChild = $ResourceClass -in @("mutable_state_child", "mutable_spool_child", "mutable_log_child")
    $inheritable = $mutableRoot -and $FixtureAccessCase -ne "MutableNonInheritable"
    $records = @([pscustomobject]@{
      identity = $ServiceAccountIdentity; type = "Allow"; rights = $rights; inherited = $mutableChild; inherit_only = $false
      container_inherit = $inheritable -or $mutableChild; object_inherit = $inheritable -or $mutableChild
    })
    switch ($FixtureAccessCase) {
      "ReadDenied" { if ($ResourceClass -in @("read_only", "read_execute")) { $records += [pscustomobject]@{ identity = "NT SERVICE\ALL SERVICES"; type = "Deny"; rights = $read; inherited = $true } } }
      "ReadOnlyGroupWrite" { if ($ResourceClass -in @("read_only", "read_execute")) { $records += [pscustomobject]@{ identity = "NT AUTHORITY\Authenticated Users"; type = "Allow"; rights = $stateWrite; inherited = $true } } }
      "ReadOnlyFullControl" { if ($ResourceClass -in @("read_only", "read_execute")) { $records += [pscustomobject]@{ identity = "BUILTIN\Users"; type = "Allow"; rights = [int64][Security.AccessControl.FileSystemRights]::FullControl; inherited = $true } } }
      "MutableWriteDenied" { if ($ResourceClass -like "mutable_*") { $records += [pscustomobject]@{ identity = "NT SERVICE\ALL SERVICES"; type = "Deny"; rights = [int64][Security.AccessControl.FileSystemRights]::WriteData; inherited = $true } } }
      "MutableModify" { if ($ResourceClass -like "mutable_*") { $records += [pscustomobject]@{ identity = $ServiceAccountIdentity; type = "Allow"; rights = [int64][Security.AccessControl.FileSystemRights]::Modify; inherited = $false } } }
      "MutableRootDelete" { if ($ResourceClass -like "mutable_*") { $records += [pscustomobject]@{ identity = $ServiceAccountIdentity; type = "Allow"; rights = [int64][Security.AccessControl.FileSystemRights]::Delete; inherited = $false } } }
      "MutableOwnership" { if ($ResourceClass -like "mutable_*") { $records += [pscustomobject]@{ identity = $ServiceAccountIdentity; type = "Allow"; rights = [int64][Security.AccessControl.FileSystemRights]::TakeOwnership; inherited = $false } } }
      "ChildDeny" { if ($mutableChild) { $records += [pscustomobject]@{ identity = $ServiceAccountIdentity; type = "Deny"; rights = [int64][Security.AccessControl.FileSystemRights]::WriteData; inherited = $true } } }
      "ChildExcessWrite" { if ($mutableChild) { $records += [pscustomobject]@{ identity = $ServiceAccountIdentity; type = "Allow"; rights = [int64][Security.AccessControl.FileSystemRights]::FullControl; inherited = $true } } }
      "ChildOwnership" { if ($mutableChild) { $records += [pscustomobject]@{ identity = $ServiceAccountIdentity; type = "Allow"; rights = [int64][Security.AccessControl.FileSystemRights]::TakeOwnership; inherited = $true } } }
      "AllServicesInheritedWrite" { if ($ResourceClass -in @("read_only", "ancestor")) { $records += [pscustomobject]@{ identity = "NT SERVICE\ALL SERVICES"; type = "Allow"; rights = $stateWrite; inherited = $true } } }
      "AncestorWrite" { if ($ResourceClass -eq "ancestor") { $records += [pscustomobject]@{ identity = $ServiceAccountIdentity; type = "Allow"; rights = [int64][Security.AccessControl.FileSystemRights]::WriteData; inherited = $true } } }
      "AncestorDelete" { if ($ResourceClass -eq "ancestor") { $records += [pscustomobject]@{ identity = $ServiceAccountIdentity; type = "Allow"; rights = [int64][Security.AccessControl.FileSystemRights]::Delete; inherited = $true } } }
      "SiblingWrite" { if ($ResourceClass -eq "protected_sibling") { $records += [pscustomobject]@{ identity = $ServiceAccountIdentity; type = "Allow"; rights = [int64][Security.AccessControl.FileSystemRights]::WriteData; inherited = $true } } }
      "NestedSiblingWrite" { if ($ResourceClass -eq "protected_sibling" -and $Path -match "nested-sibling-unsafe") { $records += [pscustomobject]@{ identity = $ServiceAccountIdentity; type = "Allow"; rights = [int64][Security.AccessControl.FileSystemRights]::WriteData; inherited = $true } } }
      "RuntimeOwnerWrite" { if ($ResourceClass -eq "runtime_management" -and (Split-Path -Leaf $Path) -ieq ".mg44-runtime-owner.json") { $records += [pscustomobject]@{ identity = $ServiceAccountIdentity; type = "Allow"; rights = [int64][Security.AccessControl.FileSystemRights]::WriteData; inherited = $true } } }
      "RuntimeTransactionWrite" { if ($ResourceClass -eq "runtime_management" -and $Path -match "(?i)[\\/]transactions[\\/]") { $records += [pscustomobject]@{ identity = $ServiceAccountIdentity; type = "Allow"; rights = [int64][Security.AccessControl.FileSystemRights]::WriteData; inherited = $true } } }
      "UnknownRuntimeSubtreeWrite" { if ($ResourceClass -eq "runtime_management" -and $Path -match "(?i)[\\/]unknown-runtime-subtree(?:[\\/]|$)") { $records += [pscustomobject]@{ identity = $ServiceAccountIdentity; type = "Allow"; rights = [int64][Security.AccessControl.FileSystemRights]::WriteData; inherited = $true } } }
      "TraversalDenied" { if ($ResourceClass -eq "ancestor") { $records += [pscustomobject]@{ identity = "NT SERVICE\ALL SERVICES"; type = "Deny"; rights = [int64][Security.AccessControl.FileSystemRights]::Traverse; inherited = $true } } }
    }
    return $records
  }
  return @(Get-Acl -LiteralPath $Path | ForEach-Object { $_.Access } | ForEach-Object {
    [pscustomobject]@{
      identity = [string]$_.IdentityReference.Value; type = [string]$_.AccessControlType; rights = [int64]$_.FileSystemRights; inherited = [bool]$_.IsInherited
      inherit_only = [bool]($_.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly)
      container_inherit = [bool]($_.InheritanceFlags -band [Security.AccessControl.InheritanceFlags]::ContainerInherit)
      object_inherit = [bool]($_.InheritanceFlags -band [Security.AccessControl.InheritanceFlags]::ObjectInherit)
    }
  })
}
function ConvertTo-StablePrincipal {
  param([string]$Identity)
  if ($Identity -ieq "NT SERVICE\$serviceName") {
    $sha1 = [Security.Cryptography.SHA1]::Create()
    try { $hash = $sha1.ComputeHash([Text.Encoding]::Unicode.GetBytes($serviceName.ToUpperInvariant())) }
    finally { $sha1.Dispose() }
    $parts = for ($offset = 0; $offset -lt 20; $offset += 4) { [BitConverter]::ToUInt32($hash, $offset) }
    return "S-1-5-80-" + ($parts -join "-")
  }
  try { return ([Security.Principal.NTAccount]$Identity).Translate([Security.Principal.SecurityIdentifier]).Value }
  catch { return $Identity.ToUpperInvariant() }
}
function Assert-EffectiveAccess {
  param([string]$Path, [ValidateSet("read_only", "read_execute", "mutable_state", "mutable_spool", "mutable_log", "mutable_state_child", "mutable_spool_child", "mutable_log_child", "ancestor", "protected_sibling", "runtime_management")][string]$ResourceClass)
  $serviceSid = ConvertTo-StablePrincipal $ServiceAccountIdentity
  $allServicesSid = "S-1-5-80-0"; $systemSid = "S-1-5-18"; $administratorsSid = "S-1-5-32-544"
  $readMask = [int64][Security.AccessControl.FileSystemRights]::ReadAndExecute
  $writeMask = [int64]([Security.AccessControl.FileSystemRights]::WriteData -bor [Security.AccessControl.FileSystemRights]::AppendData)
  $childDeleteMask = [int64][Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles
  $rootDestructiveMask = [int64]([Security.AccessControl.FileSystemRights]::Delete -bor [Security.AccessControl.FileSystemRights]::ChangePermissions -bor [Security.AccessControl.FileSystemRights]::TakeOwnership)
  $managedMask = [int64]([Security.AccessControl.FileSystemRights]::FullControl)
  $required = switch ($ResourceClass) {
    "read_execute" { $readMask }
    "mutable_state" { $readMask -bor $writeMask }
    "mutable_spool" { $readMask -bor $writeMask -bor $childDeleteMask }
    "mutable_log" { $readMask -bor $writeMask -bor $childDeleteMask }
    "mutable_state_child" { $readMask -bor $writeMask }
    "mutable_spool_child" { $readMask -bor $writeMask -bor $childDeleteMask }
    "mutable_log_child" { $readMask -bor $writeMask -bor $childDeleteMask }
    "ancestor" { [int64][Security.AccessControl.FileSystemRights]::Traverse }
    "protected_sibling" { [int64]0 }
    "runtime_management" { [int64]0 }
    default { [int64]([Security.AccessControl.FileSystemRights]::Read) }
  }
  $allowedMask = switch ($ResourceClass) {
    "mutable_state" { $required }
    "mutable_spool" { $required }
    "mutable_log" { $required }
    "mutable_state_child" { $required }
    "mutable_spool_child" { $required -bor [int64][Security.AccessControl.FileSystemRights]::Delete }
    "mutable_log_child" { $required -bor [int64][Security.AccessControl.FileSystemRights]::Delete }
    "ancestor" { $readMask }
    "protected_sibling" { $readMask }
    "runtime_management" { $readMask }
    default { $readMask }
  }
  $serviceAllow = [int64]0; $serviceInheritableAllow = [int64]0; $allServicesAllow = [int64]0; $nonapprovedAllow = [int64]0; $applicableDeny = [int64]0; $nonapprovedDeny = [int64]0
  foreach ($rule in @(Get-AccessRuleRecords $Path $ResourceClass)) {
    if ($rule.PSObject.Properties.Name -contains "inherit_only" -and $rule.inherit_only) { continue }
    $principal = ConvertTo-StablePrincipal ([string]$rule.identity); $rights = [int64]$rule.rights
    if ($rule.type -eq "Deny") {
      if ($principal -in @($serviceSid, $allServicesSid)) { $applicableDeny = $applicableDeny -bor $rights }
      elseif ($principal -notin @($systemSid, $administratorsSid)) { $nonapprovedDeny = $nonapprovedDeny -bor $rights }
      continue
    }
    if ($principal -eq $serviceSid) {
      $serviceAllow = $serviceAllow -bor $rights
      if (($rule.PSObject.Properties.Name -contains "container_inherit") -and $rule.container_inherit -and $rule.object_inherit) { $serviceInheritableAllow = $serviceInheritableAllow -bor $rights }
    }
    elseif ($principal -eq $allServicesSid) { $allServicesAllow = $allServicesAllow -bor $rights }
    elseif ($principal -notin @($systemSid, $administratorsSid)) { $nonapprovedAllow = $nonapprovedAllow -bor $rights }
  }
  Assert-True (($applicableDeny -band $required) -eq 0) "access_contract_required_right_denied"
  Assert-True (($nonapprovedDeny -band $required) -eq 0) "access_contract_unproven_principal_deny"
  if ($ResourceClass -eq "ancestor") {
    Assert-True (((($serviceAllow -bor $allServicesAllow) -band (-bnot $applicableDeny)) -band $required) -eq $required) "access_contract_traverse_missing"
    Assert-True ((($serviceAllow -bor $allServicesAllow -bor $nonapprovedAllow) -band ($writeMask -bor $childDeleteMask -bor $rootDestructiveMask)) -eq 0) "access_contract_ancestor_mutable"
    return
  }
  if ($ResourceClass -in @("protected_sibling", "runtime_management")) {
    Assert-True ((($serviceAllow -bor $allServicesAllow -bor $nonapprovedAllow) -band ($writeMask -bor $childDeleteMask -bor $rootDestructiveMask)) -eq 0) "access_contract_sibling_mutable"
    return
  }
  Assert-True ((($serviceAllow -band (-bnot $applicableDeny)) -band $required) -eq $required) "access_contract_required_right_missing"
  if ($ResourceClass -in @("mutable_state", "mutable_spool", "mutable_log")) {
    Assert-True (($serviceInheritableAllow -band $required) -eq $required) "access_contract_mutable_inheritance_missing"
  }
  Assert-True (($serviceAllow -band (-bnot $allowedMask) -band $managedMask) -eq 0) "access_contract_service_rights_excessive"
  Assert-True (($allServicesAllow -band $managedMask) -eq 0) "access_contract_all_services_grant_forbidden"
  Assert-True (($nonapprovedAllow -band $managedMask) -eq 0) "access_contract_nonapproved_principal_grant"
  Assert-True (($serviceAllow -band $rootDestructiveMask) -eq 0) "access_contract_root_destructive_right_forbidden"
}
function Assert-PathTraversalAccess {
  param([string]$Path)
  $full = [IO.Path]::GetFullPath($Path); $rootPath = [IO.Path]::GetPathRoot($full); $relative = $full.Substring($rootPath.Length); $cursor = $rootPath
  Assert-EffectiveAccess $rootPath "ancestor"
  $segments = @($relative -split "[\\/]" | Where-Object { $_ })
  for ($index = 0; $index -lt $segments.Count; $index++) {
    $segment = $segments[$index]
    $cursor = Join-Path $cursor $segment
    $isFinalContainer = $index -eq ($segments.Count - 1) -and (Test-Path -LiteralPath $cursor -PathType Container)
    if (-not $isFinalContainer -and (Test-Path -LiteralPath $cursor -PathType Container)) { Assert-EffectiveAccess $cursor "ancestor" }
  }
}
function Test-ServiceStartName {
  if ($FixtureMode) { return $FixtureScmStartName -ieq $ServiceAccountIdentity }
  $service = Get-CimInstance Win32_Service -Filter "Name='$serviceName'" -ErrorAction SilentlyContinue
  return $null -ne $service -and [string]$service.StartName -ieq $ServiceAccountIdentity
}
function Get-CombinedConfigIdentity {
  param([string]$EnvFile, [string]$NodeFile)
  Assert-True (Test-Path -LiteralPath $EnvFile -PathType Leaf) "agent_env_missing"
  Assert-True (Test-Path -LiteralPath $NodeFile -PathType Leaf) "agent_node_config_missing"
  return Get-TextSha256 ((Get-Sha256 $EnvFile) + (Get-Sha256 $NodeFile))
}
function Test-Administrator {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object Security.Principal.WindowsPrincipal($identity)
  return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Assert-FixtureRoot {
  param([string]$Path)
  $full = [IO.Path]::GetFullPath($Path); $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
  Assert-True ($full.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase)) "fixture_root_must_be_under_temp"
}
function Get-ActiveTarget {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return $null }
  $item = Get-Item -LiteralPath $Path -Force
  Assert-True ([bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) "active_path_not_junction"
  return [string]$item.Target
}
function Remove-Junction {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return }
  $item = Get-Item -LiteralPath $Path -Force
  Assert-True ([bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) "refusing_to_remove_non_junction"
  [IO.Directory]::Delete($item.FullName)
}
function Set-ActiveJunction {
  param([string]$ActivePath, [string]$TargetPath)
  Assert-True (Test-Path -LiteralPath $TargetPath -PathType Container) "junction_target_missing"
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $ActivePath) | Out-Null
  $next = "$ActivePath.next"; $old = "$ActivePath.old"
  foreach ($path in @($next, $old)) { if (Test-Path -LiteralPath $path) { Remove-Junction $path } }
  New-Item -ItemType Junction -Path $next -Target $TargetPath | Out-Null
  if (Test-Path -LiteralPath $ActivePath) { Move-Item -LiteralPath $ActivePath -Destination $old }
  Move-Item -LiteralPath $next -Destination $ActivePath
  if (Test-Path -LiteralPath $old) { Remove-Junction $old }
}
function Invoke-ServiceCommand {
  param([string]$Wrapper, [string]$Command)
  & $Wrapper $Command
  if ($LASTEXITCODE -ne 0) { throw "service_command_${Command}_failed" }
}
function Write-JsonAtomic {
  param([string]$Path, [hashtable]$Data)
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
  $temporary = "$Path.tmp"
  $Data | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $temporary -Encoding UTF8
  Move-Item -LiteralPath $temporary -Destination $Path -Force
}
function Get-OwnerPath { return Join-Path $root ".mg44-runtime-owner.json" }
function Assert-OwnedRuntime {
  $path = Get-OwnerPath
  Assert-True (Test-Path -LiteralPath $path -PathType Leaf) "runtime_owner_marker_missing"
  $owner = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
  Assert-True ($owner.schema_version -eq $ownerSchema) "runtime_owner_schema_invalid"
  Assert-True ($owner.component -eq $component -and $owner.service_name -eq $serviceName) "runtime_owner_component_mismatch"
  Assert-True ($owner.root_fingerprint -eq (Get-TextSha256 $root.ToLowerInvariant())) "runtime_owner_root_mismatch"
  Assert-True ([string]$owner.installation_id -match "^[0-9a-f]{32}$") "runtime_owner_installation_id_invalid"
  Assert-True ([string]$owner.service_account_model -eq "VirtualServiceAccount") "runtime_owner_account_model_mismatch"
  Assert-True ([string]$owner.service_account_binding_sha256 -eq (Get-ServiceAccountBindingSha256)) "runtime_owner_account_binding_mismatch"
  foreach ($name in @("approved_agent_identity_binding_sha256", "approved_config_binding_sha256", "approved_secret_reference_binding_sha256")) {
    if ($owner.PSObject.Properties.Name -contains $name) { Assert-True ([string]$owner.$name -match "^[0-9a-f]{64}$") "runtime_owner_binding_invalid" }
  }
}
function Initialize-OwnedRuntime {
  $path = Get-OwnerPath
  if (Test-Path -LiteralPath $path) { Assert-OwnedRuntime; return }
  $unexpected = @(Get-ChildItem -LiteralPath $root -Force | Where-Object { $_.Name -ne ".agent-runtime.lock" })
  Assert-True ($unexpected.Count -eq 0) "runtime_root_not_empty_or_owned"
  Write-JsonAtomic $path @{
    schema_version = $ownerSchema; component = $component; service_name = $serviceName
    root_fingerprint = Get-TextSha256 $root.ToLowerInvariant(); installation_id = [guid]::NewGuid().ToString("N")
    service_account_model = "VirtualServiceAccount"; service_account_binding_sha256 = Get-ServiceAccountBindingSha256
    lifecycle_state = "owned"; created_at = [DateTime]::UtcNow.ToString("o")
  }
}
function Invoke-ArtifactVerifier {
  param([string]$Artifact, [string]$Manifest, [string]$SourceCommit, [string]$ArtifactSha, [string]$ExtractedRoot)
  $arguments = @{
    ArtifactPath = $Artifact; ManifestPath = $Manifest; ExpectedSourceCommit = $SourceCommit; ExpectedArtifactSha256 = $ArtifactSha
    ExpectedRuntimeVersion = [string]$trust.node_runtime.version; ExpectedNodeArchiveSha256 = [string]$trust.node_runtime.sha256
    ExpectedServiceWrapperVersion = [string]$trust.service_wrapper.version; ExpectedServiceWrapperSha256 = [string]$trust.service_wrapper.sha256
    ExpectedServiceTemplateSha256 = if ($ExpectedServiceTemplateSha256) { $ExpectedServiceTemplateSha256 } else { [string]$trust.service_template.sha256 }
    ExpectedServiceAccountBindingSha256 = if ($ExpectedServiceAccountBindingSha256) { $ExpectedServiceAccountBindingSha256 } else { [string]$trust.service_account.binding_sha256 }
    ExpectedSecretReferenceSchema = if ($ExpectedSecretReferenceSchema) { $ExpectedSecretReferenceSchema } else { [string]$trust.secret_reference.schema_version }
    AllowFixtureRuntime = [bool]$FixtureMode
  }
  if ($ExtractedRoot) { $arguments["ExtractedRoot"] = $ExtractedRoot }
  & $verifier @arguments | Out-Null
}
function Assert-ArtifactAuthorization {
  Assert-ServiceAccountContract
  Assert-CanonicalServiceTemplate
  Assert-True ($ArtifactPath -and $ManifestPath -and $EnvPath -and $NodeConfigPath) "artifact_manifest_configs_required"
  Assert-True ($ExpectedSourceCommit -match "^[0-9a-fA-F]{40}$") "expected_source_commit_required"
  Assert-True ($ExpectedArtifactSha256 -match "^[0-9a-fA-F]{64}$") "expected_artifact_sha256_required"
  if (-not $FixtureMode) {
    Assert-True ($ExpectedServiceTemplateSha256 -match "^[0-9a-fA-F]{64}$") "expected_service_template_sha256_required"
    Assert-True ($ExpectedServiceTemplateSha256.ToLowerInvariant() -eq [string]$trust.service_template.sha256) "expected_service_template_sha256_mismatch"
    Assert-True ($ExpectedServiceAccountBindingSha256 -match "^[0-9a-fA-F]{64}$") "expected_service_account_binding_sha256_required"
    Assert-True ($ExpectedServiceAccountBindingSha256.ToLowerInvariant() -eq [string]$trust.service_account.binding_sha256) "expected_service_account_binding_sha256_mismatch"
    Assert-True ($ExpectedSecretReferenceSchema -eq [string]$trust.secret_reference.schema_version) "expected_secret_reference_schema_mismatch"
  }
  Invoke-ArtifactVerifier $ArtifactPath $ManifestPath $ExpectedSourceCommit.ToLowerInvariant() $ExpectedArtifactSha256.ToLowerInvariant() $null
}
function Invoke-LauncherValidation {
  param([string]$ReleaseDir, [string]$EnvFile, [string]$NodeFile)
  $launcher = Join-Path $ReleaseDir "bin\Start-AgentRelease.ps1"
  Assert-True (Test-Path -LiteralPath $launcher -PathType Leaf) "release_launcher_missing"
  & $launcher -ReleaseRoot $ReleaseDir -EnvPath $EnvFile -NodeConfigPath $NodeFile `
    -ExpectedServiceAccountBindingSha256 ([string]$trust.service_account.binding_sha256) `
    -ExpectedSecretReferenceSchema ([string]$trust.secret_reference.schema_version) `
    -ValidateOnly -AllowFixtureRuntime:$FixtureMode -RequireSafeDefaults | Out-Null
  Get-SecretReferenceEvidence $EnvFile $ReleaseDir | Out-Null
}
function Test-CandidateArchive {
  Assert-ArtifactAuthorization
  $temporary = Join-Path ([IO.Path]::GetTempPath()) ("jta-candidate-" + [guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Path $temporary | Out-Null
  try {
    Expand-Archive -LiteralPath $ArtifactPath -DestinationPath $temporary
    Invoke-ArtifactVerifier $ArtifactPath $ManifestPath $ExpectedSourceCommit.ToLowerInvariant() $ExpectedArtifactSha256.ToLowerInvariant() $temporary
    Copy-Item -LiteralPath $ManifestPath -Destination (Join-Path $temporary "release-manifest.json")
    Invoke-LauncherValidation $temporary $EnvPath $NodeConfigPath
    $secretReference = Get-SecretReferenceEvidence $EnvPath $temporary
    $agentIdentity = Get-AgentIdentityEvidence $EnvPath $NodeConfigPath $temporary
    Assert-CallerBindingAnchors ([string]$agentIdentity.binding_sha256) (Get-CombinedConfigIdentity $EnvPath $NodeConfigPath) ([string]$secretReference.binding_sha256)
    if ($FixtureMode) { Assert-AgentRuntimeAccessContract $temporary (Split-Path -Parent $EnvPath) $EnvPath $NodeConfigPath }
  } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force } }
}
function Get-ReleaseMetadata {
  param([string]$ReleaseDir, [string]$ExpectedSource, [string]$ExpectedArtifact)
  Assert-True (Test-Path -LiteralPath $ReleaseDir -PathType Container) "release_slot_missing"
  $manifestFile = Join-Path $ReleaseDir "release-manifest.json"
  Assert-True (Test-Path -LiteralPath $manifestFile -PathType Leaf) "release_slot_manifest_missing"
  $manifest = Get-Content -Raw -LiteralPath $manifestFile | ConvertFrom-Json
  Assert-True ([string]$manifest.source_commit -eq $ExpectedSource) "release_slot_source_mismatch"
  Assert-True ([string]$manifest.artifact_sha256 -eq $ExpectedArtifact) "release_slot_artifact_mismatch"
  Assert-True ((Split-Path -Leaf $ReleaseDir) -eq "$ExpectedSource-$($ExpectedArtifact.Substring(0, 16))") "release_slot_identity_mismatch"
  return $manifest
}
function Test-InstalledSlot {
  param([string]$ReleaseDir, [string]$ConfigDir, [string]$ExpectedSource, [string]$ExpectedArtifact, [string]$ExpectedConfig)
  Get-ReleaseMetadata $ReleaseDir $ExpectedSource $ExpectedArtifact | Out-Null
  Assert-True (Test-Path -LiteralPath $ConfigDir -PathType Container) "config_revision_missing"
  Assert-True ((Split-Path -Leaf $ConfigDir) -eq $ExpectedConfig) "config_revision_identity_mismatch"
  $envFile = Join-Path $ConfigDir "agent.env"; $nodeFile = Join-Path $ConfigDir "node.json"
  Assert-True ((Get-CombinedConfigIdentity $envFile $nodeFile) -eq $ExpectedConfig) "config_revision_sha256_mismatch"
  Invoke-LauncherValidation $ReleaseDir $envFile $nodeFile
}
function Stage-Candidate {
  Assert-ArtifactAuthorization
  $source = $ExpectedSourceCommit.ToLowerInvariant(); $artifactSha = $ExpectedArtifactSha256.ToLowerInvariant()
  $configId = Get-CombinedConfigIdentity $EnvPath $NodeConfigPath
  $releaseId = "$source-$($artifactSha.Substring(0, 16))"
  $releaseDir = Join-Path $root "releases\agent\$releaseId"; $configDir = Join-Path $root "config\agent\revisions\$configId"
  $createdRelease = -not (Test-Path -LiteralPath $releaseDir); $createdConfig = -not (Test-Path -LiteralPath $configDir)
  if ($createdRelease) {
    $stage = "$releaseDir.staging"
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $stage | Out-Null
    try {
      Expand-Archive -LiteralPath $ArtifactPath -DestinationPath $stage
      Invoke-ArtifactVerifier $ArtifactPath $ManifestPath $source $artifactSha $stage
      Copy-Item -LiteralPath $ManifestPath -Destination (Join-Path $stage "release-manifest.json")
      Invoke-LauncherValidation $stage $EnvPath $NodeConfigPath
      New-Item -ItemType Directory -Force -Path (Split-Path -Parent $releaseDir) | Out-Null
      Move-Item -LiteralPath $stage -Destination $releaseDir
    } finally { if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force } }
  }
  if ($createdConfig) {
    New-Item -ItemType Directory -Force -Path $configDir | Out-Null
    Copy-Item -LiteralPath $EnvPath -Destination (Join-Path $configDir "agent.env")
    Copy-Item -LiteralPath $NodeConfigPath -Destination (Join-Path $configDir "node.json")
  }
  try {
    Test-InstalledSlot $releaseDir $configDir $source $artifactSha $configId
    $secretReference = Get-SecretReferenceEvidence (Join-Path $configDir "agent.env") $releaseDir
    $agentIdentity = Get-AgentIdentityEvidence (Join-Path $configDir "agent.env") (Join-Path $configDir "node.json") $releaseDir
    Assert-CallerBindingAnchors ([string]$agentIdentity.binding_sha256) $configId ([string]$secretReference.binding_sha256)
    Assert-AgentRuntimeAccessContract $releaseDir $configDir (Join-Path $configDir "agent.env") (Join-Path $configDir "node.json")
  } catch {
    if ($createdConfig -and (Test-Path -LiteralPath $configDir)) { Remove-Item -LiteralPath $configDir -Recurse -Force }
    if ($createdRelease -and (Test-Path -LiteralPath $releaseDir)) { Remove-Item -LiteralPath $releaseDir -Recurse -Force }
    throw
  }
  return [ordered]@{
    release_id = $releaseId; release_dir = $releaseDir; config_id = $configId; config_dir = $configDir
    source_commit = $source; artifact_sha256 = $artifactSha; created_release = $createdRelease; created_config = $createdConfig
    secret_reference_binding_sha256 = [string]$secretReference.binding_sha256
    agent_identity_binding_sha256 = [string]$agentIdentity.binding_sha256
  }
}
function Get-EnvValue {
  param([string]$Path, [string]$Name)
  $line = Get-Content -LiteralPath $Path | Where-Object { $_ -match ("^\s*" + [regex]::Escape($Name) + "\s*=") } | Select-Object -First 1
  if (-not $line) { return $null }
  return ($line -split "=", 2)[1].Trim()
}
function Get-SecretReferenceEvidence {
  param([string]$EnvFile, [string]$ReleaseRoot)
  $direct = Get-Content -LiteralPath $EnvFile | Where-Object { $_ -match "^\s*TELEMETRY_NODE_SECRET\s*=" } | Select-Object -First 1
  Assert-True (-not $direct) "direct_signing_secret_forbidden_in_workstation_mode"
  $reference = Get-EnvValue $EnvFile "TELEMETRY_NODE_SECRET_FILE"
  Assert-True (-not [string]::IsNullOrWhiteSpace([string]$reference)) "secret_file_reference_required"
  Assert-True ([IO.Path]::IsPathRooted($reference) -and -not $reference.StartsWith("\\")) "secret_file_reference_must_be_local_absolute"
  $full = Assert-SafeLocalPathObject $reference "Leaf"
  $releasePrefix = [IO.Path]::GetFullPath($ReleaseRoot).TrimEnd("\") + "\"
  Assert-True (-not $full.StartsWith($releasePrefix, [StringComparison]::OrdinalIgnoreCase)) "secret_file_reference_must_be_external"
  $forbiddenRoots = @(
    (Join-Path $root "releases"), (Join-Path $root "config"), (Join-Path $root "state"), (Join-Path $root "spool"), (Join-Path $root "logs"),
    (Split-Path -Parent ([IO.Path]::GetFullPath((Get-EnvValue $EnvFile "STATE_PATH")))),
    ([IO.Path]::GetFullPath((Get-EnvValue $EnvFile "SPOOL_DIR"))),
    (Split-Path -Parent ([IO.Path]::GetFullPath((Get-EnvValue $EnvFile "TELEMETRY_SERVER_BATCH_LATEST_FILE")))),
    (Split-Path -Parent ([IO.Path]::GetFullPath((Get-EnvValue $EnvFile "TELEMETRY_BATCH_OUTPUT_FILE"))))
  )
  foreach ($forbiddenRoot in $forbiddenRoots) {
    $prefix = [IO.Path]::GetFullPath($forbiddenRoot).TrimEnd("\") + "\"
    Assert-True (-not ($full -eq $prefix.TrimEnd("\") -or $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase))) "secret_file_reference_in_runtime_data_boundary"
  }
  return [ordered]@{
    schema_version = $secretReferenceSchema
    binding_sha256 = Get-TextSha256 ("$secretReferenceSchema|" + $full.ToLowerInvariant() + "|" + (Get-ServiceAccountBindingSha256))
    file_present = $true
    value_accessed = $false
    service_access = "read_only"
  }
}
function Get-AgentIdentityEvidence {
  param([string]$EnvFile, [string]$NodeFile, [string]$ReleaseRoot)
  $node = Get-Content -Raw -LiteralPath $NodeFile | ConvertFrom-Json
  $nodeId = [string]$node.node_id
  $keyId = [string](Get-EnvValue $EnvFile "TELEMETRY_NODE_KEY_ID")
  Assert-True ($nodeId -match "^[A-Za-z0-9][A-Za-z0-9._-]{2,127}$") "workstation_node_identity_invalid"
  Assert-True ($keyId -match "^[A-Za-z0-9][A-Za-z0-9._-]{2,127}$") "workstation_signing_key_identity_invalid"
  Assert-True (-not ($nodeId -match "(?i)lax") -and -not ($keyId -match "(?i)lax")) "workstation_identity_lax_marker_forbidden"
  if (-not $FixtureMode) {
    Assert-True (-not ($nodeId -match "(?i)fixture|placeholder|example|replace") -and -not ($keyId -match "(?i)fixture|placeholder|example|replace")) "workstation_identity_placeholder_forbidden"
  }
  $reference = Get-SecretReferenceEvidence $EnvFile $ReleaseRoot
  return [ordered]@{
    schema_version = "jerry.workstation.agent-identity.v1"
    binding_sha256 = Get-TextSha256 ("jerry.workstation.agent-identity.v1|$nodeId|$keyId|$($reference.binding_sha256)")
    secret_value_accessed = $false
    lax_identity = $false
  }
}
function Assert-AgentRuntimeAccessContract {
  param([string]$ReleaseDir, [string]$ConfigDir, [string]$EnvFile, [string]$NodeFile)
  $release = Assert-SafeLocalPathObject $ReleaseDir "Container"
  $config = Assert-SafeLocalPathObject $ConfigDir "Container"
  $envConfig = Assert-SafeLocalPathObject $EnvFile "Leaf"
  $nodeConfig = Assert-SafeLocalPathObject $NodeFile "Leaf"
  $wrapper = Assert-SafeLocalPathObject $(if ($FixtureMode) { $defaultTemplate } else { $ServiceWrapperPath }) "Leaf"
  $secretEvidence = Get-SecretReferenceEvidence $EnvFile $ReleaseDir
  $secret = [string]$secretEvidence.binding_sha256
  Assert-True ($secret -match "^[0-9a-f]{64}$") "secret_reference_evidence_invalid"
  $secretPath = Assert-SafeLocalPathObject (Get-EnvValue $EnvFile "TELEMETRY_NODE_SECRET_FILE") "Leaf"
  $stateDir = Assert-SafeLocalPathObject (Split-Path -Parent ([IO.Path]::GetFullPath((Get-EnvValue $EnvFile "STATE_PATH")))) "Container"
  $spoolDir = Assert-SafeLocalPathObject (Get-EnvValue $EnvFile "SPOOL_DIR") "Container"
  $latestDir = Assert-SafeLocalPathObject (Split-Path -Parent ([IO.Path]::GetFullPath((Get-EnvValue $EnvFile "TELEMETRY_SERVER_BATCH_LATEST_FILE")))) "Container"
  $outputDir = Assert-SafeLocalPathObject (Split-Path -Parent ([IO.Path]::GetFullPath((Get-EnvValue $EnvFile "TELEMETRY_BATCH_OUTPUT_FILE")))) "Container"
  $logDir = if ($FixtureMode) { Assert-SafeLocalPathObject (Join-Path (Split-Path -Parent $stateDir) "fixture-modeled-logs") "Container" } else { Assert-SafeLocalPathObject (Join-Path $root "logs\agent") "Container" }
  foreach ($readOnly in @($release, $config, $envConfig, $nodeConfig, $secretPath)) {
    Assert-PathTraversalAccess $readOnly
    Assert-EffectiveAccess $readOnly "read_only"
  }
  Assert-PathTraversalAccess $wrapper; Assert-EffectiveAccess $wrapper "read_execute"
  foreach ($releaseDirectory in @(Get-ChildItem -LiteralPath $release -Recurse -Directory -Force)) {
    $releaseContainer = Assert-SafeLocalPathObject $releaseDirectory.FullName "Container"
    Assert-PathTraversalAccess $releaseContainer; Assert-EffectiveAccess $releaseContainer "read_only"
  }
  foreach ($releaseFile in @(Get-ChildItem -LiteralPath $release -Recurse -File -Force)) {
    $releaseLeaf = Assert-SafeLocalPathObject $releaseFile.FullName "Leaf"
    Assert-PathTraversalAccess $releaseLeaf
    Assert-EffectiveAccess $releaseLeaf $(if ($releaseFile.Name -ieq "node.exe") { "read_execute" } else { "read_only" })
  }
  $rootPolicy = @{}
  foreach ($stateWrite in @($stateDir, $latestDir, $outputDir) | Select-Object -Unique) { $rootPolicy[$stateWrite.ToLowerInvariant()] = [pscustomobject]@{ path = $stateWrite; root_class = "mutable_state"; child_class = "mutable_state_child" } }
  $rootPolicy[$spoolDir.ToLowerInvariant()] = [pscustomobject]@{ path = $spoolDir; root_class = "mutable_spool"; child_class = "mutable_spool_child" }
  $rootPolicy[$logDir.ToLowerInvariant()] = [pscustomobject]@{ path = $logDir; root_class = "mutable_log"; child_class = "mutable_log_child" }
  $runtimeLogDir = Join-Path $root "logs\agent"
  if ((Test-Path -LiteralPath $runtimeLogDir -PathType Container) -and -not $rootPolicy.ContainsKey(([IO.Path]::GetFullPath($runtimeLogDir)).ToLowerInvariant())) {
    $runtimeLogDir = Assert-SafeLocalPathObject $runtimeLogDir "Container"
    $rootPolicy[$runtimeLogDir.ToLowerInvariant()] = [pscustomobject]@{ path = $runtimeLogDir; root_class = "mutable_log"; child_class = "mutable_log_child" }
  }
  $policies = @($rootPolicy.Values | Sort-Object { $_.path.Length } -Descending)
  foreach ($policy in $policies) { Assert-PathTraversalAccess $policy.path; Assert-EffectiveAccess $policy.path $policy.root_class }

  $seenMutableDescendants = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  foreach ($policy in $policies) {
    foreach ($descendant in @(Get-ChildItem -LiteralPath $policy.path -Recurse -Force -ErrorAction SilentlyContinue)) {
      $full = [IO.Path]::GetFullPath($descendant.FullName)
      if (@($policies | Where-Object { $_.path -ieq $full }).Count -gt 0) { continue }
      if (-not $seenMutableDescendants.Add($full)) { continue }
      $ownerPolicy = @($policies | Where-Object { $full.StartsWith($_.path.TrimEnd("\") + "\", [StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1)[0]
      Assert-True ($null -ne $ownerPolicy) "access_contract_mutable_descendant_unclassified"
      Assert-SafeLocalPathObject $full $(if ($descendant.PSIsContainer) { "Container" } else { "Leaf" }) | Out-Null
      Assert-EffectiveAccess $full $ownerPolicy.child_class
    }
  }

  if (Test-Path -LiteralPath $root -PathType Container) {
    $runtimeRoot = Assert-SafeLocalPathObject $root "Container"
    Assert-EffectiveAccess $runtimeRoot "runtime_management"
    $runtimePrefix = $runtimeRoot.TrimEnd("\") + "\"
    $releaseBoundary = (Join-Path $runtimeRoot "releases\agent").TrimEnd("\") + "\"
    $configBoundary = (Join-Path $runtimeRoot "config\agent\revisions").TrimEnd("\") + "\"
    $activeReleaseAlias = Join-Path $runtimeRoot "active\agent"
    $activeConfigAlias = Join-Path $runtimeRoot "config\agent\active"
    $pendingRuntimeItems = [Collections.Generic.Queue[object]]::new()
    foreach ($runtimeItem in @(Get-ChildItem -LiteralPath $runtimeRoot -Force -ErrorAction SilentlyContinue)) { $pendingRuntimeItems.Enqueue($runtimeItem) }

    while ($pendingRuntimeItems.Count -gt 0) {
      $runtimeItem = $pendingRuntimeItems.Dequeue()
      $runtimeFull = [IO.Path]::GetFullPath($runtimeItem.FullName)
      Assert-True ($runtimeFull.StartsWith($runtimePrefix, [StringComparison]::OrdinalIgnoreCase)) "access_contract_runtime_descendant_escape"
      if (@($policies | Where-Object { $runtimeFull -ieq $_.path -or $runtimeFull.StartsWith($_.path.TrimEnd("\") + "\", [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) { continue }

      $relative = $runtimeFull.Substring($runtimePrefix.Length)
      if ($runtimeFull -ieq $activeReleaseAlias -or $runtimeFull -ieq $activeConfigAlias) {
        $aliasItem = Get-Item -LiteralPath $runtimeFull -Force
        Assert-True ([bool]($aliasItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) "access_contract_active_boundary_not_alias"
        $aliasTarget = Get-ActiveTarget $runtimeFull
        $expectedBoundary = if ($runtimeFull -ieq $activeReleaseAlias) { $releaseBoundary } else { $configBoundary }
        Assert-True ($aliasTarget -and ([IO.Path]::GetFullPath($aliasTarget)).StartsWith($expectedBoundary, [StringComparison]::OrdinalIgnoreCase)) "access_contract_active_boundary_target_invalid"
        Assert-EffectiveAccess $runtimeFull "runtime_management"
        continue
      }

      $itemType = if ($runtimeItem.PSIsContainer) { "Container" } else { "Leaf" }
      Assert-SafeLocalPathObject $runtimeFull $itemType | Out-Null
      $resourceClass = $null
      if ($relative -in @(".agent-runtime.lock", ".mg44-runtime-owner.json", "active", "releases", "releases\agent", "config", "config\agent", "config\agent\revisions", "transactions", "services", "services\agent", "logs", "state", "spool")) {
        $resourceClass = "runtime_management"
      }
      elseif ($relative -in @("transactions\agent-current.json", "transactions\agent-pending.json")) {
        $resourceClass = "runtime_management"
      }
      elseif ($relative.StartsWith("services\agent\", [StringComparison]::OrdinalIgnoreCase)) {
        $resourceClass = if (-not $runtimeItem.PSIsContainer -and $runtimeItem.Name -ieq "agent-service.exe") { "read_execute" } elseif (-not $runtimeItem.PSIsContainer -and $runtimeItem.Name -ieq "agent-service.xml") { "read_only" } else { "runtime_management" }
      }
      elseif ($runtimeFull.StartsWith($releaseBoundary, [StringComparison]::OrdinalIgnoreCase)) {
        $resourceClass = if (-not $runtimeItem.PSIsContainer -and $runtimeItem.Name -ieq "node.exe") { "read_execute" } else { "read_only" }
      }
      elseif ($runtimeFull.StartsWith($configBoundary, [StringComparison]::OrdinalIgnoreCase)) {
        $resourceClass = "read_only"
      }

      if (-not $resourceClass) {
        Assert-EffectiveAccess $runtimeFull "runtime_management"
        throw "access_contract_unknown_runtime_descendant"
      }
      Assert-EffectiveAccess $runtimeFull $resourceClass
      if ($runtimeItem.PSIsContainer) {
        foreach ($child in @(Get-ChildItem -LiteralPath $runtimeFull -Force -ErrorAction SilentlyContinue)) { $pendingRuntimeItems.Enqueue($child) }
      }
    }
  }

  $mutableRoots = @($policies.path)
  $seenProtected = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  foreach ($mutableParent in @($mutableRoots | ForEach-Object { Split-Path -Parent $_ } | Select-Object -Unique)) {
    foreach ($sibling in @(Get-ChildItem -LiteralPath $mutableParent -Force -ErrorAction SilentlyContinue)) {
      $siblingFull = [IO.Path]::GetFullPath($sibling.FullName)
      if (@($policies | Where-Object { $siblingFull -ieq $_.path -or $siblingFull.StartsWith($_.path.TrimEnd("\") + "\", [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) { continue }
      if ($siblingFull -ieq [IO.Path]::GetFullPath($root)) { continue }
      foreach ($protected in @($sibling) + @(if ($sibling.PSIsContainer) { Get-ChildItem -LiteralPath $siblingFull -Recurse -Force -ErrorAction SilentlyContinue })) {
        $protectedFull = [IO.Path]::GetFullPath($protected.FullName)
        if (-not $seenProtected.Add($protectedFull)) { continue }
        Assert-SafeLocalPathObject $protectedFull $(if ($protected.PSIsContainer) { "Container" } else { "Leaf" }) | Out-Null
        Assert-EffectiveAccess $protectedFull "protected_sibling"
      }
    }
  }
}
function Assert-CallerBindingAnchors {
  param([string]$AgentIdentityBinding, [string]$ConfigBinding, [string]$SecretReferenceBinding)
  if (-not $FixtureMode) {
    Assert-True ($ExpectedAgentIdentityBindingSha256 -match "^[0-9a-fA-F]{64}$") "expected_agent_identity_binding_required"
    Assert-True ($ExpectedConfigBindingSha256 -match "^[0-9a-fA-F]{64}$") "expected_config_binding_required"
    Assert-True ($ExpectedSecretReferenceBindingSha256 -match "^[0-9a-fA-F]{64}$") "expected_secret_reference_binding_required"
  }
  if ($ExpectedAgentIdentityBindingSha256) { Assert-True ($AgentIdentityBinding -eq $ExpectedAgentIdentityBindingSha256.ToLowerInvariant()) "agent_identity_binding_authorization_mismatch" }
  if ($ExpectedConfigBindingSha256) { Assert-True ($ConfigBinding -eq $ExpectedConfigBindingSha256.ToLowerInvariant()) "config_binding_authorization_mismatch" }
  if ($ExpectedSecretReferenceBindingSha256) { Assert-True ($SecretReferenceBinding -eq $ExpectedSecretReferenceBindingSha256.ToLowerInvariant()) "secret_reference_binding_authorization_mismatch" }
}
function Get-SpoolCount {
  param([string]$ConfigDir)
  $spoolPath = Get-EnvValue (Join-Path $ConfigDir "agent.env") "SPOOL_DIR"
  if (-not $spoolPath -or -not (Test-Path -LiteralPath $spoolPath -PathType Container)) { return 0 }
  return @(Get-ChildItem -LiteralPath $spoolPath -File -ErrorAction SilentlyContinue).Count
}
function Test-AgentHealth {
  param([string]$ActiveRelease, [string]$ActiveConfig, [int]$MaximumSpoolCount, [switch]$Recovery)
  if ($SimulateHealthFailure -and -not $Recovery) { return $false }
  if ($FixtureMode) {
    return (Test-Path -LiteralPath (Join-Path $ActiveRelease "release-manifest.json")) -and
      (Test-Path -LiteralPath (Join-Path $ActiveConfig "agent.env")) -and
      (Get-SpoolCount $ActiveConfig) -le $MaximumSpoolCount
  }
  $port = Get-EnvValue (Join-Path $ActiveConfig "agent.env") "HEALTH_PORT"
  if (-not $port) { return $false }
  for ($attempt = 0; $attempt -lt 40; $attempt++) {
    try {
      $health = Invoke-RestMethod -Uri "http://127.0.0.1:$port/healthz" -TimeoutSec 1
      if ($health.ok -eq $true -and (Get-SpoolCount $ActiveConfig) -le $MaximumSpoolCount) { return $true }
    } catch { Start-Sleep -Milliseconds 250 }
  }
  return $false
}
function Get-CurrentTransactionPath { return Join-Path $root "transactions\agent-current.json" }
function Get-PendingTransactionPath { return Join-Path $root "transactions\agent-pending.json" }
function Read-Transaction {
  param([string]$Path)
  Assert-True (Test-Path -LiteralPath $Path -PathType Leaf) "transaction_missing"
  $value = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
  Assert-True ($value.schema_version -eq $transactionSchema -and $value.component -eq $component) "transaction_invalid"
  return $value
}
function Write-PendingTransaction {
  param([hashtable]$Data)
  $Data["schema_version"] = $transactionSchema; $Data["component"] = $component; $Data["recorded_at"] = [DateTime]::UtcNow.ToString("o")
  $Data["service_account_model"] = "VirtualServiceAccount"; $Data["service_account_binding_sha256"] = Get-ServiceAccountBindingSha256
  Write-JsonAtomic (Get-PendingTransactionPath) $Data
}
function Write-CurrentTransaction {
  param([hashtable]$Data)
  $Data["schema_version"] = $transactionSchema; $Data["component"] = $component; $Data["recorded_at"] = [DateTime]::UtcNow.ToString("o")
  $Data["service_account_model"] = "VirtualServiceAccount"; $Data["service_account_binding_sha256"] = Get-ServiceAccountBindingSha256
  Write-JsonAtomic (Get-CurrentTransactionPath) $Data
}
function Remove-PendingTransaction { $path = Get-PendingTransactionPath; if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force } }
function Get-ActiveEvidence {
  $transaction = Read-Transaction (Get-CurrentTransactionPath)
  Assert-True ([string]$transaction.service_account_model -eq "VirtualServiceAccount") "transaction_account_model_mismatch"
  Assert-True ([string]$transaction.service_account_binding_sha256 -eq (Get-ServiceAccountBindingSha256)) "transaction_account_binding_mismatch"
  Assert-True ([string]$transaction.approved_agent_identity_binding_sha256 -eq [string]$transaction.agent_identity_binding_sha256) "transaction_agent_identity_authorization_mismatch"
  Assert-True ([string]$transaction.approved_config_binding_sha256 -eq [string]$transaction.active_config) "transaction_config_authorization_mismatch"
  Assert-True ([string]$transaction.approved_secret_reference_binding_sha256 -eq [string]$transaction.secret_reference_binding_sha256) "transaction_secret_reference_authorization_mismatch"
  return [ordered]@{
    release_id = [string]$transaction.active_release; config_id = [string]$transaction.active_config
    source_commit = [string]$transaction.active_source_commit; artifact_sha256 = [string]$transaction.active_artifact_sha256
    secret_reference_binding_sha256 = [string]$transaction.secret_reference_binding_sha256
    agent_identity_binding_sha256 = [string]$transaction.agent_identity_binding_sha256
  }
}
function Assert-ActiveEvidence {
  param($Evidence)
  $releaseDir = Join-Path $root "releases\agent\$($Evidence.release_id)"; $configDir = Join-Path $root "config\agent\revisions\$($Evidence.config_id)"
  Test-InstalledSlot $releaseDir $configDir $Evidence.source_commit $Evidence.artifact_sha256 $Evidence.config_id
  $reference = Get-SecretReferenceEvidence (Join-Path $configDir "agent.env") $releaseDir
  Assert-True ([string]$Evidence.secret_reference_binding_sha256 -eq [string]$reference.binding_sha256) "transaction_secret_reference_binding_mismatch"
  $agentIdentity = Get-AgentIdentityEvidence (Join-Path $configDir "agent.env") (Join-Path $configDir "node.json") $releaseDir
  Assert-True ([string]$Evidence.agent_identity_binding_sha256 -eq [string]$agentIdentity.binding_sha256) "transaction_agent_identity_binding_mismatch"
  Assert-True ((Get-ActiveTarget (Join-Path $root "active\agent")) -eq $releaseDir) "active_release_transaction_mismatch"
  Assert-True ((Get-ActiveTarget (Join-Path $root "config\agent\active")) -eq $configDir) "active_config_transaction_mismatch"
}
function Write-OwnerBindings {
  param([string]$AgentIdentityBinding, [string]$ConfigBinding, [string]$SecretReferenceBinding)
  $ownerPath = Get-OwnerPath; $owner = Get-Content -Raw -LiteralPath $ownerPath | ConvertFrom-Json
  Write-JsonAtomic $ownerPath @{
    schema_version = $ownerSchema; component = $component; service_name = $serviceName
    root_fingerprint = Get-TextSha256 $root.ToLowerInvariant(); installation_id = [string]$owner.installation_id
    service_account_model = "VirtualServiceAccount"; service_account_binding_sha256 = Get-ServiceAccountBindingSha256
    approved_agent_identity_binding_sha256 = $AgentIdentityBinding; approved_config_binding_sha256 = $ConfigBinding
    approved_secret_reference_binding_sha256 = $SecretReferenceBinding
    lifecycle_state = "owned"; updated_at = [DateTime]::UtcNow.ToString("o")
  }
}
function Assert-NoPendingRecovery { Assert-True (-not (Test-Path -LiteralPath (Get-PendingTransactionPath))) "pending_activation_recovery_required" }

function Test-PendingFirstInstallRecovery {
  param($Record)
  return ([string]$Record.operation -eq "Install") -and
    (-not $Record.previous_release) -and (-not $Record.previous_config) -and
    (-not $Record.previous_source_commit) -and (-not $Record.previous_artifact_sha256)
}
function Assert-PendingFirstInstallRecovery {
  param($Record)
  Assert-True (Test-PendingFirstInstallRecovery $Record) "first_install_recovery_record_invalid"
  $source = [string]$Record.target_source_commit; $artifact = [string]$Record.target_artifact_sha256
  $release = [string]$Record.target_release; $config = [string]$Record.target_config
  Assert-True ($source -match "^[0-9a-f]{40}$" -and $artifact -match "^[0-9a-f]{64}$") "first_install_recovery_target_invalid"
  Assert-True ($release -eq "$source-$($artifact.Substring(0, 16))") "first_install_recovery_release_invalid"
  Assert-True ($config -match "^[0-9a-f]{64}$") "first_install_recovery_config_invalid"
  Assert-True (($Record.PSObject.Properties.Name -contains "target_release_created") -and ($Record.target_release_created -is [bool])) "first_install_recovery_release_ownership_missing"
  Assert-True (($Record.PSObject.Properties.Name -contains "target_config_created") -and ($Record.target_config_created -is [bool])) "first_install_recovery_config_ownership_missing"
  Assert-True (-not (Test-Path -LiteralPath (Get-CurrentTransactionPath))) "first_install_recovery_current_transaction_unexpected"
}
function Remove-OwnedFirstInstallJunctions {
  param([string]$BasePath, [string]$ExpectedTarget)
  foreach ($path in @($BasePath, "$BasePath.next", "$BasePath.old")) {
    $item = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) { continue }
    Assert-True ([bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) "first_install_recovery_path_not_junction"
    Assert-True ([string]$item.Target -eq $ExpectedTarget) "first_install_recovery_junction_target_mismatch"
    [IO.Directory]::Delete($item.FullName)
  }
}
function Write-RetryableOwnerState {
  $ownerPath = Get-OwnerPath; $owner = Get-Content -Raw -LiteralPath $ownerPath | ConvertFrom-Json
  $data = @{
    schema_version = $ownerSchema; component = $component; service_name = $serviceName
    root_fingerprint = Get-TextSha256 $root.ToLowerInvariant(); installation_id = [string]$owner.installation_id
    service_account_model = "VirtualServiceAccount"; service_account_binding_sha256 = Get-ServiceAccountBindingSha256
    lifecycle_state = "uninstalled_retryable"; updated_at = [DateTime]::UtcNow.ToString("o")
  }
  foreach ($name in @("approved_agent_identity_binding_sha256", "approved_config_binding_sha256", "approved_secret_reference_binding_sha256")) {
    if ($owner.PSObject.Properties.Name -contains $name) { $data[$name] = [string]$owner.$name }
  }
  Write-JsonAtomic $ownerPath $data
}
function Recover-PendingFirstInstall {
  param($Record)
  Assert-PendingFirstInstallRecovery $Record
  $targetReleaseDir = Join-Path $root "releases\agent\$($Record.target_release)"
  $targetConfigDir = Join-Path $root "config\agent\revisions\$($Record.target_config)"
  $activeReleasePath = Join-Path $root "active\agent"; $activeConfigPath = Join-Path $root "config\agent\active"
  $serviceExe = Join-Path $root "services\agent\agent-service.exe"
  if (-not $FixtureMode) {
    if (Test-Path -LiteralPath $serviceExe -PathType Leaf) {
      try { Invoke-ServiceCommand $serviceExe "stop" } catch { }
      try { Invoke-ServiceCommand $serviceExe "uninstall" } catch { }
    }
    Assert-True (@(Get-Service -Name $serviceName -ErrorAction SilentlyContinue).Count -eq 0) "first_install_service_recovery_failed"
  }
  Remove-OwnedFirstInstallJunctions $activeReleasePath $targetReleaseDir
  Remove-OwnedFirstInstallJunctions $activeConfigPath $targetConfigDir
  $serviceDir = Join-Path $root "services\agent"; if (Test-Path -LiteralPath $serviceDir) { Remove-Item -LiteralPath $serviceDir -Recurse -Force }
  if ($Record.target_release_created -and (Test-Path -LiteralPath $targetReleaseDir)) { Remove-Item -LiteralPath $targetReleaseDir -Recurse -Force }
  if ($Record.target_config_created -and (Test-Path -LiteralPath $targetConfigDir)) { Remove-Item -LiteralPath $targetConfigDir -Recurse -Force }
  Remove-PendingTransaction
  Write-RetryableOwnerState
  Assert-True (-not (Test-Path -LiteralPath $activeReleasePath)) "first_install_release_boundary_not_removed"
  Assert-True (-not (Test-Path -LiteralPath $activeConfigPath)) "first_install_config_boundary_not_removed"
  Assert-True (-not (Test-Path -LiteralPath (Get-PendingTransactionPath))) "first_install_pending_journal_not_removed"
}

$root = [IO.Path]::GetFullPath($RuntimeRoot)
Assert-True ([IO.Path]::IsPathRooted($root)) "runtime_root_must_be_absolute"
Assert-True ($root -ne [IO.Path]::GetPathRoot($root)) "runtime_root_cannot_be_volume_root"
Assert-ServiceAccountContract
Assert-CanonicalServiceTemplate
if ($FixtureMode) { Assert-FixtureRoot $root }
$confirm = switch ($Operation) {
  "Install" { [bool]$ConfirmInstall }; "Upgrade" { [bool]$ConfirmUpgrade }; "Rollback" { [bool]$ConfirmRollback }; "Uninstall" { [bool]$ConfirmUninstall }; default { $false }
}
if ($Operation -ne "Status") { Assert-True ($DryRun -xor $confirm) "exactly_one_dry_run_or_matching_confirmation_required" }

if ($Operation -eq "Status") {
  $owned = Test-Path -LiteralPath (Get-OwnerPath) -PathType Leaf
  if ($owned) { Assert-OwnedRuntime }
  $releaseTarget = Get-ActiveTarget (Join-Path $root "active\agent"); $configTarget = Get-ActiveTarget (Join-Path $root "config\agent\active")
  $manifest = if ($releaseTarget -and (Test-Path -LiteralPath (Join-Path $releaseTarget "release-manifest.json"))) { Get-Content -Raw -LiteralPath (Join-Path $releaseTarget "release-manifest.json") | ConvertFrom-Json } else { $null }
  $currentTransaction = if (Test-Path -LiteralPath (Get-CurrentTransactionPath) -PathType Leaf) { Read-Transaction (Get-CurrentTransactionPath) } else { $null }
  $serviceStartNameVerified = if ($releaseTarget -and $configTarget) { Test-ServiceStartName } else { $null }
  $bindingAnchorsVerified = if ($currentTransaction) {
    [string]$currentTransaction.approved_agent_identity_binding_sha256 -eq [string]$currentTransaction.agent_identity_binding_sha256 -and
    [string]$currentTransaction.approved_config_binding_sha256 -eq [string]$currentTransaction.active_config -and
    [string]$currentTransaction.approved_secret_reference_binding_sha256 -eq [string]$currentTransaction.secret_reference_binding_sha256
  } else { $null }
  [ordered]@{
    ok = $true; owned = $owned; installed = [bool]($releaseTarget -and $configTarget)
    active_release_id = if ($releaseTarget) { Split-Path -Leaf $releaseTarget } else { $null }
    active_config_id = if ($configTarget) { Split-Path -Leaf $configTarget } else { $null }
    source_commit = if ($manifest) { [string]$manifest.source_commit } else { $null }
    artifact_sha256 = if ($manifest) { [string]$manifest.artifact_sha256 } else { $null }
    runtime_version = if ($manifest) { [string]$manifest.runtime_version } else { $null }
    pending_spool_count = if ($configTarget) { Get-SpoolCount $configTarget } else { 0 }
    pending_recovery = Test-Path -LiteralPath (Get-PendingTransactionPath)
    service_account_model = "VirtualServiceAccount"; service_account_binding_sha256 = Get-ServiceAccountBindingSha256
    agent_identity_binding_sha256 = if ($currentTransaction) { [string]$currentTransaction.agent_identity_binding_sha256 } else { $null }
    output_allowlist_version = "jerry.workstation.status.v1"; secret_values_printed = $false; private_connection_metadata_printed = $false; lax_runtime_touched = $false
    service_start_name_verified = $serviceStartNameVerified
    caller_binding_anchors_verified = $bindingAnchorsVerified
  } | ConvertTo-Json -Compress
  return
}

if ($DryRun) {
  if ($Operation -in @("Install", "Upgrade")) {
    Test-CandidateArchive
    if ($Operation -eq "Upgrade") { Assert-OwnedRuntime; Assert-NoPendingRecovery; Assert-ActiveEvidence (Get-ActiveEvidence) }
  } elseif ($Operation -eq "Rollback") {
    Assert-OwnedRuntime
    $pendingPath = Get-PendingTransactionPath; $recoveringPending = Test-Path -LiteralPath $pendingPath
    $record = if ($recoveringPending) { Read-Transaction $pendingPath } else { Read-Transaction (Get-CurrentTransactionPath) }
    if ($recoveringPending -and (Test-PendingFirstInstallRecovery $record)) {
      Assert-PendingFirstInstallRecovery $record
      [ordered]@{ ok = $true; operation = $Operation; dry_run = $true; recovery_mode = "interrupted_first_install"; mutation_performed = $false; service_registered = $false; production_contact = $false; lax_runtime_touched = $false } | ConvertTo-Json -Compress
      return
    }
    Assert-True ($record.previous_release -and $record.previous_config -and $record.previous_source_commit -and $record.previous_artifact_sha256) "rollback_previous_slot_missing"
    Test-InstalledSlot (Join-Path $root "releases\agent\$($record.previous_release)") (Join-Path $root "config\agent\revisions\$($record.previous_config)") ([string]$record.previous_source_commit) ([string]$record.previous_artifact_sha256) ([string]$record.previous_config)
  } else { Assert-OwnedRuntime; Assert-NoPendingRecovery }
  [ordered]@{ ok = $true; operation = $Operation; dry_run = $true; fixture_mode = [bool]$FixtureMode; mutation_performed = $false; service_registered = $false; production_contact = $false; lax_runtime_touched = $false } | ConvertTo-Json -Compress
  return
}

if (-not $FixtureMode) {
  Assert-True ($AuthorizationId -match "^[A-Za-z0-9._-]{8,128}$") "production_authorization_id_required"
  Assert-True (Test-Administrator) "administrator_required_for_service_mutation"
  Assert-True ($ServiceWrapperPath -and (Test-Path -LiteralPath $ServiceWrapperPath -PathType Leaf)) "service_wrapper_required"
  Assert-True ((Split-Path -Leaf $ServiceWrapperPath) -ceq [string]$trust.service_wrapper.name) "service_wrapper_filename_mismatch"
  $wrapperSource = [Uri][string]$trust.service_wrapper.url
  Assert-True ($wrapperSource.Scheme -eq "https" -and $wrapperSource.Host -eq "github.com" -and $wrapperSource.AbsolutePath -eq "/winsw/winsw/releases/download/v2.12.0/WinSW-x64.exe") "service_wrapper_source_trust_invalid"
  Assert-True ((Get-Sha256 $ServiceWrapperPath) -eq [string]$trust.service_wrapper.sha256) "service_wrapper_sha256_mismatch"
  Assert-True (-not $ServiceTemplatePath) "custom_service_template_forbidden"
  Assert-True ((Get-Sha256 $defaultTemplate) -eq [string]$trust.service_template.sha256) "service_template_sha256_mismatch"
}
if ($Operation -eq "Install") { if (-not (Test-Path -LiteralPath $root)) { New-Item -ItemType Directory -Path $root | Out-Null } }
else { Assert-True (Test-Path -LiteralPath $root -PathType Container) "runtime_root_missing" }

$lock = [IO.File]::Open((Join-Path $root ".agent-runtime.lock"), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
try {
  if ($Operation -eq "Install") { Initialize-OwnedRuntime } else { Assert-OwnedRuntime }
  if ($Operation -in @("Install", "Upgrade")) {
    Assert-NoPendingRecovery
    $candidate = Stage-Candidate
    $activeReleasePath = Join-Path $root "active\agent"; $activeConfigPath = Join-Path $root "config\agent\active"
    $previousReleaseDir = Get-ActiveTarget $activeReleasePath; $previousConfigDir = Get-ActiveTarget $activeConfigPath
    $previous = $null
    if ($Operation -eq "Install") { Assert-True (-not $previousReleaseDir -and -not $previousConfigDir) "agent_already_installed" }
    else { Assert-True ($previousReleaseDir -and $previousConfigDir) "agent_upgrade_requires_existing_release"; Assert-True (Test-ServiceStartName) "service_start_name_mismatch"; $previous = Get-ActiveEvidence; Assert-ActiveEvidence $previous }
    $spoolBefore = Get-SpoolCount $candidate.config_dir
    $pending = @{
      operation = $Operation; phase = "prepared"
      previous_release = if ($previous) { $previous.release_id } else { $null }; previous_config = if ($previous) { $previous.config_id } else { $null }
      previous_source_commit = if ($previous) { $previous.source_commit } else { $null }; previous_artifact_sha256 = if ($previous) { $previous.artifact_sha256 } else { $null }
      target_release = $candidate.release_id; target_config = $candidate.config_id; target_source_commit = $candidate.source_commit; target_artifact_sha256 = $candidate.artifact_sha256
      target_release_created = [bool]$candidate.created_release; target_config_created = [bool]$candidate.created_config
      secret_reference_binding_sha256 = $candidate.secret_reference_binding_sha256
      agent_identity_binding_sha256 = $candidate.agent_identity_binding_sha256
      approved_agent_identity_binding_sha256 = $candidate.agent_identity_binding_sha256
      approved_config_binding_sha256 = $candidate.config_id
      approved_secret_reference_binding_sha256 = $candidate.secret_reference_binding_sha256
      maximum_spool_count = $spoolBefore
    }
    Write-PendingTransaction $pending
    $serviceExe = Join-Path $root "services\agent\agent-service.exe"; $installedThisAttempt = $false
    try {
      if (-not $FixtureMode) {
        $serviceDir = Split-Path -Parent $serviceExe; $logDir = Join-Path $root "logs\agent"
        New-Item -ItemType Directory -Force -Path $serviceDir, $logDir | Out-Null
        Copy-Item -LiteralPath $ServiceWrapperPath -Destination $serviceExe -Force
        $installedWrapper = Assert-SafeLocalPathObject $serviceExe "Leaf"
        Assert-PathTraversalAccess $installedWrapper; Assert-EffectiveAccess $installedWrapper "read_execute"
        $xml = [IO.File]::ReadAllText($defaultTemplate)
        $xml = $xml.Replace("__ACTIVE_ROOT__", (ConvertTo-XmlText $activeReleasePath)).Replace("__ENV_PATH__", (ConvertTo-XmlText (Join-Path $activeConfigPath "agent.env"))).Replace("__NODE_CONFIG_PATH__", (ConvertTo-XmlText (Join-Path $activeConfigPath "node.json"))).Replace("__LOG_PATH__", (ConvertTo-XmlText $logDir)).Replace("__SERVICE_ACCOUNT_BINDING_SHA256__", (ConvertTo-XmlText ([string]$trust.service_account.binding_sha256))).Replace("__SECRET_REFERENCE_SCHEMA__", (ConvertTo-XmlText ([string]$trust.secret_reference.schema_version)))
        Assert-True (-not ($xml -match "__[A-Z_]+__")) "service_template_placeholder_unresolved"
        [xml]$rendered = $xml
        Assert-True ($rendered.service.serviceaccount.domain -ceq "NT SERVICE" -and $rendered.service.serviceaccount.user -ceq $serviceName) "rendered_service_account_identity_invalid"
        Assert-True ($null -eq $rendered.SelectSingleNode("/service/serviceaccount/password") -and $rendered.service.serviceaccount.allowservicelogon -ceq "false") "rendered_service_account_privilege_invalid"
        [IO.File]::WriteAllText((Join-Path $serviceDir "agent-service.xml"), $xml, (New-Object Text.UTF8Encoding($false)))
        $installedServiceConfig = Assert-SafeLocalPathObject (Join-Path $serviceDir "agent-service.xml") "Leaf"
        Assert-EffectiveAccess $installedServiceConfig "read_only"
        if ($Operation -eq "Upgrade") { Invoke-ServiceCommand $serviceExe "stop" }
      }
      $pending["phase"] = "service_stopped"; Write-PendingTransaction $pending
      Set-ActiveJunction $activeReleasePath $candidate.release_dir; $pending["phase"] = "release_switched"; Write-PendingTransaction $pending
      Set-ActiveJunction $activeConfigPath $candidate.config_dir; $pending["phase"] = "config_switched"; Write-PendingTransaction $pending
      if (-not $FixtureMode) { if ($Operation -eq "Install") { Invoke-ServiceCommand $serviceExe "install"; $installedThisAttempt = $true }; Invoke-ServiceCommand $serviceExe "start" }
      Assert-True (Test-ServiceStartName) "service_start_name_mismatch"
      $pending["phase"] = "service_started"; Write-PendingTransaction $pending
      Assert-True (Test-AgentHealth $activeReleasePath $activeConfigPath $spoolBefore) "agent_activation_health_or_spool_failed"
      Test-InstalledSlot $candidate.release_dir $candidate.config_dir $candidate.source_commit $candidate.artifact_sha256 $candidate.config_id
      Write-CurrentTransaction @{
        operation = $Operation
        previous_release = if ($previous) { $previous.release_id } else { $null }; previous_config = if ($previous) { $previous.config_id } else { $null }
        previous_source_commit = if ($previous) { $previous.source_commit } else { $null }; previous_artifact_sha256 = if ($previous) { $previous.artifact_sha256 } else { $null }
        active_release = $candidate.release_id; active_config = $candidate.config_id; active_source_commit = $candidate.source_commit; active_artifact_sha256 = $candidate.artifact_sha256
        secret_reference_binding_sha256 = $candidate.secret_reference_binding_sha256
        agent_identity_binding_sha256 = $candidate.agent_identity_binding_sha256
        approved_agent_identity_binding_sha256 = $candidate.agent_identity_binding_sha256
        approved_config_binding_sha256 = $candidate.config_id
        approved_secret_reference_binding_sha256 = $candidate.secret_reference_binding_sha256
        state_preserved = $true; spool_preserved = $true; secret_file_preserved = $true; spool_count_after = Get-SpoolCount $candidate.config_dir
      }
      Write-OwnerBindings $candidate.agent_identity_binding_sha256 $candidate.config_id $candidate.secret_reference_binding_sha256
      Remove-PendingTransaction
    } catch {
      if (-not $FixtureMode -and (Test-Path -LiteralPath $serviceExe)) { try { Invoke-ServiceCommand $serviceExe "stop" } catch { } }
      $recovered = $false
      if ($previous) {
        try {
          Set-ActiveJunction $activeReleasePath $previousReleaseDir; Set-ActiveJunction $activeConfigPath $previousConfigDir
          $previousSpool = Get-SpoolCount $previousConfigDir
          if (-not $FixtureMode) { Invoke-ServiceCommand $serviceExe "start" }
          $recovered = Test-AgentHealth $activeReleasePath $activeConfigPath $previousSpool -Recovery
          if ($recovered) { Assert-ActiveEvidence $previous }
        } catch { $recovered = $false }
      } else {
        try {
          if (-not $FixtureMode -and (Test-Path -LiteralPath $serviceExe)) { try { Invoke-ServiceCommand $serviceExe "uninstall" } catch { } }
          foreach ($junction in @($activeReleasePath, $activeConfigPath)) { if (Test-Path -LiteralPath $junction) { Remove-Junction $junction } }
          $serviceDir = Join-Path $root "services\agent"; if (Test-Path -LiteralPath $serviceDir) { Remove-Item -LiteralPath $serviceDir -Recurse -Force }
          if ($candidate.created_release -and (Test-Path -LiteralPath $candidate.release_dir)) { Remove-Item -LiteralPath $candidate.release_dir -Recurse -Force }
          if ($candidate.created_config -and (Test-Path -LiteralPath $candidate.config_dir)) { Remove-Item -LiteralPath $candidate.config_dir -Recurse -Force }
          $recovered = (-not (Test-Path -LiteralPath $activeReleasePath)) -and (-not (Test-Path -LiteralPath $activeConfigPath))
        } catch { $recovered = $false }
      }
      if ($recovered) { Remove-PendingTransaction; throw "agent_activation_failed_rolled_back" }
      throw "agent_activation_failed_recovery_required"
    }
    [ordered]@{ ok = $true; operation = $Operation; active_release = $candidate.release_id; active_config = $candidate.config_id; health = "pass"; spool_growth = 0; service_start_name_verified = $true; fixture_mode = [bool]$FixtureMode; lax_runtime_touched = $false } | ConvertTo-Json -Compress
    return
  }
  if ($Operation -eq "Rollback") {
    if (Test-Path -LiteralPath (Get-CurrentTransactionPath) -PathType Leaf) { Assert-True (Test-ServiceStartName) "service_start_name_mismatch" }
    $pendingPath = Get-PendingTransactionPath; $recoveringPending = Test-Path -LiteralPath $pendingPath
    $record = if ($recoveringPending) { Read-Transaction $pendingPath } else { Read-Transaction (Get-CurrentTransactionPath) }
    if ($recoveringPending -and (Test-PendingFirstInstallRecovery $record)) {
      Recover-PendingFirstInstall $record
      [ordered]@{ ok = $true; operation = "Rollback"; recovery = "interrupted_first_install_removed"; installed = $false; retryable = $true; state_preserved = $true; spool_preserved = $true; secret_file_preserved = $true; fixture_mode = [bool]$FixtureMode; lax_runtime_touched = $false } | ConvertTo-Json -Compress
      return
    }
    Assert-True ($record.previous_release -and $record.previous_config -and $record.previous_source_commit -and $record.previous_artifact_sha256) "rollback_previous_slot_missing"
    $target = [ordered]@{ release_id = [string]$record.previous_release; config_id = [string]$record.previous_config; source_commit = [string]$record.previous_source_commit; artifact_sha256 = [string]$record.previous_artifact_sha256 }
    $targetReleaseDir = Join-Path $root "releases\agent\$($target.release_id)"; $targetConfigDir = Join-Path $root "config\agent\revisions\$($target.config_id)"
    Test-InstalledSlot $targetReleaseDir $targetConfigDir $target.source_commit $target.artifact_sha256 $target.config_id
    $current = if ($recoveringPending) { $null } else { Get-ActiveEvidence }; if ($current) { Assert-ActiveEvidence $current }
    $activeReleasePath = Join-Path $root "active\agent"; $activeConfigPath = Join-Path $root "config\agent\active"
    if (-not $recoveringPending) {
      Write-PendingTransaction @{
        operation = "Rollback"; phase = "prepared"
        previous_release = $current.release_id; previous_config = $current.config_id; previous_source_commit = $current.source_commit; previous_artifact_sha256 = $current.artifact_sha256
        target_release = $target.release_id; target_config = $target.config_id; target_source_commit = $target.source_commit; target_artifact_sha256 = $target.artifact_sha256
      }
    }
    $serviceExe = Join-Path $root "services\agent\agent-service.exe"; $targetSpool = Get-SpoolCount $targetConfigDir
    try {
      if (-not $FixtureMode) { Invoke-ServiceCommand $serviceExe "stop" }
      Set-ActiveJunction $activeReleasePath $targetReleaseDir; Set-ActiveJunction $activeConfigPath $targetConfigDir
      if (-not $FixtureMode) { Invoke-ServiceCommand $serviceExe "start" }
      Assert-True (Test-AgentHealth $activeReleasePath $activeConfigPath $targetSpool) "rollback_health_or_spool_failed"
      Test-InstalledSlot $targetReleaseDir $targetConfigDir $target.source_commit $target.artifact_sha256 $target.config_id
      $targetReference = Get-SecretReferenceEvidence (Join-Path $targetConfigDir "agent.env") $targetReleaseDir
      $targetIdentity = Get-AgentIdentityEvidence (Join-Path $targetConfigDir "agent.env") (Join-Path $targetConfigDir "node.json") $targetReleaseDir
      Write-CurrentTransaction @{
        operation = "Rollback"
        previous_release = if ($current) { $current.release_id } else { [string]$record.target_release }; previous_config = if ($current) { $current.config_id } else { [string]$record.target_config }
        previous_source_commit = if ($current) { $current.source_commit } else { [string]$record.target_source_commit }; previous_artifact_sha256 = if ($current) { $current.artifact_sha256 } else { [string]$record.target_artifact_sha256 }
        active_release = $target.release_id; active_config = $target.config_id; active_source_commit = $target.source_commit; active_artifact_sha256 = $target.artifact_sha256
        secret_reference_binding_sha256 = [string]$targetReference.binding_sha256
        agent_identity_binding_sha256 = [string]$targetIdentity.binding_sha256
        approved_agent_identity_binding_sha256 = [string]$targetIdentity.binding_sha256
        approved_config_binding_sha256 = $target.config_id
        approved_secret_reference_binding_sha256 = [string]$targetReference.binding_sha256
        state_preserved = $true; spool_preserved = $true; secret_file_preserved = $true; spool_count_after = Get-SpoolCount $targetConfigDir
      }
      Write-OwnerBindings ([string]$targetIdentity.binding_sha256) $target.config_id ([string]$targetReference.binding_sha256)
      Remove-PendingTransaction
    } catch {
      if ($current) {
        $restored = $false
        try {
          if (-not $FixtureMode) { try { Invoke-ServiceCommand $serviceExe "stop" } catch { } }
          $currentReleaseDir = Join-Path $root "releases\agent\$($current.release_id)"; $currentConfigDir = Join-Path $root "config\agent\revisions\$($current.config_id)"
          Set-ActiveJunction $activeReleasePath $currentReleaseDir; Set-ActiveJunction $activeConfigPath $currentConfigDir
          $currentSpool = Get-SpoolCount $currentConfigDir
          if (-not $FixtureMode) { Invoke-ServiceCommand $serviceExe "start" }
          Assert-True (Test-AgentHealth $activeReleasePath $activeConfigPath $currentSpool -Recovery) "rollback_restore_health_failed"
          Remove-PendingTransaction; $restored = $true
        } catch { $restored = $false }
        if ($restored) { throw "rollback_failed_original_restored" }
      }
      throw "rollback_failed_recovery_required"
    }
    [ordered]@{ ok = $true; operation = "Rollback"; active_release = $target.release_id; no_rebuild = $true; state_preserved = $true; spool_preserved = $true; secret_file_preserved = $true; service_start_name_verified = $true; fixture_mode = [bool]$FixtureMode; lax_runtime_touched = $false } | ConvertTo-Json -Compress
    return
  }
  if ($Operation -eq "Uninstall") {
    Assert-NoPendingRecovery
    Assert-True (Test-ServiceStartName) "service_start_name_mismatch"
    $serviceExe = Join-Path $root "services\agent\agent-service.exe"
    if (-not $FixtureMode -and (Test-Path -LiteralPath $serviceExe)) { try { Invoke-ServiceCommand $serviceExe "stop" } catch { }; Invoke-ServiceCommand $serviceExe "uninstall" }
    foreach ($junction in @((Join-Path $root "active\agent"), (Join-Path $root "config\agent\active"))) { if (Test-Path -LiteralPath $junction) { Remove-Junction $junction } }
    $serviceDir = Join-Path $root "services\agent"; if (Test-Path -LiteralPath $serviceDir) { Remove-Item -LiteralPath $serviceDir -Recurse -Force }
    if ($FixtureMode) { $lock.Dispose(); $lock = $null; Remove-Item -LiteralPath $root -Recurse -Force }
    else {
      $ownerPath = Get-OwnerPath; $owner = Get-Content -Raw -LiteralPath $ownerPath | ConvertFrom-Json
      $ownerData = @{
        schema_version = $ownerSchema; component = $component; service_name = $serviceName
        root_fingerprint = Get-TextSha256 $root.ToLowerInvariant(); installation_id = [string]$owner.installation_id
        service_account_model = "VirtualServiceAccount"; service_account_binding_sha256 = Get-ServiceAccountBindingSha256
        lifecycle_state = "uninstalled_data_preserved"; updated_at = [DateTime]::UtcNow.ToString("o")
      }
      foreach ($name in @("approved_agent_identity_binding_sha256", "approved_config_binding_sha256", "approved_secret_reference_binding_sha256")) {
        if ($owner.PSObject.Properties.Name -contains $name) { $ownerData[$name] = [string]$owner.$name }
      }
      Write-JsonAtomic $ownerPath $ownerData
    }
    [ordered]@{ ok = $true; operation = "Uninstall"; service_removed = $true; service_start_name_verified_before_removal = $true; active_boundaries_removed = $true; persistent_data_preserved = (-not $FixtureMode); fixture_mode = [bool]$FixtureMode; lax_runtime_touched = $false } | ConvertTo-Json -Compress
    return
  }
} finally { if ($null -ne $lock) { $lock.Dispose() } }
