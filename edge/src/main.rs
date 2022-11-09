use log::{info, debug};
use std::fs;
use uuid::Uuid;

const LOCAL_WORKING_DIR : &str = "/opt/edge-os-edge";

fn get_device_id() -> String {
    let id_path = format!("{}/device_id", LOCAL_WORKING_DIR);
    debug!("looking for existing id at: {id_path}");

    let (device_id, is_new) = match fs::read_to_string(id_path.clone()) {
        Ok(id) => (id, false),
        Err(_error) => (Uuid::new_v4().to_string(), true),
    };

    if is_new {
        // create the file for a new device
        fs::create_dir_all(LOCAL_WORKING_DIR).unwrap_or_else(|e| panic!("Error creating dir: {}", e));
        fs::write(id_path, device_id.clone()).unwrap_or_else(|e| panic!("Error writing id file: {}", e));
    }

    return device_id;
}

fn main() {
    env_logger::init();

    let device_id = get_device_id();
    info!("Starting edge-os-edge: {device_id}");
}
