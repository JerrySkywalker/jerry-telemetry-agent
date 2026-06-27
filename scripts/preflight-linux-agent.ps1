param(
  [string]$StateDir = "/var/lib/jerry-telemetry-agent",
  [string]$HubHealthUrl = "http://127.0.0.1:3000/healthz"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

Write-Host "linux_preflight_mode=read_only_template"
Write-Host "checks_count=7"
Write-Host "docker_available_command=command -v docker"
Write-Host "docker_compose_available_command=docker compose version"
Write-Host "disk_summary_command=df -h /"
Write-Host "memory_summary_command=free -h"
Write-Host "hub_health_command=curl -fsS $HubHealthUrl"
Write-Host "state_dir_check_command=test -d $StateDir && test -w $StateDir"
Write-Host "conflict_check_command=systemctl list-timers --all --no-pager | grep -F jerry-telemetry-agent || true"
Write-Host "production_changes=false"
