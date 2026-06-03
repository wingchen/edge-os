# EdgeOS Windows Service — Recovery Configuration & Monitor
#
# Run as Administrator after installing EdgeOS on a Windows machine.
# The NSIS installer sets these automatically on fresh installs, but
# run this manually if you installed before the fix or need to re-apply.
#
# Usage:
#   .\windows-service-recovery.ps1           — apply recovery settings only
#   .\windows-service-recovery.ps1 -Monitor  — apply settings then watch for restart

param(
    [switch]$Monitor
)

# ── Apply failure recovery settings ──────────────────────────────────────────
#
# reset= 60 : failure counter resets after the service has been running 60s
#             without issue — gives effectively unlimited restarts for transient
#             WebSocket disconnects.
# actions   : restart after 5s, then 10s, then 30s on repeated rapid failures.
# failureflag 1 : trigger restart actions even on non-zero clean exit
#                 (needed because our service reports SERVICE_STOPPED with
#                  exit code 1 on unexpected WebSocket drop).

Write-Host "Applying failure recovery settings..."
sc.exe failure EdgeOS reset= 60 actions= restart/5000/restart/10000/restart/30000
sc.exe failureflag EdgeOS 1

Write-Host ""
Write-Host "Current failure recovery config:"
sc.exe qfailure EdgeOS

if (-not $Monitor) { exit }

# ── Monitor: watch for stop → auto-restart ───────────────────────────────────
#
# Run this before restarting the cloud server to verify that SCM automatically
# restarts the service after a WebSocket drop (exit code 1).
#
# Expected sequence:
#   1. Service goes STOPPED with WIN32_EXIT_CODE: 1
#   2. SCM waits 5 seconds (first failure action)
#   3. Service returns to RUNNING automatically

Write-Host ""
Write-Host "Monitoring service state (Ctrl+C to stop)..."
Write-Host "Restart the cloud server now to trigger a WebSocket drop."
Write-Host ""

while ($true) {
    $query  = sc.exe query EdgeOS
    $state  = ($query | Select-String "STATE").ToString().Trim()
    $exit   = ($query | Select-String "WIN32_EXIT_CODE").ToString().Trim()

    if ($state -match "STOPPED") {
        Write-Host "$(Get-Date -Format 'HH:mm:ss') — STOPPED"
        Write-Host "  $exit"
        Write-Host "  Waiting for SCM to restart (expect ~5s)..."

        # Poll until running again or give up after 60s
        $deadline = (Get-Date).AddSeconds(60)
        while ((Get-Date) -lt $deadline) {
            Start-Sleep 1
            $s = (sc.exe query EdgeOS | Select-String "STATE").ToString()
            if ($s -match "RUNNING") {
                Write-Host "$(Get-Date -Format 'HH:mm:ss') — RUNNING (SCM restarted successfully)"
                exit 0
            }
        }
        Write-Host "$(Get-Date -Format 'HH:mm:ss') — still not running after 60s, SCM did not restart"
        exit 1
    }

    Write-Host "$(Get-Date -Format 'HH:mm:ss') — $state"
    Start-Sleep 2
}
