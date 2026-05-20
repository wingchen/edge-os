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
;   Upgrade        — PREINSTALL disables the service (prevents SCM restart via
;                    failure actions), stops it, and polls until fully stopped
;                    so the file lock is released before CopyFiles runs.
;                    POSTINSTALL copies the new binary and restarts the service.
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

  ; $R9 = sc.exe path for direct nsExec calls (32-bit NSIS → Sysnative works).
  StrCpy $R9 "$WINDIR\Sysnative\sc.exe"

  ; Default diagnostic string (read by POSTINSTALL if CopyFiles fails).
  StrCpy $0 "PREINSTALL: service not found — fresh install, no stop needed"

  ; Check whether the service exists at all.
  ; Exit code 0 = service registered; non-zero = not installed.
  nsExec::ExecToStack '"$R9" query EdgeOS'
  Pop $R0  ; exit code
  Pop $R1  ; output (discard)

  ${If} $R0 == "0"
    StrCpy $0 "PREINSTALL: service exists — disabling and stopping"

    ; Disable the service so SCM cannot restart it via failure actions
    ; while we are copying files. POSTINSTALL restores start= auto.
    nsExec::Exec '"$R9" config EdgeOS start= disabled'
    Pop $R0

    ; Send the stop signal. Ignore non-zero — service may already be stopping.
    nsExec::Exec '"$R9" stop EdgeOS'
    Pop $R0

    ; Poll until the service leaves the RUNNING state (up to 30 s).
    ; sc stop is asynchronous: a zero exit code only means the stop signal was
    ; accepted, not that the process has exited and released the file lock.
    ;
    ; Pipe sc query through 64-bit cmd.exe. Use $WINDIR\System32\ for the
    ; sc.exe and findstr.exe paths inside the command string — Sysnative is
    ; invisible inside the 64-bit cmd.exe child (see PATH NOTE above).
    StrCpy $R2 0
    preinstall_poll:
      nsExec::ExecToStack '$WINDIR\Sysnative\cmd.exe /c "$WINDIR\System32\sc.exe" query EdgeOS | "$WINDIR\System32\findstr.exe" /C:"RUNNING" /C:"PENDING"'
      Pop $R3  ; exit code: 0 = still transitioning, non-zero = fully stopped
      Pop $R4  ; output (discard)
      ${If} $R3 != "0"
        StrCpy $0 "PREINSTALL: service stopped after $R2s"
        Goto preinstall_stop_done
      ${EndIf}
      IntOp $R2 $R2 + 1
      ${If} $R2 >= 30
        ; 30 s elapsed — force-kill so CopyFiles is not blocked by a file lock.
        StrCpy $0 "PREINSTALL: timed out after 30s — force-killed edge-os-edge.exe"
        nsExec::Exec '"$WINDIR\Sysnative\taskkill.exe" /F /IM edge-os-edge.exe'
        Pop $R3
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

  ; ── Collect diagnostic state before attempting the copy ────────────────────
  ; Stored in $R6 (sc query output) and $R8 (tasklist output).
  ; Only shown to the user if CopyFiles fails below.
  nsExec::ExecToStack '"$WINDIR\Sysnative\sc.exe" query EdgeOS'
  Pop $R5  ; exit code (discard)
  Pop $R6  ; sc query output
  nsExec::ExecToStack '$SYSDIR\cmd.exe /c tasklist /FI "IMAGENAME eq edge-os-edge.exe" /FO CSV /NH'
  Pop $R7  ; exit code (discard)
  Pop $R8  ; tasklist output

  ; ── Copy sidecar binary to ProgramData ────────────────────────────────────
  ; PREINSTALL stopped the service cleanly, so there should be no file lock.
  ; Keeping the binary at C:\ProgramData\EdgeOS avoids path-with-spaces
  ; quoting issues when registering the service via sc.exe.
  ClearErrors
  CopyFiles /SILENT "$INSTDIR\edge-os-edge.exe" "C:\ProgramData\EdgeOS\edge-os-edge.exe"
  IfErrors postinstall_copy_failed postinstall_copy_ok

  postinstall_copy_failed:
    MessageBox MB_OK "CopyFiles failed — edge-os-edge.exe may still be locked.$\n$\n\
$0$\n$\n\
sc query before copy:$\n$R6$\n\
tasklist: $R8"
    Abort "Failed to copy edge-os-edge.exe. See the diagnostic above."

  postinstall_copy_ok:

  ; ── Version file ───────────────────────────────────────────────────────────
  FileOpen $R0 "C:\ProgramData\EdgeOS\version" w
  FileWrite $R0 "${VERSION}"
  FileClose $R0

  ; Use 64-bit sc.exe via Sysnative for all service control (same reason as PREINSTALL).
  StrCpy $R9 "$WINDIR\Sysnative\sc.exe"

  ; ── Detect existing service ────────────────────────────────────────────────
  ; $R2 = 0 means service already exists (upgrade), non-zero means fresh install.
  nsExec::ExecToStack '"$R9" query EdgeOS'
  Pop $R2  ; exit code: 0 = service exists
  Pop $R1  ; stdout (discard)

  ; ── Service: restart (upgrade) or register (fresh install) ────────────────
  ${If} $R2 == "0"
    ; Upgrade: binary is replaced — re-enable and start the service.
    nsExec::Exec '"$R9" config EdgeOS start= auto'
    Pop $R0
    nsExec::Exec '"$R9" start EdgeOS'
    Pop $R0

  ${Else}
    ; Fresh install: register as demand-start (no config.json yet).
    ; install_daemon_windows() promotes to auto-start when credentials are saved.
    nsExec::Exec '"$R9" create EdgeOS binPath= "C:\ProgramData\EdgeOS\edge-os-edge.exe" start= demand DisplayName= "EdgeOS Edge"'
    Pop $R0
    nsExec::Exec '"$R9" description EdgeOS "EdgeOS edge daemon"'
    Pop $R0

    ; If config.json already exists (re-install or service recovery), the setup
    ; wizard won't run again, so promote to auto-start and start right now.
    IfFileExists "C:\ProgramData\EdgeOS\config.json" 0 no_autostart
      nsExec::Exec '"$R9" config EdgeOS start= auto'
      Pop $R0
      nsExec::Exec '"$R9" start EdgeOS'
      Pop $R0
    no_autostart:

  ${EndIf}

  ; ── Failure recovery ───────────────────────────────────────────────────────
  ; Restart on unexpected exit: 5 s, 10 s, 30 s. Reset counter after 24 h.
  nsExec::Exec '"$R9" failure EdgeOS reset= 86400 actions= restart/5000/restart/10000/restart/30000'
  Pop $R0
  ; Also restart on exit code 0 (clean WebSocket drop, not an SCM stop).
  nsExec::Exec '"$R9" failureflag EdgeOS 1'
  Pop $R0

!macroend
