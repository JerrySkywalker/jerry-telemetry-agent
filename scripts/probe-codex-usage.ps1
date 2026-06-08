param(
  [string]$Endpoint = "https://chatgpt.com/backend-api/wham/usage",
  [string]$NodeId = $env:COMPUTERNAME
)

$CodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME ".codex" }
$AuthPath = Join-Path $CodexHome "auth.json"

if (-not (Test-Path $AuthPath)) {
  throw "Codex auth.json not found at $AuthPath. Run codex login first."
}

$auth = Get-Content $AuthPath -Raw | ConvertFrom-Json
$AccessToken = $auth.tokens.access_token
if (-not $AccessToken) { $AccessToken = $auth.access_token }

if (-not $AccessToken) {
  throw "No access token found in $AuthPath. Do not print or upload auth.json."
}

$Headers = @{
  Authorization = "Bearer $AccessToken"
  Accept = "application/json"
}

$data = Invoke-RestMethod -Uri $Endpoint -Headers $Headers -Method GET

$snapshot = [ordered]@{
  type = "codex.usage.snapshot"
  schema_version = 1
  source = "chatgpt_backend_wham_usage"
  observed_at = (Get-Date).ToUniversalTime().ToString("o")
  node_id = $NodeId

  plan_type = $data.plan_type
  rate_limit_reached_type = $data.rate_limit_reached_type
  rate_limit_reset_credits = $data.rate_limit_reset_credits

  rate_limit = $data.rate_limit

  additional_rate_limits = @(
    $data.additional_rate_limits | ForEach-Object {
      [ordered]@{
        limit_name = $_.limit_name
        metered_feature = $_.metered_feature
        rate_limit = $_.rate_limit
      }
    }
  )

  credits = $data.credits
  spend_control = $data.spend_control

  raw_omitted_keys = @(
    "account_id",
    "user_id",
    "email",
    "referral_beacon",
    "promo"
  )
}

$snapshot | ConvertTo-Json -Depth 20
