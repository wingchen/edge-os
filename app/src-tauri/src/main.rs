// Hides the console window on Windows release builds (no-op on macOS/Linux)
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    edge_os_app_lib::run()
}
