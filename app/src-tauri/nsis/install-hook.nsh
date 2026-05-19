; EdgeOS Windows Service install/update hook.
; Tauri calls NSIS_HOOK_PREINSTALL before copying app files,
; and NSIS_HOOK_POSTINSTALL after. The installer already runs elevated.
;
;   Fresh install  — PREINSTALL is a safe no-op (service doesn't exist yet).
;                    POSTINSTALL creates the data dir, copies the binary to
;                    C:\ProgramData\EdgeOS (no spaces — avoids sc quoting issues),
;                    registers the service as demand-start.
;                    Service starts when the user saves credentials in the wizard.
;
;   Upgrade        — PREINSTALL clears failureflag (so a clean stop is not
;                    treated as a failure by SCM), stops the service, and waits
;                    for the process to exit so the file lock is released.
;                    POSTINSTALL copies the new binary and restarts the service.

!include "LogicLib.nsh"

!macro NSIS_HOOK_PREINSTALL

  ; Only stop the service if it is actively RUNNING.
  ; If it is already stopped (or does not exist) there is no file lock — skip.
  nsExec::ExecToStack '$SYSDIR\cmd.exe /c $SYSDIR\sc.exe query EdgeOS | $SYSDIR\findstr.exe RUNNING'
  Pop $R0  ; 0 = RUNNING found in output
  Pop $R1

  ${If} $R0 == "0"
    ; Clear failureflag so a clean stop is not treated as a failure by SCM
    ; (failureflag=1 would otherwise restart the process 5 s later).
    nsExec::Exec '$SYSDIR\sc.exe failureflag EdgeOS 0'
    Pop $R0
    ; Stop the service cleanly.
    nsExec::Exec '$SYSDIR\sc.exe stop EdgeOS'
    Pop $R0
    ${If} $R0 != "0"
      Abort "Failed to stop the EdgeOS service (exit code $R0). Please stop it manually and retry."
    ${EndIf}
    ; Give the process time to fully exit and release the file lock.
    Sleep 5000
  ${EndIf}

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

  ; ── Copy sidecar binary to ProgramData ────────────────────────────────────
  ; PREINSTALL stopped the service cleanly, so there is no file lock here.
  ; Keeping the binary at C:\ProgramData\EdgeOS avoids path-with-spaces
  ; quoting issues when registering the service via sc.exe.
  CopyFiles /SILENT "$INSTDIR\edge-os-edge.exe" "C:\ProgramData\EdgeOS\edge-os-edge.exe"

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
    ; Upgrade: binary is replaced — just start the service again.
    nsExec::Exec 'sc start EdgeOS'
    Pop $R0

  ${Else}
    ; Fresh install: register as demand-start (no config.json yet).
    ; install_daemon_windows() promotes to auto-start when credentials are saved.
    nsExec::Exec 'sc create EdgeOS binPath= "C:\ProgramData\EdgeOS\edge-os-edge.exe" start= demand DisplayName= "EdgeOS Edge"'
    Pop $R0
    nsExec::Exec 'sc description EdgeOS "EdgeOS edge daemon"'
    Pop $R0

    ; If config.json already exists (re-install or service recovery), the setup
    ; wizard won't run again, so promote to auto-start and start right now.
    IfFileExists "C:\ProgramData\EdgeOS\config.json" 0 no_autostart
      nsExec::Exec 'sc config EdgeOS start= auto'
      Pop $R0
      nsExec::Exec 'sc start EdgeOS'
      Pop $R0
    no_autostart:

  ${EndIf}

  ; ── Failure recovery ───────────────────────────────────────────────────────
  ; Restart on unexpected exit: 5 s, 10 s, 30 s. Reset counter after 24 h.
  nsExec::Exec 'sc failure EdgeOS reset= 86400 actions= restart/5000/restart/10000/restart/30000'
  Pop $R0
  ; Also restart on exit code 0 (clean WebSocket drop, not an SCM stop).
  nsExec::Exec 'sc failureflag EdgeOS 1'
  Pop $R0

!macroend
