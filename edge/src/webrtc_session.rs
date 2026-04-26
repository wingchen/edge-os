use bytes::Bytes;
use futures_channel::mpsc::UnboundedSender;
use log::{debug, error, info};
use serde::Deserialize;
use std::sync::Arc;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio::sync::{mpsc as tokio_mpsc, Mutex};
use tokio_tungstenite::tungstenite::protocol::Message;
use webrtc::api::APIBuilder;
use webrtc::data_channel::data_channel_message::DataChannelMessage;
use webrtc::data_channel::RTCDataChannel;
use webrtc::ice_transport::ice_credential_type::RTCIceCredentialType;
use webrtc::ice_transport::ice_server::RTCIceServer;
use webrtc::peer_connection::configuration::RTCConfiguration;
use webrtc::peer_connection::peer_connection_state::RTCPeerConnectionState;
use webrtc::peer_connection::sdp::session_description::RTCSessionDescription;


#[derive(Deserialize)]
pub struct OfferPayload {
    pub session_id: String,
    pub sdp: String,
    pub turn_host: Option<String>,
    pub turn_username: Option<String>,
    pub turn_credential: Option<String>,
}

pub fn extract_session_id(json: &str) -> Option<String> {
    let v: serde_json::Value = serde_json::from_str(json).ok()?;
    v.get("session_id")?.as_str().map(str::to_string)
}

pub async fn handle_webrtc_offer(
    json_payload: String,
    tx: UnboundedSender<Message>,
    mut ice_rx: tokio_mpsc::UnboundedReceiver<String>,
) {
    let payload: OfferPayload = match serde_json::from_str(&json_payload) {
        Ok(p) => p,
        Err(e) => {
            error!("failed to parse WEBRTC_OFFER: {}", e);
            return;
        }
    };

    let session_id = payload.session_id.clone();
    info!("starting WebRTC session {}", session_id);

    let mut ice_servers = vec![RTCIceServer {
        urls: vec!["stun:stun.l.google.com:19302".to_owned()],
        ..Default::default()
    }];

    if let (Some(host), Some(user), Some(cred)) = (
        payload.turn_host.filter(|h| !h.is_empty()),
        payload.turn_username,
        payload.turn_credential,
    ) {
        ice_servers.push(RTCIceServer {
            urls: vec![format!("turn:{}:3478", host)],
            username: user,
            credential: cred,
            credential_type: RTCIceCredentialType::Password,
        });
    }

    let api = APIBuilder::new().build();
    let config = RTCConfiguration { ice_servers, ..Default::default() };

    let pc = match api.new_peer_connection(config).await {
        Ok(p) => Arc::new(p),
        Err(e) => {
            error!("failed to create RTCPeerConnection: {}", e);
            return;
        }
    };

    let (close_tx, close_rx) = tokio::sync::oneshot::channel::<()>();
    let close_tx = Arc::new(Mutex::new(Some(close_tx)));

    pc.on_peer_connection_state_change(Box::new({
        let close_tx = Arc::clone(&close_tx);
        let session_id = session_id.clone();
        move |state: RTCPeerConnectionState| {
            let close_tx = Arc::clone(&close_tx);
            let session_id = session_id.clone();
            Box::pin(async move {
                info!("WebRTC session {} state: {:?}", session_id, state);
                if matches!(
                    state,
                    RTCPeerConnectionState::Failed
                        | RTCPeerConnectionState::Closed
                        | RTCPeerConnectionState::Disconnected
                ) {
                    let mut lock = close_tx.lock().await;
                    if let Some(sender) = lock.take() {
                        let _ = sender.send(());
                    }
                }
            })
        }
    }));

    // Local ICE candidates → send to cloud via WebSocket
    pc.on_ice_candidate(Box::new({
        let session_id = session_id.clone();
        let tx = tx.clone();
        move |c| {
            let session_id = session_id.clone();
            let tx = tx.clone();
            Box::pin(async move {
                if let Some(candidate) = c {
                    match candidate.to_json() {
                        Ok(init) => {
                            let payload = serde_json::json!({
                                "session_id": session_id,
                                "candidate": init.candidate,
                                "sdpMLineIndex": init.sdp_mline_index.unwrap_or(0),
                                "sdpMid": init.sdp_mid.clone().unwrap_or_default(),
                            });
                            let _ = tx.unbounded_send(Message::Text(
                                format!("ICE_CANDIDATE {}", payload),
                            ));
                            debug!("sent ICE candidate for session {}", session_id);
                        }
                        Err(e) => error!("failed to serialize ICE candidate: {}", e),
                    }
                }
            })
        }
    }));

    // Data channel opened by cloud — bridge to local SSH
    pc.on_data_channel(Box::new(move |dc: Arc<RTCDataChannel>| {
        Box::pin(async move {
            info!("data channel '{}' received", dc.label());
            let dc_open = Arc::clone(&dc);
            dc.on_open(Box::new(move || {
                let dc = Arc::clone(&dc_open);
                Box::pin(async move {
                    info!("data channel open, bridging to 127.0.0.1:22");
                    if let Err(e) = bridge_to_ssh(dc).await {
                        error!("SSH bridge error: {}", e);
                    }
                })
            }));
        })
    }));

    // Set remote description (offer from cloud)
    let offer = match RTCSessionDescription::offer(payload.sdp) {
        Ok(o) => o,
        Err(e) => {
            error!("failed to parse SDP offer: {}", e);
            return;
        }
    };

    if let Err(e) = pc.set_remote_description(offer).await {
        error!("set_remote_description failed: {}", e);
        return;
    }

    let answer = match pc.create_answer(None).await {
        Ok(a) => a,
        Err(e) => {
            error!("create_answer failed: {}", e);
            return;
        }
    };

    if let Err(e) = pc.set_local_description(answer.clone()).await {
        error!("set_local_description failed: {}", e);
        return;
    }

    let answer_payload = serde_json::json!({
        "session_id": session_id,
        "sdp": answer.sdp,
    });
    let _ = tx.unbounded_send(Message::Text(format!("WEBRTC_ANSWER {}", answer_payload)));
    info!("WebRTC answer sent for session {}", session_id);

    // Route incoming ICE candidates from cloud into the peer connection
    let pc_for_ice = Arc::clone(&pc);
    tokio::spawn(async move {
        while let Some(json) = ice_rx.recv().await {
            if let Ok(v) = serde_json::from_str::<serde_json::Value>(&json) {
                let candidate_str = v
                    .get("candidate")
                    .and_then(|c| c.as_str())
                    .unwrap_or("")
                    .to_string();
                let sdp_mline_index = v
                    .get("sdpMLineIndex")
                    .and_then(|i| i.as_u64())
                    .map(|i| i as u16);
                let sdp_mid = v
                    .get("sdpMid")
                    .and_then(|m| m.as_str())
                    .map(str::to_string);

                let init = webrtc::ice_transport::ice_candidate::RTCIceCandidateInit {
                    candidate: candidate_str,
                    sdp_mline_index,
                    sdp_mid,
                    ..Default::default()
                };

                if let Err(e) = pc_for_ice.add_ice_candidate(init).await {
                    error!("add_ice_candidate failed: {}", e);
                }
            }
        }
    });

    let _ = close_rx.await;
    let _ = pc.close().await;
    info!("WebRTC session {} closed", session_id);
}

async fn bridge_to_ssh(
    dc: Arc<RTCDataChannel>,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let tcp = TcpStream::connect("127.0.0.1:22").await?;
    let (mut tcp_read, mut tcp_write) = tcp.into_split();

    // Channel so on_message callback can hand data to the TCP writer task
    let (to_tcp_tx, mut to_tcp_rx) = tokio_mpsc::unbounded_channel::<Bytes>();

    dc.on_message(Box::new(move |msg: DataChannelMessage| {
        let tx = to_tcp_tx.clone();
        Box::pin(async move {
            let _ = tx.send(msg.data);
        })
    }));

    // Data channel → TCP
    tokio::spawn(async move {
        while let Some(data) = to_tcp_rx.recv().await {
            if let Err(e) = tcp_write.write_all(&data).await {
                error!("TCP write error: {}", e);
                break;
            }
        }
    });

    // TCP → data channel (drives this task until EOF)
    let mut buf = [0u8; 4096];
    loop {
        let n = tcp_read.read(&mut buf).await?;
        if n == 0 {
            break;
        }
        dc.send(&Bytes::copy_from_slice(&buf[..n])).await?;
    }

    Ok(())
}
