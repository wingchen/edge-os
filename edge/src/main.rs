use log::{debug, info, warn, error, LevelFilter};
use std::env;
use std::fs;
use std::str;
use url;
use std::process::{Command};
use std::collections::HashMap;
use std::sync::Arc;
use std::{thread, time};
use std::io;
use futures_util::{future, pin_mut, StreamExt};
use tokio::io::{AsyncReadExt};
use tokio::sync::Mutex;
use tokio_tungstenite::{connect_async, tungstenite::protocol::Message};
use tokio::net::UnixListener;
use tokio::time::{sleep};
use sysinfo::{PidExt, Pid, ProcessExt, System, SystemExt, Process};
use std::os::unix::fs::PermissionsExt;
use systemd_journal_logger::JournalLog;

mod config;
mod edge_system;

#[tokio::main]
async fn main() {
    JournalLog::default().install().unwrap();
    log::set_max_level(LevelFilter::Debug);

    let local_working_dir = match env::var("EDGE_OS_EDGE_DIR") {
        Ok(val) => val,
        Err(_e) => "/opt/edge-os-edge".to_string(),
    };

    let uuid = config::get_device_id(local_working_dir.clone());
    let password = config::get_device_password(local_working_dir.clone());
    info!("Starting edge-os-edge: {uuid}");

    config::get_websocat(local_working_dir.clone()).await;
    info!("websocat is properly installed");

    let team_hash = match env::var("EDGE_OS_CLOUD_TEAM_HASH") {
        Ok(val) => val,
        Err(_e) => "Q6rL8ENP9lYV97wzpxKGR2ybZ".to_string(),
    };

    let cloud = match env::var("EDGE_OS_CLOUD_URL") {
        Ok(cloud_url) => cloud_url,
        Err(_e) => "ws://127.0.0.1:4000".to_string(),
    };

    let cloud_server_url = format!("{}/et/{}/{}/{}/websocket", cloud, team_hash, uuid, password);
    info!("Connecting to: {cloud_server_url}");

    let (ping_tx, ping_rx) = futures_channel::mpsc::unbounded();
    tokio::spawn(start_pinging(ping_tx.clone()));
    tokio::spawn(custom_metrics(ping_tx.clone()));

    let url = url::Url::parse(&cloud_server_url).unwrap();
    let (ws_stream, _) = connect_async(url).await.expect("WebSocket failed to connect");
    debug!("WebSocket handshake has been successfully completed");

    let (write, read) = ws_stream.split();

    let ping_to_ws = ping_rx.map(Ok).forward(write);
    let process_map: HashMap<String, u32> = HashMap::new();
    let websocat_process_map = Arc::new(Mutex::new(process_map));

    let ws_to_edge = {
        read.for_each(|message| async {
            // getting to websocat_process to see if that's populated already
            let process_map = Arc::clone(&websocat_process_map);
            let mut locked_websocat_process_map = process_map.lock().await;

            let command_str = message.unwrap().to_string();

            if command_str == "" {
                debug!("ignoring the empty message");
            } else {
                let command_split: Vec<&str> = command_str.split_whitespace().collect();

                match &command_split[..] {
                    [""] => {
                        // it's a pong response, 
                        // use it to clean up outstanding websocat_processes a bit
                        let system = System::new_all();
                        let processes = system.processes();
                        locked_websocat_process_map.retain(|_, v| is_websocat_process(processes, *v));

                        handle_pong();
                    },

                    ["SSH", session_id] => {
                        let session_id_str = session_id.to_string();

                        match locked_websocat_process_map.get(&session_id_str) {
                            Some(&_process_id) => error!("websocat_process is already running, ignoring the command"),
                            None => {
                                let process_id = create_ssh_process(cloud.clone(), local_working_dir.clone(), uuid.clone(), session_id_str.clone());
                                locked_websocat_process_map.insert(session_id_str.clone(), process_id);
                                info!("websocat_process created at: {}", command_str);
                            }
                        }
                    },

                    ["CONNECT", session_id, port_number] => {
                        let session_id_str = session_id.to_string();
                        let port_number_u: u32 = port_number.parse().unwrap();

                        match locked_websocat_process_map.get(&session_id_str) {
                            Some(&_process_id) => error!("websocat_process is already running, ignoring the command"),
                            None => {
                                let process_id = create_connection_process(cloud.clone(), local_working_dir.clone(), uuid.clone(), session_id_str.clone(), port_number_u);
                                locked_websocat_process_map.insert(session_id_str.clone(), process_id);
                                info!("websocat_process created at: {} for port {}", command_str, port_number);
                            }
                        }
                    },

                    ["STOP_SESSION", session_id] => {
                        let session_id_str = session_id.to_string();

                        match locked_websocat_process_map.get(&session_id_str) {
                            Some(&process_id) => {
                                kill_websocat_process(process_id);
                                locked_websocat_process_map.remove(&session_id_str);
                                info!("websocat_process for session {} removed", session_id);
                            },
                            None => error!("websocat_process is not running, nothing to stop"),
                        }
                    },

                    _ => warn!("unknown message: '{}'", command_str),
                }
            }
        })
    };

    pin_mut!(ping_to_ws, ws_to_edge);
    future::select(ping_to_ws, ws_to_edge).await;
}

// send ping from time to time so that the cloud server knows
// that we are alive
async fn start_pinging(tx: futures_channel::mpsc::UnboundedSender<Message>) {
    let twenty = 20;
    let twenty_secs = time::Duration::from_secs(twenty);

    // sends the latest system info over
    // TODO: do this asycn with a random wait time to prevent a huge amount of traffic hitting server after each server update
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
            // sends system status every 15 mins
            let system_status = edge_system::get_edge_status();
            let system_status_payload = format!("EDGE_STATUS {}", system_status);
            tx.unbounded_send(Message::Text(system_status_payload)).unwrap();
            time_counter = 0;
        }
    }
}

// listen to local file socket for custom metrics uploads
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
                        // got a WouldBlock error from custom_metrics, ignoring it 
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

async fn custom_metrics(tx: futures_channel::mpsc::UnboundedSender<Message>) {
    let file_socket = "/tmp/edge-os-custom.sock";
    fs::remove_file(file_socket).unwrap_or(());
    let listener = UnixListener::bind(file_socket).unwrap();

    // change the file socket permission here
    let mut file_socket_permissions = fs::metadata(file_socket).unwrap().permissions();
    file_socket_permissions.set_mode(0o666);
    fs::set_permissions(file_socket, file_socket_permissions).unwrap();

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

// Helper method which will read data from stdin and send it along the
// sender provided. This function is used for test only.
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

fn create_tcp_to_websocat_process(cloud: String, local_working_dir: String, uuid: String, session_id: String, port: u32) -> u32 {
    let websocat_path = format!("{}/websocat", local_working_dir);
    let websocket_url = format!("{}/e-ssh/{}/{}/websocket", cloud, uuid, session_id);
    info!("tcp connecting to: {websocket_url}");

    let child = 
        Command::new(websocat_path)
            .arg("-v")
            .arg("--binary")
            .arg("--ping-interval=20")
            .arg(websocket_url)
            .arg(format!("tcp:127.0.0.1:{}", port))
            .spawn()
            .expect("failed to execute websocat");

    return child.id();
}

fn create_ssh_process(cloud: String, local_working_dir: String, uuid: String, session_id: String) -> u32 {
    return create_tcp_to_websocat_process(cloud, local_working_dir, uuid, session_id, 22);
}

fn create_connection_process(cloud: String, local_working_dir: String, uuid: String, session_id: String, port_number: u32) -> u32 {
    return create_tcp_to_websocat_process(cloud, local_working_dir, uuid, session_id, port_number);
}

fn kill_websocat_process(pid: u32) {
    let system = System::new_all();

    if is_websocat_process(system.processes(), pid) {
        info!("killing websocat_process {}", pid);
        system.process(Pid::from_u32(pid)).unwrap().kill();
    } else {
        error!("websocat_process {} does not exist, ignoring", pid)
    }
}

fn is_websocat_process(processes: &HashMap<Pid, Process>, pid: u32) -> bool {
    for (ppid, process) in &*processes {
        if pid.to_string() == ppid.to_string() && process.name().contains("websocat") {
            debug!("found websocat_process {}", pid);
            return true;
        }
    }

    return false;
}

fn handle_pong() {
    // debug!("websocat getting pong back");
}
