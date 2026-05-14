use log::{debug, info, warn, error, LevelFilter};
use std::env;
use std::fs;
use std::str;
use std::collections::HashMap;
use std::sync::Arc;
use url;
use std::{thread, time};
use std::io;
use futures_util::{future, pin_mut, StreamExt};
use tokio::io::{AsyncReadExt};
use tokio::sync::{Mutex, mpsc as tokio_mpsc};
use tokio_tungstenite::{connect_async, tungstenite::protocol::Message};
use tokio::time::{sleep};

mod config;
mod edge_system;
mod tcp_to_websocket;
mod webrtc_session;

#[cfg(not(target_os = "windows"))]
mod camera_pipeline;
#[cfg(not(target_os = "windows"))]
mod camera_manager;
#[cfg(not(target_os = "windows"))]
mod clip_stream;
#[cfg(not(target_os = "windows"))]
mod event_store;
#[cfg(not(target_os = "windows"))]
mod rtsp_camera;
#[cfg(not(target_os = "windows"))]
mod yolo;

#[cfg(unix)]
use tokio::net::UnixListener;
#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;

#[tokio::main]
async fn main() {
    #[cfg(target_os = "windows")]
    {
        let log_dir = std::env::var("APPDATA")
            .map(std::path::PathBuf::from)
            .unwrap_or_else(|_| std::path::PathBuf::from("."))
            .join("EdgeOS");
        std::fs::create_dir_all(&log_dir).ok();
        let log_file = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(log_dir.join("edge.log"))
            .expect("cannot open log file");
        env_logger::Builder::from_env(
            env_logger::Env::default().default_filter_or("info"),
        )
        .target(env_logger::Target::Pipe(Box::new(log_file)))
        .init();
    }
    #[cfg(not(target_os = "windows"))]
    {
        env_logger::init();
        log::set_max_level(LevelFilter::Debug);
    }

    #[cfg(not(target_os = "windows"))]
    gstreamer::init().expect("GStreamer init failed");

    let local_working_dir = match env::var("EDGE_OS_EDGE_DIR") {
        Ok(val) => val,
        Err(_e) => "/opt/edge-os-edge".to_string(),
    };

    let uuid = config::get_device_id(local_working_dir.clone());
    let password = config::get_device_password(local_working_dir.clone());
    info!("Starting edge-os-edge: {uuid}");

    let (cloud, team_hash) = read_config(&local_working_dir);

    let cloud_server_url = format!("{}/et/{}/{}/{}/websocket", cloud, team_hash, uuid, password);
    info!("Connecting to: {cloud_server_url}");

    // Start camera manager on non-Windows platforms
    #[cfg(not(target_os = "windows"))]
    let cam_dir = local_working_dir.clone();
    #[cfg(not(target_os = "windows"))]
    let (frame_map, event_store) = camera_manager::start(&cam_dir).await;
    #[cfg(not(target_os = "windows"))]
    let frame_map_http   = Arc::clone(&frame_map);
    #[cfg(not(target_os = "windows"))]
    let frame_map_webrtc = Arc::clone(&frame_map);
    #[cfg(not(target_os = "windows"))]
    let event_store_http  = Arc::clone(&event_store);
    #[cfg(not(target_os = "windows"))]
    let event_store_webrtc = Arc::clone(&event_store);
    #[cfg(not(target_os = "windows"))]
    tokio::spawn(async move {
        camera_manager::serve(frame_map_http, &cam_dir, event_store_http, 4001).await;
    });

    write_status(&local_working_dir, "connecting", &cloud);

    let (ping_tx, ping_rx) = futures_channel::mpsc::unbounded();
    tokio::spawn(start_pinging(ping_tx.clone()));
    tokio::spawn(custom_metrics(ping_tx.clone()));

    let url = url::Url::parse(&cloud_server_url).unwrap();
    let (ws_stream, _) = connect_async(url).await.expect("WebSocket failed to connect");
    debug!("WebSocket handshake has been successfully completed");

    write_status(&local_working_dir, "connected", &cloud);

    let (write, read) = ws_stream.split();
    let ping_to_ws = ping_rx.map(Ok).forward(write);

    // keyed by session_id, routes incoming ICE_CANDIDATE messages to the right WebRTC task
    let webrtc_sessions: Arc<Mutex<HashMap<String, tokio_mpsc::UnboundedSender<String>>>> =
        Arc::new(Mutex::new(HashMap::new()));

    let signaling_tx = ping_tx.clone();
    let cloud_ref = cloud.clone();
    let uuid_ref = uuid.clone();
    #[cfg(not(target_os = "windows"))]
    let frame_map_ref   = frame_map_webrtc;
    #[cfg(not(target_os = "windows"))]
    let event_store_ref = event_store_webrtc;

    let ws_to_edge = {
        read.for_each(move |message| {
            let sessions     = Arc::clone(&webrtc_sessions);
            let signaling_tx = signaling_tx.clone();
            let cloud        = cloud_ref.clone();
            let uuid         = uuid_ref.clone();
            #[cfg(not(target_os = "windows"))]
            let frame_map    = Arc::clone(&frame_map_ref);
            #[cfg(not(target_os = "windows"))]
            let event_store  = Arc::clone(&event_store_ref);
            async move {
                let command_str = message.unwrap().to_string();

                if command_str.is_empty() {
                    return;
                }

                info!("[cloud→edge] {}", command_str);

                let mut parts = command_str.splitn(2, ' ');
                let command = parts.next().unwrap_or("");
                let payload = parts.next().unwrap_or("");

                match command {
                    "" => handle_pong(),

                    "SSH" => {
                        let session_id_str = payload.to_string();
                        let cloud_value = cloud.clone();
                        let uuid_value = uuid.clone();
                        debug!("creating ssh session with: {}", command_str);

                        thread::spawn(move || {
                            tcp_to_websocket::start_tcp_to_websocket_bridge(cloud_value, uuid_value, session_id_str)
                        });

                        info!("ssh session created with: {}", command_str);
                    }

                    "WEBRTC_OFFER" => {
                        let json = payload.to_string();
                        let session_id = webrtc_session::extract_session_id(&json).unwrap_or_default();
                        let connection_type = webrtc_session::extract_connection_type(&json);
                        let (ice_tx, ice_rx) = tokio_mpsc::unbounded_channel();
                        sessions.lock().await.insert(session_id.clone(), ice_tx);
                        let tx = signaling_tx.clone();
                        match connection_type.as_str() {
                            "rdp" => {
                                tokio::spawn(webrtc_session::handle_rdp_offer(json, tx, ice_rx));
                            }
                            #[cfg(not(target_os = "windows"))]
                            "camera" => {
                                tokio::spawn(webrtc_session::handle_camera_offer(json, tx, ice_rx, frame_map, event_store));
                            }
                            #[cfg(not(target_os = "windows"))]
                            "camera_video" => {
                                let offer: webrtc_session::OfferPayload =
                                    match serde_json::from_str(&json) {
                                        Ok(p) => p,
                                        Err(e) => { warn!("bad camera_video offer: {e}"); return; }
                                    };
                                let camera_id = offer.camera_id.clone().unwrap_or_default();
                                let cmd_tx = frame_map.lock().await
                                    .get(&camera_id)
                                    .and_then(|s| s.pipeline.as_ref())
                                    .map(|p| p.cmd_tx.clone());
                                match cmd_tx {
                                    Some(tx_pipe) => {
                                        let _ = tx_pipe.send(
                                            camera_pipeline::PipelineCmd::AddViewer {
                                                session_id: session_id.clone(),
                                                offer,
                                                signaling_tx: tx,
                                                ice_rx,
                                            }
                                        ).await;
                                    }
                                    None => warn!("no pipeline for camera {camera_id}"),
                                }
                            }
                            _ => {
                                tokio::spawn(webrtc_session::handle_webrtc_offer(json, tx, ice_rx));
                            }
                        };
                        info!("WebRTC {} offer received for session {}", connection_type, session_id);
                    }

                    "ICE_CANDIDATE" => {
                        let json = payload.to_string();
                        let session_id = webrtc_session::extract_session_id(&json).unwrap_or_default();
                        let lock = sessions.lock().await;
                        match lock.get(&session_id) {
                            Some(ice_tx) => { let _ = ice_tx.send(json); }
                            None => warn!("no active WebRTC session for ICE candidate {}", session_id),
                        }
                    }

                    "WEBRTC_CLOSE" => {
                        let json = payload.to_string();
                        let session_id = webrtc_session::extract_session_id(&json).unwrap_or_default();
                        sessions.lock().await.remove(&session_id);
                        #[cfg(not(target_os = "windows"))]
                        {
                            let map = frame_map.lock().await;
                            for state in map.values() {
                                if let Some(pipe) = &state.pipeline {
                                    let _ = pipe.cmd_tx.send(
                                        camera_pipeline::PipelineCmd::RemoveViewer {
                                            session_id: session_id.clone(),
                                        }
                                    ).await;
                                }
                            }
                        }
                        info!("WEBRTC_CLOSE: session {} removed", session_id);
                    }

                    _ => warn!("unknown message: '{}'", command_str),
                }
            }
        })
    };

    pin_mut!(ping_to_ws, ws_to_edge);
    future::select(ping_to_ws, ws_to_edge).await;

    write_status(&local_working_dir, "disconnected", &cloud);
}

fn read_config(dir: &str) -> (String, String) {
    let path = format!("{}/config.json", dir);
    if let Ok(content) = fs::read_to_string(&path) {
        if let Ok(v) = serde_json::from_str::<serde_json::Value>(&content) {
            let url  = v.get("cloud_url").and_then(|v| v.as_str()).map(str::to_string);
            let hash = v.get("team_hash").and_then(|v| v.as_str()).map(str::to_string);
            if let (Some(u), Some(h)) = (url, hash) {
                return (u, h);
            }
        }
    }
    let cloud = env::var("EDGE_OS_CLOUD_URL")
        .unwrap_or_else(|_| "ws://127.0.0.1:4000".to_string());
    let hash = env::var("EDGE_OS_CLOUD_TEAM_HASH")
        .unwrap_or_else(|_| "Q6rL8ENP9lYV97wzpxKGR2ybZ".to_string());
    (cloud, hash)
}

fn write_status(dir: &str, status: &str, cloud_url: &str) {
    use std::time::{SystemTime, UNIX_EPOCH};
    let ts = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    let json = format!(
        r#"{{"status":"{}","cloud_url":"{}","updated_at":{}}}"#,
        status, cloud_url, ts
    );
    let path = format!("{}/status.json", dir);
    if let Err(e) = fs::write(&path, &json) {
        error!("failed to write status file {}: {}", path, e);
    }
}

async fn start_pinging(tx: futures_channel::mpsc::UnboundedSender<Message>) {
    let twenty = 20;
    let twenty_secs = time::Duration::from_secs(twenty);

    thread::sleep(time::Duration::from_secs(3));
    let system_info = edge_system::get_edge_info();
    let system_info_payload = format!("EDGE_INFO {}", system_info);
    tx.unbounded_send(Message::Text(system_info_payload)).unwrap();

    edge_system::get_edge_status();

    let mut time_counter = 0;
    let fifteen_count: u64 = (10 * 60) / twenty;

    loop {
        thread::sleep(twenty_secs);
        debug!("sending WebSocket ping");
        tx.unbounded_send(Message::Ping(vec![])).unwrap();
        time_counter += 1;

        if time_counter % fifteen_count == 0 {
            let system_status = edge_system::get_edge_status();
            let system_status_payload = format!("EDGE_STATUS {}", system_status);
            tx.unbounded_send(Message::Text(system_status_payload)).unwrap();
            time_counter = 0;
        }
    }
}

// Unix: listen on a Unix domain socket
#[cfg(unix)]
async fn handle_custom_metrics(stream: tokio::net::UnixStream, tx: futures_channel::mpsc::UnboundedSender<Message>) {
    match stream.readable().await {
        Ok(()) => {
            let mut buf = [0; 4096];
            loop {
                match stream.try_read(&mut buf) {
                    Ok(0) => {
                        warn!("got nothing from custom_metrics. probably user closing the file socket");
                        break;
                    }
                    Ok(n) => {
                        debug!("read {} bytes for custom_metrics", n);
                        match str::from_utf8(&buf[..n]) {
                            Ok(message) => {
                                info!("got custom message {}", message);
                                let custom_metrics_payload = format!("EDGE_CUSTOM {}", message);
                                tx.unbounded_send(Message::Text(custom_metrics_payload)).unwrap();
                            },
                            Err(e) => {
                                error!("Invalid UTF-8 sequence: {}", e);
                                break;
                            },
                        };
                    }
                    Err(ref e) if e.kind() == io::ErrorKind::WouldBlock => {
                        sleep(time::Duration::from_millis(300)).await;
                    }
                    Err(e) => {
                        error!("got an unknown error {}", e.kind());
                        break;
                    }
                }
            }
        },
        Err(e) => {
            error!("cannot handle data stream with error {}, ignoring... ", e);
        },
    }
}

// Windows: listen on a TCP loopback port instead of a Unix socket
#[cfg(windows)]
async fn handle_custom_metrics(mut stream: tokio::net::TcpStream, tx: futures_channel::mpsc::UnboundedSender<Message>) {
    let mut buf = [0u8; 4096];
    loop {
        match stream.read(&mut buf).await {
            Ok(0) => {
                warn!("custom_metrics client disconnected");
                break;
            }
            Ok(n) => {
                debug!("read {} bytes for custom_metrics", n);
                match str::from_utf8(&buf[..n]) {
                    Ok(message) => {
                        info!("got custom message {}", message);
                        let custom_metrics_payload = format!("EDGE_CUSTOM {}", message);
                        tx.unbounded_send(Message::Text(custom_metrics_payload)).unwrap();
                    }
                    Err(e) => {
                        error!("Invalid UTF-8 sequence: {}", e);
                        break;
                    }
                }
            }
            Err(e) => {
                error!("custom_metrics read error: {}", e);
                break;
            }
        }
    }
}

#[cfg(unix)]
async fn custom_metrics(tx: futures_channel::mpsc::UnboundedSender<Message>) {
    let file_socket = "/tmp/edge-os-custom.sock";
    fs::remove_file(file_socket).unwrap_or(());
    let listener = UnixListener::bind(file_socket).unwrap();

    let mut perms = fs::metadata(file_socket).unwrap().permissions();
    perms.set_mode(0o666);
    fs::set_permissions(file_socket, perms).unwrap();

    info!("custom_metrics thread started");

    loop {
        match listener.accept().await {
            Ok((stream, _addr)) => {
                debug!("new custom_metrics client connected");
                tokio::spawn(handle_custom_metrics(stream, tx.clone()));
            }
            Err(e) => {
                error!("Error with custom metrics: {}", e);
            }
        }
    }
}

#[cfg(windows)]
async fn custom_metrics(tx: futures_channel::mpsc::UnboundedSender<Message>) {
    use tokio::net::TcpListener;
    let listener = TcpListener::bind("127.0.0.1:9393").await.unwrap();
    info!("custom_metrics thread started on 127.0.0.1:9393");
    loop {
        match listener.accept().await {
            Ok((stream, _addr)) => {
                debug!("new custom_metrics client connected");
                tokio::spawn(handle_custom_metrics(stream, tx.clone()));
            }
            Err(e) => {
                error!("Error with custom metrics: {}", e);
            }
        }
    }
}

async fn _read_stdin(tx: futures_channel::mpsc::UnboundedSender<Message>) {
    let mut stdin = tokio::io::stdin();
    loop {
        let mut buf = vec![0; 1024];
        let n = match stdin.read(&mut buf).await {
            Err(_) | Ok(0) => break,
            Ok(n) => n,
        };
        buf.truncate(n);
        tx.unbounded_send(Message::binary(buf)).unwrap();
    }
}

fn handle_pong() {
    // debug!("getting pong");
}
