; EdgeOS Windows Service install/update hook.
; Tauri calls NSIS_HOOK_PREINSTALL before copying app files,
; and NSIS_HOOK_POSTINSTALL after. The installer already runs elevated.
;
;   PREINSTALL  — silently disables and stops the service (best-effort, no dialog).
;   POSTINSTALL — copies binary silently; if still locked, skips copy and continues.
;                 Starts service silently on upgrades/reinstalls; only shows a
;                 dialog if start fails, offering to open Services.
;
; PATH NOTE — use $SYSDIR for sc.exe everywhere:
;   $SYSDIR always resolves to the real System32 in NSIS regardless of whether
;   the installer is 32-bit or 64-bit (NSIS disables WOW64 redirection internally).
;   $WINDIR\Sysnative is only visible to 32-bit processes — Tauri's NSIS installer
;   is 64-bit so Sysnative does not exist and sc.exe calls via that path fail silently.
;   cmd.exe children also use $SYSDIR in their embedded path strings.

!include "LogicLib.nsh"

!macro NSIS_HOOK_PREINSTALL

  StrCpy $R9 "$SYSDIR\sc.exe"

  ; Silently disable and stop the service so it does not restart during the
  ; file copy. If the service is not registered (fresh install) these fail
  ; silently — that is fine. No dialog, no polling.
  nsExec::Exec '"$R9" config EdgeOS start= disabled'
  Pop $R0
  nsExec::Exec '"$R9" stop EdgeOS'
  Pop $R0

!macroend

!macro NSIS_HOOK_POSTINSTALL

  ; ── Data directory ─────────────────────────────────────────────────────────
  CreateDirectory "C:\ProgramData\EdgeOS"

  ; Grant Users:(OI)(CI)Modify so the non-elevated Tauri app can write
  ; config.json and status.json without a UAC prompt.
  nsExec::Exec 'icacls "C:\ProgramData\EdgeOS" /grant "Users:(OI)(CI)M" /T'
  Pop $R0

  ; ── Machine environment variable ───────────────────────────────────────────
  WriteRegStr HKLM \
    "SYSTEM\CurrentControlSet\Control\Session Manager\Environment" \
    "EDGE_OS_EDGE_DIR" "C:\ProgramData\EdgeOS"

  ; ── Copy sidecar binary ───────────────────────────────────────────────────
  ; PREINSTALL already stopped the service. If the binary is still locked for
  ; any reason, skip the copy silently and move on — the rest of the install
  ; (config, service registration, failure recovery) still completes normally.
  ClearErrors
  CopyFiles /SILENT "$INSTDIR\edge-os-edge.exe" "C:\ProgramData\EdgeOS\edge-os-edge.exe"
  ClearErrors

  ; ── Version file ───────────────────────────────────────────────────────────
  FileOpen $R0 "C:\ProgramData\EdgeOS\version" w
  FileWrite $R0 "${VERSION}"
  FileClose $R0

  StrCpy $R9 "$SYSDIR\sc.exe"

  ; ── Detect existing service ────────────────────────────────────────────────
  nsExec::ExecToStack '"$R9" query EdgeOS'
  Pop $R2  ; 0 = service exists (upgrade), non-zero = fresh install
  Pop $R1

  ; ── Service: register (fresh) or re-enable (upgrade) ──────────────────────
  ${If} $R2 == "0"
    nsExec::Exec '"$R9" config EdgeOS start= auto'
    Pop $R0
  ${Else}
    nsExec::Exec '"$R9" create EdgeOS binPath= "C:\ProgramData\EdgeOS\edge-os-edge.exe" start= demand DisplayName= "EdgeOS Edge"'
    Pop $R0
    nsExec::Exec '"$R9" description EdgeOS "EdgeOS edge daemon"'
    Pop $R0
  ${EndIf}

  ; ── Failure recovery ───────────────────────────────────────────────────────
  ; reset= 60: failure counter resets after the service has been running 60 s without issue,
  ; giving effectively unlimited restarts for transient disconnects.
  nsExec::Exec '"$R9" failure EdgeOS reset= 60 actions= restart/5000/restart/10000/restart/30000'
  Pop $R0
  nsExec::Exec '"$R9" failureflag EdgeOS 1'
  Pop $R0

  ; ── Start the service automatically ──────────────────────────────────────
  ; For upgrades and reinstalls (config.json already exists), start silently
  ; with no prompt — success needs no popup. Only show a dialog on failure.
  ; Fresh installs without config.json skip this; the Tauri setup wizard
  ; handles first-time configuration and will start the service from there.
  StrCpy $R3 "0"
  ${If} $R2 == "0"
    StrCpy $R3 "1"
  ${Else}
    IfFileExists "C:\ProgramData\EdgeOS\config.json" 0 +2
      StrCpy $R3 "1"
  ${EndIf}

  ${If} $R3 == "1"
    nsExec::Exec '"$R9" start EdgeOS'
    Pop $R0
    Sleep 3000

    nsExec::ExecToStack '$SYSDIR\cmd.exe /c "$SYSDIR\sc.exe" query EdgeOS | "$SYSDIR\findstr.exe" RUNNING'
    Pop $R4
    Pop $R5
    ${If} $R4 != "0"
      ; Service did not start — offer Services so the user can start manually.
      MessageBox MB_YESNO \
        "The EdgeOS service did not start automatically.$\n$\n\
Click Yes to open Windows Services where you can start it manually$\n\
(find $\"EdgeOS Edge$\" in the list, right-click $\"Start$\").$\n$\n\
Click No to finish the installation and start it later." \
        IDNO postinstall_no_start
      ExecShell "" "services.msc"
    ${EndIf}

    postinstall_no_start:
  ${EndIf}

!macroend
