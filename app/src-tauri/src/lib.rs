use std::sync::Mutex;
use tauri::{
    menu::{Menu, MenuItem, PredefinedMenuItem},
    tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent},
    Manager, PhysicalPosition, WebviewWindowBuilder,
};

struct StatusMenuItem(Mutex<MenuItem<tauri::Wry>>);

pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .invoke_handler(tauri::generate_handler![
            save_config,
            get_status,
            open_setup,
            open_main_window,
            quit_app,
            list_cameras,
            add_camera,
            remove_camera,
            preview_camera,
        ])
        .setup(|app| {
            #[cfg(target_os = "macos")]
            app.set_activation_policy(tauri::ActivationPolicy::Accessory);

            build_tray(app)?;
            start_daemon_monitor(app.handle().clone());

            if config_exists() {
                show_main_window(app.handle())?;
            } else {
                show_setup_window(app.handle())?;
            }

            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error running EdgeOS app");
}

// ── Status panel ──────────────────────────────────────────────────────────────

fn toggle_status_panel(app: &tauri::AppHandle, click_pos: PhysicalPosition<f64>) {
    match app.get_webview_window("status") {
        Some(win) => {
            if win.is_visible().unwrap_or(false) {
                let _ = win.hide();
            } else {
                position_and_show(&win, click_pos);
            }
        }
        None => {
            let result = WebviewWindowBuilder::new(
                app,
                "status",
                tauri::WebviewUrl::App("status.html".into()),
            )
            .title("")
            .decorations(false)
            .transparent(true)
            .always_on_top(true)
            .inner_size(320.0, 210.0)
            .resizable(false)
            .skip_taskbar(true)
            .visible(false)
            .build();

            if let Ok(win) = result {
                position_and_show(&win, click_pos);
            }
        }
    }
}

fn position_and_show(win: &tauri::WebviewWindow, click_pos: PhysicalPosition<f64>) {
    // Center panel horizontally under the click; keep it below the menu bar
    let x = (click_pos.x - 160.0).max(0.0) as i32;
    let y = (click_pos.y + 4.0) as i32;
    let _ = win.set_position(PhysicalPosition::new(x, y));
    let _ = win.show();
    let _ = win.set_focus();
}

// ── Main window ───────────────────────────────────────────────────────────────

fn show_main_window(app: &tauri::AppHandle) -> tauri::Result<()> {
    match app.get_webview_window("main-app") {
        Some(win) => {
            let _ = win.show();
            let _ = win.set_focus();
        }
        None => {
            WebviewWindowBuilder::new(app, "main-app", tauri::WebviewUrl::App("main.html".into()))
                .title("EdgeOS")
                .inner_size(900.0, 640.0)
                .min_inner_size(700.0, 500.0)
                .resizable(true)
                .build()?;
        }
    }
    Ok(())
}

#[tauri::command]
fn open_main_window(app: tauri::AppHandle) -> Result<(), String> {
    show_main_window(&app).map_err(|e| e.to_string())
}

// ── Setup window ──────────────────────────────────────────────────────────────

fn show_setup_window(app: &tauri::AppHandle) -> tauri::Result<()> {
    if app.get_webview_window("setup").is_none() {
        WebviewWindowBuilder::new(app, "setup", tauri::WebviewUrl::App("setup.html".into()))
            .title("EdgeOS Setup")
            .inner_size(440.0, 460.0)
            .resizable(false)
            .center()
            .build()?;
    } else if let Some(win) = app.get_webview_window("setup") {
        let _ = win.show();
        let _ = win.set_focus();
    }
    Ok(())
}

// ── Tauri commands ────────────────────────────────────────────────────────────

#[tauri::command]
fn get_status() -> serde_json::Value {
    let status = read_connection_status().unwrap_or_else(|| "unknown".to_string());
    let (cloud_url, team_hash) = read_config_fields();
    serde_json::json!({
        "status":     status,
        "cloud_url":  cloud_url,
        "team_hash":  team_hash,
    })
}

#[tauri::command]
fn open_setup(app: tauri::AppHandle) -> Result<(), String> {
    // Hide the status panel first
    if let Some(win) = app.get_webview_window("status") {
        let _ = win.hide();
    }
    show_setup_window(&app).map_err(|e| e.to_string())
}

#[tauri::command]
fn quit_app(app: tauri::AppHandle) {
    app.exit(0);
}

#[tauri::command]
fn save_config(
    cloud_url: String,
    team_hash: String,
    app: tauri::AppHandle,
) -> Result<(), String> {
    // Preserve existing cameras array when saving connection config
    let existing = read_full_config();
    let cameras = existing.get("cameras").cloned().unwrap_or(serde_json::json!([]));
    let config = serde_json::json!({
        "cloud_url": cloud_url,
        "team_hash": team_hash,
        "cameras":   cameras,
    });
    std::fs::write(config_file_path(), config.to_string()).map_err(|e| e.to_string())?;

    let _ = restart_daemon(); // best-effort: silently skip if daemon not installed yet

    if let Some(win) = app.get_webview_window("setup") {
        let _ = win.close();
    }

    show_main_window(&app).map_err(|e| e.to_string())?;

    Ok(())
}

async fn reload_daemon_cameras() -> Result<(), String> {
    reqwest::Client::new()
        .post("http://127.0.0.1:4001/reload")
        .send()
        .await
        .map_err(|e| e.to_string())?;
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

fn read_config_fields() -> (String, String) {
    let v = read_full_config();
    let cloud_url = v.get("cloud_url").and_then(|u| u.as_str()).unwrap_or("").to_string();
    let team_hash = v.get("team_hash").and_then(|h| h.as_str()).unwrap_or("").to_string();
    (cloud_url, team_hash)
}

fn read_full_config() -> serde_json::Value {
    std::fs::read_to_string(config_file_path())
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or(serde_json::json!({}))
}

// ── Camera commands ───────────────────────────────────────────────────────────

#[tauri::command]
fn list_cameras() -> serde_json::Value {
    let config = read_full_config();
    config.get("cameras").cloned().unwrap_or(serde_json::json!([]))
}

#[tauri::command]
async fn add_camera(name: String, rtsp_url: String, fps: Option<u32>) -> Result<String, String> {
    let id = uuid_v4();
    let mut config = read_full_config();
    let cameras = config
        .get_mut("cameras")
        .and_then(|c| c.as_array_mut());

    let entry = serde_json::json!({
        "id":       id,
        "name":     name,
        "rtsp_url": rtsp_url,
        "fps":      fps.unwrap_or(1),
    });

    match cameras {
        Some(arr) => { arr.push(entry); }
        None => { config["cameras"] = serde_json::json!([entry]); }
    }

    std::fs::write(config_file_path(), config.to_string()).map_err(|e| e.to_string())?;
    let _ = reload_daemon_cameras().await;
    Ok(id.to_string())
}

#[tauri::command]
async fn remove_camera(id: String) -> Result<(), String> {
    let mut config = read_full_config();
    if let Some(arr) = config.get_mut("cameras").and_then(|c| c.as_array_mut()) {
        arr.retain(|c| c.get("id").and_then(|v| v.as_str()) != Some(&id));
    }
    std::fs::write(config_file_path(), config.to_string()).map_err(|e| e.to_string())?;
    let _ = reload_daemon_cameras().await;
    Ok(())
}

/// Ask the edge daemon to grab one RTSP frame and return it as base64 JPEG.
/// All codec logic lives in the daemon (localhost:4001/preview).
#[tauri::command]
async fn preview_camera(rtsp_url: String) -> Result<String, String> {
    let client = reqwest::Client::new();
    let resp = tokio::time::timeout(
        std::time::Duration::from_secs(35),
        client
            .post("http://127.0.0.1:4001/preview")
            .json(&serde_json::json!({ "rtsp_url": rtsp_url }))
            .send(),
    )
    .await
    .map_err(|_| "preview timed out — is the edge daemon running?".to_string())?
    .map_err(|e| format!("failed to reach edge daemon: {e}"))?;

    if !resp.status().is_success() {
        let msg = resp.text().await.unwrap_or_default();
        return Err(msg);
    }

    let bytes = resp.bytes().await.map_err(|e| e.to_string())?;
    use base64::Engine;
    Ok(base64::engine::general_purpose::STANDARD.encode(&bytes))
}

fn uuid_v4() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    // Simple unique ID: timestamp + random suffix (no uuid dep needed)
    let ts = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis();
    format!("cam-{:x}", ts)
}

// ── Tray ──────────────────────────────────────────────────────────────────────

fn build_tray(app: &mut tauri::App) -> tauri::Result<()> {
    let status  = MenuItem::with_id(app, "status", "● Checking...", false, None::<&str>)?;
    let sep1    = PredefinedMenuItem::separator(app)?;
    let open    = MenuItem::with_id(app, "open",  "Open EdgeOS", true, None::<&str>)?;
    let setup   = MenuItem::with_id(app, "setup", "Settings…",   true, None::<&str>)?;
    let sep2    = PredefinedMenuItem::separator(app)?;
    let quit    = MenuItem::with_id(app, "quit",  "Quit EdgeOS", true, None::<&str>)?;

    // Store status item in managed state so the monitor loop can update its text
    app.manage(StatusMenuItem(Mutex::new(status.clone())));

    let menu = Menu::with_items(app, &[&status, &sep1, &open, &setup, &sep2, &quit])?;

    TrayIconBuilder::with_id("main")
        .tooltip("EdgeOS")
        .icon(app.default_window_icon().unwrap().clone())
        .menu(&menu)
        .show_menu_on_left_click(false) // left click shows status panel; right click shows menu
        .on_menu_event(|app, event| match event.id().as_ref() {
            "quit"  => app.exit(0),
            "open"  => { let _ = show_main_window(app); }
            "setup" => { let _ = show_setup_window(app); }
            _       => {}
        })
        .on_tray_icon_event(|tray, event| {
            if let TrayIconEvent::Click {
                button: MouseButton::Left,
                button_state: MouseButtonState::Up,
                position,
                ..
            } = event
            {
                toggle_status_panel(tray.app_handle(), position);
            }
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
    if let Some(state) = app.try_state::<StatusMenuItem>() {
        state.0.lock().unwrap().set_text(text)?;
    }
    Ok(())
}
