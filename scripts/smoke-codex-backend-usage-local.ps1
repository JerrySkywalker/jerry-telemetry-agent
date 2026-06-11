param(
  [string]$OutputDir = ".smoke"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Find-JsonProperty {
  param(
    [object]$Value,

    [Parameter(Mandatory = $true)]
    [string]$Name
  )

  if ($null -eq $Value) {
    return $null
  }

  if ($Value -is [System.Collections.IDictionary]) {
    foreach ($key in $Value.Keys) {
      if ($key -eq $Name) {
        return $Value[$key]
      }
      $found = Find-JsonProperty -Value $Value[$key] -Name $Name
      if ($null -ne $found) {
        return $found
      }
    }
    return $null
  }

  if ($Value -is [pscustomobject]) {
    foreach ($property in $Value.PSObject.Properties) {
      if ($property.Name -eq $Name) {
        return $property.Value
      }
      $found = Find-JsonProperty -Value $property.Value -Name $Name
      if ($null -ne $found) {
        return $found
      }
    }
    return $null
  }

  if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
    foreach ($item in $Value) {
      $found = Find-JsonProperty -Value $item -Name $Name
      if ($null -ne $found) {
        return $found
      }
    }
  }

  return $null
}

function Assert-NoForbiddenMarker {
  param([Parameter(Mandatory = $true)][string]$Text)

  $forbidden = @(
    ("access" + "_token"),
    ("refresh" + "_token"),
    ("id" + "_token"),
    "email",
    "account_id",
    "user_id",
    "referral_beacon",
    "promo"
  )

  foreach ($marker in $forbidden) {
    if ($Text.Contains($marker)) {
      throw "Smoke output contains forbidden marker: $marker"
    }
  }
}

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME ".codex" }
$authPath = Join-Path $codexHome "auth.json"
$endpoint = if ($env:CODEX_USAGE_ENDPOINT) { $env:CODEX_USAGE_ENDPOINT } else { "https://chatgpt.com/backend-api/wham/usage" }
$authFileExists = Test-Path -LiteralPath $authPath -PathType Leaf
$authFileLength = 0
$authMode = ""
$hasAccessToken = $false

if (-not $authFileExists) {
  Write-Host "auth_file_exists=False"
  Write-Host "auth_file_length=0"
  Write-Host "auth_mode="
  Write-Host "has_access_token=False"
  Write-Host "endpoint=$endpoint"
  throw "Codex auth.json was not found. Set CODEX_HOME or authenticate Codex CLI locally."
}

function Get-OptionalProperty {
  param(
    [object]$Value,

    [Parameter(Mandatory = $true)]
    [string]$Name
  )

  if ($null -eq $Value) {
    return ""
  }

  $property = $Value.PSObject.Properties[$Name]
  if ($null -eq $property) {
    return ""
  }

  return $property.Value
}

$authFileLength = (Get-Item -LiteralPath $authPath).Length
$auth = Get-Content -Raw -LiteralPath $authPath | ConvertFrom-Json
$authModeValue = Find-JsonProperty -Value $auth -Name "auth_mode"
if ($authModeValue -is [string]) {
  $authMode = $authModeValue
}
$accessTokenKey = ("access" + "_token")
$accessToken = Find-JsonProperty -Value $auth -Name $accessTokenKey
if (-not ($accessToken -is [string]) -or $accessToken.Length -eq 0) {
  Write-Host "auth_file_exists=True"
  Write-Host "auth_file_length=$authFileLength"
  Write-Host "auth_mode=$authMode"
  Write-Host "has_access_token=False"
  Write-Host "endpoint=$endpoint"
  throw "Codex auth.json does not contain an access token."
}
$hasAccessToken = $true

$outputRoot = Join-Path $repoRoot $OutputDir
$snapshotPath = Join-Path $outputRoot "codex-usage-latest.safe.snapshot.json"
$lastGoodPath = Join-Path $outputRoot "codex-usage-last-good.safe.snapshot.json"
$statePath = Join-Path $outputRoot "agent-state.json"
$spoolDir = Join-Path $outputRoot "spool"
New-Item -ItemType Directory -Force -Path $outputRoot, $spoolDir | Out-Null

$previousEnv = @{
  AGENT_MODE = $env:AGENT_MODE
  CODEX_HOME = $env:CODEX_HOME
  CODEX_PROVIDER = $env:CODEX_PROVIDER
  TELEMETRY_COLLECTOR_MODE = $env:TELEMETRY_COLLECTOR_MODE
  TELEMETRY_OUTPUT_MODE = $env:TELEMETRY_OUTPUT_MODE
  TELEMETRY_OUTPUT_FILE = $env:TELEMETRY_OUTPUT_FILE
  CODEX_USAGE_LATEST_PATH = $env:CODEX_USAGE_LATEST_PATH
  CODEX_USAGE_LAST_GOOD_PATH = $env:CODEX_USAGE_LAST_GOOD_PATH
  STATE_PATH = $env:STATE_PATH
  SPOOL_DIR = $env:SPOOL_DIR
  TELEMETRY_NODE_ID = $env:TELEMETRY_NODE_ID
  TELEMETRY_HOSTNAME = $env:TELEMETRY_HOSTNAME
  TELEMETRY_REGION = $env:TELEMETRY_REGION
  TELEMETRY_COLLECTOR = $env:TELEMETRY_COLLECTOR
  HEALTH_SERVER_ENABLED = $env:HEALTH_SERVER_ENABLED
}

Push-Location $repoRoot
try {
  $env:AGENT_MODE = "once"
  $env:CODEX_HOME = $codexHome
  $env:CODEX_PROVIDER = "backend-usage"
  $env:TELEMETRY_COLLECTOR_MODE = "codex-backend-usage"
  $env:TELEMETRY_OUTPUT_MODE = "file"
  $env:TELEMETRY_OUTPUT_FILE = $snapshotPath
  $env:CODEX_USAGE_LATEST_PATH = $snapshotPath
  $env:CODEX_USAGE_LAST_GOOD_PATH = $lastGoodPath
  $env:STATE_PATH = $statePath
  $env:SPOOL_DIR = $spoolDir
  $env:TELEMETRY_NODE_ID = "local-backend-usage-smoke"
  $env:TELEMETRY_HOSTNAME = $env:COMPUTERNAME
  $env:TELEMETRY_REGION = "local"
  $env:TELEMETRY_COLLECTOR = "codex-backend-usage"
  $env:HEALTH_SERVER_ENABLED = "false"

  npm run dev -- --once --collector codex-backend-usage
  if ($LASTEXITCODE -ne 0) {
    throw "Agent smoke run failed with exit code $LASTEXITCODE"
  }

  if (-not (Test-Path -LiteralPath $snapshotPath -PathType Leaf)) {
    throw "Smoke snapshot was not written."
  }

  $snapshotText = Get-Content -Raw -LiteralPath $snapshotPath
  Assert-NoForbiddenMarker -Text $snapshotText
  $snapshot = $snapshotText | ConvertFrom-Json

  if ($snapshot.type -ne "codex.usage.snapshot") { throw "Smoke snapshot type mismatch." }
  if ($null -eq $snapshot.status -or $null -eq $snapshot.status.ok) { throw "Smoke snapshot is missing status.ok." }
  if (-not ($snapshot.limits -is [System.Collections.IEnumerable])) { throw "Smoke snapshot is missing limits array." }
  if (-not ($snapshot.limits_detail -is [System.Collections.IEnumerable])) { throw "Smoke snapshot is missing limits_detail array." }
  if (-not $snapshot.observed_at) { throw "Smoke snapshot is missing observed_at." }
  if ($null -eq $snapshot.node -or -not $snapshot.node.id) { throw "Smoke snapshot is missing node.id." }

  $limits = @($snapshot.limits)
  $limitsDetail = @($snapshot.limits_detail)
  $defaultLimit = @($limits | Where-Object { $_.scope -eq "default" -or $_.name -eq "default" })
  $sparkLimit = @($limits | Where-Object { $_.name -eq "GPT-5.3-Codex-Spark" })
  if ($limits.Count -gt 0) {
    if ($defaultLimit.Count -eq 0) {
      throw "Smoke snapshot has limits but no default limit."
    }

    if ($snapshotText.Contains("GPT-5.3-Codex-Spark") -and $sparkLimit.Count -eq 0) {
      throw "Smoke snapshot mentions GPT-5.3-Codex-Spark outside limits."
    }
  }

  $detailFieldsPresent = ($limitsDetail.Count -gt 0) -and (@($limitsDetail | Where-Object { $_.PSObject.Properties["completeness"] -and $_.PSObject.Properties["status"] }).Count -eq $limitsDetail.Count)
  $resetCandidatePresent = @($limitsDetail | Where-Object {
    ($_.PSObject.Properties["reset_at_iso"] -and $null -ne $_.reset_at_iso) -or
    ($_.PSObject.Properties["reset_in_seconds"] -and $null -ne $_.reset_in_seconds) -or
    ($_.PSObject.Properties["window_seconds"] -and $null -ne $_.window_seconds)
  }).Count -gt 0
  $absoluteUsageCandidatePresent = @($limitsDetail | Where-Object {
    ($_.PSObject.Properties["total"] -and $null -ne $_.total) -or
    ($_.PSObject.Properties["used"] -and $null -ne $_.used) -or
    ($_.PSObject.Properties["remaining"] -and $null -ne $_.remaining)
  }).Count -gt 0

  $rawOmittedKeys = if ($snapshot.raw_omitted_keys) { (@($snapshot.raw_omitted_keys) -join ",") } else { "" }
  Write-Host "auth_file_exists=$authFileExists"
  Write-Host "auth_file_length=$authFileLength"
  Write-Host "auth_mode=$authMode"
  Write-Host "has_access_token=$hasAccessToken"
  Write-Host "endpoint=$endpoint"
  Write-Host "output_snapshot_path=$snapshotPath"
  Write-Host "status_ok=$($snapshot.status.ok)"
  Write-Host "error_code=$(Get-OptionalProperty -Value $snapshot.status -Name "error_code")"
  Write-Host "message=$(Get-OptionalProperty -Value $snapshot.status -Name "message")"
  Write-Host "limits_count=$($limits.Count)"
  Write-Host "limits_detail_count=$($limitsDetail.Count)"
  Write-Host "detail_fields_present=$detailFieldsPresent"
  Write-Host "reset_candidate_present=$resetCandidatePresent"
  Write-Host "absolute_usage_candidate_present=$absoluteUsageCandidatePresent"
  Write-Host "secret_leak_detected=false"
  Write-Host "default_limit_found=$($defaultLimit.Count -gt 0)"
  Write-Host "spark_limit_found=$($sparkLimit.Count -gt 0)"
  Write-Host "raw_omitted_keys=$rawOmittedKeys"
  Write-Host "observed_at=$($snapshot.observed_at)"
  Write-Host "node_id=$($snapshot.node.id)"
} finally {
  Pop-Location
  foreach ($key in $previousEnv.Keys) {
    if ($null -eq $previousEnv[$key]) {
      Remove-Item -Path "Env:$key" -ErrorAction SilentlyContinue
    } else {
      Set-Item -Path "Env:$key" -Value $previousEnv[$key]
    }
  }
}
