# Amer Teams for Windows 11

## Install
Run **AmerTeams-Setup-<version>.exe** and follow the wizard.

| Option | What it does |
|---|---|
| Amer Teams desktop app (required) | Installs to `C:\Program Files\Amer Teams`, Start menu entry, Windows Firewall rule for calls |
| Desktop shortcut | Shortcut on the desktop |
| Start with Windows | Opens at sign-in so you receive calls |
| Local server (optional) | Chat, call and AI servers in `C:\ProgramData\Amer Teams\server` for testing on your Wi-Fi; needs Docker Desktop. Start menu gets **Set up** and **Stop** entries |

Uninstall from **Settings → Apps → Installed apps → Amer Teams**. Silent install for IT: `AmerTeams-Setup-<version>.exe /S`, uninstall `"C:\Program Files\Amer Teams\Uninstall.exe" /S`.
Requirements: Windows 10 1809 or Windows 11, 64-bit.

## Get the installer
- **GitHub (recommended):** push this repo; the `windows` job builds the app, builds the installer, then installs it silently on a Windows machine, launches the app, checks shortcuts and the Installed-apps entry, and uninstalls. Download it from the run's *Artifacts*. Tag a release (`git tag v0.5.0 && git push --tags`) to attach it to a GitHub Release.
- **On your PC:** `powershell -ExecutionPolicy Bypass -File installer\build-installer.ps1`

## SmartScreen
Without a code-signing certificate Windows shows "Windows protected your PC" (More info → Run anyway). For distribution, sign the installer and app with an EV or OV certificate:
`signtool sign /fd SHA256 /tr http://timestamp.digicert.com /td SHA256 /f cert.pfx /p <password> AmerTeams-Setup-<version>.exe`
