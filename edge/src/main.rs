use log::{debug, info, warn, error};
use std::env;
use url;
use std::process::Command;
use std::collections::HashMap;
use std::sync::Arc;
use std::{thread, time};
use futures_util::{future, pin_mut, StreamExt};
use tokio::io::{AsyncReadExt};
use tokio::sync::Mutex;
use tokio_tungstenite::{connect_async, tungstenite::protocol::Message};
use sysinfo::{PidExt, Pid, ProcessExt, System, SystemExt, Process};

mod config;
mod edge_system;

#[tokio::main]
async fn main() {
    env_logger::init();
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

    let url = url::Url::parse(&cloud_server_url).unwrap();
    let (stdin_tx, stdin_rx) = futures_channel::mpsc::unbounded();
    tokio::spawn(start_pinging(stdin_tx));

    let (ws_stream, _) = connect_async(url).await.expect("Failed to connect");
    debug!("WebSocket handshake has been successfully completed");

    let (write, read) = ws_stream.split();

    let stdin_to_ws = stdin_rx.map(Ok).forward(write);
    let process_map: HashMap<String, u32> = HashMap::new();
    let websocat_process_map = Arc::new(Mutex::new(process_map));

    let ws_to_stdout = {
        read.for_each(|message| async {
            // getting to websocat_process to see if that's populated already
            let process_map = Arc::clone(&websocat_process_map);
            let mut locked_websocat_process_map = process_map.lock().await;

            let command_str = message.unwrap().to_string();
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
                            let process_id = create_websocat_process(cloud.clone(), local_working_dir.clone(), uuid.clone(), session_id_str.clone());
                            locked_websocat_process_map.insert(session_id_str.clone(), process_id);
                            info!("websocat_process created at: {}", command_str);
                        }
                    }
                },

                ["STOP_SSH", session_id] => {
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

                _ => warn!("unknown message: {}", command_str),
            }
        })
    };

    pin_mut!(stdin_to_ws, ws_to_stdout);
    future::select(stdin_to_ws, ws_to_stdout).await;
}

// send ping from time to time so that the cloud server knows
// that we are alive
async fn start_pinging(tx: futures_channel::mpsc::UnboundedSender<Message>) {
    let twenty = 20;
    let twenty_secs = time::Duration::from_secs(twenty);

    // sends the latest system info over
    thread::sleep(time::Duration::from_secs(3));
    let system_info = edge_system::get_edge_info();
    let system_info_payload = format!("EDGE_INFO {}", system_info);
    tx.unbounded_send(Message::Text(system_info_payload)).unwrap();

    let mut time_counter = 0;
    let fifteen_count: u64 = (15 * 60) / twenty;

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

fn create_websocat_process(cloud: String, local_working_dir: String, uuid: String, session_id: String) -> u32 {
    let websocat_path = format!("{}/websocat", local_working_dir);
    let ssh_websocket_url = format!("{}/e-ssh/{}/{}/websocket", cloud, uuid, session_id);
    info!("ssh connecting to: {ssh_websocket_url}");

    let child = 
        Command::new(websocat_path)
            .arg("-v")
            // .arg("--oneshot")
            .arg("--binary")
            .arg("--ping-interval=20")
            .arg(ssh_websocket_url)
            .arg("tcp:127.0.0.1:22")
            .spawn()
            .expect("failed to execute websocat");

    return child.id();
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
