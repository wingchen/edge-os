use log::{debug, info, warn, error};
use std::sync::Arc;
use tokio::sync::Mutex;
use futures::StreamExt;
use openh264::formats::YUVSource;
use url::Url;
use retina::client::{Credentials, PlayOptions, Session, SessionOptions, SetupOptions};
use retina::codec::CodecItem;
use openh264::decoder::Decoder;

#[derive(Clone)]
pub struct CameraConfig {
    pub id: String,
    pub name: String,
    pub rtsp_url: String,
    pub fps: u32,
}

/// Latest JPEG frame shared between the stream task and HTTP server.
pub type SharedFrame = Arc<Mutex<Option<Vec<u8>>>>;

/// Spawn a task that continuously pulls frames from an RTSP stream and stores
/// the latest JPEG in a shared frame store. Reconnects automatically on error.
pub async fn start(camera: CameraConfig) -> SharedFrame {
    let frame_store: SharedFrame = Arc::new(Mutex::new(None));
    let store = Arc::clone(&frame_store);

    tokio::spawn(async move {
        loop {
            info!("[camera:{}] connecting to {}", camera.id, camera.rtsp_url);
            match run_stream(&camera, Arc::clone(&store)).await {
                Ok(_) => info!("[camera:{}] stream ended, reconnecting…", camera.id),
                Err(e) => warn!("[camera:{}] stream error: {e}, reconnecting in 5s…", camera.id),
            }
            tokio::time::sleep(std::time::Duration::from_secs(5)).await;
        }
    });

    frame_store
}

async fn run_stream(camera: &CameraConfig, store: SharedFrame) -> anyhow::Result<()> {
    let mut url = Url::parse(&camera.rtsp_url)?;

    let creds = if !url.username().is_empty() {
        let username = url.username().to_string();
        let password = url.password().unwrap_or("").to_string();
        let _ = url.set_username("");
        let _ = url.set_password(None);
        Some(Credentials { username, password })
    } else {
        None
    };

    let session_opts = SessionOptions::default().creds(creds);
    let mut session = Session::describe(url, session_opts).await?;

    // Find the first H.264 video stream
    let video_idx = session
        .streams()
        .iter()
        .position(|s| s.media() == "video" && s.encoding_name() == "h264")
        .ok_or_else(|| anyhow::anyhow!("no H.264 stream found"))?;

    session.setup(video_idx, SetupOptions::default()
        .frame_format(retina::codec::FrameFormat::SIMPLE)).await?;

    // Extract SPS/PPS before consuming session with play()
    let sps_pps: Option<(Vec<u8>, Vec<u8>)> = match session.streams()[video_idx].parameters() {
        Some(retina::codec::ParametersRef::Video(vp)) => {
            match vp.codec_params() {
                retina::codec::VideoParametersCodec::H264 { sps, pps } => {
                    info!("[camera:{}] SPS/PPS from SDP — sps={} bytes, pps={} bytes",
                        camera.id, sps.len(), pps.len());
                    Some((sps.to_vec(), pps.to_vec()))
                }
                _ => None,
            }
        }
        _ => None,
    };

    let mut play = session
        .play(PlayOptions::default())
        .await?
        .demuxed()?;

    let mut decoder = Decoder::new()?;

    if let Some((sps, pps)) = sps_pps {
        let mut buf = vec![0u8, 0, 0, 1];
        buf.extend_from_slice(&sps);
        let _ = decoder.decode(&buf);
        let mut buf = vec![0u8, 0, 0, 1];
        buf.extend_from_slice(&pps);
        let _ = decoder.decode(&buf);
        info!("[camera:{}] decoder pre-initialized with SPS/PPS", camera.id);
    }
    let target_interval = std::time::Duration::from_secs_f64(1.0 / camera.fps.max(1) as f64);
    let mut last_frame_at = std::time::Instant::now() - target_interval;
    let mut prev_luma: Option<Vec<u8>> = None;

    loop {
        match play.next().await {
            Some(Ok(CodecItem::VideoFrame(frame))) => {
                let now = std::time::Instant::now();
                if now.duration_since(last_frame_at) < target_interval {
                    continue;
                }

                let data = frame.data();
                match decoder.decode(data) {
                    Ok(Some(yuv)) => {
                        // dimensions() is private — derive from dimensions_uv()
                        let (uv_w, uv_h) = yuv.dimensions_uv();
                        let (w, h) = (uv_w * 2, uv_h * 2);

                        // Frame differencing on luma — skip encode if scene is static
                        let luma = yuv.y().to_vec();
                        let changed = match &prev_luma {
                            None => true,
                            Some(prev) => motion_detected(prev, &luma, w),
                        };
                        prev_luma = Some(luma);

                        if changed {
                            match encode_jpeg(&yuv, w, h) {
                                Ok(jpeg) => {
                                    debug!("[camera:{}] new frame {}x{} {}b", camera.id, w, h, jpeg.len());
                                    *store.lock().await = Some(jpeg);
                                    last_frame_at = now;
                                }
                                Err(e) => error!("[camera:{}] jpeg encode: {e}", camera.id),
                            }
                        } else {
                            debug!("[camera:{}] static frame skipped", camera.id);
                            last_frame_at = now;
                        }
                    }
                    Ok(None) => {} // decoder buffering
                    Err(e) => debug!("[camera:{}] decode error: {e}", camera.id),
                }
            }
            Some(Ok(_)) => {} // audio or other stream items
            Some(Err(e)) => return Err(e.into()),
            None => return Ok(()),
        }
    }
}

/// Connect to an RTSP URL, decode the first available H.264 frame, return JPEG bytes.
/// Used by the /preview HTTP endpoint. All fixes (credentials, Annex B framing, SPS/PPS
/// pre-init) are identical to run_stream.
pub async fn grab_one_frame(rtsp_url: &str) -> anyhow::Result<Vec<u8>> {
    let mut url = Url::parse(rtsp_url)?;

    let creds = if !url.username().is_empty() {
        let username = url.username().to_string();
        let password = url.password().unwrap_or("").to_string();
        let _ = url.set_username("");
        let _ = url.set_password(None);
        Some(Credentials { username, password })
    } else {
        None
    };

    let mut session = Session::describe(url, SessionOptions::default().creds(creds)).await?;

    let video_idx = session
        .streams()
        .iter()
        .position(|s| s.media() == "video" && s.encoding_name() == "h264")
        .ok_or_else(|| anyhow::anyhow!("no H.264 stream found"))?;

    session.setup(video_idx, SetupOptions::default()
        .frame_format(retina::codec::FrameFormat::SIMPLE)).await?;

    let sps_pps: Option<(Vec<u8>, Vec<u8>)> = match session.streams()[video_idx].parameters() {
        Some(retina::codec::ParametersRef::Video(vp)) => {
            match vp.codec_params() {
                retina::codec::VideoParametersCodec::H264 { sps, pps } =>
                    Some((sps.to_vec(), pps.to_vec())),
                _ => None,
            }
        }
        _ => None,
    };

    let mut play = session.play(PlayOptions::default()).await?.demuxed()?;
    let mut decoder = Decoder::new()?;

    if let Some((sps, pps)) = sps_pps {
        let mut buf = vec![0u8, 0, 0, 1];
        buf.extend_from_slice(&sps);
        let _ = decoder.decode(&buf);
        let mut buf = vec![0u8, 0, 0, 1];
        buf.extend_from_slice(&pps);
        let _ = decoder.decode(&buf);
    }

    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);

    loop {
        if std::time::Instant::now() > deadline {
            anyhow::bail!("timed out waiting for a decodeable frame — check URL and credentials");
        }
        match play.next().await {
            Some(Ok(CodecItem::VideoFrame(frame))) => {
                match decoder.decode(frame.data()) {
                    Ok(Some(yuv)) => {
                        let (uv_w, uv_h) = yuv.dimensions_uv();
                        let (w, h) = (uv_w * 2, uv_h * 2);
                        return encode_jpeg(&yuv, w, h);
                    }
                    Ok(None) => continue,
                    Err(_) => continue,
                }
            }
            Some(Ok(_)) => continue,
            Some(Err(e)) => anyhow::bail!("stream error: {e}"),
            None => anyhow::bail!("stream ended before a frame was decoded"),
        }
    }
}

/// Scan Annex B NAL units (up to 512 bytes) for IDR (type 5) or SPS (type 7).
/// Both indicate a random-access point / keyframe.
fn is_keyframe(data: &[u8]) -> bool {
    let limit = data.len().min(512);
    let mut i = 0;
    while i + 5 <= limit {
        if data[i..i+4] == [0, 0, 0, 1] {
            let nal_type = data[i + 4] & 0x1F;
            if nal_type == 5 || nal_type == 7 { return true; }
            i += 5;
        } else {
            i += 1;
        }
    }
    false
}

/// Mean-absolute-difference on sampled luma plane. Returns true if motion detected.
fn motion_detected(prev: &[u8], curr: &[u8], _width: usize) -> bool {
    if prev.len() != curr.len() {
        return true;
    }
    let step = 8usize;
    let samples = prev.len() / step;
    if samples == 0 {
        return true;
    }
    let sum: u64 = prev
        .iter()
        .zip(curr.iter())
        .step_by(step)
        .map(|(a, b)| (*a as i16 - *b as i16).unsigned_abs() as u64)
        .sum();
    (sum / samples as u64) > 8
}

/// Convert DecodedYUV to JPEG bytes via the built-in write_rgb8 path.
fn encode_jpeg(yuv: &openh264::decoder::DecodedYUV<'_>, w: usize, h: usize) -> anyhow::Result<Vec<u8>> {
    let mut rgb = vec![0u8; w * h * 3];
    yuv.write_rgb8(&mut rgb);

    let img: image::RgbImage = image::ImageBuffer::from_raw(w as u32, h as u32, rgb)
        .ok_or_else(|| anyhow::anyhow!("failed to create image buffer"))?;

    let mut buf = Vec::new();
    img.write_to(&mut std::io::Cursor::new(&mut buf), image::ImageFormat::Jpeg)?;
    Ok(buf)
}
