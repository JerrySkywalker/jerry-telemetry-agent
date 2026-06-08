$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Push-Location $repoRoot
try {
  $failures = New-Object System.Collections.Generic.List[string]
  $paths = git ls-files --cached --others --exclude-standard

  foreach ($path in $paths) {
    $normalized = $path -replace "\\", "/"
    if ($normalized -match "^(node_modules|dist|coverage|state|spool|tmp)/") {
      continue
    }

    $name = [IO.Path]::GetFileName($normalized)
    if ($name -eq ".env" -or $name -eq "auth.json" -or $normalized -match "\.raw\.local-only\.json$") {
      $failures.Add("forbidden file: $normalized")
      continue
    }

    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
      continue
    }

    $content = Get-Content -Raw -LiteralPath $path

    if ($content -match "(?im)^\s*(access_token|refresh_token|TELEMETRY_NODE_SECRET)\s*[:=]\s*['""]?(?!\$\{)[^'""\s][^'""\r\n]{8,}") {
      $failures.Add("possible secret assignment: $normalized")
    }

    if ($normalized -match "(snapshot|latest|usage).*\.json$") {
      if ($content -match '"(email|user_id)"\s*:') {
        $failures.Add("snapshot contains forbidden identity key: $normalized")
      }
      if ($content -match '"account_id"\s*:\s*"(?!\[REDACTED\])') {
        $failures.Add("snapshot contains unredacted account_id: $normalized")
      }
    }
  }

  if ($failures.Count -gt 0) {
    Write-Error ("Light secret scan failed:`n" + ($failures -join "`n"))
  }

  Write-Host "Light secret scan completed."
} finally {
  Pop-Location
}
