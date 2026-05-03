use std::sync::Arc;
use tokio::sync::Mutex;
use futures::StreamExt;
use url::Url;
use retina::client::{Credentials, PlayOptions, Session, SessionOptions, SetupOptions};
use retina::codec::CodecItem;
use openh264::decoder::Decoder;
use openh264::formats::YUVSource;

/// Latest JPEG frame shared between the GStreamer appsink and HTTP server.
pub type SharedFrame = Arc<Mutex<Option<Vec<u8>>>>;

/// Connect to an RTSP URL, decode the first available H.264 frame, return JPEG bytes.
/// Used by the /preview HTTP endpoint.
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
                        let mut rgb = vec![0u8; w * h * 3];
                        yuv.write_rgb8(&mut rgb);
                        let img = image::RgbImage::from_raw(w as u32, h as u32, rgb)
                            .ok_or_else(|| anyhow::anyhow!("failed to create RgbImage"))?;
                        return encode_jpeg_from_rgb(&img);
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

/// JPEG-encode an RgbImage. Used by the inference thread for best-frame storage.
pub fn encode_jpeg_from_rgb(img: &image::RgbImage) -> anyhow::Result<Vec<u8>> {
    let mut buf = Vec::new();
    img.write_to(&mut std::io::Cursor::new(&mut buf), image::ImageFormat::Jpeg)?;
    Ok(buf)
}
