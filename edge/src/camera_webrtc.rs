use futures_channel::mpsc::UnboundedSender;
use gstreamer as gst;
use gstreamer::prelude::*;
use gstreamer_sdp as gst_sdp;
use gstreamer_webrtc as gst_webrtc;
use log::{error, info, warn};
use tokio::sync::mpsc as tokio_mpsc;
use tokio_tungstenite::tungstenite::protocol::Message;

use crate::webrtc_session::OfferPayload;

pub async fn handle_camera_video_offer(
    json_payload: String,
    tx: UnboundedSender<Message>,
    mut ice_rx: tokio_mpsc::UnboundedReceiver<String>,
    frame_map: crate::camera_manager::FrameMap,
) {
    let payload: OfferPayload = match serde_json::from_str(&json_payload) {
        Ok(p) => p,
        Err(e) => { error!("[camera_video] failed to parse offer: {e}"); return; }
    };

    let session_id  = payload.session_id.clone();
    let camera_id   = payload.camera_id.clone().unwrap_or_default();

    info!("[camera_video] session={session_id} camera={camera_id}");

    // Look up RTSP URL from frame_map
    let rtsp_url = {
        let map = frame_map.lock().await;
        match map.get(&camera_id) {
            Some(cam) => cam.rtsp_url.clone(),
            None => {
                error!("[camera_video] camera '{camera_id}' not found");
                return;
            }
        }
    };

    info!("[camera_video] rtsp_url={rtsp_url}");

    // Build GStreamer pipeline.
    // No explicit pt= or payload= — webrtcbin negotiates the payload type from
    // the browser's SDP offer and caps-negotiates it back to rtph264pay before
    // data flows. Hardcoding pt=96 causes a silent mismatch because Firefox
    // never lists 96 in its H264 codec list (it uses 126, 97, 105, 103).
    let pipeline_str = format!(
        "rtspsrc location=\"{rtsp_url}\" latency=100 protocols=tcp name=src \
         ! rtph264depay \
         ! h264parse config-interval=-1 name=parser \
         ! rtph264pay config-interval=-1 name=rtppay \
         ! webrtcbin name=sendrecv bundle-policy=max-bundle"
    );
    info!("[camera_video] pipeline: {pipeline_str}");

    let pipeline = match gst::parse::launch(&pipeline_str) {
        Ok(p) => p.downcast::<gst::Pipeline>().expect("is pipeline"),
        Err(e) => { error!("[camera_video] pipeline parse failed: {e}"); return; }
    };

    let webrtcbin = match pipeline.by_name("sendrecv") {
        Some(w) => w,
        None => { error!("[camera_video] webrtcbin element not found"); return; }
    };

    // STUN
    webrtcbin.set_property_from_str("stun-server", "stun://stun.l.google.com:19302");

    // TURN (optional)
    if let (Some(host), Some(user), Some(cred)) = (
        payload.turn_host.as_deref().filter(|h| !h.is_empty()),
        payload.turn_username.as_deref(),
        payload.turn_credential.as_deref(),
    ) {
        let turn_uri = format!("turn://{user}:{cred}@{host}:3478");
        webrtcbin.emit_by_name::<bool>("add-turn-server", &[&turn_uri.as_str()]);
        info!("[camera_video] TURN server configured: {host}");
    }

    // ── ICE state monitoring ───────────────────────────────────────────────────
    let sid_conn = session_id.clone();
    webrtcbin.connect("notify::ice-connection-state", false, move |values| {
        let el = values[0].get::<gst::Element>().unwrap();
        let state = el.property::<gst_webrtc::WebRTCICEConnectionState>("ice-connection-state");
        info!("[camera_video] session={sid_conn} ICE connection state → {state:?}");
        None
    });

    let sid_gather = session_id.clone();
    webrtcbin.connect("notify::ice-gathering-state", false, move |values| {
        let el = values[0].get::<gst::Element>().unwrap();
        let state = el.property::<gst_webrtc::WebRTCICEGatheringState>("ice-gathering-state");
        info!("[camera_video] session={sid_gather} ICE gathering state → {state:?}");
        None
    });

    // ── on-ice-candidate → send to cloud ──────────────────────────────────────
    let tx_ice       = tx.clone();
    let sid_ice      = session_id.clone();
    webrtcbin.connect("on-ice-candidate", false, move |values| {
        let mline_index: u32  = values[1].get().expect("mline_index");
        let candidate: String = values[2].get().expect("candidate");

        // candidate: F C proto prio IP port typ type [raddr X rport Y]
        let parts: Vec<&str> = candidate.split_whitespace().collect();
        let addr  = parts.get(4).copied().unwrap_or("?");
        let port  = parts.get(5).copied().unwrap_or("?");
        let ctype = parts.get(7).copied().unwrap_or("?");
        info!("[camera_video] → ICE {ctype} {addr}:{port} mline={mline_index}");

        let payload = serde_json::json!({
            "session_id":    sid_ice,
            "candidate":     candidate,
            "sdpMLineIndex": mline_index,
            "sdpMid":        "",
        });
        let _ = tx_ice.unbounded_send(Message::Text(format!("ICE_CANDIDATE {payload}")));
        None
    });

    // ── Set remote description (browser's offer) then create answer ───────────
    let sdp_msg = match gst_sdp::SDPMessage::parse_buffer(payload.sdp.as_bytes()) {
        Ok(s) => s,
        Err(e) => { error!("[camera_video] SDP parse failed: {e}"); return; }
    };
    let offer = gst_webrtc::WebRTCSessionDescription::new(
        gst_webrtc::WebRTCSDPType::Offer,
        sdp_msg,
    );

    let webrtcbin_ans = webrtcbin.clone();
    let tx_ans        = tx.clone();
    let sid_ans       = session_id.clone();
    let pipeline_ans  = pipeline.clone();
    // Capture the tokio handle here (async context) so we can spawn tasks from
    // inside GStreamer Promise callbacks, which run on GStreamer's own thread pool
    // and do not have a tokio context — calling tokio::spawn there would panic.
    let rt_ans = tokio::runtime::Handle::current();

    // Promise for set-remote-description: on completion, create answer
    let set_remote_promise = gst::Promise::with_change_func(move |_reply| {
        let webrtcbin2 = webrtcbin_ans.clone();
        let tx2        = tx_ans.clone();
        let sid2       = sid_ans.clone();
        let pipeline2  = pipeline_ans.clone();
        let rt2        = rt_ans.clone();

        let create_ans_promise = gst::Promise::with_change_func(move |reply| {
            let s = match reply {
                Ok(Some(s)) => s,
                other => {
                    error!("[camera_video] create-answer reply: {other:?}");
                    return;
                }
            };
            let answer = match s.value("answer") {
                Ok(v) => match v.get::<gst_webrtc::WebRTCSessionDescription>() {
                    Ok(a) => a,
                    Err(e) => { error!("[camera_video] answer type error: {e}"); return; }
                },
                Err(e) => { error!("[camera_video] no answer field: {e}"); return; }
            };

            webrtcbin2.emit_by_name::<()>(
                "set-local-description",
                &[&answer, &None::<gst::Promise>],
            );

            let sdp_str = answer.sdp().to_string();
            info!("[camera_video] answer SDP:\n{sdp_str}");

            // Extract the negotiated payload type from the answer's m=video line
            // ("m=video 9 UDP/TLS/RTP/SAVPF 126 97 105 103" → 126) and set it
            // explicitly on rtph264pay. Without this, rtph264pay defaults to pt=96
            // because the pipeline's caps negotiation races with set-local-description,
            // and webrtcbin's sink pad hasn't locked its accepted caps yet. The browser
            // drops every RTP packet whose PT isn't in the answer SDP.
            let negotiated_pt: u32 = sdp_str
                .lines()
                .find(|l| l.starts_with("m=video"))
                .and_then(|l| l.split_whitespace().nth(3))
                .and_then(|s| s.parse().ok())
                .unwrap_or(96);
            if let Some(rtppay) = pipeline2.by_name("rtppay") {
                rtppay.set_property("pt", negotiated_pt);
                info!("[camera_video] set rtph264pay pt={negotiated_pt}");
            }

            let resp = serde_json::json!({
                "session_id": sid2,
                "sdp":        sdp_str,
            });
            let _ = tx2.unbounded_send(Message::Text(format!("WEBRTC_ANSWER {resp}")));
            info!("[camera_video] answer sent for session {sid2}");

            // SDP negotiation complete and PT pinned — start pipeline.
            info!("[camera_video] starting pipeline to PLAYING after SDP negotiation");
            if let Err(e) = pipeline2.set_state(gst::State::Playing) {
                error!("[camera_video] pipeline PLAYING failed: {e}");
            }

            // Request an immediate keyframe so the browser can start decoding
            // without waiting for the camera's natural keyframe interval (can be 30s+).
            // Give rtspsrc ~1 s to establish the RTSP session before pushing the event.
            // Use rt2 (captured tokio Handle) — tokio::spawn here would panic because
            // GStreamer Promise callbacks run on GStreamer threads, not tokio threads.
            let pipeline_fku = pipeline2.clone();
            rt2.spawn(async move {
                tokio::time::sleep(std::time::Duration::from_millis(1000)).await;
                if let Some(parser) = pipeline_fku.by_name("parser") {
                    if let Some(sinkpad) = parser.static_pad("sink") {
                        let fku = gst::event::CustomUpstream::new(
                            gst::Structure::builder("GstForceKeyUnit")
                                .field("all-headers", true)
                                .field("count", 0u32)
                                .build(),
                        );
                        let ok = sinkpad.push_event(fku);
                        info!("[camera_video] force-key-unit sent: {ok}");
                    }
                }
            });
        });

        webrtcbin_ans.emit_by_name::<()>(
            "create-answer",
            &[&None::<gst::Structure>, &create_ans_promise],
        );
    });

    // ── READY state: webrtcbin initialises but caps aren't locked yet ─────────
    // We must NOT go to PLAYING before the SDP is negotiated. If we start the
    // pipeline now, rtph264pay picks a default PT (usually 96) and caps lock.
    // When webrtcbin later negotiates e.g. pt=126 from the browser's offer,
    // rtph264pay is already locked to pt=96 → PT mismatch → browser drops all
    // RTP → ontrack never fires.
    // Instead: go to READY (elements init, no caps lock), do SDP negotiation,
    // then go to PLAYING inside the create-answer callback once the PT is known.
    if let Err(e) = pipeline.set_state(gst::State::Ready) {
        error!("[camera_video] pipeline READY failed: {e}");
        return;
    }
    info!("[camera_video] pipeline READY, starting SDP negotiation for session {session_id}");

    webrtcbin.emit_by_name::<()>(
        "set-remote-description",
        &[&offer, &set_remote_promise],
    );

    // ── Route incoming ICE candidates from cloud → webrtcbin ─────────────────
    let webrtcbin_ice = webrtcbin.clone();
    let pipeline_eos  = pipeline.clone();
    tokio::spawn(async move {
        while let Some(json) = ice_rx.recv().await {
            if let Ok(v) = serde_json::from_str::<serde_json::Value>(&json) {
                let candidate  = v["candidate"].as_str().unwrap_or("").to_string();
                let mline: u32 = v["sdpMLineIndex"].as_u64().unwrap_or(0) as u32;
                webrtcbin_ice.emit_by_name::<()>(
                    "add-ice-candidate",
                    &[&mline, &candidate],
                );
            }
        }
        // Channel closed → browser disconnected → stop pipeline
        info!("[camera_video] ice_rx closed, sending EOS");
        pipeline_eos.send_event(gst::event::Eos::new());
    });

    // ── Bus loop (blocking) ───────────────────────────────────────────────────
    let sid_bus  = session_id.clone();
    let pipeline_bus = pipeline.clone();
    tokio::task::spawn_blocking(move || {
        let bus = pipeline_bus.bus().expect("pipeline has bus");
        for msg in bus.iter_timed(gst::ClockTime::NONE) {
            match msg.view() {
                gst::MessageView::Error(err) => {
                    error!("[camera_video] session={sid_bus} gst error: {} ({:?})",
                        err.error(), err.debug());
                    break;
                }
                gst::MessageView::Eos(_) => {
                    info!("[camera_video] session={sid_bus} EOS");
                    break;
                }
                gst::MessageView::Warning(w) => {
                    warn!("[camera_video] gst warning: {}", w.error());
                }
                _ => {}
            }
        }
        let _ = pipeline_bus.set_state(gst::State::Null);
        info!("[camera_video] session={sid_bus} pipeline stopped");
    }).await.ok();
}
