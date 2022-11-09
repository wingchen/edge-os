use log::{info};
use std::env;
mod config;

fn main() {
    env_logger::init();
    let local_working_dir = match env::var("EDGE_OS_EDGE_DIR") {
        Ok(val) => val,
        Err(_e) => "/opt/edge-os-edge".to_string(),
    };

    let device_id = config::get_device_id(local_working_dir);
    info!("Starting edge-os-edge: {device_id}");
}
