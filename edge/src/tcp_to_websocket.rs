use log::{debug, info, warn, error};
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use tungstenite::{connect, Message};
use url::Url;
use std::sync::Arc;

pub fn start_tcp_to_websocket_bridge(cloud: String, uuid: String, session_id: String) {
    // Start a TCP server on port 22 for ssh
    let listener = TcpListener::bind("127.0.0.1:22").expect("Failed to bind to port");
    info!("connecting to local ssh server...");

    let cloud_shared = Arc::new(cloud);
    let uuid_shared = Arc::new(uuid);
    let session_id_shared = Arc::new(session_id);

    // Accept incoming TCP connections
    for stream in listener.incoming() {
        match stream {
            Ok(tcp_stream) => {
                let cloud_shared_value = Arc::clone(&cloud_shared);
                let uuid_shared_value = Arc::clone(&uuid_shared);
                let session_id_shared_value = Arc::clone(&session_id_shared);

                // Handle each TCP connection in a different thread
                std::thread::spawn(move || {
                    handle_websocket_connection(tcp_stream, cloud_shared_value, uuid_shared_value, session_id_shared_value);
                });
            }
            Err(e) => {
                error!("Error accepting connection: {}", e);
            }
        }
    }
}

fn handle_websocket_connection(tcp_stream: TcpStream, cloud: Arc<String>, uuid: Arc<String>, session_id: Arc<String>) {
    let websocket_url = format!("{}/e-ssh/{}/{}/websocket", cloud, uuid, session_id);

    match tcp_stream.try_clone() {
        Ok(stream) => {
            let connection_err_msg = format!("Can't connect to {}", websocket_url);
            let (mut ws_socket, response) =
                connect(Url::parse(&websocket_url).unwrap()).expect(&connection_err_msg[..]);
            
            info!("Connected to WebSocket server");
            debug!("Response HTTP code: {}", response.status());
            debug!("Response contains the following headers:");

            for (ref header, _value) in response.headers() {
                debug!("* {}", header);
            }

            // Handle messages from the WebSocket
            // std::thread::spawn(move || {
            //     let ws_socket_shared_value = Arc::clone(&ws_socket_shared);

            //     loop {
            //         if ws_socket_shared_value.can_read() {
            //             let msg = &ws_socket_shared_value.read_message();
            //         }

            //         // match msg {
            //         //     Ok(msg) => {
            //         //         debug!("Received: {}", msg);
            //         //         // relaly to tcp connection
            //         //     }
            //         //     Err(Error::ConnectionClosed) => {
            //         //         error!("WebSocket connection closed");
            //         //         break;
            //         //     }
            //         //     Err(e) => {
            //         //         error!("Error reading message from WebSocket: {}", e);
            //         //         break;
            //         //     }
            //         // }
            //     }
            // });

            // Handle messages from the TCP connection
            let mut tcp_reader = tcp_stream.try_clone().expect("Failed to clone TCP stream");
            loop {
                let mut buffer = [0; 1024];
                match tcp_reader.read(&mut buffer) {
                    Ok(n) if n > 0 => {
                        let tcp_message = String::from_utf8_lossy(&buffer[..n]);
                        debug!("Received message from TCP: {}", tcp_message);

                        // Forward the TCP message to the WebSocket
                        if  ws_socket.can_write() {
                            ws_socket.write_message(Message::Text(tcp_message.to_string()));
                        }
                    }
                    Ok(_) => {
                        error!("TCP connection closed");
                        break;
                    }
                    Err(e) => {
                        error!("Error reading from TCP connection: {}", e);
                        break;
                    }
                }
            }
        }
        Err(e) => {
            error!("Error cloning TCP stream: {}", e);
        }
    }
}
