; Amer Teams — Windows 11 installer (NSIS 3, Unicode, x64)
; Build:  makensis /DVERSION=0.5.0 /DAPPDIR=<flutter Release dir> /DSERVERDIR=<staged server dir> amer-teams.nsi

Unicode true
ManifestDPIAware true
!include "MUI2.nsh"
!include "x64.nsh"
!include "WinVer.nsh"
!include "LogicLib.nsh"
!include "FileFunc.nsh"

!ifndef VERSION
  !define VERSION "0.5.0"
!endif
!ifndef APPDIR
  !define APPDIR "..\app\build\windows\x64\runner\Release"
!endif
!ifndef SERVERDIR
  !define SERVERDIR "stage\server"
!endif
!define APPNAME   "Amer Teams"
!define PUBLISHER "Amer Telecom"
!define EXE       "amer_teams.exe"
!define UNINSTKEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\AmerTeams"
!define SERVERDATA "$APPDATA\Amer Teams\server"   ; with SetShellVarContext all: C:\ProgramData\Amer Teams\server

Name "${APPNAME}"
OutFile "AmerTeams-Setup-${VERSION}.exe"
InstallDir "$PROGRAMFILES64\${APPNAME}"
InstallDirRegKey HKLM "${UNINSTKEY}" "InstallLocation"
RequestExecutionLevel admin
SetCompressor /SOLID lzma
BrandingText "${APPNAME} ${VERSION}"
VIProductVersion "${VERSION}.0"
VIAddVersionKey "ProductName" "${APPNAME}"
VIAddVersionKey "CompanyName" "${PUBLISHER}"
VIAddVersionKey "FileDescription" "${APPNAME} Setup"
VIAddVersionKey "FileVersion" "${VERSION}"
VIAddVersionKey "LegalCopyright" "${PUBLISHER}"

!define MUI_ICON   "amer-teams.ico"
!define MUI_UNICON "amer-teams.ico"
!define MUI_WELCOMEFINISHPAGE_BITMAP "wizard.bmp"
!define MUI_UNWELCOMEFINISHPAGE_BITMAP "wizard.bmp"
!define MUI_HEADERIMAGE
!define MUI_HEADERIMAGE_RIGHT
!define MUI_HEADERIMAGE_BITMAP "header.bmp"
!define MUI_ABORTWARNING
!define MUI_COMPONENTSPAGE_SMALLDESC

!define MUI_WELCOMEPAGE_TITLE "Install ${APPNAME}"
!define MUI_WELCOMEPAGE_TEXT "${APPNAME} is an end-to-end encrypted collaboration app with chat, teams, calls, meetings and the Amer AI co-pilot.$\r$\n$\r$\nSetup installs the desktop app. You can also install a local server on this PC for testing on your Wi-Fi.$\r$\n$\r$\nClick Next to continue."
!define MUI_FINISHPAGE_RUN "$INSTDIR\${EXE}"
!define MUI_FINISHPAGE_RUN_TEXT "Open ${APPNAME}"
!define MUI_FINISHPAGE_SHOWREADME ""
!define MUI_FINISHPAGE_SHOWREADME_NOTCHECKED
!define MUI_FINISHPAGE_SHOWREADME_TEXT "Set up the local server now (needs Docker Desktop)"
!define MUI_FINISHPAGE_SHOWREADME_FUNCTION RunServerSetup

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_LICENSE "LICENSE.txt"
!insertmacro MUI_PAGE_COMPONENTS
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "English"

; ---------------------------------------------------------------- checks
Function .onInit
  ${IfNot} ${RunningX64}
    MessageBox MB_ICONSTOP "${APPNAME} needs 64-bit Windows 10 or Windows 11."
    Abort
  ${EndIf}
  ${IfNot} ${AtLeastWin10}
    MessageBox MB_ICONSTOP "${APPNAME} needs Windows 10 (version 1809) or Windows 11."
    Abort
  ${EndIf}
  SetRegView 64
  SetShellVarContext all          ; shortcuts and data for all users
  ; close a running copy before upgrading
  nsExec::Exec 'taskkill /IM ${EXE} /F'
FunctionEnd

; ---------------------------------------------------------------- sections
Section "${APPNAME} desktop app" SecApp
  SectionIn RO
  SetOutPath "$INSTDIR"
  File /r "${APPDIR}\*.*"
  File "amer-teams.ico"
  WriteUninstaller "$INSTDIR\Uninstall.exe"

  CreateDirectory "$SMPROGRAMS\${APPNAME}"
  CreateShortcut "$SMPROGRAMS\${APPNAME}\${APPNAME}.lnk" "$INSTDIR\${EXE}" "" "$INSTDIR\amer-teams.ico"
  CreateShortcut "$SMPROGRAMS\${APPNAME}\Uninstall ${APPNAME}.lnk" "$INSTDIR\Uninstall.exe"

  ; Add/Remove Programs (Settings > Apps > Installed apps)
  WriteRegStr HKLM "${UNINSTKEY}" "DisplayName" "${APPNAME}"
  WriteRegStr HKLM "${UNINSTKEY}" "DisplayVersion" "${VERSION}"
  WriteRegStr HKLM "${UNINSTKEY}" "Publisher" "${PUBLISHER}"
  WriteRegStr HKLM "${UNINSTKEY}" "DisplayIcon" "$INSTDIR\amer-teams.ico"
  WriteRegStr HKLM "${UNINSTKEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKLM "${UNINSTKEY}" "UninstallString" '"$INSTDIR\Uninstall.exe"'
  WriteRegStr HKLM "${UNINSTKEY}" "QuietUninstallString" '"$INSTDIR\Uninstall.exe" /S'
  WriteRegDWORD HKLM "${UNINSTKEY}" "NoModify" 1
  WriteRegDWORD HKLM "${UNINSTKEY}" "NoRepair" 1
  ${GetSize} "$INSTDIR" "/S=0K" $0 $1 $2
  IntFmt $0 "0x%08X" $0
  WriteRegDWORD HKLM "${UNINSTKEY}" "EstimatedSize" "$0"

  ; allow calls through Windows Firewall (media is end-to-end encrypted)
  nsExec::Exec 'netsh advfirewall firewall add rule name="Amer Teams" dir=in action=allow program="$INSTDIR\${EXE}" enable=yes profile=private,domain'
SectionEnd

Section "Desktop shortcut" SecDesktop
  CreateShortcut "$DESKTOP\${APPNAME}.lnk" "$INSTDIR\${EXE}" "" "$INSTDIR\amer-teams.ico"
SectionEnd

Section "Start with Windows" SecStartup
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Run" "AmerTeams" '"$INSTDIR\${EXE}" --minimized'
SectionEnd

Section /o "Local server for testing on your Wi-Fi (needs Docker Desktop)" SecServer
  SetOutPath "${SERVERDATA}"
  File /r "${SERVERDIR}\*.*"
  ; server writes its settings and certificates here, so ordinary users need modify rights
  nsExec::Exec 'icacls "${SERVERDATA}" /grant *S-1-5-32-545:(OI)(CI)M /T /Q'
  nsExec::Exec 'netsh advfirewall firewall add rule name="Amer Teams Server (web)" dir=in action=allow protocol=TCP localport=80,7881 profile=private'
  nsExec::Exec 'netsh advfirewall firewall add rule name="Amer Teams Server (media)" dir=in action=allow protocol=UDP localport=50000-50100 profile=private'
  CreateShortcut "$SMPROGRAMS\${APPNAME}\Set up ${APPNAME} Server.lnk" "powershell.exe" \
    '-NoExit -ExecutionPolicy Bypass -File "${SERVERDATA}\deploy\setup-local.ps1"' "$INSTDIR\amer-teams.ico"
  CreateShortcut "$SMPROGRAMS\${APPNAME}\Stop ${APPNAME} Server.lnk" "powershell.exe" \
    `-NoExit -Command "Set-Location '${SERVERDATA}\deploy'; docker compose -f docker-compose.yml -f docker-compose.local.yml down"` "$INSTDIR\amer-teams.ico"
  WriteRegStr HKLM "${UNINSTKEY}" "ServerInstalled" "1"

  nsExec::ExecToStack 'cmd /c docker --version'
  Pop $0
  ${If} $0 != 0
    MessageBox MB_ICONINFORMATION|MB_OK "Docker Desktop was not found.$\r$\n$\r$\nThe server files are installed. Install Docker Desktop from docker.com, then run 'Set up ${APPNAME} Server' from the Start menu."
  ${EndIf}
SectionEnd

LangString DESC_App ${LANG_ENGLISH} "The ${APPNAME} desktop app (required)."
LangString DESC_Desktop ${LANG_ENGLISH} "Put an ${APPNAME} shortcut on the desktop."
LangString DESC_Startup ${LANG_ENGLISH} "Open ${APPNAME} when you sign in to Windows so you receive calls."
LangString DESC_Server ${LANG_ENGLISH} "Chat, call and AI servers on this PC for testing with phones on the same Wi-Fi. Requires Docker Desktop."
!insertmacro MUI_FUNCTION_DESCRIPTION_BEGIN
  !insertmacro MUI_DESCRIPTION_TEXT ${SecApp} $(DESC_App)
  !insertmacro MUI_DESCRIPTION_TEXT ${SecDesktop} $(DESC_Desktop)
  !insertmacro MUI_DESCRIPTION_TEXT ${SecStartup} $(DESC_Startup)
  !insertmacro MUI_DESCRIPTION_TEXT ${SecServer} $(DESC_Server)
!insertmacro MUI_FUNCTION_DESCRIPTION_END

Function RunServerSetup
  ${If} ${SectionIsSelected} ${SecServer}
    Exec 'powershell.exe -NoExit -ExecutionPolicy Bypass -File "${SERVERDATA}\deploy\setup-local.ps1"'
  ${EndIf}
FunctionEnd

; ---------------------------------------------------------------- uninstall
Function un.onInit
  SetRegView 64
  SetShellVarContext all
FunctionEnd

Section "Uninstall"
  nsExec::Exec 'taskkill /IM ${EXE} /F'
  ReadRegStr $0 HKLM "${UNINSTKEY}" "ServerInstalled"
  ${If} $0 == "1"
    MessageBox MB_YESNO|MB_ICONQUESTION "Also stop the local server and remove its files?$\r$\n$\r$\nChats stored on this server are kept in Docker volumes unless you delete them in Docker Desktop." IDNO keepServer
      nsExec::Exec 'cmd /c cd /d "${SERVERDATA}\deploy" && docker compose -f docker-compose.yml -f docker-compose.local.yml down'
      RMDir /r "${SERVERDATA}"
      RMDir "$APPDATA\Amer Teams"
    keepServer:
    nsExec::Exec 'netsh advfirewall firewall delete rule name="Amer Teams Server (web)"'
    nsExec::Exec 'netsh advfirewall firewall delete rule name="Amer Teams Server (media)"'
  ${EndIf}
  nsExec::Exec 'netsh advfirewall firewall delete rule name="Amer Teams"'
  DeleteRegValue HKLM "Software\Microsoft\Windows\CurrentVersion\Run" "AmerTeams"
  Delete "$DESKTOP\${APPNAME}.lnk"
  RMDir /r "$SMPROGRAMS\${APPNAME}"
  RMDir /r "$INSTDIR"
  DeleteRegKey HKLM "${UNINSTKEY}"
SectionEnd
