# Builds AmerTeams-Setup-<version>.exe on your Windows 11 PC.
# Needs: Flutter (stable), Visual Studio 2022 with "Desktop development with C++", NSIS (winget install NSIS.NSIS), Python.
$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
Set-Location "$root\app"
if (-not (Test-Path windows)) { flutter create . --org com.amerteams --project-name amer_teams --platforms=windows }
python ..\tools\patch_native.py windows
flutter pub get
flutter build windows --release
$rel = "$root\app\build\windows\x64\runner\Release"
foreach ($d in "msvcp140.dll","vcruntime140.dll","vcruntime140_1.dll") { Copy-Item "$env:WINDIR\System32\$d" $rel -Force }
Set-Location "$root\installer"
Remove-Item stage\server -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory stage\server | Out-Null
Copy-Item ..\deploy stage\server\deploy -Recurse; Copy-Item ..\services stage\server\services -Recurse; Copy-Item ..\docs stage\server\docs -Recurse
Remove-Item stage\server\deploy\.env, stage\server\services\orchestrator\tests -Recurse -Force -ErrorAction SilentlyContinue
$v = (Select-String -Path ..\app\pubspec.yaml -Pattern '^version: (\S+?)\+').Matches[0].Groups[1].Value
$nsis = @("${env:ProgramFiles(x86)}\NSIS\makensis.exe", "$env:ProgramFiles\NSIS\makensis.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $nsis) { throw "NSIS not found. Install it with: winget install NSIS.NSIS" }
& $nsis /DVERSION=$v /DAPPDIR=$rel /DSERVERDIR=stage\server amer-teams.nsi
Write-Host "`nInstaller ready: $root\installer\AmerTeams-Setup-$v.exe"
