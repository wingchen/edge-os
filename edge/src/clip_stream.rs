use log::{error, info};
use std::sync::Arc;
use tokio::io::AsyncReadExt;
use webrtc::data_channel::RTCDataChannel;

/// Stream a clip file as raw bytes over the data channel.
/// Each binary message is prefixed with [0x53, 0x54] ('S','T') so the browser
/// can distinguish stream chunks from save-download chunks.
/// The browser accumulates all chunks and plays via URL.createObjectURL.
pub fn start_clip_stream(
    clip_path: String,
    event_id:  i64,
    dc:        Arc<RTCDataChannel>,
) {
    tokio::spawn(async move {
        stream_clip_bytes(clip_path, event_id, dc).await;
    });
}

async fn stream_clip_bytes(clip_path: String, event_id: i64, dc: Arc<RTCDataChannel>) {
    let _ = dc.send_text(serde_json::json!({
        "type":     "CLIP_STREAM_META",
        "event_id": event_id,
    }).to_string()).await;

    let mut file = match tokio::fs::File::open(&clip_path).await {
        Ok(f) => f,
        Err(e) => {
            error!("[clip_stream] event_id={event_id} open failed: {e}");
            let _ = dc.send_text(serde_json::json!({
                "type":     "CLIP_STREAM_ERROR",
                "event_id": event_id,
                "reason":   "clip file not found",
            }).to_string()).await;
            return;
        }
    };

    info!("[clip_stream] event_id={event_id} → {clip_path}");
    let mut buf = vec![0u8; 32_768]; // 32 KB read buffer
    loop {
        match file.read(&mut buf).await {
            Ok(0) => break, // EOF
            Ok(n) => {
                let mut payload = Vec::with_capacity(n + 2);
                payload.push(0x53); // 'S'
                payload.push(0x54); // 'T'
                payload.extend_from_slice(&buf[..n]);
                if dc.send(&bytes::Bytes::from(payload)).await.is_err() {
                    break; // data channel closed
                }
            }
            Err(e) => { error!("[clip_stream] read error: {e}"); break; }
        }
    }

    let _ = dc.send_text(serde_json::json!({
        "type":     "CLIP_STREAM_DONE",
        "event_id": event_id,
    }).to_string()).await;
    info!("[clip_stream] event_id={event_id} done");
}
