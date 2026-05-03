use std::collections::HashMap;
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::anyhow;
use futures_channel::mpsc::UnboundedSender;
use gstreamer as gst;
use gstreamer::prelude::*;
use gstreamer_app as gst_app;
use gstreamer_sdp as gst_sdp;
use gstreamer_webrtc as gst_webrtc;
use log::{error, info, warn};
use tokio::sync::mpsc as tokio_mpsc;
use tokio_tungstenite::tungstenite::protocol::Message;

use crate::event_store::EventStore;
use crate::rtsp_camera::SharedFrame;
use crate::webrtc_session::OfferPayload;

// ── Public command API ────────────────────────────────────────────────────────

pub enum PipelineCmd {
    AddViewer {
        session_id:   String,
        offer:        OfferPayload,
        signaling_tx: UnboundedSender<Message>,
        ice_rx:       tokio_mpsc::UnboundedReceiver<String>,
    },
    RemoveViewer {
        session_id: String,
    },
    StartRecording {
        event_id:  i64,
        clip_path: String,
    },
    StopRecording {
        event_id: i64,
    },
}

/// Handle to an always-on per-camera GStreamer pipeline.
/// Clone the cmd_tx to send commands from any task or thread.
pub struct CameraGstPipeline {
    pub cmd_tx: tokio_mpsc::Sender<PipelineCmd>,
}

impl CameraGstPipeline {
    pub fn new(
        camera_id:    String,
        rtsp_url:     String,
        event_store:  std::sync::Arc<std::sync::Mutex<EventStore>>,
        clips_dir:    String,
        shared_frame: SharedFrame,
        inference_tx: Option<tokio::sync::mpsc::Sender<image::RgbImage>>,
    ) -> anyhow::Result<Self> {
        let (cmd_tx, cmd_rx) = tokio_mpsc::channel(16);
        let rt = tokio::runtime::Handle::current();

        let cmd_tx_inner = cmd_tx.clone();
        std::thread::spawn(move || {
            if let Err(e) = pipeline_loop(camera_id, rtsp_url, event_store, clips_dir, shared_frame, inference_tx, cmd_tx_inner, cmd_rx, rt) {
                error!("[camera_pipeline] loop exited: {e}");
            }
        });

        Ok(Self { cmd_tx })
    }
}

// ── Internal branch state ─────────────────────────────────────────────────────

struct ViewerBranch {
    tee_src:  gst::Pad,
    queue:    gst::Element,
    pay:      gst::Element,
    webrtc:   gst::Element,
    event_id: Option<i64>,
}

struct RecordingBranch {
    /// YOLO event ids that fired while this recording was active and should
    /// share the same clip_path when the recording finalises.
    shared_event_ids: Vec<i64>,
    tee_src:          gst::Pad,
    queue:            gst::Element,
    parse:            gst::Element,
    mux:              gst::Element,
    filesink:         gst::Element,
}

// ── Pipeline loop (runs on a dedicated std::thread) ───────────────────────────

fn pipeline_loop(
    camera_id:    String,
    rtsp_url:     String,
    event_store:  std::sync::Arc<std::sync::Mutex<EventStore>>,
    clips_dir:    String,
    shared_frame: SharedFrame,
    inference_tx: Option<tokio::sync::mpsc::Sender<image::RgbImage>>,
    cmd_tx:       tokio_mpsc::Sender<PipelineCmd>,
    mut cmd_rx:   tokio_mpsc::Receiver<PipelineCmd>,
    rt:           tokio::runtime::Handle,
) -> anyhow::Result<()> {
    // Base pipeline: source + demux + parse + tee.
    // Recording and WebRTC branches are added dynamically.
    let pipeline_str = format!(
        "rtspsrc location=\"{rtsp_url}\" latency=100 name=src \
         ! rtph264depay \
         ! h264parse config-interval=-1 name=parser \
         ! tee name=t \
           t. ! queue ! fakesink sync=false name=placeholder \
           t. ! queue leaky=downstream max-size-buffers=2 \
              ! h264parse ! avdec_h264 ! tee name=rawt \
           rawt. ! queue leaky=downstream max-size-buffers=2 \
                 ! videoconvert \
                 ! videorate ! video/x-raw,framerate=2/1 \
                 ! jpegenc quality=85 \
                 ! appsink name=thumbnail sync=false emit-signals=true \
           rawt. ! queue leaky=downstream max-size-buffers=2 \
                 ! videoconvert ! video/x-raw,format=RGB \
                 ! videorate ! video/x-raw,framerate=2/1 \
                 ! appsink name=yolo sync=false emit-signals=true"
    );

    let pipeline = gst::parse::launch(&pipeline_str)?
        .downcast::<gst::Pipeline>()
        .map_err(|_| anyhow!("not a pipeline"))?;

    let tee = pipeline.by_name("t").unwrap();

    // Wire up thumbnail appsink → SharedFrame
    if let Some(el) = pipeline.by_name("thumbnail") {
        if let Ok(appsink) = el.downcast::<gst_app::AppSink>() {
            let frame_cb = shared_frame.clone();
            let rt_cb    = rt.clone();
            appsink.set_callbacks(
                gst_app::AppSinkCallbacks::builder()
                    .new_sample(move |sink| {
                        let sample = sink.pull_sample().map_err(|_| gst::FlowError::Error)?;
                        let buffer = sample.buffer().ok_or(gst::FlowError::Error)?;
                        let map = buffer.map_readable().map_err(|_| gst::FlowError::Error)?;
                        let jpeg = map.as_slice().to_vec();
                        let frame = frame_cb.clone();
                        rt_cb.spawn(async move { *frame.lock().await = Some(jpeg); });
                        Ok(gst::FlowSuccess::Ok)
                    })
                    .build(),
            );
            info!("[pipeline:{camera_id}] thumbnail appsink wired");
        }
    }

    // Wire YOLO appsink → inference channel
    if let Some(infer_tx) = inference_tx {
        if let Some(el) = pipeline.by_name("yolo") {
            if let Ok(appsink) = el.downcast::<gst_app::AppSink>() {
                appsink.set_callbacks(
                    gst_app::AppSinkCallbacks::builder()
                        .new_sample(move |sink| {
                            let sample = sink.pull_sample().map_err(|_| gst::FlowError::Error)?;
                            let caps   = sample.caps().ok_or(gst::FlowError::Error)?;
                            let s      = caps.structure(0).ok_or(gst::FlowError::Error)?;
                            let w: i32 = s.get("width").map_err(|_| gst::FlowError::Error)?;
                            let h: i32 = s.get("height").map_err(|_| gst::FlowError::Error)?;
                            let buf    = sample.buffer().ok_or(gst::FlowError::Error)?;
                            let map    = buf.map_readable().map_err(|_| gst::FlowError::Error)?;
                            if let Some(rgb) = image::RgbImage::from_raw(
                                w as u32, h as u32, map.as_slice().to_vec(),
                            ) {
                                let _ = infer_tx.try_send(rgb);
                            }
                            Ok(gst::FlowSuccess::Ok)
                        })
                        .build(),
                );
                info!("[pipeline:{camera_id}] YOLO appsink wired");
            }
        }
    }

    pipeline.set_state(gst::State::Playing)?;
    info!("[pipeline:{camera_id}] started (always-on)");

    let bus = pipeline.bus().unwrap();
    let mut viewers:              HashMap<String, ViewerBranch>  = HashMap::new();
    let mut recordings:           HashMap<i64, RecordingBranch>  = HashMap::new();
    // Tracks which event_id belongs to the current liveview recording so we can
    // stop exactly that branch when the last viewer disconnects.
    let mut liveview_recording_eid: Option<i64> = None;

    loop {
        // ── GStreamer bus ─────────────────────────────────────────────────────
        while let Some(msg) = bus.timed_pop(10 * gst::ClockTime::MSECOND) {
            use gst::MessageView;
            match msg.view() {
                MessageView::Error(err) => {
                    error!("[pipeline:{camera_id}] GST error: {} — {:?}",
                        err.error(), err.debug());
                }
                MessageView::Warning(w) => {
                    warn!("[pipeline:{camera_id}] GST warning: {}", w.error());
                }
                MessageView::Application(app) => {
                    // "recording-done" is posted by a filesink pad probe when EOS
                    // reaches it — that means mp4mux has flushed and the clip is valid.
                    // We can't rely on the pipeline-level EOS message because the other
                    // sinks (thumbnail, YOLO) keep running indefinitely.
                    if let Some(s) = app.structure().filter(|s| s.name() == "recording-done") {
                        let eid: i64     = s.get("event-id").unwrap_or(0);
                        let path: String = s.get("clip-path").unwrap_or_default();
                        if let Some(rec) = recordings.remove(&eid) {
                            info!("[pipeline:{camera_id}] clip finalised event_id={eid} → {path} (shared: {:?})", rec.shared_event_ids);
                            if let Ok(store) = event_store.lock() {
                                let _ = store.set_clip_path(eid, &path);
                                for shared_eid in &rec.shared_event_ids {
                                    let _ = store.set_clip_path(*shared_eid, &path);
                                }
                            }
                            cleanup_branch(&pipeline, &tee, rec.tee_src,
                                &[&rec.queue, &rec.parse, &rec.mux, &rec.filesink]);
                        }
                    }
                }
                _ => {}
            }
        }

        // ── Commands ──────────────────────────────────────────────────────────
        while let Ok(cmd) = cmd_rx.try_recv() {
            match cmd {
                PipelineCmd::AddViewer { session_id, offer, signaling_tx, ice_rx } => {
                    let unix_now = SystemTime::now()
                        .duration_since(UNIX_EPOCH).unwrap_or_default().as_secs() as i64;
                    let thumb = shared_frame.try_lock()
                        .ok()
                        .and_then(|g| g.clone())
                        .unwrap_or_default();
                    let event_id = event_store.lock().ok()
                        .and_then(|store| store.start_event(
                            &camera_id, 255, "liveview", 1.0, &thumb, unix_now,
                        ).ok());

                    // Start a liveview recording for the first viewer.
                    // Runs in parallel with any active YOLO recordings — each has its own tee branch.
                    if viewers.is_empty() {
                        if let Some(eid) = event_id {
                            let clip_path = format!("{clips_dir}/liveview_{eid}.mp4");
                            match start_recording(&pipeline, &tee, &camera_id, eid, clip_path) {
                                Ok(branch) => {
                                    liveview_recording_eid = Some(eid);
                                    recordings.insert(eid, branch);
                                }
                                Err(e) => error!("[pipeline:{camera_id}] liveview recording: {e}"),
                            }
                        }
                    }

                    match add_viewer(&pipeline, &tee, &camera_id, &session_id,
                                    offer, signaling_tx, ice_rx, &rt, event_id, cmd_tx.clone()) {
                        Ok(branch) => { viewers.insert(session_id, branch); }
                        Err(e) => error!("[pipeline:{camera_id}] add_viewer: {e}"),
                    }
                }
                PipelineCmd::RemoveViewer { session_id } => {
                    if let Some(branch) = viewers.remove(&session_id) {
                        if let Some(eid) = branch.event_id {
                            let unix_now = SystemTime::now()
                                .duration_since(UNIX_EPOCH).unwrap_or_default().as_secs() as i64;
                            if let Ok(store) = event_store.lock() {
                                let _ = store.end_event(eid, unix_now, None);
                            }
                        }
                        remove_viewer(&pipeline, &tee, &camera_id, &session_id, branch);
                        // Stop only the liveview recording when the last viewer leaves.
                        // Any YOLO recordings continue unaffected.
                        if viewers.is_empty() {
                            if let Some(lv_eid) = liveview_recording_eid.take() {
                                if let Some(rec) = recordings.get(&lv_eid) {
                                    stop_recording(&camera_id, rec);
                                    // branch stays in the map until EOS fires and cleanup_branch removes it
                                }
                            }
                        }
                    }
                }
                PipelineCmd::StartRecording { event_id, clip_path } => {
                    if let Some(lv_eid) = liveview_recording_eid {
                        // Liveview is already recording — piggyback on that clip instead of
                        // starting a second branch. The clip will be written to both events
                        // when the liveview recording finalises.
                        if let Some(rec) = recordings.get_mut(&lv_eid) {
                            rec.shared_event_ids.push(event_id);
                            info!("[pipeline:{camera_id}] YOLO event {event_id} shares liveview clip (event {lv_eid})");
                        }
                    } else {
                        match start_recording(&pipeline, &tee, &camera_id, event_id, clip_path) {
                            Ok(branch) => { recordings.insert(event_id, branch); }
                            Err(e) => error!("[pipeline:{camera_id}] start_recording: {e}"),
                        }
                    }
                }
                PipelineCmd::StopRecording { event_id } => {
                    if let Some(rec) = recordings.get(&event_id) {
                        stop_recording(&camera_id, rec);
                        // branch stays in the map until EOS fires and cleanup_branch removes it
                    }
                    // if event_id is a shared/piggybacked event it has no own branch — that's fine
                }
            }
        }
    }
}

// ── add_viewer ────────────────────────────────────────────────────────────────

fn add_viewer(
    pipeline:     &gst::Pipeline,
    tee:          &gst::Element,
    camera_id:    &str,
    session_id:   &str,
    offer:        OfferPayload,
    tx:           UnboundedSender<Message>,
    ice_rx:       tokio_mpsc::UnboundedReceiver<String>,
    rt:           &tokio::runtime::Handle,
    event_id:     Option<i64>,
    cmd_tx:       tokio_mpsc::Sender<PipelineCmd>,
) -> anyhow::Result<ViewerBranch> {
    // Build branch elements
    let queue  = gst::ElementFactory::make("queue").build()?;
    let pay    = gst::ElementFactory::make("rtph264pay")
                     .property("config-interval", -1i32)
                     .build()?;
    let webrtc = gst::ElementFactory::make("webrtcbin")
                     .name(&format!("wrtc_{session_id}"))
                     .property_from_str("bundle-policy", "max-bundle")
                     .build()?;

    pipeline.add_many([&queue, &pay, &webrtc])?;

    let tee_src = tee.request_pad_simple("src_%u")
        .ok_or_else(|| anyhow!("tee request_pad failed"))?;
    tee_src.link(&queue.static_pad("sink").unwrap())?;
    gst::Element::link_many([&queue, &pay, &webrtc])?;

    // queue and pay are passive — sync immediately to PLAYING
    queue.sync_state_with_parent()?;
    pay.sync_state_with_parent()?;

    // webrtcbin stays at READY until after SDP negotiation to avoid PT race
    webrtc.set_state(gst::State::Ready)?;

    // STUN / TURN
    webrtc.set_property_from_str("stun-server", "stun://stun.l.google.com:19302");
    if let (Some(host), Some(user), Some(cred)) = (
        offer.turn_host.as_deref().filter(|h| !h.is_empty()),
        offer.turn_username.as_deref(),
        offer.turn_credential.as_deref(),
    ) {
        let turn_uri = format!("turn://{user}:{cred}@{host}:3478");
        webrtc.emit_by_name::<bool>("add-turn-server", &[&turn_uri.as_str()]);
        info!("[pipeline:{camera_id}] TURN: {host}");
    }

    // ICE state — log transitions and send RemoveViewer on disconnect/failure/close
    let cid = camera_id.to_string();
    let sid = session_id.to_string();
    let cmd_tx_ice = cmd_tx.clone();
    let rt_ice = rt.clone();
    webrtc.connect("notify::ice-connection-state", false, move |values| {
        let el    = values[0].get::<gst::Element>().unwrap();
        let state = el.property::<gst_webrtc::WebRTCICEConnectionState>("ice-connection-state");
        info!("[pipeline:{cid}] session={sid} ICE → {state:?}");
        use gst_webrtc::WebRTCICEConnectionState as S;
        if matches!(state, S::Disconnected | S::Failed | S::Closed) {
            let tx  = cmd_tx_ice.clone();
            let sid = sid.clone();
            rt_ice.spawn(async move {
                let _ = tx.send(PipelineCmd::RemoveViewer { session_id: sid }).await;
            });
        }
        None
    });

    // ICE gathering state logging
    let cid2 = camera_id.to_string();
    let sid2 = session_id.to_string();
    webrtc.connect("notify::ice-gathering-state", false, move |values| {
        let el    = values[0].get::<gst::Element>().unwrap();
        let state = el.property::<gst_webrtc::WebRTCICEGatheringState>("ice-gathering-state");
        info!("[pipeline:{cid2}] session={sid2} ICE gathering → {state:?}");
        None
    });

    // on-ice-candidate → forward to cloud
    let tx_ice  = tx.clone();
    let sid_ice = session_id.to_string();
    webrtc.connect("on-ice-candidate", false, move |values| {
        let mline_index: u32  = values[1].get().expect("mline_index");
        let candidate: String = values[2].get().expect("candidate");
        let parts: Vec<&str>  = candidate.split_whitespace().collect();
        let addr  = parts.get(4).copied().unwrap_or("?");
        let port  = parts.get(5).copied().unwrap_or("?");
        let ctype = parts.get(7).copied().unwrap_or("?");
        info!("[pipeline] → ICE {ctype} {addr}:{port} mline={mline_index}");
        let payload = serde_json::json!({
            "session_id":    sid_ice,
            "candidate":     candidate,
            "sdpMLineIndex": mline_index,
            "sdpMid":        "",
        });
        let _ = tx_ice.unbounded_send(Message::Text(format!("ICE_CANDIDATE {payload}")));
        None
    });

    // SDP: set-remote-description → create-answer → set-local-description → PLAYING
    let sdp_msg    = gst_sdp::SDPMessage::parse_buffer(offer.sdp.as_bytes())?;
    let remote_sdp = gst_webrtc::WebRTCSessionDescription::new(
        gst_webrtc::WebRTCSDPType::Offer, sdp_msg,
    );

    let webrtc_ans   = webrtc.clone();
    let pay_ans      = pay.clone();
    let pipeline_ans = pipeline.clone();
    let tx_ans       = tx.clone();
    let sid_ans      = session_id.to_string();
    let rt_ans       = rt.clone();

    let set_remote = gst::Promise::with_change_func(move |_| {
        let webrtc2   = webrtc_ans.clone();
        let pay2      = pay_ans.clone();
        let pipeline2 = pipeline_ans.clone();
        let tx2       = tx_ans.clone();
        let sid2      = sid_ans.clone();
        let rt2       = rt_ans.clone();

        let create_ans = gst::Promise::with_change_func(move |reply| {
            let s = match reply {
                Ok(Some(s)) => s,
                other => { error!("[pipeline] create-answer reply: {other:?}"); return; }
            };
            let answer = match s.value("answer") {
                Ok(v) => match v.get::<gst_webrtc::WebRTCSessionDescription>() {
                    Ok(a) => a,
                    Err(e) => { error!("[pipeline] answer type: {e}"); return; }
                },
                Err(e) => { error!("[pipeline] no answer field: {e}"); return; }
            };

            webrtc2.emit_by_name::<()>("set-local-description", &[&answer, &None::<gst::Promise>]);

            let sdp_str = answer.sdp().to_string();

            // Extract negotiated PT and pin it on rtph264pay to prevent caps race
            let negotiated_pt: u32 = sdp_str.lines()
                .find(|l| l.starts_with("m=video"))
                .and_then(|l| l.split_whitespace().nth(3))
                .and_then(|s| s.parse().ok())
                .unwrap_or(96);
            pay2.set_property("pt", negotiated_pt);
            info!("[pipeline] session={sid2} negotiated pt={negotiated_pt}");

            let resp = serde_json::json!({ "session_id": sid2, "sdp": sdp_str });
            let _ = tx2.unbounded_send(Message::Text(format!("WEBRTC_ANSWER {resp}")));

            // Now that PT is pinned, let webrtcbin go to PLAYING
            if let Some(wrtc) = pipeline2.by_name(&format!("wrtc_{sid2}")) {
                if let Err(e) = wrtc.sync_state_with_parent() {
                    error!("[pipeline] sync webrtcbin state: {e}");
                }
            }

            // Force an immediate keyframe after 1s so the browser can start decoding
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
                        info!("[pipeline] force-key-unit sent: {ok}");
                    }
                }
            });
        });

        webrtc_ans.emit_by_name::<()>("create-answer", &[&None::<gst::Structure>, &create_ans]);
    });

    webrtc.emit_by_name::<()>("set-remote-description", &[&remote_sdp, &set_remote]);

    // Route incoming ICE candidates from cloud → webrtcbin (tokio task)
    let webrtc_ice = webrtc.clone();
    rt.spawn(async move {
        let mut ice_rx = ice_rx;
        while let Some(json) = ice_rx.recv().await {
            if let Ok(v) = serde_json::from_str::<serde_json::Value>(&json) {
                let candidate = v["candidate"].as_str().unwrap_or("").to_string();
                let mline: u32 = v["sdpMLineIndex"].as_u64().unwrap_or(0) as u32;
                webrtc_ice.emit_by_name::<()>("add-ice-candidate", &[&mline, &candidate]);
            }
        }
    });

    info!("[pipeline:{camera_id}] viewer {session_id} added");
    Ok(ViewerBranch { tee_src, queue, pay, webrtc, event_id })
}

// ── remove_viewer ─────────────────────────────────────────────────────────────

fn remove_viewer(
    pipeline:   &gst::Pipeline,
    tee:        &gst::Element,
    camera_id:  &str,
    session_id: &str,
    branch:     ViewerBranch,
) {
    if let Some(sink) = branch.queue.static_pad("sink") {
        let _ = branch.tee_src.unlink(&sink);
    }
    tee.release_request_pad(&branch.tee_src);
    for el in [&branch.webrtc, &branch.pay, &branch.queue] {
        el.set_state(gst::State::Null).ok();
        pipeline.remove(el).ok();
    }
    info!("[pipeline:{camera_id}] viewer {session_id} removed");
}

// ── start_recording ───────────────────────────────────────────────────────────

fn start_recording(
    pipeline:  &gst::Pipeline,
    tee:       &gst::Element,
    camera_id: &str,
    event_id:  i64,
    clip_path: String,
) -> anyhow::Result<RecordingBranch> {
    let queue    = gst::ElementFactory::make("queue").build()?;
    // h264parse converts Annex-B → AVCC format required by mp4mux
    let parse    = gst::ElementFactory::make("h264parse").build()?;
    let mux      = gst::ElementFactory::make("mp4mux")
                       .property("fragment-duration", 500u32)
                       .build()?;
    let filesink = gst::ElementFactory::make("filesink")
                       .property("location", &clip_path)
                       .property("sync", false)
                       .build()?;

    pipeline.add_many([&queue, &parse, &mux, &filesink])?;

    let tee_src = tee.request_pad_simple("src_%u")
        .ok_or_else(|| anyhow!("tee request_pad failed for recording"))?;
    tee_src.link(&queue.static_pad("sink").unwrap())?;
    gst::Element::link_many([&queue, &parse, &mux, &filesink])?;

    for el in [&queue, &parse, &mux, &filesink] {
        el.sync_state_with_parent()?;
    }

    // The pipeline-level EOS message never fires while the other sinks (thumbnail,
    // YOLO) are still running. Instead, probe the filesink's sink pad: when EOS
    // arrives there, mp4mux has already written the moov atom and the file is valid.
    // Post a custom application message so the bus loop can do cleanup + set_clip_path.
    let bus        = pipeline.bus().unwrap();
    let cid        = camera_id.to_string();
    let clip_probe = clip_path.clone();
    if let Some(pad) = filesink.static_pad("sink") {
        pad.add_probe(gst::PadProbeType::EVENT_DOWNSTREAM, move |_, info| {
            if let Some(gst::PadProbeData::Event(ref ev)) = info.data {
                if ev.type_() == gst::EventType::Eos {
                    let s = gst::Structure::builder("recording-done")
                        .field("event-id",  event_id)
                        .field("clip-path", clip_probe.as_str())
                        .build();
                    if let Err(e) = bus.post(gst::message::Application::new(s)) {
                        error!("[pipeline:{cid}] failed to post recording-done: {e}");
                    }
                }
            }
            gst::PadProbeReturn::Ok
        });
    }

    info!("[pipeline:{camera_id}] recording started → {clip_path}");
    Ok(RecordingBranch { shared_event_ids: vec![], tee_src, queue, parse, mux, filesink })
}

// ── stop_recording ────────────────────────────────────────────────────────────

fn stop_recording(camera_id: &str, rec: &RecordingBranch) {
    // Unlink from tee so no new data enters the recording branch
    if let Some(sink) = rec.queue.static_pad("sink") {
        let _ = rec.tee_src.unlink(&sink);
    }
    // Push EOS downstream through the branch — mp4mux writes its moov atom on EOS,
    // then filesink closes the file. The EOS message on the bus triggers cleanup.
    if let Some(src) = rec.queue.static_pad("src") {
        src.push_event(gst::event::Eos::new());
    }
    info!("[pipeline:{camera_id}] recording EOS sent, awaiting finalization");
}

// ── cleanup_branch ────────────────────────────────────────────────────────────

fn cleanup_branch(
    pipeline:  &gst::Pipeline,
    tee:       &gst::Element,
    tee_src:   gst::Pad,
    elements:  &[&gst::Element],
) {
    tee.release_request_pad(&tee_src);
    for el in elements {
        el.set_state(gst::State::Null).ok();
        pipeline.remove(*el).ok();
    }
}
