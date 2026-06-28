param(
  [string]$OutputDir = ".smoke\canary-live-audit-contract"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$outputRoot = if ([IO.Path]::IsPathRooted($OutputDir)) { $OutputDir } else { Join-Path $repoRoot $OutputDir }

$contract = [pscustomobject][ordered]@{
  generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
  contract_only = $true
  commands_executed = $false
  live_ssh_used = $false
  production_mutation = $false
  purpose = "Define a future read-only live audit contract for retained telemetry canaries."
  allowed_read_only_commands = @(
    "systemctl is-active <canary service>",
    "systemctl show <canary service> with safe field allowlist",
    "docker ps with safe format fields",
    "docker inspect only with filtered safe fields and no environment output",
    "curl localhost health and status endpoints",
    "SQLite integrity check against canary database when authorized read-only",
    "bounded log reads for local analysis with count-only reporting",
    "file metadata and count checks for state, spool, and archived spool"
  )
  forbidden_mutating_commands = @(
    "systemctl start",
    "systemctl stop",
    "systemctl restart",
    "systemctl enable",
    "systemctl disable",
    "docker stop",
    "docker start",
    "docker restart",
    "docker rm",
    "docker compose up",
    "docker compose down",
    "docker compose restart",
    "scp",
    "rsync",
    "spool flush",
    "spool restore",
    "spool delete"
  )
  required_checks = [ordered]@{
    hub = @("service active", "restart count", "health", "read auth behavior", "read model", "recent events", "SQLite integrity", "non-local listener count")
    reverse_tunnel = @("service active", "restart count", "LAX localhost bind", "reachability", "non-local listener count")
    agent = @("container running", "restart count", "health", "status", "mode", "latest batch", "event types", "active spool", "archived spool counts", "last batch error", "successful send timestamp")
  }
  required_redactions = @(
    "secret values",
    "read credential values",
    "private key material",
    "signature values",
    "auth header values",
    "cookie values",
    "raw request bodies",
    "raw logs",
    "raw response bodies",
    "identity fields"
  )
  required_report_fields = @(
    "timestamp",
    "target aliases only",
    "service names",
    "container name",
    "status codes",
    "boolean pass fields",
    "restart counts",
    "spool counts",
    "event type names",
    "marker scan result",
    "skipped checks with reasons",
    "failure recommendation"
  )
  failure_handling = @(
    "Do not mutate automatically.",
    "Record safe failure summary.",
    "Recommend rollback, continued observation, or deeper diagnosis.",
    "Stop if a check would require printing a secret or raw log."
  )
  marker_scan = [ordered]@{
    required = $true
    scan_targets = @("generated reports", "sanitized summaries", "bounded log summaries")
    output = "counts only"
  }
}

New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null
$jsonPath = Join-Path $outputRoot "canary-live-audit-contract.json"
$mdPath = Join-Path $outputRoot "canary-live-audit-contract.md"
$contract | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $jsonPath -Encoding UTF8

$md = @(
  "# Canary Live Audit Contract",
  "",
  "- Contract only: true",
  "- Commands executed: false",
  "- Live SSH used by this script: false",
  "- Production mutation: false",
  "",
  "## Allowed Read-Only Checks"
)
foreach ($item in $contract.allowed_read_only_commands) {
  $md += "- $item"
}
$md += ""
$md += "## Forbidden Mutating Actions"
foreach ($item in $contract.forbidden_mutating_commands) {
  $md += "- $item"
}
$md += ""
$md += "## Required Redactions"
foreach ($item in $contract.required_redactions) {
  $md += "- $item"
}
$md += ""
$md += "## Failure Handling"
foreach ($item in $contract.failure_handling) {
  $md += "- $item"
}
$md | Set-Content -LiteralPath $mdPath -Encoding UTF8

Write-Host "canary_live_audit_contract=PASS"
Write-Host "contract_only=true"
Write-Host "commands_executed=false"
Write-Host "live_ssh_used=false"
Write-Host "production_mutation=false"
Write-Host "output_dir=$outputRoot"
