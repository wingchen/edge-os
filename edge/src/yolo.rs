use anyhow::anyhow;
use image::RgbImage;
use log::info;
use ort::{session::Session, value::Tensor};

const INPUT_SIZE: u32   = 640;
const CONF_THRESH: f32  = 0.25;
const NMS_THRESH:  f32  = 0.45;
const N_CLASSES:   usize = 80;
const N_ANCHORS:   usize = 8400;

pub struct Detection {
    pub class_id:   usize,
    pub class_name: &'static str,
    pub confidence: f32,
    /// Bounding box in normalised image coords [0..1]
    pub x1: f32, pub y1: f32,
    pub x2: f32, pub y2: f32,
}

pub struct Yolo {
    session: Session,
}

const MODEL_URL: &str =
    "https://github.com/ultralytics/assets/releases/download/v8.4.0/yolo11n.onnx";

/// Download the model if it doesn't exist. Saves atomically via a .download
/// temp file so a interrupted download doesn't leave a corrupt model.
fn ensure_model(model_path: &str) -> anyhow::Result<()> {
    if std::path::Path::new(model_path).exists() {
        return Ok(());
    }

    info!("[yolo] model not found at {model_path}");
    info!("[yolo] downloading YOLOv8n (~6 MB) from {MODEL_URL}");

    if let Some(parent) = std::path::Path::new(model_path).parent() {
        std::fs::create_dir_all(parent)?;
    }

    let response = reqwest::blocking::get(MODEL_URL)
        .map_err(|e| anyhow::anyhow!("download request failed: {e}"))?;

    if !response.status().is_success() {
        return Err(anyhow::anyhow!("download HTTP {}", response.status()));
    }

    let bytes = response.bytes()
        .map_err(|e| anyhow::anyhow!("reading download body failed: {e}"))?;

    // Write to a temp file first so a crash mid-write doesn't corrupt the model
    let tmp = format!("{model_path}.download");
    std::fs::write(&tmp, &bytes)?;
    std::fs::rename(&tmp, model_path)?;

    info!("[yolo] model saved ({:.1} MB) → {model_path}", bytes.len() as f64 / 1e6);
    Ok(())
}

impl Yolo {
    /// Load (or download) a YOLOv8n ONNX model.
    /// If the file doesn't exist it is fetched from the official Ultralytics
    /// GitHub release and saved to `model_path` before loading.
    pub fn new(model_path: &str) -> anyhow::Result<Self> {
        ensure_model(model_path)?;
        let session = Session::builder()?.commit_from_file(model_path)?;
        info!("[yolo] model loaded from {model_path}");
        Ok(Self { session })
    }

    pub fn detect(&mut self, img: &RgbImage) -> anyhow::Result<Vec<Detection>> {
        let sz   = INPUT_SIZE as usize;
        let data = preprocess(img);

        // ort 2.0-rc: Tensor::from_array((shape_slice, data_slice))
        // from_array needs (shape, Vec<T>) — not a slice
        let tensor = Tensor::<f32>::from_array(
            ([1i64, 3, sz as i64, sz as i64], data)
        )?;

        // inputs! returns Vec (not Result) in 2.0-rc — no ? here
        let outputs = self.session.run(ort::inputs!["images" => tensor])?;

        // try_extract_tensor returns (Shape, &[T])
        let (_, raw) = outputs["output0"].try_extract_tensor::<f32>()?;
        postprocess(raw)
    }
}

// ── Preprocessing ─────────────────────────────────────────────────────────────

fn preprocess(img: &RgbImage) -> Vec<f32> {
    use image::imageops::FilterType;
    let sz      = INPUT_SIZE as usize;
    let resized = image::imageops::resize(img, INPUT_SIZE, INPUT_SIZE, FilterType::Triangle);
    let mut out = vec![0.0f32; 3 * sz * sz];
    for y in 0..sz {
        for x in 0..sz {
            let p = resized.get_pixel(x as u32, y as u32);
            // NCHW layout: channel × height × width
            out[0 * sz * sz + y * sz + x] = p[0] as f32 / 255.0; // R
            out[1 * sz * sz + y * sz + x] = p[1] as f32 / 255.0; // G
            out[2 * sz * sz + y * sz + x] = p[2] as f32 / 255.0; // B
        }
    }
    out
}

// ── Postprocessing ────────────────────────────────────────────────────────────

fn postprocess(data: &[f32]) -> anyhow::Result<Vec<Detection>> {
    // YOLOv8 output: [1, 84, 8400] in row-major order
    // index for [batch=0, dim=d, anchor=i]: d * N_ANCHORS + i
    if data.len() < (4 + N_CLASSES) * N_ANCHORS {
        return Err(anyhow!("output too small: {} elements", data.len()));
    }

    let mut dets: Vec<Detection> = Vec::new();
    for i in 0..N_ANCHORS {
        let cx = data[0 * N_ANCHORS + i];
        let cy = data[1 * N_ANCHORS + i];
        let bw = data[2 * N_ANCHORS + i];
        let bh = data[3 * N_ANCHORS + i];

        let (best_class, best_score) = (0..N_CLASSES)
            .map(|c| (c, data[(4 + c) * N_ANCHORS + i]))
            .max_by(|a, b| a.1.partial_cmp(&b.1).unwrap())
            .unwrap_or((0, 0.0));

        if best_score < CONF_THRESH { continue; }

        let s  = INPUT_SIZE as f32;
        let x1 = ((cx - bw / 2.0) / s).clamp(0.0, 1.0);
        let y1 = ((cy - bh / 2.0) / s).clamp(0.0, 1.0);
        let x2 = ((cx + bw / 2.0) / s).clamp(0.0, 1.0);
        let y2 = ((cy + bh / 2.0) / s).clamp(0.0, 1.0);

        dets.push(Detection {
            class_id:   best_class,
            class_name: class_name(best_class),
            confidence: best_score,
            x1, y1, x2, y2,
        });
    }

    Ok(nms(dets))
}

// ── NMS ───────────────────────────────────────────────────────────────────────

fn nms(mut dets: Vec<Detection>) -> Vec<Detection> {
    dets.sort_by(|a, b| b.confidence.partial_cmp(&a.confidence).unwrap());
    let mut kept: Vec<Detection> = Vec::new();
    while !dets.is_empty() {
        let top = dets.remove(0);
        dets.retain(|d| d.class_id != top.class_id || iou(&top, d) <= NMS_THRESH);
        kept.push(top);
    }
    kept
}

fn iou(a: &Detection, b: &Detection) -> f32 {
    let ix1   = a.x1.max(b.x1);
    let iy1   = a.y1.max(b.y1);
    let ix2   = a.x2.min(b.x2);
    let iy2   = a.y2.min(b.y2);
    let inter = (ix2 - ix1).max(0.0) * (iy2 - iy1).max(0.0);
    let union = (a.x2 - a.x1) * (a.y2 - a.y1) + (b.x2 - b.x1) * (b.y2 - b.y1) - inter;
    if union <= 0.0 { 0.0 } else { inter / union }
}

// ── COCO class names (80 classes) ────────────────────────────────────────────

pub fn class_name(id: usize) -> &'static str {
    const NAMES: &[&str] = &[
        "person","bicycle","car","motorcycle","airplane","bus","train","truck",
        "boat","traffic light","fire hydrant","stop sign","parking meter","bench",
        "bird","cat","dog","horse","sheep","cow","elephant","bear","zebra",
        "giraffe","backpack","umbrella","handbag","tie","suitcase","frisbee",
        "skis","snowboard","sports ball","kite","baseball bat","baseball glove",
        "skateboard","surfboard","tennis racket","bottle","wine glass","cup",
        "fork","knife","spoon","bowl","banana","apple","sandwich","orange",
        "broccoli","carrot","hot dog","pizza","donut","cake","chair","couch",
        "potted plant","bed","dining table","toilet","tv","laptop","mouse",
        "remote","keyboard","cell phone","microwave","oven","toaster","sink",
        "refrigerator","book","clock","vase","scissors","teddy bear",
        "hair drier","toothbrush",
    ];
    NAMES.get(id).copied().unwrap_or("unknown")
}
