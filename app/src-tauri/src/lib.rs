use tauri::{
    menu::{Menu, MenuItem, PredefinedMenuItem},
    tray::TrayIconBuilder,
    Manager, WebviewWindowBuilder,
};

pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .invoke_handler(tauri::generate_handler![save_config])
        .setup(|app| {
            #[cfg(target_os = "macos")]
            app.set_activation_policy(tauri::ActivationPolicy::Accessory);

            build_tray(app)?;
            start_daemon_monitor(app.handle().clone());

            // Show setup wizard on first run (no config.json yet)
            if !config_exists() {
                show_setup_window(app.handle())?;
            }

            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error running EdgeOS app");
}

// ── Setup window ─────────────────────────────────────────────────────────────

fn show_setup_window(app: &tauri::AppHandle) -> tauri::Result<()> {
    if app.get_webview_window("setup").is_none() {
        WebviewWindowBuilder::new(app, "setup", tauri::WebviewUrl::App("setup.html".into()))
            .title("EdgeOS Setup")
            .inner_size(480.0, 520.0)
            .resizable(false)
            .center()
            .build()?;
    }
    Ok(())
}

// ── Tauri command: save_config ────────────────────────────────────────────────

#[tauri::command]
fn save_config(
    cloud_url: String,
    team_hash: String,
    api_token: String,
    app: tauri::AppHandle,
) -> Result<(), String> {
    // Write config.json (directory is root:admin 775 so admin user can write)
    let config = serde_json::json!({
        "cloud_url": cloud_url,
        "team_hash": team_hash,
    });
    std::fs::write(config_file_path(), config.to_string()).map_err(|e| e.to_string())?;

    // Store API token in the OS keychain
    let entry = keyring::Entry::new("com.sailoi.edgeos", "api_token").map_err(|e| e.to_string())?;
    entry.set_password(&api_token).map_err(|e| e.to_string())?;

    // Restart daemon so it picks up the new config
    restart_daemon().map_err(|e| e.to_string())?;

    // Close setup window
    if let Some(win) = app.get_webview_window("setup") {
        let _ = win.close();
    }

    Ok(())
}

fn restart_daemon() -> std::io::Result<()> {
    #[cfg(target_os = "macos")]
    {
        let script = r#"do shell script "launchctl unload /Library/LaunchDaemons/com.sailoi.edgeos.plist && launchctl load /Library/LaunchDaemons/com.sailoi.edgeos.plist" with administrator privileges"#;
        std::process::Command::new("osascript")
            .args(["-e", script])
            .status()?;
    }

    #[cfg(target_os = "linux")]
    {
        std::process::Command::new("pkexec")
            .args(["systemctl", "restart", "edge-os"])
            .status()?;
    }

    Ok(())
}

// ── Config helpers ────────────────────────────────────────────────────────────

fn config_file_path() -> &'static str {
    #[cfg(target_os = "macos")]
    { "/Library/Application Support/EdgeOS/config.json" }
    #[cfg(target_os = "linux")]
    { "/opt/edge-os-edge/config.json" }
    #[cfg(not(any(target_os = "macos", target_os = "linux")))]
    { "" }
}

fn config_exists() -> bool {
    std::path::Path::new(config_file_path()).exists()
}

pub fn get_api_token() -> Option<String> {
    keyring::Entry::new("com.sailoi.edgeos", "api_token")
        .ok()?
        .get_password()
        .ok()
}

// ── Tray ──────────────────────────────────────────────────────────────────────

fn build_tray(app: &mut tauri::App) -> tauri::Result<()> {
    let status = MenuItem::with_id(app, "status", "● Checking...", false, None::<&str>)?;
    let sep1   = PredefinedMenuItem::separator(app)?;
    let setup  = MenuItem::with_id(app, "setup", "Settings...", true, None::<&str>)?;
    let sep2   = PredefinedMenuItem::separator(app)?;
    let quit   = MenuItem::with_id(app, "quit", "Quit EdgeOS", true, None::<&str>)?;

    let menu = Menu::with_items(app, &[&status, &sep1, &setup, &sep2, &quit])?;

    TrayIconBuilder::with_id("main")
        .tooltip("EdgeOS")
        .icon(app.default_window_icon().unwrap().clone())
        .menu(&menu)
        .menu_on_left_click(true)
        .on_menu_event(|app, event| match event.id().as_ref() {
            "quit"  => app.exit(0),
            "setup" => { let _ = show_setup_window(app); }
            _       => {}
        })
        .build(app)?;

    Ok(())
}

fn start_daemon_monitor(handle: tauri::AppHandle) {
    tauri::async_runtime::spawn(async move {
        loop {
            let text = tray_status_text();
            let _ = set_tray_status(&handle, text);
            tokio::time::sleep(std::time::Duration::from_secs(5)).await;
        }
    });
}

fn tray_status_text() -> &'static str {
    match daemon_process_state() {
        ProcessState::NotInstalled => "○ Daemon not installed",
        ProcessState::Stopped      => "○ Daemon stopped",
        ProcessState::Running      => match read_connection_status().as_deref() {
            Some("connected")    => "● Connected",
            Some("connecting")   => "◌ Connecting...",
            Some("disconnected") => "○ Disconnected",
            _                    => "● Daemon running",
        },
    }
}

// ── Daemon process state ──────────────────────────────────────────────────────

enum ProcessState { NotInstalled, Stopped, Running }

fn daemon_process_state() -> ProcessState {
    #[cfg(target_os = "macos")]
    {
        if !std::path::Path::new("/Library/LaunchDaemons/com.sailoi.edgeos.plist").exists() {
            return ProcessState::NotInstalled;
        }
        let running = std::process::Command::new("launchctl")
            .args(["list", "com.sailoi.edgeos"])
            .output()
            .map(|o| o.status.success())
            .unwrap_or(false);
        if running { ProcessState::Running } else { ProcessState::Stopped }
    }
    #[cfg(target_os = "linux")]
    {
        if !std::path::Path::new("/etc/systemd/system/edge-os.service").exists() {
            return ProcessState::NotInstalled;
        }
        let running = std::process::Command::new("systemctl")
            .args(["is-active", "--quiet", "edge-os"])
            .status()
            .map(|s| s.success())
            .unwrap_or(false);
        if running { ProcessState::Running } else { ProcessState::Stopped }
    }
    #[cfg(not(any(target_os = "macos", target_os = "linux")))]
    ProcessState::NotInstalled
}

// ── Status file IPC ───────────────────────────────────────────────────────────

fn status_file_path() -> &'static str {
    #[cfg(target_os = "macos")]
    { "/Library/Application Support/EdgeOS/status.json" }
    #[cfg(target_os = "linux")]
    { "/opt/edge-os-edge/status.json" }
    #[cfg(not(any(target_os = "macos", target_os = "linux")))]
    { "" }
}

fn read_connection_status() -> Option<String> {
    let content = std::fs::read_to_string(status_file_path()).ok()?;
    let v: serde_json::Value = serde_json::from_str(&content).ok()?;
    v.get("status")?.as_str().map(str::to_string)
}

pub fn set_tray_status(app: &tauri::AppHandle, text: &str) -> tauri::Result<()> {
    if let Some(tray) = app.tray_by_id("main") {
        if let Some(menu) = tray.menu() {
            if let Some(item) = menu.get("status") {
                if let Some(item) = item.as_menuitem() {
                    item.set_text(text)?;
                }
            }
        }
    }
    Ok(())
}
