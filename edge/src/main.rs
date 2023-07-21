use log::{debug, info, warn, error, LevelFilter};
use std::env;
use std::fs;
use std::str;
use url;
use std::{thread, time};
use std::io;
use futures_util::{future, pin_mut, StreamExt};
use tokio::io::{AsyncReadExt};
use tokio_tungstenite::{connect_async, tungstenite::protocol::Message};
use tokio::net::UnixListener;
use tokio::time::{sleep};
use std::os::unix::fs::PermissionsExt;
use systemd_journal_logger::JournalLog;

mod config;
mod edge_system;
mod tcp_to_websocket;

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

    let ws_to_edge = {
        read.for_each(|message| async {
            let command_str = message.unwrap().to_string();

            if command_str == "" {
                debug!("ignoring the empty message");
            } else {
                let command_split: Vec<&str> = command_str.split_whitespace().collect();

                match &command_split[..] {
                    [""] => {
                        handle_pong();
                    },

                    ["SSH", session_id] => {
                        let session_id_str = session_id.to_string();
                        let cloud_value = cloud.clone();
                        let uuid_value = uuid.clone();
                        let session_id_str_value = session_id_str.clone();
                        debug!("creating ssh session with: {}", command_str);

                        thread::spawn(move || {
                            tcp_to_websocket::start_tcp_to_websocket_bridge(cloud_value, uuid_value, session_id_str_value)
                        });

                        info!("ssh session created with: {}", command_str);
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

fn handle_pong() {
    // debug!("getting pong");
}
