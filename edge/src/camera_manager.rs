use log::{error, info, warn};
use std::collections::HashMap;
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use axum::{
    Router,
    routing::{get, post},
    extract::{Path, Query, State},
    response::{Response, IntoResponse},
    http::{StatusCode, header, HeaderMap},
    Json,
};
use tokio::sync::Mutex;
use serde::Deserialize;

use crate::camera_pipeline::{CameraGstPipeline, PipelineCmd};
use crate::event_store::EventStore;
use crate::rtsp_camera::{SharedFrame, encode_jpeg_from_rgb};
use crate::yolo::Yolo;

pub struct CameraState {
    pub name:     String,
    pub frame:    SharedFrame,
    pub pipeline: Option<CameraGstPipeline>,
}

pub type FrameMap = Arc<Mutex<HashMap<String, CameraState>>>;

#[derive(Clone)]
struct AppState {
    frame_map:   FrameMap,
    working_dir: String,
    event_store: Arc<std::sync::Mutex<EventStore>>,
}

#[derive(Deserialize)]
struct CameraEntry {
    id: String,
    name: String,
    rtsp_url: String,
    #[serde(default = "default_fps")]
    #[allow(dead_code)]
    fps: u32,
    #[serde(default = "default_detect_classes")]
    detect_classes: Vec<usize>,
    #[serde(default = "default_confidence")]
    detect_confidence: f32,
    #[serde(default = "default_min_detections")]
    min_detections: u32,
    #[serde(default = "default_grace_secs")]
    grace_period_secs: u64,
    #[serde(default = "default_cooldown_secs")]
    cooldown_secs: u64,
}

fn default_fps()              -> u32       { 2 }
fn default_detect_classes()   -> Vec<usize>{ vec![0, 2] }  // person, car
fn default_confidence()       -> f32       { 0.75 }
fn default_min_detections()   -> u32       { 2 }
fn default_grace_secs()       -> u64       { 15 }
fn default_cooldown_secs()    -> u64       { 60 }

// ── Active-event state held in the inference thread ───────────────────────────

struct ActiveEvent {
    db_id:           i64,
    started_at:      Instant,
    last_seen_at:    Instant,
    best_confidence: f32,
    frame_count:     u32,
}

/// Load cameras from config.json, start retina thumbnail streams and
/// always-on GStreamer pipelines. Returns FrameMap for the HTTP server.
pub async fn start(working_dir: &str) -> (FrameMap, Arc<std::sync::Mutex<EventStore>>) {
    let frame_map: FrameMap = Arc::new(Mutex::new(HashMap::new()));
    let cameras = load_cameras(working_dir);

    let db_path   = format!("{}/events.db", working_dir);
    let clips_dir = format!("{}/clips", working_dir);
    std::fs::create_dir_all(&clips_dir).ok();

    let event_store = Arc::new(std::sync::Mutex::new(
        EventStore::new(&db_path).expect("failed to open event store"),
    ));

    if cameras.is_empty() {
        info!("[camera_manager] no cameras configured");
        return (frame_map, event_store);
    }

    info!("[camera_manager] starting {} camera(s)", cameras.len());

    for cam in cameras {
        let id   = cam.id.clone();
        let name = cam.name.clone();

        // Always-on GStreamer pipeline — WebRTC viewers + recording
        let frame: SharedFrame = Arc::new(Mutex::new(None));

        let (infer_tx, infer_rx) = tokio::sync::mpsc::channel::<image::RgbImage>(2);

        let pipeline = match CameraGstPipeline::new(
            cam.id.clone(),
            cam.rtsp_url.clone(),
            Arc::clone(&event_store),
            clips_dir.clone(),
            Arc::clone(&frame),
            Some(infer_tx),
        ) {
            Ok(p) => {
                info!("[camera_manager] GStreamer pipeline started for {id}");
                Some(p)
            }
            Err(e) => {
                warn!("[camera_manager] GStreamer pipeline failed for {id}: {e}");
                None
            }
        };

        // Spawn inference thread (blocking — YOLO is CPU-bound)
        let pipeline_cmd_tx = pipeline.as_ref().map(|p| p.cmd_tx.clone());
        spawn_inference_thread(
            cam.id.clone(),
            working_dir.to_string(),
            clips_dir.clone(),
            cam.detect_classes.clone(),
            cam.detect_confidence,
            cam.min_detections,
            Duration::from_secs(cam.grace_period_secs),
            Duration::from_secs(cam.cooldown_secs),
            Arc::clone(&event_store),
            pipeline_cmd_tx,
            infer_rx,
        );

        frame_map.lock().await.insert(id, CameraState { name, frame, pipeline });
    }

    (frame_map, event_store)
}

// ── Inference thread ──────────────────────────────────────────────────────────

#[allow(clippy::too_many_arguments)]
fn spawn_inference_thread(
    camera_id:       String,
    working_dir:     String,
    clips_dir:       String,
    detect_classes:  Vec<usize>,
    min_confidence:  f32,
    min_detections:  u32,
    grace_period:    Duration,
    cooldown:        Duration,
    event_store:     Arc<std::sync::Mutex<EventStore>>,
    pipeline_tx:     Option<tokio::sync::mpsc::Sender<PipelineCmd>>,
    mut frame_rx:    tokio::sync::mpsc::Receiver<image::RgbImage>,
) {
    const MAX_EVENT_DURATION: Duration = Duration::from_secs(3 * 60);
    std::thread::spawn(move || {
        let model_path = format!("{working_dir}/models/yolo11n.onnx");
        let mut yolo = match Yolo::new(&model_path) {
            Ok(y) => y,
            Err(e) => { error!("[infer:{camera_id}] YOLO load failed: {e}"); return; }
        };
        info!("[infer:{camera_id}] ready, classes={detect_classes:?}");

        let mut active:     HashMap<usize, ActiveEvent> = HashMap::new();
        let mut last_ended: HashMap<usize, Instant>     = HashMap::new();

        loop {
            let rgb = match frame_rx.blocking_recv() {
                Some(f) => f,
                None    => { info!("[infer:{camera_id}] channel closed"); break; }
            };

            let now = Instant::now();
            let unix_now = SystemTime::now()
                .duration_since(UNIX_EPOCH).unwrap_or_default().as_secs() as i64;

            // ── 1. Expire events ──────────────────────────────────────────────
            // Two end conditions:
            //   a) grace period — YOLO hasn't seen the threat for N seconds
            //   b) 3-minute cap — safety net so an event never runs forever
            let expired: Vec<usize> = active.iter()
                .filter(|(_, ev)| {
                    now.duration_since(ev.last_seen_at) > grace_period
                        || now.duration_since(ev.started_at) > MAX_EVENT_DURATION
                })
                .map(|(cls, _)| *cls)
                .collect();

            for cls in expired {
                if let Some(ev) = active.remove(&cls) {
                    let capped = now.duration_since(ev.started_at) > MAX_EVENT_DURATION;
                    if ev.frame_count >= min_detections {
                        if let Ok(store) = event_store.lock() {
                            let _ = store.end_event(ev.db_id, unix_now, None);
                        }
                        if let Some(ref tx) = pipeline_tx {
                            let _ = tx.blocking_send(PipelineCmd::StopRecording { event_id: ev.db_id });
                        }
                        let reason = if capped { "3-min cap" } else { "no threat" };
                        info!("[infer:{camera_id}] event {} ended ({} frames, {reason})",
                            ev.db_id, ev.frame_count);
                    } else {
                        // Too few detections — noise, discard
                        if let Ok(store) = event_store.lock() {
                            let _ = store.cancel_event(ev.db_id);
                        }
                        if let Some(ref tx) = pipeline_tx {
                            let _ = tx.blocking_send(PipelineCmd::StopRecording { event_id: ev.db_id });
                        }
                    }
                    last_ended.insert(cls, now);
                }
            }

            // ── 2. Run YOLO ───────────────────────────────────────────────────
            let detections = match yolo.detect(&rgb) {
                Ok(d)  => d,
                Err(e) => { error!("[infer:{camera_id}] {e}"); continue; }
            };

            let relevant: Vec<_> = detections.iter()
                .filter(|d| detect_classes.contains(&d.class_id) && d.confidence >= min_confidence)
                .collect();

            // ── 3. Update event state ─────────────────────────────────────────
            for det in relevant {
                let cls = det.class_id;

                if last_ended.get(&cls).map_or(false, |t| now.duration_since(*t) < cooldown) {
                    continue; // still in cooldown
                }

                // Encode JPEG only when needed (new event or better frame)
                match active.get_mut(&cls) {
                    Some(ev) => {
                        ev.last_seen_at = now;
                        ev.frame_count += 1;
                        if det.confidence > ev.best_confidence {
                            ev.best_confidence = det.confidence;
                            if let Ok(jpeg) = encode_jpeg_from_rgb(&rgb) {
                                if let Ok(store) = event_store.lock() {
                                    let _ = store.update_best_frame(ev.db_id, &jpeg, det.confidence);
                                }
                            }
                        } else if let Ok(store) = event_store.lock() {
                            let _ = store.increment_frame_count(ev.db_id);
                        }
                    }
                    None => {
                        // Start new event
                        let jpeg = encode_jpeg_from_rgb(&rgb).unwrap_or_default();
                        let db_id = event_store.lock().ok()
                            .and_then(|store| store.start_event(
                                &camera_id, cls, det.class_name,
                                det.confidence, &jpeg, unix_now,
                            ).ok())
                            .unwrap_or(0);

                        if db_id == 0 { continue; }

                        let clip_path = format!("{clips_dir}/event_{db_id}.mp4");
                        if let Some(ref tx) = pipeline_tx {
                            let _ = tx.blocking_send(PipelineCmd::StartRecording {
                                event_id: db_id,
                                clip_path: clip_path.clone(),
                            });
                        }
                        active.insert(cls, ActiveEvent {
                            db_id,
                            started_at:      now,
                            last_seen_at:    now,
                            best_confidence: det.confidence,
                            frame_count:     1,
                        });
                        info!("[infer:{camera_id}] {} event started (id={db_id})", det.class_name);
                    }
                }
            }
        }
    });
}

async fn cors_layer(response: axum::response::Response) -> axum::response::Response {
    let mut r = response;
    r.headers_mut().insert(
        header::ACCESS_CONTROL_ALLOW_ORIGIN,
        axum::http::HeaderValue::from_static("*"),
    );
    r
}

/// Serve camera HTTP endpoints. Owns `working_dir` so `/reload` can re-read config.
pub async fn serve(
    frame_map:   FrameMap,
    working_dir: &str,
    event_store: Arc<std::sync::Mutex<EventStore>>,
    port:        u16,
) {
    let state = AppState { frame_map, working_dir: working_dir.to_string(), event_store };
    let app = Router::new()
        .route("/frame/:camera_id",  get(frame_handler))
        .route("/cameras",           get(list_handler))
        .route("/events",            get(events_handler))
        .route("/events/:id/frame",  get(event_frame_handler))
        .route("/events/:id/clip",   get(event_clip_handler))
        .route("/stream/:camera_id",    get(mjpeg_handler))
        .route("/preview",           post(preview_handler))
        .route("/reload",            post(reload_handler))
        .layer(axum::middleware::map_response(cors_layer))
        .with_state(state);

    let addr = format!("127.0.0.1:{}", port);
    info!("[camera_manager] HTTP server on {}", addr);

    let listener = tokio::net::TcpListener::bind(&addr).await.unwrap();
    axum::serve(listener, app).await.unwrap();
}

async fn frame_handler(
    Path(camera_id): Path<String>,
    State(state): State<AppState>,
) -> impl IntoResponse {
    let map = state.frame_map.lock().await;
    match map.get(&camera_id) {
        None => (StatusCode::NOT_FOUND, "camera not found").into_response(),
        Some(cam) => {
            let frame = cam.frame.lock().await;
            match frame.as_ref() {
                None => (StatusCode::SERVICE_UNAVAILABLE, "no frame yet").into_response(),
                Some(jpeg) => Response::builder()
                    .status(StatusCode::OK)
                    .header(header::CONTENT_TYPE, "image/jpeg")
                    .header(header::CACHE_CONTROL, "no-store")
                    .body(axum::body::Body::from(jpeg.clone()))
                    .unwrap()
                    .into_response(),
            }
        }
    }
}

async fn list_handler(State(state): State<AppState>) -> impl IntoResponse {
    let map = state.frame_map.lock().await;
    let cameras: Vec<serde_json::Value> = map.iter().map(|(id, cam)| {
        serde_json::json!({"id": id, "name": cam.name})
    }).collect();
    axum::Json(cameras).into_response()
}

async fn reload_handler(State(state): State<AppState>) -> impl IntoResponse {
    let new_cameras = load_cameras(&state.working_dir);
    let mut map = state.frame_map.lock().await;

    // Start streams for cameras not yet in the map
    let mut started = 0u32;
    for cam in &new_cameras {
        if !map.contains_key(&cam.id) {
            let frame: SharedFrame = Arc::new(Mutex::new(None));
            map.insert(cam.id.clone(), CameraState {
                name: cam.name.clone(),
                frame,
                pipeline: None,   // TODO: spin up GStreamer pipeline on reload too
            });
            info!("[camera_manager] reload: started camera {}", cam.id);
            started += 1;
        }
    }

    // Remove streams for cameras no longer in config
    let current_ids: std::collections::HashSet<&str> =
        new_cameras.iter().map(|c| c.id.as_str()).collect();
    let removed: Vec<String> = map.keys()
        .filter(|id| !current_ids.contains(id.as_str()))
        .cloned()
        .collect();
    for id in &removed {
        map.remove(id);
        info!("[camera_manager] reload: removed camera {}", id);
    }

    let msg = format!("started={} removed={}", started, removed.len());
    info!("[camera_manager] reload done: {}", msg);
    (StatusCode::OK, msg).into_response()
}

async fn preview_handler(
    Json(body): Json<serde_json::Value>,
) -> impl IntoResponse {
    let rtsp_url = match body.get("rtsp_url").and_then(|v| v.as_str()) {
        Some(u) => u.to_string(),
        None => return (StatusCode::BAD_REQUEST, "missing rtsp_url").into_response(),
    };

    match crate::rtsp_camera::grab_one_frame(&rtsp_url).await {
        Ok(jpeg) => Response::builder()
            .status(StatusCode::OK)
            .header(header::CONTENT_TYPE, "image/jpeg")
            .header(header::CACHE_CONTROL, "no-store")
            .body(axum::body::Body::from(jpeg))
            .unwrap()
            .into_response(),
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
    }
}

async fn mjpeg_handler(
    Path(camera_id): Path<String>,
    State(state): State<AppState>,
) -> impl IntoResponse {
    let frame_store = {
        let map = state.frame_map.lock().await;
        map.get(&camera_id).map(|cam| Arc::clone(&cam.frame))
    };
    let frame_store = match frame_store {
        Some(f) => f,
        None => return (StatusCode::NOT_FOUND, "camera not found").into_response(),
    };
    info!("[mjpeg:{camera_id}] stream started");

    let stream = futures::stream::unfold(frame_store, |store| async move {
        // Wait until a real frame is available — never yield empty bytes
        // (a zero-length chunk in HTTP chunked encoding signals end-of-body).
        let jpeg = loop {
            tokio::time::sleep(std::time::Duration::from_millis(200)).await;
            if let Some(j) = store.lock().await.clone() { break j; }
        };
        let header = format!(
            "--frame\r\nContent-Type: image/jpeg\r\nContent-Length: {}\r\n\r\n",
            jpeg.len()
        );
        let mut v = Vec::with_capacity(header.len() + jpeg.len() + 2);
        v.extend_from_slice(header.as_bytes());
        v.extend_from_slice(&jpeg);
        v.extend_from_slice(b"\r\n");
        Some((Ok::<_, std::convert::Infallible>(bytes::Bytes::from(v)), store))
    });

    Response::builder()
        .status(StatusCode::OK)
        .header(header::CONTENT_TYPE, "multipart/x-mixed-replace;boundary=frame")
        .header(header::CACHE_CONTROL, "no-cache")
        .header(header::ACCESS_CONTROL_ALLOW_ORIGIN, "*")
        .body(axum::body::Body::from_stream(stream))
        .unwrap()
        .into_response()
}


#[derive(Deserialize)]
struct EventsQuery {
    camera_id: Option<String>,
    #[serde(default = "default_event_limit")]
    limit: usize,
    #[serde(default)]
    since: i64,
}
fn default_event_limit() -> usize { 50 }

async fn events_handler(
    Query(q): Query<EventsQuery>,
    State(state): State<AppState>,
) -> impl IntoResponse {
    let store = match state.event_store.lock() {
        Ok(s) => s,
        Err(_) => return (StatusCode::INTERNAL_SERVER_ERROR, "lock error").into_response(),
    };
    let result = match &q.camera_id {
        Some(cam_id) => store.list(cam_id, q.since, q.limit),
        None         => store.list_all(q.since, q.limit),
    };
    match result {
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
        Ok(events) => {
            let json: Vec<serde_json::Value> = events.iter().map(|e| serde_json::json!({
                "id":              e.id,
                "camera_id":       e.camera_id,
                "class_name":      e.class_name,
                "started_at":      e.started_at,
                "ended_at":        e.ended_at,
                "best_confidence": e.best_confidence,
                "frame_count":     e.frame_count,
                "clip_path":       e.clip_path,
            })).collect();
            axum::Json(json).into_response()
        }
    }
}

async fn event_frame_handler(
    Path(id): Path<i64>,
    State(state): State<AppState>,
) -> impl IntoResponse {
    let store = match state.event_store.lock() {
        Ok(s) => s,
        Err(_) => return (StatusCode::INTERNAL_SERVER_ERROR, "lock error").into_response(),
    };
    match store.get_frame(id) {
        Ok(jpeg) => Response::builder()
            .status(StatusCode::OK)
            .header(header::CONTENT_TYPE, "image/jpeg")
            .header(header::CACHE_CONTROL, "max-age=3600")
            .body(axum::body::Body::from(jpeg))
            .unwrap()
            .into_response(),
        Err(_) => (StatusCode::NOT_FOUND, "frame not found").into_response(),
    }
}

async fn event_clip_handler(
    Path(id): Path<i64>,
    headers: HeaderMap,
    State(state): State<AppState>,
) -> impl IntoResponse {
    let clip_path = {
        let store = match state.event_store.lock() {
            Ok(s) => s,
            Err(_) => return (StatusCode::INTERNAL_SERVER_ERROR, "lock error").into_response(),
        };
        match store.get_clip_path(id) {
            Ok(Some(p)) => p,
            Ok(None)    => return (StatusCode::NOT_FOUND, "no recording for this event").into_response(),
            Err(_)      => return (StatusCode::NOT_FOUND, "event not found").into_response(),
        }
    };

    let data = match tokio::fs::read(&clip_path).await {
        Ok(d)  => d,
        Err(_) => return (StatusCode::NOT_FOUND, "clip file missing from disk").into_response(),
    };
    let file_size = data.len() as u64;

    if let Some((start, end)) = headers
        .get(header::RANGE)
        .and_then(|v| v.to_str().ok())
        .and_then(|r| parse_byte_range(r, file_size))
    {
        let len   = end - start + 1;
        let slice = data[start as usize..=end as usize].to_vec();
        return Response::builder()
            .status(StatusCode::PARTIAL_CONTENT)
            .header(header::CONTENT_TYPE,  "video/mp4")
            .header(header::CONTENT_LENGTH, len)
            .header(header::CONTENT_RANGE, format!("bytes {start}-{end}/{file_size}"))
            .header(header::ACCEPT_RANGES,  "bytes")
            .body(axum::body::Body::from(slice))
            .unwrap()
            .into_response();
    }

    Response::builder()
        .status(StatusCode::OK)
        .header(header::CONTENT_TYPE,  "video/mp4")
        .header(header::CONTENT_LENGTH, file_size)
        .header(header::ACCEPT_RANGES,  "bytes")
        .body(axum::body::Body::from(data))
        .unwrap()
        .into_response()
}

fn parse_byte_range(s: &str, file_size: u64) -> Option<(u64, u64)> {
    let s     = s.strip_prefix("bytes=")?;
    let mut p = s.splitn(2, '-');
    let start: u64 = p.next()?.parse().ok()?;
    let end:   u64 = p.next()
        .and_then(|e| if e.is_empty() { None } else { e.parse().ok() })
        .unwrap_or_else(|| file_size.saturating_sub(1))
        .min(file_size.saturating_sub(1));
    if file_size == 0 || start > end { return None; }
    Some((start, end))
}

fn load_cameras(working_dir: &str) -> Vec<CameraEntry> {
    let path = format!("{}/config.json", working_dir);
    let content = match std::fs::read_to_string(&path) {
        Ok(c) => c,
        Err(_) => return vec![],
    };
    let v: serde_json::Value = match serde_json::from_str(&content) {
        Ok(v) => v,
        Err(e) => {
            warn!("[camera_manager] config parse error: {e}");
            return vec![];
        }
    };
    match v.get("cameras") {
        None => vec![],
        Some(arr) => serde_json::from_value(arr.clone()).unwrap_or_else(|e| {
            warn!("[camera_manager] cameras parse error: {e}");
            vec![]
        }),
    }
}
