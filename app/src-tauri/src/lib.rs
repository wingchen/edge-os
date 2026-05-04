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
            #[cfg(target_os = "macos")]
            check_and_update_daemon(app.handle());
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
    #[cfg(target_os = "macos")]
    {
        match daemon_process_state() {
            ProcessState::NotInstalled => {
                // First install: daemon not present yet.
                // install_daemon writes config.json + plist and loads the daemon.
                install_daemon(&cloud_url, &team_hash, &app)?;
            }
            _ => {
                // Already installed: update config then restart.
                let existing = read_full_config();
                let cameras  = existing.get("cameras").cloned().unwrap_or(serde_json::json!([]));
                let cfg      = serde_json::json!({ "cloud_url": cloud_url, "team_hash": team_hash, "cameras": cameras });
                std::fs::write(config_file_path(), cfg.to_string()).map_err(|e| e.to_string())?;
                let _ = restart_daemon();
            }
        }
    }
    #[cfg(target_os = "linux")]
    {
        let existing = read_full_config();
        let cameras  = existing.get("cameras").cloned().unwrap_or(serde_json::json!([]));
        let cfg      = serde_json::json!({ "cloud_url": cloud_url, "team_hash": team_hash, "cameras": cameras });
        std::fs::write(config_file_path(), cfg.to_string()).map_err(|e| e.to_string())?;
        let _ = restart_daemon();
    }

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
        let script = r#"do shell script "launchctl unload /Library/LaunchDaemons/com.sailoi.edgeos.plist && launchctl load -w /Library/LaunchDaemons/com.sailoi.edgeos.plist" with administrator privileges"#;
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

/// First-time installation on macOS: copies the bundled sidecar binary into
/// /Library/Application Support/EdgeOS/, writes the launchd plist, and loads
/// the daemon — all in a single osascript call that prompts for admin once.
#[cfg(target_os = "macos")]
fn install_daemon(cloud_url: &str, team_hash: &str, app: &tauri::AppHandle) -> Result<(), String> {
    let sidecar = find_sidecar_path(app)?;

    // GStreamer bundle lives in Contents/Resources/gstreamer/ inside the .app
    let resource_dir = app.path().resource_dir()
        .map_err(|e| format!("resource_dir: {e}"))?;
    let gst_lib_src    = resource_dir.join("gstreamer/lib");
    let gst_plugin_src = resource_dir.join("gstreamer/plugins");
    let has_gst_bundle = gst_lib_src.exists() && gst_plugin_src.exists();

    let edge_dir       = "/Library/Application Support/EdgeOS";
    let edge_bin       = format!("{edge_dir}/edge-os-edge");
    let gst_lib_dst    = format!("{edge_dir}/gstreamer/lib");
    let gst_plugin_dst = format!("{edge_dir}/gstreamer/plugins");
    let plist_dst      = "/Library/LaunchDaemons/com.sailoi.edgeos.plist";
    let wss_url        = cloud_url.replace("https://", "wss://").replace("http://", "ws://");

    let config_json = serde_json::json!({
        "cloud_url": cloud_url,
        "team_hash": team_hash,
        "cameras":   [],
    }).to_string();

    // GST env vars are only needed when using the bundled GStreamer
    let gst_env = if has_gst_bundle {
        format!(
            "        <key>GST_PLUGIN_PATH</key><string>{gst_plugin_dst}</string>\n\
             \x20       <key>GST_REGISTRY_1_0</key><string>{edge_dir}/gst-registry.bin</string>"
        )
    } else {
        String::new()
    };

    let plist_xml = format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.sailoi.edgeos</string>
    <key>ProgramArguments</key>
    <array><string>{edge_bin}</string></array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>EDGE_OS_EDGE_DIR</key><string>{edge_dir}</string>
        <key>EDGE_OS_CLOUD_TEAM_HASH</key><string>{team_hash}</string>
        <key>EDGE_OS_CLOUD_URL</key><string>{wss_url}</string>
        <key>RUST_LOG</key><string>info</string>
{gst_env}
    </dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>/var/log/edgeos.log</string>
    <key>StandardErrorPath</key><string>/var/log/edgeos-error.log</string>
</dict>
</plist>"#
    );

    let tmp_config = "/tmp/edgeos-config.json";
    let tmp_plist  = "/tmp/com.sailoi.edgeos.plist";
    std::fs::write(tmp_config, &config_json).map_err(|e| format!("write tmp config: {e}"))?;
    std::fs::write(tmp_plist,  &plist_xml).map_err(|e| format!("write tmp plist: {e}"))?;

    // Build the GStreamer copy commands (only if bundle is present)
    let gst_copy_cmds = if has_gst_bundle {
        format!(
            "mkdir -p '{gst_lib_dst}' '{gst_plugin_dst}' && \
             cp -R '{gst_lib_src}/.' '{gst_lib_dst}/' && \
             cp -R '{gst_plugin_src}/.' '{gst_plugin_dst}/' && ",
            gst_lib_src    = gst_lib_src.display(),
            gst_plugin_src = gst_plugin_src.display(),
        )
    } else {
        String::new()
    };

    let script = format!(
        "do shell script \
         \"mkdir -p '{edge_dir}' && chmod 775 '{edge_dir}' && \
         {gst_copy_cmds}\
         cp '{sidecar}' '{edge_bin}' && chmod 755 '{edge_bin}' && \
         cp '{tmp_config}' '{edge_dir}/config.json' && chmod 644 '{edge_dir}/config.json' && \
         mv '{tmp_plist}' '{plist_dst}' && chown root:wheel '{plist_dst}' && chmod 644 '{plist_dst}' && \
         launchctl unload '{plist_dst}' 2>/dev/null; launchctl load -w '{plist_dst}'\" \
         with administrator privileges",
        edge_dir   = edge_dir,
        sidecar    = sidecar.display(),
        edge_bin   = edge_bin,
        tmp_config = tmp_config,
        tmp_plist  = tmp_plist,
        plist_dst  = plist_dst,
    );

    let out = std::process::Command::new("osascript")
        .args(["-e", &script])
        .output()
        .map_err(|e| format!("osascript: {e}"))?;

    let _ = std::fs::remove_file(tmp_config);
    let _ = std::fs::remove_file(tmp_plist);

    if !out.status.success() {
        let err = String::from_utf8_lossy(&out.stderr);
        return Err(format!("Daemon installation failed: {err}"));
    }
    Ok(())
}

/// On every launch, check whether the installed daemon binary matches the app
/// version.  If not (user reinstalled a new DMG), copy the new sidecar over
/// the old one and restart the daemon.  The data directory is chmod 775
/// root:admin, so the copy succeeds without sudo; only the launchctl restart
/// needs the admin prompt.
#[cfg(target_os = "macos")]
fn check_and_update_daemon(app: &tauri::AppHandle) {
    if !matches!(daemon_process_state(), ProcessState::Running | ProcessState::Stopped) {
        return; // not installed yet — nothing to update
    }

    let current_version = env!("CARGO_PKG_VERSION");
    let version_file    = "/Library/Application Support/EdgeOS/version";
    let installed_ver   = std::fs::read_to_string(version_file)
        .unwrap_or_default();

    if installed_ver.trim() == current_version {
        return; // already up to date
    }

    // New version detected — copy the sidecar and restart
    let Ok(sidecar) = find_sidecar_path(app) else { return };
    let dest = "/Library/Application Support/EdgeOS/edge-os-edge";

    // The directory is chmod 775 root:admin so an admin-group user can
    // delete+recreate files without sudo.
    let _ = std::fs::remove_file(dest);
    if std::fs::copy(&sidecar, dest).is_err() { return }
    let _ = std::process::Command::new("chmod").args(["755", dest]).status();

    // Also update the bundled GStreamer. The EdgeOS dir is chmod 775 root:admin
    // so an admin-group user can create subdirectories without sudo.
    if let Ok(resource_dir) = app.path().resource_dir() {
        let gst_src = resource_dir.join("gstreamer");
        if gst_src.exists() {
            let edge_dir = "/Library/Application Support/EdgeOS";
            let gst_dst  = format!("{edge_dir}/gstreamer");
            let _ = std::process::Command::new("mkdir").args(["-p", &gst_dst]).status();
            let _ = std::process::Command::new("cp")
                .args(["-R", &format!("{}/.", gst_src.display()), &format!("{gst_dst}/")])
                .status();
        }
    }

    // Write the version file (also in the 775 dir — no sudo needed)
    let _ = std::fs::write(version_file, current_version);

    // Restart the daemon so it picks up the new binary
    let _ = restart_daemon();
}

/// Locate the bundled sidecar binary inside the running .app bundle.
/// Tauri strips the target triple when bundling, so the file is just
/// `edge-os-edge` in `Contents/MacOS/` alongside the main executable.
#[cfg(target_os = "macos")]
fn find_sidecar_path(app: &tauri::AppHandle) -> Result<std::path::PathBuf, String> {
    // resource_dir = Contents/Resources/ → parent = Contents/ → MacOS/
    let macos = app.path().resource_dir()
        .map_err(|e| format!("resource_dir: {e}"))?
        .parent()
        .map(|p| p.join("MacOS"))
        .ok_or_else(|| "could not determine Contents/MacOS path".to_string())?;

    // Exact name (what Tauri actually bundles)
    let exact = macos.join("edge-os-edge");
    if exact.exists() { return Ok(exact); }

    // Fallback scan in case a future Tauri version keeps the triple
    let entries: Vec<_> = std::fs::read_dir(&macos)
        .map(|rd| rd.flatten()
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .collect())
        .unwrap_or_default();

    for name in &entries {
        if name.starts_with("edge-os-edge") {
            return Ok(macos.join(name));
        }
    }

    Err(format!(
        "sidecar not found in {} — contents: [{}]",
        macos.display(),
        entries.join(", "),
    ))
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
