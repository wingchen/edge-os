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
;                    it. If automatic stop fails, guides user to services.msc
;                    with a Retry option.
;                    POSTINSTALL: copies new binary, offers to start service.
;                    If automatic start fails, guides user to services.msc
;                    with a Retry option.
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

  StrCpy $R9 "$WINDIR\Sysnative\sc.exe"

  ; Check if the service is registered (exit 0 = exists, upgrade path).
  nsExec::ExecToStack '"$R9" query EdgeOS'
  Pop $R0  ; exit code: 0 = service exists
  Pop $R1  ; output (discard)

  ${If} $R0 == "0"
    ; Confirm with the user before touching the running service.
    MessageBox MB_YESNO "The EdgeOS service needs to be stopped before the \
update can proceed.$\n$\nClick Yes to stop it now, or No to cancel." \
      IDYES preinstall_do_stop
      Abort "Installation cancelled."
    preinstall_do_stop:

    ; Disable so SCM failure-recovery cannot restart it during the file copy.
    ; POSTINSTALL restores start= auto.
    nsExec::Exec '"$R9" config EdgeOS start= disabled'
    Pop $R0

    ; ── Stop + poll loop ───────────────────────────────────────────────────
    ; Jumps back here if the user clicks Retry after a failed automatic stop.
    preinstall_attempt_stop:
      nsExec::Exec '"$R9" stop EdgeOS'
      Pop $R0

      StrCpy $R3 0
      preinstall_poll:
        nsExec::ExecToStack '$WINDIR\Sysnative\cmd.exe /c "$WINDIR\System32\sc.exe" query EdgeOS | "$WINDIR\System32\findstr.exe" /C:"RUNNING" /C:"PENDING"'
        Pop $R4  ; 0 = still transitioning, non-zero = fully stopped
        Pop $R5
        ${If} $R4 != "0"
          Goto preinstall_stop_done
        ${EndIf}
        IntOp $R3 $R3 + 1
        ${If} $R3 >= 15
          ; Could not stop automatically — guide the user to Services.
          MessageBox MB_RETRYCANCEL \
            "EdgeOS could not be stopped automatically.$\n$\n\
To stop it manually:$\n\
  1. Press Win + R, type  services.msc  and press Enter$\n\
  2. Find $\"EdgeOS Edge$\" in the list$\n\
  3. Right-click it and choose Stop$\n$\n\
Once stopped, click Retry to continue the installation." \
            IDRETRY preinstall_attempt_stop
            Abort "Installation cancelled. Please stop the EdgeOS service from \
Windows Services (services.msc) and run the installer again."
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
  Pop $R5
  Pop $R6  ; sc query output
  nsExec::ExecToStack '$SYSDIR\cmd.exe /c tasklist /FI "IMAGENAME eq edge-os-edge.exe" /FO CSV /NH'
  Pop $R7
  Pop $R8  ; tasklist output

  ; ── Copy sidecar binary to ProgramData ────────────────────────────────────
  ClearErrors
  CopyFiles /SILENT "$INSTDIR\edge-os-edge.exe" "C:\ProgramData\EdgeOS\edge-os-edge.exe"
  IfErrors postinstall_copy_failed postinstall_copy_ok

  postinstall_copy_failed:
    MessageBox MB_OK "Failed to copy edge-os-edge.exe — the service process \
may still be running.$\n$\nsc query: $R6$\ntasklist: $R8$\n$\n\
Please stop the EdgeOS service manually and run the installer again."
    Abort "Failed to copy edge-os-edge.exe."

  postinstall_copy_ok:

  ; ── Version file ───────────────────────────────────────────────────────────
  FileOpen $R0 "C:\ProgramData\EdgeOS\version" w
  FileWrite $R0 "${VERSION}"
  FileClose $R0

  StrCpy $R9 "$WINDIR\Sysnative\sc.exe"

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
  nsExec::Exec '"$R9" failure EdgeOS reset= 86400 actions= restart/5000/restart/10000/restart/30000'
  Pop $R0
  nsExec::Exec '"$R9" failureflag EdgeOS 1'
  Pop $R0

  ; ── Offer to start the service ────────────────────────────────────────────
  ; Show for upgrades, and for fresh installs where config.json already exists
  ; (re-install / service recovery — the setup wizard will not run again).
  StrCpy $R3 "0"
  ${If} $R2 == "0"
    StrCpy $R3 "1"
  ${Else}
    IfFileExists "C:\ProgramData\EdgeOS\config.json" 0 +2
      StrCpy $R3 "1"
  ${EndIf}

  ${If} $R3 == "1"
    MessageBox MB_YESNO "Installation complete.$\n$\nStart the EdgeOS \
service now?" IDYES postinstall_do_start
      Goto postinstall_no_start
    postinstall_do_start:

    ; ── Start + retry loop ─────────────────────────────────────────────────
    ; Jumps back here if the user clicks Retry after a failed automatic start.
    postinstall_attempt_start:

      ; Check first — user may have already started it manually via Services.
      nsExec::ExecToStack '$WINDIR\Sysnative\cmd.exe /c "$WINDIR\System32\sc.exe" query EdgeOS | "$WINDIR\System32\findstr.exe" RUNNING'
      Pop $R4  ; 0 = RUNNING found
      Pop $R5
      ${If} $R4 == "0"
        MessageBox MB_OK "The EdgeOS service is running."
        Goto postinstall_no_start
      ${EndIf}

      ; Not running yet — try to start it.
      nsExec::Exec '"$R9" start EdgeOS'
      Pop $R0

      ; Give it 3 s to reach RUNNING state, then check.
      Sleep 3000
      nsExec::ExecToStack '$WINDIR\Sysnative\cmd.exe /c "$WINDIR\System32\sc.exe" query EdgeOS | "$WINDIR\System32\findstr.exe" RUNNING'
      Pop $R4
      Pop $R5
      ${If} $R4 == "0"
        MessageBox MB_OK "The EdgeOS service started successfully."
        Goto postinstall_no_start
      ${EndIf}

      ; Could not start automatically — guide the user to Services.
      MessageBox MB_RETRYCANCEL \
        "EdgeOS could not be started automatically.$\n$\n\
To start it manually:$\n\
  1. Press Win + R, type  services.msc  and press Enter$\n\
  2. Find $\"EdgeOS Edge$\" in the list$\n\
  3. Right-click it and choose Start$\n$\n\
Once started, click Retry to confirm, or Cancel to leave it stopped." \
        IDRETRY postinstall_attempt_start
        ; User chose to leave it stopped — that is fine, the Tauri setup wizard
        ; or the user can start it from Services later.
    postinstall_no_start:
  ${EndIf}

!macroend
