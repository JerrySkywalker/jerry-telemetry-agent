param(
  [string]$OutputDir = ".smoke\artifacts",
  [switch]$RequireExistingBuild
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Test-ForbiddenPackagePath {
  param([Parameter(Mandatory = $true)][string]$RelativePath)

  $normalized = $RelativePath -replace "\\", "/"
  $leaf = [IO.Path]::GetFileName($normalized)
  if ($leaf -eq ".env" -or $leaf -like ".env.*" -or $leaf -eq "auth.json") { return $true }
  if ($normalized -match "(^|/)(node_modules|state|logs|\.smoke|tmp|coverage|backups?)(/|$)") { return $true }
  if ($normalized -match "\.raw\.local-only\.json$") { return $true }
  if ($normalized -match "(generated|local).*(credential|secret)") { return $true }
  return $false
}

function Copy-SafeItem {
  param(
    [Parameter(Mandatory = $true)][string]$Source,
    [Parameter(Mandatory = $true)][string]$DestinationRoot,
    [Parameter(Mandatory = $true)][string]$PackageRelativeRoot
  )

  if (-not (Test-Path -LiteralPath $Source)) { return }
  $sourceItem = Get-Item -LiteralPath $Source -Force
  if (-not $sourceItem.PSIsContainer) {
    $relative = $PackageRelativeRoot
    if (Test-ForbiddenPackagePath -RelativePath $relative) { return }
    $target = Join-Path $DestinationRoot $relative
    New-Item -ItemType Directory -Force -Path ([IO.Path]::GetDirectoryName($target)) | Out-Null
    Copy-Item -LiteralPath $sourceItem.FullName -Destination $target -Force
    return
  }

  $root = $sourceItem.FullName
  Get-ChildItem -LiteralPath $root -Recurse -File -Force | ForEach-Object {
    $relativeUnderRoot = [IO.Path]::GetRelativePath($root, $_.FullName)
    $relative = Join-Path $PackageRelativeRoot $relativeUnderRoot
    if (Test-ForbiddenPackagePath -RelativePath $relative) { return }
    $target = Join-Path $DestinationRoot $relative
    New-Item -ItemType Directory -Force -Path ([IO.Path]::GetDirectoryName($target)) | Out-Null
    Copy-Item -LiteralPath $_.FullName -Destination $target -Force
  }
}

function Scan-ZipPackage {
  param([Parameter(Mandatory = $true)][string]$ArtifactPath)

  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $failures = New-Object System.Collections.Generic.List[string]
  $zip = [System.IO.Compression.ZipFile]::OpenRead($ArtifactPath)
  try {
    foreach ($entry in $zip.Entries) {
      if ($entry.FullName.EndsWith("/")) { continue }
      if (Test-ForbiddenPackagePath -RelativePath $entry.FullName) {
        $failures.Add("forbidden file: $($entry.FullName)")
        continue
      }
      if ($entry.Length -gt 1048576) { continue }
      $stream = $entry.Open()
      try {
        $reader = New-Object System.IO.StreamReader($stream)
        $content = $reader.ReadToEnd()
        if ($content -match "(?im)^\s*(access_token|refresh_token|TELEMETRY_NODE_SECRET)\s*[:=]\s*['""]?(?!\$\{)[^'""\s][^'""\r\n]{8,}") {
          $failures.Add("possible secret assignment: $($entry.FullName)")
        }
        $privateKeyMarker = "-----BEGIN OPENSSH " + "PRIVATE KEY-----"
        if ($content.Contains($privateKeyMarker)) {
          $failures.Add("private key marker: $($entry.FullName)")
        }
      } finally {
        $stream.Dispose()
      }
    }
  } finally {
    $zip.Dispose()
  }
  return $failures
}

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Push-Location $repoRoot
try {
  if (-not $RequireExistingBuild) {
    npm run build
    if ($LASTEXITCODE -ne 0) { throw "build failed before package creation" }
  }
  if (-not (Test-Path -LiteralPath "dist" -PathType Container)) {
    throw "dist directory missing; run npm run build first"
  }

  $packageJson = Get-Content -Raw -LiteralPath "package.json" | ConvertFrom-Json
  $version = [string]$packageJson.version
  $shortSha = (git rev-parse --short HEAD).Trim()
  $outputRoot = Join-Path $repoRoot $OutputDir
  New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null
  $runId = Get-Date -Format "yyyyMMdd-HHmmss-ffff"
  $stageRoot = Join-Path $outputRoot "package-work-$runId"
  New-Item -ItemType Directory -Force -Path $stageRoot | Out-Null

  $items = @(
    @{ Source = "dist"; Relative = "dist" },
    @{ Source = "package.json"; Relative = "package.json" },
    @{ Source = "package-lock.json"; Relative = "package-lock.json" },
    @{ Source = "README.md"; Relative = "README.md" },
    @{ Source = "Dockerfile"; Relative = "Dockerfile" },
    @{ Source = "docker-compose.yml"; Relative = "docker-compose.yml" },
    @{ Source = "deploy"; Relative = "deploy" },
    @{ Source = "docs"; Relative = "docs" },
    @{ Source = "scripts"; Relative = "scripts" }
  )
  foreach ($item in $items) {
    Copy-SafeItem -Source $item.Source -DestinationRoot $stageRoot -PackageRelativeRoot $item.Relative
  }

  $artifactPath = Join-Path $outputRoot "jerry-telemetry-agent-$version-$shortSha.zip"
  if (Test-Path -LiteralPath $artifactPath) { Remove-Item -LiteralPath $artifactPath -Force }
  Compress-Archive -Path (Join-Path $stageRoot "*") -DestinationPath $artifactPath -CompressionLevel Optimal

  $scanFailures = @(Scan-ZipPackage -ArtifactPath $artifactPath)
  $files = Get-ChildItem -LiteralPath $stageRoot -Recurse -File -Force
  $topDirs = Get-ChildItem -LiteralPath $stageRoot -Force | ForEach-Object { $_.Name } | Sort-Object
  $manifest = [ordered]@{
    artifact_path = $artifactPath
    file_count = @($files).Count
    package_version = $version
    git_commit = (git rev-parse HEAD).Trim()
    included_top_level_entries = @($topDirs)
    excluded_patterns = @(".env", ".env.*", "auth.json", "state/", "logs/", ".smoke/", "node_modules/", "*.raw.local-only.json", "generated credentials", "backups/")
    forbidden_marker_scan = if ($scanFailures.Count -eq 0) { "pass" } else { "fail" }
    forbidden_marker_failures_count = $scanFailures.Count
  }
  $manifestPath = Join-Path $outputRoot "agent-package-manifest.json"
  $manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

  if ($scanFailures.Count -gt 0) {
    throw "package forbidden marker scan failed: $($scanFailures -join '; ')"
  }

  Write-Host "package_artifact=$artifactPath"
  Write-Host "package_manifest=$manifestPath"
  Write-Host "package_file_count=$($manifest.file_count)"
  Write-Host "forbidden_marker_scan=pass"
} finally {
  Pop-Location
}
