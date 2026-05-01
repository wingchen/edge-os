use bytes::Bytes;
use futures_channel::mpsc::UnboundedSender;
use log::{debug, error, info, warn};
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

pub fn extract_connection_type(json: &str) -> String {
    serde_json::from_str::<serde_json::Value>(json)
        .ok()
        .and_then(|v| v.get("connection_type").and_then(|t| t.as_str()).map(str::to_string))
        .unwrap_or_else(|| "ssh".to_string())
}

async fn handle_camera_channel(
    dc: Arc<RTCDataChannel>,
    frame_map: crate::camera_manager::FrameMap,
) {
    info!("camera data channel '{}' open", dc.label());
    let dc_msg = Arc::clone(&dc);

    dc.on_message(Box::new(move |msg: DataChannelMessage| {
        let dc = Arc::clone(&dc_msg);
        let frame_map = Arc::clone(&frame_map);
        Box::pin(async move {
            let text = match std::str::from_utf8(&msg.data) {
                Ok(t) => t,
                Err(e) => { error!("camera channel: non-UTF8 message: {e}"); return; }
            };
            debug!("camera channel ← {}", text);
            let v: serde_json::Value = match serde_json::from_str(text) {
                Ok(v) => v,
                Err(e) => { error!("camera channel: JSON parse error: {e} — raw: {text}"); return; }
            };
            match v.get("type").and_then(|t| t.as_str()) {
                Some("ping") => {
                    let _ = dc.send_text(r#"{"type":"pong"}"#.to_string()).await;
                }
                Some("LIST_CAMERAS") => {
                    info!("camera channel: LIST_CAMERAS requested");
                    list_cameras(&dc, &frame_map).await;
                }
                Some("GET_THUMBNAIL") => {
                    let camera_id = v.get("camera_id")
                        .and_then(|id| id.as_str())
                        .unwrap_or("")
                        .to_string();
                    info!("camera channel: GET_THUMBNAIL for '{}'", camera_id);
                    get_thumbnail(&dc, &frame_map, &camera_id).await;
                }
                other => warn!("camera channel: unknown message type {:?} — raw: {text}", other),
            }
        })
    }));
}

async fn list_cameras(
    dc: &Arc<RTCDataChannel>,
    frame_map: &crate::camera_manager::FrameMap,
) {
    let map = frame_map.lock().await;
    let cameras: Vec<serde_json::Value> = map.iter().map(|(id, (name, frame))| {
        let has_frame = frame.try_lock()
            .map(|f| f.is_some())
            .unwrap_or(false);
        info!("  camera '{}' (id={}) has_frame={}", name, id, has_frame);
        serde_json::json!({"id": id, "name": name, "has_frame": has_frame})
    }).collect();
    let resp = serde_json::json!({"type": "CAMERA_LIST", "cameras": cameras});
    let payload = resp.to_string();
    info!("sending CAMERA_LIST ({} cameras, {} bytes)", cameras.len(), payload.len());
    if let Err(e) = dc.send_text(payload).await {
        error!("failed to send CAMERA_LIST: {e}");
    }
}

async fn get_thumbnail(
    dc: &Arc<RTCDataChannel>,
    frame_map: &crate::camera_manager::FrameMap,
    camera_id: &str,
) {
    let map = frame_map.lock().await;
    let jpeg = match map.get(camera_id) {
        None => {
            warn!("get_thumbnail: camera '{}' not found in frame_map (keys: {:?})",
                camera_id, map.keys().collect::<Vec<_>>());
            let _ = dc.send_text(serde_json::json!({
                "type": "THUMBNAIL_ERROR",
                "camera_id": camera_id,
                "reason": "not found"
            }).to_string()).await;
            return;
        }
        Some((_name, shared)) => {
            let frame = shared.lock().await;
            match frame.as_ref() {
                None => {
                    warn!("get_thumbnail: camera '{}' found but SharedFrame is empty", camera_id);
                    let _ = dc.send_text(serde_json::json!({
                        "type": "THUMBNAIL_ERROR",
                        "camera_id": camera_id,
                        "reason": "no frame yet"
                    }).to_string()).await;
                    return;
                }
                Some(bytes) => {
                    info!("get_thumbnail: camera '{}' frame is {} bytes", camera_id, bytes.len());
                    bytes.clone()
                }
            }
        }
    };
    drop(map);

    let thumb = match make_thumbnail(&jpeg, 320, 180) {
        Ok(t) => {
            info!("get_thumbnail: resized {} → {} bytes", jpeg.len(), t.len());
            t
        }
        Err(e) => {
            warn!("get_thumbnail: resize failed ({e}), sending original {} bytes", jpeg.len());
            jpeg
        }
    };

    use base64::Engine;
    let b64 = base64::engine::general_purpose::STANDARD.encode(&thumb);
    let payload = serde_json::json!({
        "type": "THUMBNAIL",
        "camera_id": camera_id,
        "data": b64,
    }).to_string();
    info!("get_thumbnail: sending THUMBNAIL payload {} bytes", payload.len());
    if let Err(e) = dc.send_text(payload).await {
        error!("get_thumbnail: failed to send THUMBNAIL for '{}': {e}", camera_id);
    } else {
        info!("get_thumbnail: THUMBNAIL sent ok for '{}'", camera_id);
    }
}

fn make_thumbnail(jpeg: &[u8], max_w: u32, max_h: u32) -> anyhow::Result<Vec<u8>> {
    let img = image::load_from_memory(jpeg)?.into_rgb8();
    let (w, h) = image::GenericImageView::dimensions(&img);
    let scale = (max_w as f32 / w as f32).min(max_h as f32 / h as f32);
    let nw = ((w as f32 * scale) as u32).max(1);
    let nh = ((h as f32 * scale) as u32).max(1);
    let thumb = image::imageops::resize(&img, nw, nh, image::imageops::FilterType::Nearest);
    let mut buf = Vec::new();
    image::DynamicImage::ImageRgb8(thumb)
        .write_to(&mut std::io::Cursor::new(&mut buf), image::ImageFormat::Jpeg)?;
    Ok(buf)
}

pub async fn handle_camera_offer(
    json_payload: String,
    tx: UnboundedSender<Message>,
    mut ice_rx: tokio_mpsc::UnboundedReceiver<String>,
    frame_map: crate::camera_manager::FrameMap,
) {
    let payload: OfferPayload = match serde_json::from_str(&json_payload) {
        Ok(p) => p,
        Err(e) => { error!("failed to parse camera WEBRTC_OFFER: {}", e); return; }
    };

    let session_id = payload.session_id.clone();
    info!("starting camera WebRTC session {}", session_id);

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
        Err(e) => { error!("failed to create RTCPeerConnection for camera: {}", e); return; }
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
                info!("camera session {} state: {:?}", session_id, state);
                if matches!(state,
                    RTCPeerConnectionState::Failed |
                    RTCPeerConnectionState::Closed |
                    RTCPeerConnectionState::Disconnected
                ) {
                    if let Some(sender) = close_tx.lock().await.take() { let _ = sender.send(()); }
                }
            })
        }
    }));

    pc.on_ice_candidate(Box::new({
        let session_id = session_id.clone();
        let tx = tx.clone();
        move |c| {
            let session_id = session_id.clone();
            let tx = tx.clone();
            Box::pin(async move {
                if let Some(candidate) = c {
                    if let Ok(init) = candidate.to_json() {
                        let payload = serde_json::json!({
                            "session_id": session_id,
                            "candidate": init.candidate,
                            "sdpMLineIndex": init.sdp_mline_index.unwrap_or(0),
                            "sdpMid": init.sdp_mid.clone().unwrap_or_default(),
                        });
                        let _ = tx.unbounded_send(Message::Text(format!("ICE_CANDIDATE {}", payload)));
                    }
                }
            })
        }
    }));

    pc.on_data_channel(Box::new(move |dc: Arc<RTCDataChannel>| {
        let frame_map = Arc::clone(&frame_map);
        Box::pin(async move {
            handle_camera_channel(dc, frame_map).await;
        })
    }));

    let offer = match RTCSessionDescription::offer(payload.sdp) {
        Ok(o) => o,
        Err(e) => { error!("failed to parse camera SDP offer: {}", e); return; }
    };
    if let Err(e) = pc.set_remote_description(offer).await { error!("set_remote_description failed: {}", e); return; }

    let answer = match pc.create_answer(None).await {
        Ok(a) => a,
        Err(e) => { error!("create_answer failed: {}", e); return; }
    };
    if let Err(e) = pc.set_local_description(answer.clone()).await { error!("set_local_description failed: {}", e); return; }

    let answer_payload = serde_json::json!({"session_id": session_id, "sdp": answer.sdp});
    let _ = tx.unbounded_send(Message::Text(format!("WEBRTC_ANSWER {}", answer_payload)));
    info!("camera WebRTC answer sent for session {}", session_id);

    let pc_for_ice = Arc::clone(&pc);
    tokio::spawn(async move {
        while let Some(json) = ice_rx.recv().await {
            if let Ok(v) = serde_json::from_str::<serde_json::Value>(&json) {
                let init = webrtc::ice_transport::ice_candidate::RTCIceCandidateInit {
                    candidate: v.get("candidate").and_then(|c| c.as_str()).unwrap_or("").to_string(),
                    sdp_mline_index: v.get("sdpMLineIndex").and_then(|i| i.as_u64()).map(|i| i as u16),
                    sdp_mid: v.get("sdpMid").and_then(|m| m.as_str()).map(str::to_string),
                    ..Default::default()
                };
                if let Err(e) = pc_for_ice.add_ice_candidate(init).await {
                    error!("add_ice_candidate failed (camera): {}", e);
                }
            }
        }
    });

    let _ = close_rx.await;
    let _ = pc.close().await;
    info!("camera WebRTC session {} closed", session_id);
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
