use log::{debug, info, error, warn};
use std::env;
use url;
use std::process::Command;
use std::process::Child;
use std::sync::Arc;
use std::{thread, time};
use futures_util::{future, pin_mut, StreamExt};
use tokio::io::{AsyncReadExt};
use tokio::sync::Mutex;
use tokio_tungstenite::{connect_async, tungstenite::protocol::Message};

mod config;

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

    let cloud_server_url = match env::var("EDGE_OS_CLOUD_URL") {
        Ok(cloud_url) => format!("{}/et?team_hash={}&uuid={}&password={}", cloud_url, team_hash, uuid, password),
        Err(_e) => format!("ws://localhost:4000/et?team_hash={}&uuid={}&password={}", team_hash, uuid, password),
    };

    info!("Connecting to: {cloud_server_url}");
    let url = url::Url::parse(&cloud_server_url).unwrap();
    let (stdin_tx, stdin_rx) = futures_channel::mpsc::unbounded();
    tokio::spawn(start_pinging(stdin_tx));

    let (ws_stream, _) = connect_async(url).await.expect("Failed to connect");
    debug!("WebSocket handshake has been successfully completed");

    let (write, read) = ws_stream.split();

    let stdin_to_ws = stdin_rx.map(Ok).forward(write);
    let websocat_process = Arc::new(Mutex::new(None));

    let ws_to_stdout = {
        read.for_each(|message| async {
            // getting to websocat_process to see if that's populated already
            let the_websocat_process = Arc::clone(&websocat_process);
            let mut websocat_process_lock = the_websocat_process.lock().await;

            let data_str = message.unwrap().to_string();

            if data_str == "START_SSH" {
                if websocat_process_lock.is_some() {
                    error!("websocat_process is already running, ignoring the command");
                } else {
                    *websocat_process_lock = create_websocat_process(local_working_dir.clone());
                    debug!("websocat_process created at: {}", data_str);
                }
            } else if data_str == "STOP_SSH" {
                if websocat_process_lock.is_some() {
                    websocat_process_lock.as_mut().unwrap().kill().expect("failed to kill websocat, leaving it hanging");
                    *websocat_process_lock = None;
                } else {
                    error!("websocat_process is not running, nothing to stop");
                }
            } else if data_str == "" {
                // do nothing, it's a ping/pong message
            } else {
                warn!("unknown message: {}", data_str);
            }
        })
    };

    pin_mut!(stdin_to_ws, ws_to_stdout);
    future::select(stdin_to_ws, ws_to_stdout).await;
}

// send ping from time to time so that the cloud server knows
// that we are alive
async fn start_pinging(tx: futures_channel::mpsc::UnboundedSender<Message>) {
    let twenty_secs = time::Duration::from_secs(20);

    loop {
        thread::sleep(twenty_secs);
        debug!("sending WebSocket ping");
        tx.unbounded_send(Message::Ping(vec![])).unwrap();
    }
}

// Helper method which will read data from stdin and send it along the
// sender provided.
async fn read_stdin(tx: futures_channel::mpsc::UnboundedSender<Message>) {
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

fn create_websocat_process(local_working_dir : String) -> Option<Child> {
    let websocat_path = format!("{}/websocat", local_working_dir);

    let child = 
        Command::new(websocat_path)
            .arg("-v")
            .arg("--text")
            .arg("ws://127.0.0.1:8080")
            .arg("tcp:127.0.0.1:22")
            .spawn()
            .expect("failed to execute websocat");

    return Some(child);
}
