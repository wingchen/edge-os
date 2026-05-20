; EdgeOS Windows Service install/update hook.
; Tauri calls NSIS_HOOK_PREINSTALL before copying app files,
; and NSIS_HOOK_POSTINSTALL after. The installer already runs elevated.
;
;   Fresh install  — PREINSTALL: no-op (service not registered yet).
;                    POSTINSTALL: creates data dir, copies binary, registers
;                    service as demand-start. Offers to start immediately
;                    if config.json already exists.
;
;   Upgrade        — PREINSTALL: detects existing service, asks user to stop
;                    it via a dialog before the file copy proceeds.
;                    POSTINSTALL: copies new binary, offers to start service.
;
; PATH NOTE — Sysnative vs System32 inside child processes:
;   $WINDIR\Sysnative is a virtual folder only visible to 32-bit processes.
;   32-bit NSIS can use it to launch the real 64-bit sc.exe or cmd.exe.
;   BUT: once inside a 64-bit cmd.exe child, Sysnative does not exist.
;   Any sc.exe / findstr.exe paths embedded in a cmd /c "..." string must use
;   $WINDIR\System32 (the real directory, always accessible to 64-bit processes).
;   Direct nsExec calls from NSIS itself still use $WINDIR\Sysnative.

!include "LogicLib.nsh"

!macro NSIS_HOOK_PREINSTALL

  ; $R9 = sc.exe for direct nsExec calls (32-bit NSIS → Sysnative works).
  StrCpy $R9 "$WINDIR\Sysnative\sc.exe"

  ; Check if the service is registered at all (exit 0 = exists, upgrade path).
  ; This is a direct call — no pipe, no 64-bit cmd.exe, no Sysnative issues.
  nsExec::ExecToStack '"$R9" query EdgeOS'
  Pop $R0  ; exit code: 0 = service exists
  Pop $R1  ; output (discard)

  ${If} $R0 == "0"
    ; Service is registered — ask the user to stop it before we replace the binary.
    MessageBox MB_YESNO "The EdgeOS service must be stopped before updating.$\n$\nStop it now and continue the installation?" \
      IDYES preinstall_do_stop
      Abort "Installation cancelled. Stop the EdgeOS service and run the installer again."
    preinstall_do_stop:

    ; Disable first so SCM failure-recovery actions cannot restart it
    ; between our stop and the file copy. POSTINSTALL restores start= auto.
    nsExec::Exec '"$R9" config EdgeOS start= disabled'
    Pop $R0
    nsExec::Exec '"$R9" stop EdgeOS'
    Pop $R0

    ; Poll up to 15 s for the process to fully exit and release the file lock.
    ; sc stop is asynchronous — exit code 0 means the signal was sent, not
    ; that the process has terminated.
    ;
    ; Use $WINDIR\System32 paths inside the 64-bit cmd.exe pipe (not Sysnative —
    ; see PATH NOTE above).
    StrCpy $R3 0
    preinstall_poll:
      nsExec::ExecToStack '$WINDIR\Sysnative\cmd.exe /c "$WINDIR\System32\sc.exe" query EdgeOS | "$WINDIR\System32\findstr.exe" /C:"RUNNING" /C:"PENDING"'
      Pop $R4  ; 0 = still transitioning, non-zero = fully stopped
      Pop $R5  ; output (discard)
      ${If} $R4 != "0"
        Goto preinstall_stop_done
      ${EndIf}
      IntOp $R3 $R3 + 1
      ${If} $R3 >= 15
        ; Timeout — force-kill so the file lock is released.
        nsExec::Exec '"$WINDIR\Sysnative\taskkill.exe" /F /IM edge-os-edge.exe'
        Pop $R4
        Sleep 2000
        Goto preinstall_stop_done
      ${EndIf}
      Sleep 1000
      Goto preinstall_poll
    preinstall_stop_done:
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

  ; ── Collect diagnostic state before the copy (shown only on failure) ───────
  nsExec::ExecToStack '"$WINDIR\Sysnative\sc.exe" query EdgeOS'
  Pop $R5  ; exit code (discard)
  Pop $R6  ; sc query output
  nsExec::ExecToStack '$SYSDIR\cmd.exe /c tasklist /FI "IMAGENAME eq edge-os-edge.exe" /FO CSV /NH'
  Pop $R7  ; exit code (discard)
  Pop $R8  ; tasklist output

  ; ── Copy sidecar binary to ProgramData ────────────────────────────────────
  ClearErrors
  CopyFiles /SILENT "$INSTDIR\edge-os-edge.exe" "C:\ProgramData\EdgeOS\edge-os-edge.exe"
  IfErrors postinstall_copy_failed postinstall_copy_ok

  postinstall_copy_failed:
    MessageBox MB_OK "Failed to copy edge-os-edge.exe — the service process may still be running.$\n$\n\
sc query: $R6$\ntasklist: $R8$\n$\n\
Please stop the EdgeOS service manually and run the installer again."
    Abort "Failed to copy edge-os-edge.exe."

  postinstall_copy_ok:

  ; ── Version file ───────────────────────────────────────────────────────────
  FileOpen $R0 "C:\ProgramData\EdgeOS\version" w
  FileWrite $R0 "${VERSION}"
  FileClose $R0

  ; Use 64-bit sc.exe via Sysnative for all service control.
  StrCpy $R9 "$WINDIR\Sysnative\sc.exe"

  ; ── Detect existing service ────────────────────────────────────────────────
  nsExec::ExecToStack '"$R9" query EdgeOS'
  Pop $R2  ; exit code: 0 = service exists (upgrade), non-zero = fresh install
  Pop $R1  ; stdout (discard)

  ; ── Service: register (fresh) or re-enable (upgrade) ──────────────────────
  ${If} $R2 == "0"
    ; Upgrade: binary replaced — restore auto-start (PREINSTALL disabled it).
    nsExec::Exec '"$R9" config EdgeOS start= auto'
    Pop $R0

  ${Else}
    ; Fresh install: register as demand-start (no config.json yet).
    nsExec::Exec '"$R9" create EdgeOS binPath= "C:\ProgramData\EdgeOS\edge-os-edge.exe" start= demand DisplayName= "EdgeOS Edge"'
    Pop $R0
    nsExec::Exec '"$R9" description EdgeOS "EdgeOS edge daemon"'
    Pop $R0
  ${EndIf}

  ; ── Failure recovery ───────────────────────────────────────────────────────
  nsExec::Exec '"$R9" failure EdgeOS reset= 86400 actions= restart/5000/restart/10000/restart/30000'
  Pop $R0
  nsExec::Exec '"$R9" failureflag EdgeOS 1'
  Pop $R0

  ; ── Offer to start the service now ────────────────────────────────────────
  ; Show the prompt if this is an upgrade, or a fresh install where config.json
  ; already exists (re-install / service recovery — wizard won't run again).
  StrCpy $R3 "0"  ; flag: show start prompt?
  ${If} $R2 == "0"
    StrCpy $R3 "1"  ; upgrade — always offer to start
  ${Else}
    IfFileExists "C:\ProgramData\EdgeOS\config.json" 0 +2
      StrCpy $R3 "1"  ; config exists — offer to start
  ${EndIf}

  ${If} $R3 == "1"
    MessageBox MB_YESNO "Installation complete.$\n$\nStart the EdgeOS service now?" \
      IDYES postinstall_start_service
      Goto postinstall_no_start
    postinstall_start_service:
      nsExec::Exec '"$R9" start EdgeOS'
      Pop $R0
      ${If} $R0 == "0"
        MessageBox MB_OK "EdgeOS service started successfully."
      ${Else}
        MessageBox MB_OK "EdgeOS service could not be started (error $R0).$\nYou can start it manually from Windows Services."
      ${EndIf}
    postinstall_no_start:
  ${EndIf}

!macroend
