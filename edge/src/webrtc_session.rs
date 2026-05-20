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


#[derive(Deserialize, Clone)]
pub struct IceServerConfig {
    pub urls:       Vec<String>,
    pub username:   Option<String>,
    pub credential: Option<String>,
}

#[derive(Deserialize)]
pub struct OfferPayload {
    pub session_id:  String,
    pub sdp:         String,
    pub camera_id:   Option<String>,
    pub ice_servers: Option<Vec<IceServerConfig>>,
}

/// Convert the server-provided ice_servers list into webrtc-rs RTCIceServer structs.
/// Falls back to Google STUN if the server sends nothing.
fn build_rtc_ice_servers(servers: Option<&[IceServerConfig]>) -> Vec<RTCIceServer> {
    let servers = match servers {
        Some(s) if !s.is_empty() => s,
        _ => return vec![RTCIceServer {
            urls: vec!["stun:stun.l.google.com:19302".to_owned()],
            ..Default::default()
        }],
    };

    // webrtc-rs 0.11 does not support ?transport= query params or the turns: scheme.
    // Strip query params; drop turns: URLs (TLS TURN) since the library rejects them.
    let sanitize = |u: &str| -> Option<String> {
        let base = u.split('?').next().unwrap_or(u);
        if base.starts_with("turns:") { return None; }
        Some(base.to_owned())
    };

    let mut result: Vec<RTCIceServer> = Vec::new();
    for s in servers {
        let urls: Vec<String> = s.urls.iter().filter_map(|u| sanitize(u)).collect();
        if urls.is_empty() { continue; }
        let is_turn = urls.iter().any(|u| u.starts_with("turn:"));
        if is_turn {
            if let (Some(u), Some(c)) = (s.username.as_deref(), s.credential.as_deref()) {
                result.push(RTCIceServer {
                    urls,
                    username:        u.to_owned(),
                    credential:      c.to_owned(),
                    credential_type: RTCIceCredentialType::Password,
                });
            }
        } else {
            result.push(RTCIceServer { urls, ..Default::default() });
        }
    }
    result
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

#[cfg(not(target_os = "windows"))]
type EventStore = Arc<std::sync::Mutex<crate::event_store::EventStore>>;

#[cfg(not(target_os = "windows"))]
async fn handle_camera_channel(
    dc:          Arc<RTCDataChannel>,
    frame_map:   crate::camera_manager::FrameMap,
    event_store: EventStore,
) {
    info!("camera data channel '{}' open", dc.label());
    let dc_msg = Arc::clone(&dc);

    dc.on_message(Box::new(move |msg: DataChannelMessage| {
        let dc          = Arc::clone(&dc_msg);
        let frame_map   = Arc::clone(&frame_map);
        let event_store = Arc::clone(&event_store);
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
                Some("LIST_EVENTS") => {
                    let camera_id = v.get("camera_id").and_then(|id| id.as_str()).unwrap_or("").to_string();
                    let page      = v.get("page").and_then(|p| p.as_u64()).unwrap_or(0) as usize;
                    let per_page  = v.get("per_page").and_then(|p| p.as_u64()).unwrap_or(10).min(50) as usize;
                    info!("camera channel: LIST_EVENTS camera='{}' page={} per_page={}", camera_id, page, per_page);
                    list_events(&dc, &event_store, &camera_id, page, per_page).await;
                }
                Some("GET_EVENT_FRAME") => {
                    let event_id = v.get("event_id").and_then(|id| id.as_i64()).unwrap_or(0);
                    get_event_frame(&dc, &event_store, event_id).await;
                }
                Some("GET_EVENT_CLIP") => {
                    let event_id = v.get("event_id").and_then(|id| id.as_i64()).unwrap_or(0);
                    info!("camera channel: GET_EVENT_CLIP event_id={}", event_id);
                    send_clip(&dc, &event_store, event_id).await;
                }
                Some("STREAM_CLIP") => {
                    let event_id = v.get("event_id").and_then(|id| id.as_i64()).unwrap_or(0);
                    let clip_path: Option<String> = event_store.lock().ok()
                        .and_then(|store| store.get_clip_path(event_id).ok().flatten());
                    match clip_path {
                        None => {
                            let _ = dc.send_text(serde_json::json!({
                                "type": "CLIP_STREAM_ERROR", "event_id": event_id,
                                "reason": "no recording saved for this event",
                            }).to_string()).await;
                        }
                        Some(path) => {
                            info!("camera channel: STREAM_CLIP event_id={event_id}");
                            crate::clip_stream::start_clip_stream(path, event_id, Arc::clone(&dc));
                        }
                    }
                }
                other => warn!("camera channel: unknown message type {:?} — raw: {text}", other),
            }
        })
    }));
}

#[cfg(not(target_os = "windows"))]
async fn list_cameras(
    dc: &Arc<RTCDataChannel>,
    frame_map: &crate::camera_manager::FrameMap,
) {
    let map = frame_map.lock().await;
    let cameras: Vec<serde_json::Value> = map.iter().map(|(id, cam)| {
        let has_frame = cam.frame.try_lock()
            .map(|f| f.is_some())
            .unwrap_or(false);
        info!("  camera '{}' (id={}) has_frame={}", cam.name, id, has_frame);
        serde_json::json!({"id": id, "name": cam.name, "has_frame": has_frame})
    }).collect();
    let resp = serde_json::json!({"type": "CAMERA_LIST", "cameras": cameras});
    let payload = resp.to_string();
    info!("sending CAMERA_LIST ({} cameras, {} bytes)", cameras.len(), payload.len());
    if let Err(e) = dc.send_text(payload).await {
        error!("failed to send CAMERA_LIST: {e}");
    }
}

#[cfg(not(target_os = "windows"))]
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
        Some(cam) => {
            let frame = cam.frame.lock().await;
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

#[cfg(not(target_os = "windows"))]
async fn list_events(
    dc:          &Arc<RTCDataChannel>,
    event_store: &EventStore,
    camera_id:   &str,
    page:        usize,
    per_page:    usize,
) {
    let offset = page * per_page;
    // Acquire lock, do all DB work, drop lock — MutexGuard never crosses an await.
    let payload: String = event_store.lock().ok()
        .map(|store| {
            let total  = store.count(camera_id).unwrap_or(0);
            let events = store.list_page(camera_id, offset, per_page).unwrap_or_default();
            let total_pages = ((total as f64) / (per_page as f64)).ceil() as i64;
            let events_json: Vec<serde_json::Value> = events.iter().map(|e| serde_json::json!({
                "id":              e.id,
                "class_name":      e.class_name,
                "started_at":      e.started_at,
                "ended_at":        e.ended_at,
                "best_confidence": e.best_confidence,
                "frame_count":     e.frame_count,
                "has_clip":        e.clip_path.is_some(),
            })).collect();
            serde_json::json!({
                "type":        "EVENT_LIST",
                "events":      events_json,
                "page":        page,
                "per_page":    per_page,
                "total":       total,
                "total_pages": total_pages.max(1),
            }).to_string()
        })
        .unwrap_or_else(|| r#"{"type":"EVENT_LIST","events":[],"page":0,"total_pages":1,"total":0}"#.to_string());

    let _ = dc.send_text(payload).await;
}

#[cfg(not(target_os = "windows"))]
async fn get_event_frame(
    dc:          &Arc<RTCDataChannel>,
    event_store: &EventStore,
    event_id:    i64,
) {
    // Lock, read, drop — no MutexGuard across await.
    let jpeg: Option<Vec<u8>> = event_store.lock().ok()
        .and_then(|store| store.get_frame(event_id).ok());

    let payload = match jpeg {
        None => serde_json::json!({
            "type": "EVENT_FRAME_ERROR", "event_id": event_id, "reason": "not found"
        }).to_string(),
        Some(raw) => {
            let thumb = make_thumbnail(&raw, 320, 180).unwrap_or(raw);
            use base64::Engine;
            let b64 = base64::engine::general_purpose::STANDARD.encode(&thumb);
            serde_json::json!({
                "type": "EVENT_FRAME", "event_id": event_id, "data": b64,
            }).to_string()
        }
    };
    let _ = dc.send_text(payload).await;
}

#[cfg(not(target_os = "windows"))]
async fn send_clip(
    dc:          &Arc<RTCDataChannel>,
    event_store: &EventStore,
    event_id:    i64,
) {
    // Lock, read clip_path, drop lock immediately before any await.
    let clip_path: Option<String> = event_store.lock().ok()
        .and_then(|store| store.get_clip_path(event_id).ok().flatten());

    let path = match clip_path {
        Some(p) => p,
        None => {
            let _ = dc.send_text(serde_json::json!({
                "type": "CLIP_ERROR", "event_id": event_id, "reason": "no recording saved"
            }).to_string()).await;
            return;
        }
    };

    let data = match tokio::fs::read(&path).await {
        Ok(d) if !d.is_empty() => d,
        _ => {
            let _ = dc.send_text(serde_json::json!({
                "type": "CLIP_ERROR", "event_id": event_id, "reason": "clip file not found or empty"
            }).to_string()).await;
            return;
        }
    };

    const CHUNK: usize = 65_536; // 64 KB per message
    let total_chunks = (data.len() + CHUNK - 1) / CHUNK;

    let _ = dc.send_text(serde_json::json!({
        "type": "CLIP_META", "event_id": event_id,
        "size": data.len(), "total_chunks": total_chunks,
    }).to_string()).await;

    for i in 0..total_chunks {
        let start = i * CHUNK;
        let end   = (start + CHUNK).min(data.len());
        if dc.send(&Bytes::copy_from_slice(&data[start..end])).await.is_err() {
            break;
        }
    }

    let _ = dc.send_text(serde_json::json!({
        "type": "CLIP_DONE", "event_id": event_id,
    }).to_string()).await;

    info!("camera channel: clip sent event_id={} size={}", event_id, data.len());
}

#[cfg(not(target_os = "windows"))]
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

#[cfg(not(target_os = "windows"))]
pub async fn handle_camera_offer(
    json_payload: String,
    tx:           UnboundedSender<Message>,
    mut ice_rx:   tokio_mpsc::UnboundedReceiver<String>,
    frame_map:    crate::camera_manager::FrameMap,
    event_store:  EventStore,
) {
    let payload: OfferPayload = match serde_json::from_str(&json_payload) {
        Ok(p) => p,
        Err(e) => { error!("failed to parse camera WEBRTC_OFFER: {}", e); return; }
    };

    let session_id = payload.session_id.clone();
    info!("starting camera WebRTC session {}", session_id);

    let ice_servers = build_rtc_ice_servers(payload.ice_servers.as_deref());

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
        let frame_map   = Arc::clone(&frame_map);
        let event_store = Arc::clone(&event_store);
        Box::pin(async move {
            handle_camera_channel(dc, frame_map, event_store).await;
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
    handle_webrtc_offer_on_port(json_payload, tx, ice_rx, 22).await;
}

pub async fn handle_rdp_offer(
    json_payload: String,
    tx: UnboundedSender<Message>,
    ice_rx: tokio_mpsc::UnboundedReceiver<String>,
) {
    handle_webrtc_offer_on_port(json_payload, tx, ice_rx, 3389).await;
}

async fn handle_webrtc_offer_on_port(
    json_payload: String,
    tx: UnboundedSender<Message>,
    mut ice_rx: tokio_mpsc::UnboundedReceiver<String>,
    tcp_port: u16,
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

    let ice_servers = build_rtc_ice_servers(payload.ice_servers.as_deref());

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

    // Data channel opened by cloud — bridge to local TCP port
    pc.on_data_channel(Box::new(move |dc: Arc<RTCDataChannel>| {
        Box::pin(async move {
            info!("data channel '{}' received", dc.label());
            let dc_open = Arc::clone(&dc);
            dc.on_open(Box::new(move || {
                let dc = Arc::clone(&dc_open);
                Box::pin(async move {
                    // Windows RDP resets the TCP connection (WSAECONNRESET) when
                    // transitioning from the pre-auth winlogon session to the user's
                    // desktop session. mstsc.exe reconnects automatically; we must
                    // also reconnect the local bridge so it picks up the new session.
                    // Retry on clean close or ConnectionReset (up to 3 attempts).
                    // Only report an error for unrecoverable failures (e.g. ECONNREFUSED
                    // = RDP not enabled) — sending raw text over the data channel on
                    // a mid-session error would corrupt the RDP stream.
                    let mut attempts = 0u8;
                    loop {
                        info!("bridging to 127.0.0.1:{} (attempt {})", tcp_port, attempts + 1);
                        match bridge_to_tcp(Arc::clone(&dc), tcp_port).await {
                            Ok(()) => {
                                attempts += 1;
                                if attempts < 3 {
                                    info!("TCP connection to port {} closed cleanly, retrying in 2s (session transition?)", tcp_port);
                                    tokio::time::sleep(std::time::Duration::from_secs(2)).await;
                                } else {
                                    info!("TCP connection to port {} closed, bridge done after {} attempts", tcp_port, attempts);
                                    break;
                                }
                            }
                            Err(e) => {
                                let is_reset = e.downcast_ref::<std::io::Error>()
                                    .map(|io_e| io_e.kind() == std::io::ErrorKind::ConnectionReset)
                                    .unwrap_or(false);
                                if is_reset && attempts < 3 {
                                    attempts += 1;
                                    info!("TCP connection to port {} reset by remote (session transition), retrying in 2s", tcp_port);
                                    tokio::time::sleep(std::time::Duration::from_secs(2)).await;
                                } else {
                                    error!("TCP bridge error on port {}: {}", tcp_port, e);
                                    let msg = format!("ERROR: could not connect to 127.0.0.1:{} — {}", tcp_port, e);
                                    let _ = dc.send(&Bytes::from(msg.into_bytes())).await;
                                    break;
                                }
                            }
                        }
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

async fn bridge_to_tcp(
    dc: Arc<RTCDataChannel>,
    port: u16,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let tcp = TcpStream::connect(format!("127.0.0.1:{port}")).await?;
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
