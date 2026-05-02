use log::{info, warn};
use std::collections::HashMap;
use std::sync::Arc;
use axum::{
    Router,
    routing::{get, post},
    extract::{Path, State},
    response::{Response, IntoResponse},
    http::{StatusCode, header},
    Json,
};
use tokio::sync::Mutex;
use serde::Deserialize;

use crate::rtsp_camera::{CameraConfig, SharedFrame, start as start_camera};

pub struct CameraState {
    pub name:     String,
    pub rtsp_url: String,
    pub frame:    SharedFrame,
}

pub type FrameMap = Arc<Mutex<HashMap<String, CameraState>>>;

#[derive(Clone)]
struct AppState {
    frame_map: FrameMap,
    working_dir: String,
}

#[derive(Deserialize)]
struct CameraEntry {
    id: String,
    name: String,
    rtsp_url: String,
    #[serde(default = "default_fps")]
    fps: u32,
}

fn default_fps() -> u32 { 1 }

/// Load cameras from config.json and start a stream task for each.
/// Returns a map of camera_id → SharedFrame for the HTTP server.
pub async fn start(working_dir: &str) -> FrameMap {
    let frame_map: FrameMap = Arc::new(Mutex::new(HashMap::new()));
    let cameras = load_cameras(working_dir);

    if cameras.is_empty() {
        info!("[camera_manager] no cameras configured");
        return frame_map;
    }

    info!("[camera_manager] starting {} camera(s)", cameras.len());

    for cam in cameras {
        let id       = cam.id.clone();
        let name     = cam.name.clone();
        let rtsp_url = cam.rtsp_url.clone();
        let cfg = CameraConfig {
            id: cam.id,
            name: cam.name,
            rtsp_url: cam.rtsp_url,
            fps: cam.fps,
        };
        let frame = start_camera(cfg).await;
        frame_map.lock().await.insert(id, CameraState { name, rtsp_url, frame });
    }

    frame_map
}

/// Serve camera HTTP endpoints. Owns `working_dir` so `/reload` can re-read config.
pub async fn serve(frame_map: FrameMap, working_dir: &str, port: u16) {
    let state = AppState { frame_map, working_dir: working_dir.to_string() };
    let app = Router::new()
        .route("/frame/:camera_id", get(frame_handler))
        .route("/cameras", get(list_handler))
        .route("/preview", post(preview_handler))
        .route("/reload", post(reload_handler))
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
            let cfg = CameraConfig {
                id: cam.id.clone(),
                name: cam.name.clone(),
                rtsp_url: cam.rtsp_url.clone(),
                fps: cam.fps,
            };
            let frame = start_camera(cfg).await;
            map.insert(cam.id.clone(), CameraState {
                name: cam.name.clone(),
                rtsp_url: cam.rtsp_url.clone(),
                frame,
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
