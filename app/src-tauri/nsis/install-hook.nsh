; EdgeOS Windows Service install/update hook.
; Tauri calls !insertmacro NSIS_HOOK_POSTINSTALL after copying all app files.
; The NSIS installer already runs elevated, so no UAC is needed here.
;
; Both scenarios are handled:
;
;   Fresh install  — creates data dir, copies binary, registers service (demand-start).
;                    Service starts when user completes the Tauri setup wizard.
;                    restart_daemon() then promotes it to auto-start so reboots
;                    don't fire the service before config.json exists.
;
;   Upgrade        — stops the running service FIRST (releases file lock), then
;                    replaces the binary, then restarts. Binary copy must happen
;                    after stop — Windows locks the exe of a running service.

!include "LogicLib.nsh"

!macro NSIS_HOOK_POSTINSTALL

  ; ── Data directory ─────────────────────────────────────────────────────────
  CreateDirectory "C:\ProgramData\EdgeOS"

  ; Grant Users:(OI)(CI)Modify so the non-elevated Tauri app can later write
  ; config.json and status.json without requiring another UAC prompt.
  nsExec::Exec 'icacls "C:\ProgramData\EdgeOS" /grant "Users:(OI)(CI)M" /T'
  Pop $R0

  ; ── Machine environment variable ───────────────────────────────────────────
  ; Ensures the service process always finds the data directory, even if
  ; the default fallback in the binary ever changes.
  WriteRegStr HKLM \
    "SYSTEM\CurrentControlSet\Control\Session Manager\Environment" \
    "EDGE_OS_EDGE_DIR" "C:\ProgramData\EdgeOS"

  ; ── Detect existing service and stop it before touching the binary ─────────
  ; $R2 = 0 means service already exists (upgrade), non-zero means fresh install.
  ; We save to $R2 so the result survives the Stop-Service command that follows.
  nsExec::ExecToStack 'sc query EdgeOS'
  Pop $R2  ; exit code: 0 = service exists
  Pop $R1  ; stdout (discard)

  ${If} $R2 == "0"
    ; Upgrade: stop the service so it releases the file lock on the binary.
    ; WaitForStatus only reflects SCM state — the process may still hold the
    ; file handle briefly after that. Sleep gives it time to fully exit.
    nsExec::Exec 'sc stop EdgeOS'
    Pop $R0
    Sleep 5000
  ${EndIf}

  ; ── Copy sidecar binary ────────────────────────────────────────────────────
  ; Service is now stopped (or never existed), so the binary is not file-locked.
  ; Tauri strips the target triple when bundling, so the file in $INSTDIR is
  ; always named edge-os-edge.exe.
  CopyFiles /SILENT "$INSTDIR\edge-os-edge.exe" "C:\ProgramData\EdgeOS\edge-os-edge.exe"

  ; ── Version file ───────────────────────────────────────────────────────────
  ; Written here so Tauri's check_and_update_daemon sees a matching version on
  ; first app launch and does not re-trigger the update unnecessarily.
  ; ${VERSION} is defined by Tauri's NSIS template from tauri.conf.json.
  FileOpen $R0 "C:\ProgramData\EdgeOS\version" w
  FileWrite $R0 "${VERSION}"
  FileClose $R0

  ; ── Service: restart (upgrade) or register (fresh install) ────────────────
  ${If} $R2 == "0"
    ; Upgrade: start the service with the newly copied binary.
    nsExec::Exec 'sc start EdgeOS'
    Pop $R0

  ${Else}
    ; Fresh install: register service as demand-start (no config.json yet).
    ; restart_daemon() promotes it to auto-start when credentials are saved.
    nsExec::Exec 'sc create EdgeOS binPath= "C:\ProgramData\EdgeOS\edge-os-edge.exe" start= demand DisplayName= "EdgeOS Edge"'
    Pop $R0
    nsExec::Exec 'sc description EdgeOS "EdgeOS edge daemon"'
    Pop $R0

  ${EndIf}

  ; ── Failure recovery ───────────────────────────────────────────────────────
  ; Restart on unexpected exit: 5s, 10s, 30s, then keep retrying every 30s.
  ; Reset the failure counter after 24 h of clean uptime.
  nsExec::Exec 'sc failure EdgeOS reset= 86400 actions= restart/5000/restart/10000/restart/30000'
  Pop $R0
  ; Also restart on exit code 0 (WebSocket dropped cleanly, not SCM-stopped).
  nsExec::Exec 'sc failureflag EdgeOS 1'
  Pop $R0

!macroend
