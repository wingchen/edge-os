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
;   Upgrade        — PREINSTALL stops and force-kills the process so the file
;                    lock is released before Tauri (and then our copy) touches it.
;                    POSTINSTALL copies the new binary and restarts the service.

!include "LogicLib.nsh"

!macro NSIS_HOOK_PREINSTALL

  ; Only act if the service exists (safe no-op on fresh install).
  nsExec::ExecToStack 'sc.exe query EdgeOS'
  Pop $R0  ; 0 = service exists
  Pop $R1

  ${If} $R0 == "0"
    ; Clean stop via SCM — does NOT trigger failure-recovery restart.
    ; (taskkill /F looks like a crash: SCM would restart the process after 5 s,
    ; re-locking the binary before POSTINSTALL's CopyFiles runs.)
    nsExec::Exec 'sc.exe stop EdgeOS'
    Pop $R0

    ; Wait up to 10 s for the service to reach STOPPED state.
    StrCpy $R2 0
    ${While} $R2 < 20
      Sleep 500
      nsExec::ExecToStack 'cmd /c sc.exe query EdgeOS | findstr STOPPED'
      Pop $R3  ; 0 = STOPPED found in output
      Pop $R4
      ${If} $R3 == "0"
        ${Break}
      ${EndIf}
      IntOp $R2 $R2 + 1
    ${EndWhile}
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
  ; The process was killed in PREINSTALL so there is no file lock.
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
