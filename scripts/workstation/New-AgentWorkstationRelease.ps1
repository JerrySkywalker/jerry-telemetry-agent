param(
  [string]$OutputDir = ".smoke\workstation-release\artifacts",
  [Parameter(Mandatory = $true)][string]$NodeArchivePath,
  [string]$ExpectedSourceCommit,
  [switch]$AllowDirtyFixture
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Assert-True { param([bool]$Condition, [string]$Code); if (-not $Condition) { throw $Code } }
function Get-Sha256 {
  param([string]$Path)
  $stream = [IO.File]::OpenRead($Path)
  $sha = [Security.Cryptography.SHA256]::Create()
  try { return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace("-", "").ToLowerInvariant() }
  finally { $sha.Dispose(); $stream.Dispose() }
}
function Get-SafeRelativePath {
  param([string]$Root, [string]$Path)
  $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd("\") + "\"
  $pathFull = [IO.Path]::GetFullPath($Path)
  Assert-True ($pathFull.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) "path_outside_root"
  return $pathFull.Substring($rootFull.Length)
}
function Copy-DirectoryContents {
  param([string]$Source, [string]$Destination)
  New-Item -ItemType Directory -Force -Path $Destination | Out-Null
  Get-ChildItem -LiteralPath $Source -Force | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $Destination -Recurse -Force }
}
function Remove-TemporaryRoot {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return }
  $resolved = (Resolve-Path -LiteralPath $Path).Path
  $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
  Assert-True ($resolved.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase)) "unsafe_temporary_cleanup_path"
  Remove-Item -LiteralPath $resolved -Recurse -Force
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$trust = Get-Content -Raw -LiteralPath (Join-Path $repoRoot "deploy\workstation\trusted-runtime.json") | ConvertFrom-Json
$nodeArchive = (Resolve-Path -LiteralPath $NodeArchivePath).Path
$nodeArchiveSha = Get-Sha256 $nodeArchive
Assert-True ($nodeArchiveSha -eq [string]$trust.node_runtime.sha256) "node_archive_sha256_mismatch"

Push-Location $repoRoot
try {
  $sourceCommit = (git rev-parse HEAD).Trim().ToLowerInvariant()
  Assert-True ($sourceCommit -match "^[0-9a-f]{40}$") "source_commit_invalid"
  if ($ExpectedSourceCommit) { Assert-True ($sourceCommit -eq $ExpectedSourceCommit.ToLowerInvariant()) "source_commit_mismatch" }
  $trackedChanges = @(git status --porcelain=v1 --untracked-files=no)
  if (-not $AllowDirtyFixture) { Assert-True ($trackedChanges.Count -eq 0) "source_tree_must_be_clean" }

  $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("jta-release-" + [guid]::NewGuid().ToString("N"))
  $sourceZip = Join-Path $tempRoot "source.zip"
  $sourceRoot = Join-Path $tempRoot "source"
  $nodeExtractRoot = Join-Path $tempRoot "node"
  $releaseRoot = Join-Path $tempRoot "release"
  New-Item -ItemType Directory -Force -Path $tempRoot, $sourceRoot, $nodeExtractRoot, $releaseRoot | Out-Null
  try {
    git archive --format=zip --output=$sourceZip $sourceCommit
    if ($LASTEXITCODE -ne 0) { throw "source_archive_failed" }
    Expand-Archive -LiteralPath $sourceZip -DestinationPath $sourceRoot
    Expand-Archive -LiteralPath $nodeArchive -DestinationPath $nodeExtractRoot
    $nodeExe = Get-ChildItem -LiteralPath $nodeExtractRoot -Filter node.exe -Recurse -File | Select-Object -First 1
    Assert-True ($null -ne $nodeExe) "node_executable_missing"
    $nodeHome = $nodeExe.Directory.FullName
    $npmCmd = Join-Path $nodeHome "npm.cmd"
    Assert-True (Test-Path -LiteralPath $npmCmd) "node_npm_missing"
    $nodeVersion = (& $nodeExe.FullName --version).Trim()
    Assert-True ($nodeVersion -eq ("v" + [string]$trust.node_runtime.version)) "node_runtime_version_mismatch"

    $oldPath = $env:PATH
    $env:PATH = "$nodeHome;$oldPath"
    try {
      Push-Location $sourceRoot
      try {
        & $npmCmd ci
        if ($LASTEXITCODE -ne 0) { throw "builder_npm_ci_failed" }
        & $npmCmd run build
        if ($LASTEXITCODE -ne 0) { throw "builder_build_failed" }
      } finally { Pop-Location }
    } finally { $env:PATH = $oldPath }

    $runtimeDir = Join-Path $releaseRoot "runtime"
    $appDir = Join-Path $releaseRoot "app"
    $binDir = Join-Path $releaseRoot "bin"
    New-Item -ItemType Directory -Force -Path $runtimeDir, $appDir, $binDir | Out-Null
    Copy-Item -LiteralPath $nodeExe.FullName -Destination (Join-Path $runtimeDir "node.exe") -Force
    $nodeLicense = Join-Path $nodeHome "LICENSE"
    if (Test-Path -LiteralPath $nodeLicense) { Copy-Item -LiteralPath $nodeLicense -Destination (Join-Path $runtimeDir "NODE-LICENSE") -Force }
    Copy-DirectoryContents (Join-Path $sourceRoot "dist") (Join-Path $appDir "dist")
    Copy-Item -LiteralPath (Join-Path $sourceRoot "package.json") -Destination (Join-Path $appDir "package.json")
    Copy-Item -LiteralPath (Join-Path $sourceRoot "scripts\workstation\Start-AgentRelease.ps1") -Destination $binDir
    Copy-Item -LiteralPath (Join-Path $sourceRoot "scripts\workstation\Test-AgentReleaseManifest.ps1") -Destination $binDir

    $forbidden = @(Get-ChildItem -LiteralPath $releaseRoot -Recurse -File -Force | Where-Object {
      $relative = (Get-SafeRelativePath $releaseRoot $_.FullName).Replace("\", "/")
      $relative -match "(^|/)(\.git|\.env|state|spool|logs|backups?|coverage|tests?|node_modules)(/|$)" -or $relative -match "\.ts$|\.map$|\.d\.ts$|\.raw\."
    })
    Assert-True ($forbidden.Count -eq 0) "release_contains_forbidden_files"
    $files = @(Get-ChildItem -LiteralPath $releaseRoot -Recurse -File -Force | Sort-Object FullName | ForEach-Object {
      [ordered]@{
        path = (Get-SafeRelativePath $releaseRoot $_.FullName).Replace("\", "/")
        sha256 = Get-Sha256 $_.FullName
        size_bytes = [int64]$_.Length
      }
    })
    $package = Get-Content -Raw -LiteralPath (Join-Path $sourceRoot "package.json") | ConvertFrom-Json
    $outputRoot = if ([IO.Path]::IsPathRooted($OutputDir)) { $OutputDir } else { Join-Path $repoRoot $OutputDir }
    New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null
    $artifactName = "jerry-telemetry-agent-$($package.version)-$sourceCommit-win-x64-node22.zip"
    $artifactPath = Join-Path $outputRoot $artifactName
    if (Test-Path -LiteralPath $artifactPath) { Remove-Item -LiteralPath $artifactPath -Force }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::CreateFromDirectory($releaseRoot, $artifactPath, [IO.Compression.CompressionLevel]::Optimal, $false)
    $artifactSha = Get-Sha256 $artifactPath
    $manifestPath = "$artifactPath.manifest.json"
    [ordered]@{
      schema_version = "jerry.workstation.release.v1"
      component = "jerry-telemetry-agent"
      source_repository = "JerrySkywalker/jerry-telemetry-agent"
      source_commit = $sourceCommit
      artifact_filename = $artifactName
      artifact_sha256 = $artifactSha
      artifact_size_bytes = (Get-Item -LiteralPath $artifactPath).Length
      runtime_version = [string]$trust.node_runtime.version
      build_tool_version = "npm $(& $npmCmd --version); PowerShell $($PSVersionTable.PSVersion)"
      artifact_file_list_or_digest = [ordered]@{ algorithm = "sha256"; files = $files }
      required_config_key_names = @(
        "AGENT_MODE", "TELEMETRY_OUTPUT_MODE", "TELEMETRY_NODE_CONFIG_PATH",
        "TELEMETRY_NODE_SECRET_FILE", "TELEMETRY_NODE_KEY_ID", "TELEMETRY_HUB_BATCH_URL",
        "TELEMETRY_HUB_REQUEST_TIMEOUT_MS", "TELEMETRY_SERVER_BATCH_LATEST_FILE",
        "TELEMETRY_BATCH_OUTPUT_FILE", "STATE_PATH", "SPOOL_DIR", "HEALTH_SERVER_ENABLED",
        "HEALTH_HOST", "HEALTH_PORT"
      )
      default_activation_state = [ordered]@{
        message_gateway_readiness_collector_enabled = $false
        output_mode = "file"
        http_upload_enabled = $false
      }
      build_timestamp = [DateTime]::UtcNow.ToString("o")
      platform = "win32"
      architecture = "x64"
      entrypoint = "app/dist/src/server-agent-daemon.js"
      node_archive_sha256 = $nodeArchiveSha
      service_wrapper_version = [string]$trust.service_wrapper.version
      service_wrapper_sha256 = [string]$trust.service_wrapper.sha256
      collector_name = "message-gateway-readiness"
      event_type = "message.gateway.readiness"
      loopback_required = $true
      state_preserved_on_upgrade = $true
      spool_preserved_on_upgrade = $true
      secret_files_preserved = $true
      production_build_required = $false
      production_git_required = $false
      production_npm_required = $false
      fixture_runtime = $false
    } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

    & (Join-Path $repoRoot "scripts\workstation\Test-AgentReleaseManifest.ps1") -ArtifactPath $artifactPath -ManifestPath $manifestPath -ExpectedSourceCommit $sourceCommit | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "release_manifest_verification_failed" }
    [ordered]@{
      ok = $true
      artifact = $artifactPath
      manifest = $manifestPath
      source_commit = $sourceCommit
      artifact_sha256 = $artifactSha
      runtime_version = [string]$trust.node_runtime.version
      file_count = $files.Count
      production_contact = $false
      service_registered = $false
      lax_runtime_touched = $false
    } | ConvertTo-Json -Compress
  } finally { Remove-TemporaryRoot $tempRoot }
} finally { Pop-Location }
