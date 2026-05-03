use anyhow::anyhow;
use gstreamer as gst;
use gstreamer::prelude::*;
use gstreamer_sdp as gst_sdp;
use gstreamer_webrtc as gst_webrtc;
use log::{error, info};
use std::sync::Arc;
use webrtc::data_channel::RTCDataChannel;

/// Spawn a GStreamer pipeline that reads the mp4 clip and streams it over a
/// new WebRTC video track.  Signalling (SDP answer + ICE) is sent back through
/// the existing data channel so the cloud is not involved.
///
/// Returns a sender that the caller must forward browser ICE candidates into.
pub fn start_clip_stream(
    clip_path: String,
    offer_sdp: String,
    event_id:  i64,
    dc:        Arc<RTCDataChannel>,
    rt:        tokio::runtime::Handle,
) -> tokio::sync::mpsc::UnboundedSender<String> {
    let (ice_tx, ice_rx) = tokio::sync::mpsc::unbounded_channel::<String>();

    std::thread::spawn(move || {
        if let Err(e) = clip_loop(clip_path, offer_sdp, event_id, dc, ice_rx, rt) {
            error!("[clip_stream] event_id={event_id}: {e}");
        }
    });

    ice_tx
}

fn clip_loop(
    clip_path: String,
    offer_sdp: String,
    event_id:  i64,
    dc:        Arc<RTCDataChannel>,
    mut ice_rx: tokio::sync::mpsc::UnboundedReceiver<String>,
    rt:        tokio::runtime::Handle,
) -> anyhow::Result<()> {
    // ── Elements ──────────────────────────────────────────────────────────────
    let filesrc = gst::ElementFactory::make("filesrc")
        .property("location", &clip_path)
        .build()?;
    let demux = gst::ElementFactory::make("qtdemux").build()?;
    let queue = gst::ElementFactory::make("queue").build()?;
    let parse = gst::ElementFactory::make("h264parse")
        .property("config-interval", -1i32)
        .build()?;
    let pay = gst::ElementFactory::make("rtph264pay")
        .property("config-interval", -1i32)
        .build()?;
    let wb = gst::ElementFactory::make("webrtcbin")
        .property_from_str("bundle-policy", "max-bundle")
        .build()?;

    let pipeline = gst::Pipeline::new();
    pipeline.add_many([&filesrc, &demux, &queue, &parse, &pay, &wb])?;
    filesrc.link(&demux)?;
    gst::Element::link_many([&queue, &parse, &pay, &wb])?;

    // qtdemux has dynamic pads — link the video pad to queue once it appears
    let queue_w = queue.downgrade();
    demux.connect_pad_added(move |_, pad| {
        let Some(q) = queue_w.upgrade() else { return };
        let caps = pad.current_caps().unwrap_or_else(|| pad.query_caps(None));
        if caps.structure(0).map_or(false, |s| s.name().contains("video")) {
            let sink = q.static_pad("sink").unwrap();
            if !sink.is_linked() {
                if let Err(e) = pad.link(&sink) {
                    error!("[clip_stream] pad link: {e:?}");
                }
            }
        }
    });

    // ── STUN + ICE → data channel ─────────────────────────────────────────────
    wb.set_property_from_str("stun-server", "stun://stun.l.google.com:19302");
    {
        let dc2 = Arc::clone(&dc);
        let rt2 = rt.clone();
        wb.connect("on-ice-candidate", false, move |vals| {
            let mline: u32        = vals[1].get().unwrap_or(0);
            let candidate: String = vals[2].get().unwrap_or_default();
            let dc  = Arc::clone(&dc2);
            let msg = serde_json::json!({
                "type":          "STREAM_CLIP_ICE_EDGE",
                "event_id":      event_id,
                "candidate":     candidate,
                "sdpMLineIndex": mline,
            }).to_string();
            rt2.spawn(async move { let _ = dc.send_text(msg).await; });
            None
        });
    }

    // Keep webrtcbin at READY until PT is pinned (same fix as live camera view)
    wb.set_state(gst::State::Ready)?;

    // ── SDP offer → answer ────────────────────────────────────────────────────
    let sdp_msg = gst_sdp::SDPMessage::parse_buffer(offer_sdp.as_bytes())?;
    let remote  = gst_webrtc::WebRTCSessionDescription::new(
        gst_webrtc::WebRTCSDPType::Offer, sdp_msg,
    );

    let wb_neg  = wb.clone();
    let pay_neg = pay.clone();
    let dc_neg  = Arc::clone(&dc);
    let rt_neg  = rt.clone();

    let set_remote = gst::Promise::with_change_func(move |_| {
        let wb2  = wb_neg.clone();
        let pay2 = pay_neg.clone();
        let dc2  = Arc::clone(&dc_neg);
        let rt2  = rt_neg.clone();

        let create_ans = gst::Promise::with_change_func(move |reply| {
            let s = match reply { Ok(Some(s)) => s, _ => return };
            let answer = match s.value("answer").ok()
                .and_then(|v| v.get::<gst_webrtc::WebRTCSessionDescription>().ok())
            { Some(a) => a, None => return };

            wb2.emit_by_name::<()>("set-local-description", &[&answer, &None::<gst::Promise>]);

            let sdp_str = answer.sdp().to_string();
            // Pin the negotiated PT on rtph264pay to prevent caps race
            let pt: u32 = sdp_str.lines()
                .find(|l| l.starts_with("m=video"))
                .and_then(|l| l.split_whitespace().nth(3))
                .and_then(|s| s.parse().ok())
                .unwrap_or(96);
            pay2.set_property("pt", pt);
            wb2.sync_state_with_parent().ok();

            let msg = serde_json::json!({
                "type":     "STREAM_CLIP_ANSWER",
                "event_id": event_id,
                "sdp":      sdp_str,
            }).to_string();
            let dc3 = Arc::clone(&dc2);
            rt2.spawn(async move { let _ = dc3.send_text(msg).await; });
        });

        wb_neg.emit_by_name::<()>("create-answer", &[&None::<gst::Structure>, &create_ans]);
    });

    wb.emit_by_name::<()>("set-remote-description", &[&remote, &set_remote]);

    // ── Start pipeline (wb stays at READY until sync_state_with_parent above) ─
    pipeline.set_state(gst::State::Playing)?;
    info!("[clip_stream] event_id={event_id} → {clip_path}");

    // ── Route browser ICE candidates → webrtcbin ──────────────────────────────
    let wb_ice = wb.clone();
    rt.spawn(async move {
        while let Some(json) = ice_rx.recv().await {
            if let Ok(v) = serde_json::from_str::<serde_json::Value>(&json) {
                let candidate: String = v["candidate"].as_str().unwrap_or("").to_string();
                let mline: u32 = v["sdpMLineIndex"].as_u64().unwrap_or(0) as u32;
                wb_ice.emit_by_name::<()>("add-ice-candidate", &[&mline, &candidate]);
            }
        }
    });

    // ── Bus loop ──────────────────────────────────────────────────────────────
    let bus = pipeline.bus().unwrap();
    loop {
        if let Some(msg) = bus.timed_pop(50 * gst::ClockTime::MSECOND) {
            use gst::MessageView;
            match msg.view() {
                MessageView::Eos(_) => {
                    info!("[clip_stream] event_id={event_id} done");
                    let dc2 = Arc::clone(&dc);
                    rt.spawn(async move {
                        let _ = dc2.send_text(serde_json::json!({
                            "type": "STREAM_CLIP_DONE", "event_id": event_id,
                        }).to_string()).await;
                    });
                    break;
                }
                MessageView::Error(err) => {
                    error!("[clip_stream] GST error: {}", err.error());
                    let dc2 = Arc::clone(&dc);
                    rt.spawn(async move {
                        let _ = dc2.send_text(serde_json::json!({
                            "type": "STREAM_CLIP_ERROR",
                            "event_id": event_id,
                            "reason": "pipeline error",
                        }).to_string()).await;
                    });
                    break;
                }
                _ => {}
            }
        }
    }

    pipeline.set_state(gst::State::Null)?;
    Ok(())
}
