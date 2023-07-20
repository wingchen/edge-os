use log::{debug, info, error};
use std::io::{Read, Write, ErrorKind};
use std::time::Duration;
use std::net::{TcpStream};
use futures_util::{future, pin_mut, StreamExt};
use tokio::runtime::Runtime;
use tokio_tungstenite::{connect_async, tungstenite::protocol::Message};

pub fn start_tcp_to_websocket_bridge(cloud: String, uuid: String, session_id: String) {
    // Start a TCP server on port 22 for ssh
    match TcpStream::connect("127.0.0.1:22") {
        Ok(tcp_stream) => {
            let cloud_value = cloud.clone();
            let uuid_value = uuid.clone();
            let session_id_value = session_id.clone();

            tcp_stream.set_read_timeout(Some(Duration::from_secs(30))).unwrap();

            // Handle each TCP connection in a different thread
            std::thread::spawn(move || {
                let rt = Runtime::new().unwrap();
                rt.block_on(handle_websocket_connection(tcp_stream, cloud_value, uuid_value, session_id_value));
            });
        }
        Err(err) => {
            error!("Failed to connect to the TCP server: {}", err);
        }
    }
}

async fn tcp_to_websocket_loop(sender: futures_channel::mpsc::UnboundedSender<Message>, mut tcp_stream: TcpStream) {
    loop {
        let mut buffer = [0; 2048];
        sender.unbounded_send(Message::Ping(vec![])).unwrap();

        match tcp_stream.read(&mut buffer) {
            Ok(n) if n > 0 => {
                let tcp_message = &buffer[..n];
                debug!("Received message of size {} from TCP, passing alone", n);
                sender.unbounded_send(Message::binary(tcp_message)).unwrap();
            }
            Ok(_) => {
                error!("TCP connection closed");
                break;
            }
            Err(e) if e.kind() == ErrorKind::WouldBlock => {
                // Timeout occurred
                debug!("Read timeout occurred. Time for another ping");
            }
            Err(e) => {
                error!("Error reading from TCP connection: {}", e);
                break;
            }
        }
    }
}

async fn handle_websocket_connection(tcp_stream: TcpStream, cloud: String, uuid: String, session_id: String) {
    let websocket_url = format!("{}/e-ssh/{}/{}/websocket", cloud, uuid, session_id);
    let url = url::Url::parse(&websocket_url).unwrap();

    let (sender, receiver) = futures_channel::mpsc::unbounded();
    let tcp_stream_read = tcp_stream.try_clone().expect("Failed to clone TCP stream");
    tokio::spawn(tcp_to_websocket_loop(sender, tcp_stream_read));

    let (ws_stream, _) = connect_async(url).await.expect("Failed to connect");
    info!("Connected to WebSocket server");

    let (write, read) = ws_stream.split();
    let tcp_to_ws = receiver.map(Ok).forward(write);

    let ws_to_tcp = {
        read.for_each(|message| async {
            let mut tcp_stream_write = tcp_stream.try_clone().expect("Failed to clone TCP stream");
            let data = message.unwrap().into_data();
            tcp_stream_write.write_all(data.as_slice()).unwrap();
        })
    };

    pin_mut!(tcp_to_ws, ws_to_tcp);
    future::select(tcp_to_ws, ws_to_tcp).await;
}
