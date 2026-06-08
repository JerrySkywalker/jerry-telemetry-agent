$ErrorActionPreference = "Stop"

npm install
npm run typecheck
npm test
npm run build
docker compose config

Write-Host "Local smoke completed."
