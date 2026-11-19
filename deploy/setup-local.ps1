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
# Amer chat assistant: its own account and a secret it uses to call the AI engine (added once, kept on re-runs)
if (-not (Select-String -Path .env -Pattern "^AMER_BOT_SECRET=" -Quiet)) {
  Add-Content -Encoding ascii .env "AMER_BOT_USER=amer`nAMER_BOT_PASSWORD=Am$(Rand 20)!Q`nAMER_BOT_SECRET=$(Rand 48)"
}
# partner policy secret, shared by the Synapse module and the orchestrator (docs/PARTNERS.md)
if (-not (Select-String -Path .env -Pattern "^AMER_FEDERATION_SECRET=" -Quiet)) { Add-Content -Encoding ascii .env "AMER_FEDERATION_SECRET=$(Rand 48)" }
$envs = @{}; Get-Content .env | ForEach-Object { if ($_ -match "^(\w+)=(.*)$") { $envs[$matches[1]] = $matches[2] } }
(Get-Content livekit.yaml -Raw) -replace "keys:\r?\n(  #.*\r?\n)?  .*", "keys:`n  $($envs.LIVEKIT_API_KEY): $($envs.LIVEKIT_API_SECRET)" -replace "api_key: LK_API_KEY", "api_key: $($envs.LIVEKIT_API_KEY)" | Set-Content -Encoding ascii livekit.yaml
if (-not (Test-Path synapse/homeserver.yaml)) {
  docker run --rm -v "${PWD}/synapse:/data" -e SYNAPSE_SERVER_NAME=$ip -e SYNAPSE_REPORT_STATS=no matrixdotorg/synapse:v1.120.0 generate
  $hs = Get-Content synapse/homeserver.yaml -Raw
  $hs = $hs -replace "(?ms)^database:.*?(?=^\S)", "database:`n  name: psycopg2`n  args: {user: synapse, password: $($envs.POSTGRES_PASSWORD), database: synapse, host: postgres, cp_min: 5, cp_max: 10}`n"
  $hs = $hs -replace "listeners:`n", "listeners:`n  - port: 9000`n    type: metrics`n    bind_addresses: ['0.0.0.0']`n"
  $hs = $hs.TrimEnd() + "`n"; $hs += "`nencryption_enabled_by_default_for_room_type: all`nenable_registration: true`nregistration_requires_token: true`npassword_config:`n  enabled: true`n  policy: {enabled: true, minimum_length: 10, require_digit: true, require_symbol: true, require_lowercase: true, require_uppercase: true}`npublic_baseurl: http://$ip/`nenable_metrics: true`nuser_directory: {enabled: true, search_all_users: true, prefer_local_users: true}`nretention: {enabled: true, purge_jobs: [{interval: 1h}]}`n"
  Set-Content -Encoding ascii synapse/homeserver.yaml $hs
}
# Repair configs made by earlier versions: Synapse generates its own registration secret
$hsPath = "synapse/homeserver.yaml"
$hsText = Get-Content $hsPath -Raw
if ($hsText -match "registration_shared_secret_path") {
  ($hsText -replace "(?m)^registration_shared_secret_path:.*\r?\n", "") | Set-Content -Encoding ascii $hsPath
  Write-Host "Repaired Synapse config (removed duplicate registration secret)."
}
$hsText = Get-Content $hsPath -Raw
if ($hsText -notmatch "(?m)^user_directory") {
  Add-Content -Encoding ascii $hsPath "`nuser_directory: {enabled: true, search_all_users: true, prefer_local_users: true}"
  Write-Host "Enabled the people directory (everyone can find each other)."
}
if ((Get-Content $hsPath -Raw) -notmatch "(?m)^room_list_publication_rules") {
  Add-Content -Encoding ascii $hsPath "`n# public teams appear in Discover teams`nroom_list_publication_rules: [{action: allow}]"
}
if ((Get-Content $hsPath -Raw) -notmatch "(?m)^rc_message") {
  Add-Content -Encoding ascii $hsPath "`n# business messaging rates (Synapse default 0.2/s, burst 10, throttles active chats and meetings)`nrc_message: {per_second: 10, burst_count: 100}"
}
if ((Get-Content $hsPath -Raw) -notmatch "(?m)^retention") {
  Add-Content -Encoding ascii $hsPath "`nretention: {enabled: true, purge_jobs: [{interval: 1h}]}"
  Write-Host "Enabled disappearing messages."
}
if ((Get-Content $hsPath -Raw) -notmatch "amer_federation.AmerFederation") {
  Add-Content -Encoding ascii $hsPath "`n# Amer Teams partner policy (docs/PARTNERS.md)`nmodules:`n  - module: amer_federation.AmerFederation`n    config: {orchestrator: `"http://orchestrator:8080`", secret: `"$($envs.AMER_FEDERATION_SECRET)`"}"
  Write-Host "Enabled the partner policy: only approved partner servers can connect."
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
# create the Amer account (ignored if it already exists) and start the assistant
docker compose exec -T synapse register_new_matrix_user -c /data/homeserver.yaml -u $envs.AMER_BOT_USER -p $envs.AMER_BOT_PASSWORD --no-admin http://localhost:8008 2>$null | Out-Null
docker compose -f docker-compose.yml -f docker-compose.local.yml up -d amer-bot
Write-Host "Amer assistant started: users can open Amer > Chat with Amer, or @mention Amer in a group."
Start-Sleep 8
try {
  $inv = Invoke-RestMethod -Method Post -Uri "http://localhost/api/v1/admin/invites" -ContentType "application/json" `
    -Headers @{Authorization = "Bearer $($login.access_token)"} -Body '{"uses_allowed": 10, "expiry_days": 30}'
  Write-Host "`nFirst invite code (10 sign-ups, valid 30 days):  $($inv.token)" -ForegroundColor Green
} catch { Write-Host "Could not create an invite code yet; sign in as admin and use Users > New invite code." }
Write-Host "Admin created. Sign in to the app as 'admin'. More invite codes: Users > New invite code."
Write-Host "`nServer ready. In the app, sign in with server  http://$ip"
# Phones on the same Wi-Fi must reach the server (TCP 80), and calls need the media ports (TCP 7881, UDP 50000-50100).
try {
  foreach ($r in @(@{n="Amer Teams web"; p="TCP"; l="80"}, @{n="Amer Teams media TCP"; p="TCP"; l="7881"}, @{n="Amer Teams media UDP"; p="UDP"; l="50000-50100"})) {
    if (-not (Get-NetFirewallRule -DisplayName $r.n -ErrorAction SilentlyContinue)) {
      New-NetFirewallRule -DisplayName $r.n -Direction Inbound -Protocol $r.p -LocalPort $r.l -Action Allow -Profile Private,Domain | Out-Null
    }
  }
  Write-Host "Windows Firewall: opened TCP 80, 7881 and UDP 50000-50100 for private networks."
} catch {
  Write-Host "Could not add firewall rules (run PowerShell as Administrator). Calls from phones need TCP 80, 7881 and UDP 50000-50100 open."
}
