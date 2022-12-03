use log::{debug, info};
use std::io;
use std::fs;
use std::fs::File;
use std::path::Path;
use std::env::consts;
use std::collections::HashMap;
use std::os::unix::fs::PermissionsExt;
use uuid::Uuid;

fn get_websocat_url() -> Option<String> {
   let websocat_url_base = "https://github.com/vi/websocat/releases/download/v1.11.0/";
   let candidates = HashMap::from([
      ("x86_64", format!("{}/websocat.x86_64-unknown-linux-musl", websocat_url_base)),
      ("arm", format!("{}/websocat.arm-unknown-linux-musleabi", websocat_url_base)),
      ("aarch64", format!("{}/websocat.aarch64-unknown-linux-musl", websocat_url_base)),
   ]);

   return candidates.get(consts::ARCH).cloned();
}

pub async fn get_websocat(local_working_dir : String) {
   let websocat_path = format!("{}/websocat", local_working_dir);
   debug!("looking for existing websocat at: {websocat_path}");

   if !Path::new(&websocat_path).exists() {
      info!("no websocat found, downloading");

      let websocat_url = match get_websocat_url() {
         Some(url) => url,
         None => panic!("websocat does not support your architecture: {}. bailing", consts::ARCH)
      };

      let resp = reqwest::get(websocat_url).await.expect("cannot download websocat");
      let mut out = File::create(&websocat_path).expect("failed to create websocat file");

      let bytes = resp.bytes().await;
      let mut slice: &[u8] = bytes.as_ref().expect("failed to digest websocat file");
      io::copy(&mut slice, &mut out).expect("failed to websocat to file location");

      // chmod +x so that we will be able to execute it
      let mut perms = fs::metadata(&websocat_path).unwrap().permissions();
      // Read/write/exec for owner and read for others.
      perms.set_mode(0o744);
      fs::set_permissions(websocat_path, perms).unwrap();
   }
}

fn get_or_create_config_content(local_working_dir : String, path : String) -> String {
   let content_path = format!("{}/{}", local_working_dir, path);
   debug!("looking for existing content at: {content_path}");

   let (content, is_new) = match fs::read_to_string(content_path.clone()) {
      Ok(id) => (id, false),
      Err(_error) => (Uuid::new_v4().to_string(), true),
   };

   if is_new {
      // create the file for a new device
      fs::create_dir_all(local_working_dir).unwrap_or_else(|e| panic!("Error creating dir: {}", e));
      fs::write(content_path, content.clone()).unwrap_or_else(|e| panic!("Error writing id file: {}", e));
   }

   return content;
}

pub fn get_device_id(local_working_dir : String) -> String {
   return get_or_create_config_content(local_working_dir, "/device_id".to_string());
}

pub fn get_device_password(local_working_dir : String) -> String {
   return get_or_create_config_content(local_working_dir, "/device_password".to_string());
}

#[cfg(test)]
mod tests_get_device_id {
   use super::*;

   const LOCAL_WORKING_DIR: &str = "./test_data";
   const LOCAL_ID : &str = "./test_data/device_id";

   #[test]
   fn check_get_device_id_with_new_id(){
      // make sure we do not even have the test data folder
      fs::remove_file(LOCAL_ID.to_string()).unwrap_or_default();
      fs::remove_dir_all(LOCAL_WORKING_DIR.to_string()).unwrap_or_default();

      let uuid = get_device_id(LOCAL_WORKING_DIR.to_string());

      match Uuid::parse_str(&uuid) {
         Ok(_uuid) => assert!(true),
         _ => assert!(false),
      }
   }

   #[test]
   fn check_get_device_id_with_existing_id(){
      let some_id = Uuid::new_v4().to_string();

      // pre-populate the id
      fs::create_dir_all(LOCAL_WORKING_DIR.to_string()).unwrap_or_default();
      fs::write(LOCAL_ID.to_string(), some_id.clone()).unwrap_or_default();

      let uuid = get_device_id(LOCAL_WORKING_DIR.to_string());
      assert_eq!(some_id, uuid);
   }
}

#[cfg(test)]
mod tests_get_websocat {
   use super::*;

   const LOCAL_WORKING_DIR: &str = "./test_data";
   const LOCAL_WEBSOCAT_PATH : &str = "./test_data/websocat";

   #[actix_rt::test]
   async fn check_websocat_is_yet_to_be_downloaded(){
      fs::create_dir_all(LOCAL_WORKING_DIR.to_string()).unwrap_or_default();
      fs::remove_file(LOCAL_WEBSOCAT_PATH.to_string()).unwrap_or_default();

      get_websocat(LOCAL_WORKING_DIR.to_string()).await;
      assert!(Path::new(LOCAL_WEBSOCAT_PATH).exists());
   }
}
