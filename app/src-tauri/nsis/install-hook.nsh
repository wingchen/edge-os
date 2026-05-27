; EdgeOS Windows Service install/update hook.
; Tauri calls NSIS_HOOK_PREINSTALL before copying app files,
; and NSIS_HOOK_POSTINSTALL after. The installer already runs elevated.
;
;   PREINSTALL  — silently attempts to stop the service (best-effort, no dialog).
;   POSTINSTALL — copies binary; if copy fails (service still running), shows a
;                 Retry/Cancel dialog instructing the user to stop manually.
;                 Same for service start: try once, show Retry/Cancel on failure.
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

  ; ── Copy sidecar binary — retry loop ──────────────────────────────────────
  ; If edge-os-edge.exe is still running it holds a file lock on the copy in
  ; ProgramData. Ask the user to stop it and click Retry.
  postinstall_copy_retry:
    ClearErrors
    CopyFiles /SILENT "$INSTDIR\edge-os-edge.exe" "C:\ProgramData\EdgeOS\edge-os-edge.exe"
    IfErrors postinstall_copy_failed postinstall_copy_ok

  postinstall_copy_failed:
    MessageBox MB_RETRYCANCEL \
      "Could not copy edge-os-edge.exe — the EdgeOS service may still be running.$\n$\n\
To stop it manually:$\n\
  1. Press Win + R, type  services.msc  and press Enter$\n\
  2. Find $\"EdgeOS Edge$\" in the list$\n\
  3. Right-click it and choose Stop$\n\
  (Or open Task Manager, find edge-os-edge.exe under Details, and End Task.)$\n$\n\
Once stopped, click Retry to continue, or Cancel to abort." \
      IDRETRY postinstall_copy_retry
      Abort "Installation cancelled."

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
  ; reset= 60: failure counter resets after the service has been running 60 s without issue,
  ; giving effectively unlimited restarts for transient disconnects.
  nsExec::Exec '"$R9" failure EdgeOS reset= 60 actions= restart/5000/restart/10000/restart/30000'
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

    ; ── Start — try once, then let user verify manually ───────────────────
    postinstall_attempt_start:

      nsExec::Exec '"$R9" start EdgeOS'
      Pop $R0
      Sleep 3000

    postinstall_verify_start:

      nsExec::ExecToStack '$WINDIR\Sysnative\cmd.exe /c "$WINDIR\System32\sc.exe" query EdgeOS | "$WINDIR\System32\findstr.exe" RUNNING'
      Pop $R4
      Pop $R5
      ${If} $R4 == "0"
        MessageBox MB_OK "The EdgeOS service is running."
        Goto postinstall_no_start
      ${EndIf}

      MessageBox MB_YESNO \
        "EdgeOS is not running yet.$\n$\n\
To start it manually:$\n\
  1. Press Win + R, type  services.msc  and press Enter$\n\
  2. Find $\"EdgeOS Edge$\" in the list$\n\
  3. Right-click it and choose Start$\n$\n\
Once started, click Yes to verify, or No to leave it stopped." \
        IDYES postinstall_verify_start
        ; User chose No — leave it stopped, that is fine.

    postinstall_no_start:
  ${EndIf}

!macroend
