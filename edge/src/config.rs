use log::{debug};
use std::fs;
use uuid::Uuid;

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
