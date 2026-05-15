; EdgeOS Windows Service install/update hook.
; Tauri calls NSIS_HOOK_PREINSTALL before copying app files,
; and NSIS_HOOK_POSTINSTALL after. The installer already runs elevated.
;
;   Fresh install  — PREINSTALL is a safe no-op (service doesn't exist yet).
;                    POSTINSTALL creates the data dir, sets the env var, and
;                    registers the service pointing to $INSTDIR (demand-start).
;                    Service starts when the user saves credentials in the wizard.
;
;   Upgrade        — PREINSTALL stops and force-kills the process so Tauri can
;                    freely overwrite the binary in $INSTDIR. POSTINSTALL then
;                    updates the service binPath and restarts it.

!include "LogicLib.nsh"

!macro NSIS_HOOK_PREINSTALL

  ; Stop the service and force-kill the process before Tauri overwrites the binary.
  ; Both commands are safe no-ops if the service / process does not exist.
  nsExec::Exec 'sc stop EdgeOS'
  Pop $R0
  nsExec::Exec 'taskkill /F /IM edge-os-edge.exe'
  Pop $R0
  Sleep 1000

!macroend

!macro NSIS_HOOK_POSTINSTALL

  ; ── Data directory ─────────────────────────────────────────────────────────
  ; Config and status files live here; the service binary lives in $INSTDIR.
  CreateDirectory "C:\ProgramData\EdgeOS"

  ; Grant Users:(OI)(CI)Modify so the non-elevated Tauri app can write
  ; config.json and status.json without a UAC prompt.
  nsExec::Exec 'icacls "C:\ProgramData\EdgeOS" /grant "Users:(OI)(CI)M" /T'
  Pop $R0

  ; ── Machine environment variable ───────────────────────────────────────────
  WriteRegStr HKLM \
    "SYSTEM\CurrentControlSet\Control\Session Manager\Environment" \
    "EDGE_OS_EDGE_DIR" "C:\ProgramData\EdgeOS"

  ; ── Version file ───────────────────────────────────────────────────────────
  FileOpen $R0 "C:\ProgramData\EdgeOS\version" w
  FileWrite $R0 "${VERSION}"
  FileClose $R0

  ; ── Detect existing service ────────────────────────────────────────────────
  ; $R2 = 0 means service already exists (upgrade), non-zero means fresh install.
  nsExec::ExecToStack 'sc query EdgeOS'
  Pop $R2  ; exit code: 0 = service exists
  Pop $R1  ; stdout (discard)

  ; ── Service: restart (upgrade) or register (fresh install) ────────────────
  ${If} $R2 == "0"
    ; Upgrade: update binPath in case the install directory changed, then start.
    nsExec::Exec 'sc config EdgeOS binPath= "$INSTDIR\edge-os-edge.exe"'
    Pop $R0
    nsExec::Exec 'sc start EdgeOS'
    Pop $R0

  ${Else}
    ; Fresh install: register as demand-start (no config.json yet).
    ; restart_daemon() promotes to auto-start when credentials are saved.
    nsExec::Exec 'sc create EdgeOS binPath= "$INSTDIR\edge-os-edge.exe" start= demand DisplayName= "EdgeOS Edge"'
    Pop $R0
    nsExec::Exec 'sc description EdgeOS "EdgeOS edge daemon"'
    Pop $R0

  ${EndIf}

  ; ── Failure recovery ───────────────────────────────────────────────────────
  ; Restart on unexpected exit: 5 s, 10 s, 30 s. Reset counter after 24 h.
  nsExec::Exec 'sc failure EdgeOS reset= 86400 actions= restart/5000/restart/10000/restart/30000'
  Pop $R0
  ; Also restart on exit code 0 (clean WebSocket drop, not an SCM stop).
  nsExec::Exec 'sc failureflag EdgeOS 1'
  Pop $R0

!macroend
