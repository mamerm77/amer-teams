# Amer Teams — local LAN test setup for Windows (Docker Desktop required)
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot
$ip = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.PrefixOrigin -eq "Dhcp" -and $_.InterfaceAlias -notmatch "vEthernet|WSL|Loopback" } | Select-Object -First 1).IPAddress
if (-not $ip) { $ip = Read-Host "Enter this PC's Wi-Fi IP address (ipconfig)" }
Write-Host "Using LAN IP $ip"
function Rand($n){ -join ((1..$n) | ForEach-Object { '{0:x}' -f (Get-Random -Maximum 16) }) }
if (-not (Test-Path .env)) {
  $key = Read-Host "Paste your Anthropic API key (or press Enter to skip AI for now)"
@"
DOMAIN=$ip
SERVER_NAME=$ip
LAN_IP=$ip
POSTGRES_PASSWORD=$(Rand 32)
LIVEKIT_API_KEY=APIamerteams
LIVEKIT_API_SECRET=$(Rand 64)
ANTHROPIC_API_KEY=$key
LLM_MODEL=claude-sonnet-4-5
GUARDIAN_BLOCK_LABELS=Confidential,Restricted
"@ | Set-Content -Encoding ascii .env
}
$envs = @{}; Get-Content .env | ForEach-Object { if ($_ -match "^(\w+)=(.*)$") { $envs[$matches[1]] = $matches[2] } }
(Get-Content livekit.yaml -Raw) -replace "keys:\r?\n(  #.*\r?\n)?  .*", "keys:`n  $($envs.LIVEKIT_API_KEY): $($envs.LIVEKIT_API_SECRET)" | Set-Content -Encoding ascii livekit.yaml
if (-not (Test-Path synapse/homeserver.yaml)) {
  docker run --rm -v "${PWD}/synapse:/data" -e SYNAPSE_SERVER_NAME=$ip -e SYNAPSE_REPORT_STATS=no matrixdotorg/synapse:v1.120.0 generate
  $hs = Get-Content synapse/homeserver.yaml -Raw
  $hs = $hs -replace "(?ms)^database:.*?(?=^\S)", "database:`n  name: psycopg2`n  args: {user: synapse, password: $($envs.POSTGRES_PASSWORD), database: synapse, host: postgres, cp_min: 5, cp_max: 10}`n"
  $hs = $hs -replace "listeners:`n", "listeners:`n  - port: 9000`n    type: metrics`n    bind_addresses: ['0.0.0.0']`n"
  $hs = $hs.TrimEnd() + "`n"; $hs += "`nencryption_enabled_by_default_for_room_type: all`nenable_registration: true`nregistration_requires_token: true`npassword_config:`n  enabled: true`n  policy: {enabled: true, minimum_length: 10, require_digit: true, require_symbol: true, require_lowercase: true, require_uppercase: true}`npublic_baseurl: http://$ip/`nenable_metrics: true`nuser_directory: {enabled: true, search_all_users: true, prefer_local_users: true}`n"
  Set-Content -Encoding ascii synapse/homeserver.yaml $hs
}
# Repair configs made by earlier versions: Synapse generates its own registration secret
$hsPath = "synapse/homeserver.yaml"
$hsText = Get-Content $hsPath -Raw
if ($hsText -match "registration_shared_secret_path") {
  ($hsText -replace "(?m)^registration_shared_secret_path:.*\r?\n", "") | Set-Content -Encoding ascii $hsPath
  Write-Host "Repaired Synapse config (removed duplicate registration secret)."
}
docker compose -f docker-compose.yml -f docker-compose.local.yml up -d --build
docker compose -f docker-compose.yml -f docker-compose.local.yml restart synapse | Out-Null
Start-Sleep 15
Write-Host "Waiting for the chat server to start..."
$ready = $false
for ($i = 0; $i -lt 60 -and -not $ready; $i++) {
  try { Invoke-RestMethod "http://localhost/_matrix/client/versions" -TimeoutSec 3 | Out-Null; $ready = $true } catch { Start-Sleep 3 }
}
if (-not $ready) {
  Write-Host "The chat server did not start. Its last log lines:" -ForegroundColor Red
  docker compose logs --tail 30 synapse
  exit 1
}
Write-Host "`nCreate the administrator account (password: 10+ chars, upper, lower, number, symbol):"
$adminPw = Read-Host "Admin password" -AsSecureString
$pw = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($adminPw))
docker compose exec synapse register_new_matrix_user -c /data/homeserver.yaml -u admin -p $pw --admin http://localhost:8008
if ($LASTEXITCODE -ne 0) { Write-Host "(If the account already exists, the password you typed must be its current password.)" }
$login = Invoke-RestMethod -Method Post -Uri "http://localhost/_matrix/client/v3/login" -ContentType "application/json" `
  -Body (@{type="m.login.password"; identifier=@{type="m.id.user"; user="admin"}; password=$pw; initial_device_display_name="Amer AI engine"} | ConvertTo-Json)
Add-Content -Encoding ascii .env "SYNAPSE_ADMIN_TOKEN=$($login.access_token)"
docker compose -f docker-compose.yml -f docker-compose.local.yml up -d orchestrator
Start-Sleep 8
try {
  $inv = Invoke-RestMethod -Method Post -Uri "http://localhost/api/v1/admin/invites" -ContentType "application/json" `
    -Headers @{Authorization = "Bearer $($login.access_token)"} -Body '{"uses_allowed": 10, "expiry_days": 30}'
  Write-Host "`nFirst invite code (10 sign-ups, valid 30 days):  $($inv.token)" -ForegroundColor Green
} catch { Write-Host "Could not create an invite code yet; sign in as admin and use Users > New invite code." }
Write-Host "Admin created. Sign in to the app as 'admin'. More invite codes: Users > New invite code."
Write-Host "`nServer ready. In the app, sign in with server  http://$ip"
Write-Host "Allow Windows Firewall: TCP 80, 7881 and UDP 50000-50100 if prompted."
