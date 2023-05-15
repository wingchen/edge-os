use log::{debug, info, error};
use std::convert::{TryFrom};
use sysinfo::{NetworkExt, System, SystemExt, DiskExt, ComponentExt, CpuExt};
use serde::{Deserialize, Serialize};
use regex::Regex;
use std::process::{Command, Stdio};
use std::io::{BufRead, BufReader};

extern crate byte_unit;
use byte_unit::{Byte, ByteUnit};

#[derive(Serialize, Deserialize)]
struct EdgeDisk {
   name: String,
   total: f64,
   available: f64,
   removable: bool,
}

#[derive(Serialize, Deserialize)]
struct EdgeNetwork {
	name: String,
	received: f64,
	transmitted: f64,
}

#[derive(Serialize, Deserialize)]
struct EdgeTemperature {
	label: String,
	temperature: f32,
}

#[derive(Serialize, Deserialize)]
struct EdgeCpu {
	name: String,
	usage: f32,
}

#[derive(Serialize, Deserialize)]
struct EdgeGpu {
   usage: f64,
	temperature: f64,
}

#[derive(Serialize, Deserialize)]
struct EdgeMemory {
	total_memory: f64,
	used_memory: f64,
	total_swap: f64,
	used_swap: f64,
}

#[derive(Serialize, Deserialize)]
struct EdgeStatus {
	disk: Vec<EdgeDisk>,
	network: Vec<EdgeNetwork>,
	temperature: Vec<EdgeTemperature>,
	cpu: Vec<EdgeCpu>,
   gpu: Option<EdgeGpu>,
	memory: EdgeMemory,
	process_count: usize,
}

#[derive(Serialize, Deserialize)]
struct EdgeInfo {
	cpu_count: usize,
	sys_name: String,
	kernel_version: String,
	os_version: String,
	host_name: String,
}

fn run_command(command: &str, args: &[&str]) -> Vec<String> {
   let mut cmd = Command::new(command);
   cmd.args(args)
      .stdout(Stdio::piped())
      .stderr(Stdio::piped());

   let mut child = cmd.spawn().unwrap();

   let mut output_lines: Vec<String> = Vec::new();

   let mut buf_reader = BufReader::new(child.stdout.as_mut().unwrap());
   loop {
      let mut buf = String::new();
      match buf_reader.read_line(&mut buf) {
         Ok(n) => {
            if n == 0 {
               break;
            }
            info!("{}", buf.trim().to_string());
            output_lines.push(buf.trim().to_string());
         }
         Err(e) => {
            error!("Error reading command output: {e}");
            break;
         }
      }
   }

   let status = child.wait().unwrap();
   if !status.success() {
      let error_message = format!("Command failed with exit code {:?}", status.code());
      error!("{}", error_message);
      output_lines.push(error_message);
   }

   output_lines
}

fn calculate_average(numbers: &[f64]) -> f64 {
   let sum = numbers.iter().sum::<f64>();
   let count = numbers.len() as f64;
   sum / count
}

fn get_mb_value(value: u64) -> f64 {
	return Byte::from_bytes(u128::try_from(value).unwrap()).get_adjusted_unit(ByteUnit::MB).get_value();
}

fn get_kb_value(value: u64) -> f64 {
	return Byte::from_bytes(u128::try_from(value).unwrap()).get_adjusted_unit(ByteUnit::KB).get_value();
}

fn get_disk_status(disks: &[sysinfo::Disk]) -> Vec<EdgeDisk> {
	let mut disk_status = Vec::new();

	for disk in disks {
		let edge_disk = EdgeDisk {
      	name: disk.name().to_str().unwrap_or_default().to_string(),
        	total: get_mb_value(disk.total_space()),
        	available: get_mb_value(disk.available_space()),
        	removable: disk.is_removable(),
    	};

	   disk_status.push(edge_disk);
	}

	return disk_status;
}

fn get_network_status(networks: &sysinfo::Networks) -> Vec<EdgeNetwork> {
	let mut networks_status = Vec::new();

	for (interface_name, data) in networks {
		let edge_network = EdgeNetwork {
      	name: interface_name.to_string(),
        	received: get_kb_value(data.received()),
        	transmitted: get_kb_value(data.transmitted()),
    	};

    	networks_status.push(edge_network);
	}

	return networks_status;
}

fn get_temperature_status(components: &[sysinfo::Component]) -> Vec<EdgeTemperature> {
	let mut temperature_status = Vec::new();

	for component in components {
		let edge_temperature = EdgeTemperature {
      	label: component.label().to_string(),
        	temperature: component.temperature(),
    	};

    	temperature_status.push(edge_temperature);
	}

	return temperature_status;
}

fn get_cpu_status(cpus: &[sysinfo::Cpu]) -> Vec<EdgeCpu> {
	let mut cpu_status = Vec::new();

	for cpu in cpus {
		let edge_cpu = EdgeCpu {
      	name: cpu.name().to_string(),
        	usage: cpu.cpu_usage(),
    	};

    	cpu_status.push(edge_cpu);
	}

	return cpu_status;
}

fn is_tegra_system() -> bool {
   let output = Command::new("uname")
                  .arg("-a")
                  .output()
                  .expect("Failed to run uname command");
   let stdout = String::from_utf8_lossy(&output.stdout);
   let re = Regex::new(r"tegra").unwrap();
   re.is_match(&stdout)
}

fn get_tegra_gpu_status(input: &str) -> Option<(f64, f64)> {
   let mut usage_num = -1.0;
   let mut temp_num = -1.0;

  	// get usage data
   let re_usage = Regex::new(r"(GR3D_FREQ (\d+\.?\d*)%@)").unwrap();

   if let Some(caps) = re_usage.captures(input) {
   	if let Some(usage) = caps.get(2) {
	      usage_num = usage.as_str().parse::<f64>().ok()?;
	   }
   }

   // get temp data
   let re_temp = Regex::new(r"(GPU@(\d+\.?\d*)C)").unwrap();

   if let Some(caps) = re_temp.captures(input) {
   	if let Some(temp) = caps.get(2) {
	      temp_num = temp.as_str().parse::<f64>().ok()?;
	   }
   }

   if usage_num == -1.0 && temp_num == -1.0 {
   	return None;
   } else {
   	return Some((usage_num, temp_num));
   }
}

fn get_gpu_status() -> Option<EdgeGpu> {
	if is_tegra_system() {
		let command = "tegrastats --interval 1000 | head -n 3";
		let gpu_status_lines = run_command("/bin/sh", vec!["-c", command].as_slice());
		let mut gpu_usages: Vec<f64> = Vec::new();
		let mut gpu_tmps: Vec<f64> = Vec::new();

		for line in gpu_status_lines {
			// debug!("gpu_status_lines: {line}");

      	match get_tegra_gpu_status(&line) {
	         Some((usage, degree)) => {
	            gpu_usages.push(usage);
	            gpu_tmps.push(degree);
	         }
	         None => {
	            error!("could not parse tegrastats reponse for GPU data");
	         }
	      }
    	}

    	let gpu = EdgeGpu {
	   	usage: calculate_average(&gpu_usages),
			temperature: calculate_average(&gpu_tmps),
	   };

	   return Some(gpu);
	}

	return None;
}

pub fn get_edge_status() -> String {
	let mut sys = System::new_all();
	sys.refresh_all();

	let edge_memory = EdgeMemory {
   	total_memory: get_mb_value(sys.total_memory()),
   	used_memory: get_mb_value(sys.used_memory()),
   	total_swap: get_mb_value(sys.total_swap()),
   	used_swap: get_mb_value(sys.used_swap()),
   };

   // sleep a bit to collect some CPU data 
   sys.refresh_cpu();
	std::thread::sleep(std::time::Duration::from_millis(500));
	sys.refresh_cpu();

	let edge_status = EdgeStatus {
      disk: get_disk_status(sys.disks()),
      network: get_network_status(sys.networks()),
      temperature: get_temperature_status(sys.components()),
      cpu: get_cpu_status(sys.cpus()),
      gpu: get_gpu_status(),
      memory: edge_memory,
      process_count: sys.processes().len(),
   };

   let json_edge_status = serde_json::to_string(&edge_status).unwrap();
   debug!("current edge status is: {json_edge_status}");

	return json_edge_status;
}

pub fn get_edge_info() -> String {
	let mut sys = System::new_all();
	sys.refresh_all();

	let edge_info = EdgeInfo {
   	cpu_count: sys.cpus().len(),
   	sys_name: sys.name().unwrap_or_default(),
   	kernel_version: sys.kernel_version().unwrap_or_default(),
   	os_version: sys.os_version().unwrap_or_default(),
   	host_name: sys.host_name().unwrap_or_default(),
   };

   let json_edge_info = serde_json::to_string(&edge_info).unwrap();
   debug!("current edge info is: {json_edge_info}");

	return json_edge_info;
}

#[cfg(test)]
mod tests_get_edge_status {
   use super::*;

   #[test]
   fn check_if_we_are_getting_data(){
      let edge_status = get_edge_status();
      assert_ne!(edge_status, "");
   }
}

#[cfg(test)]
mod tests_get_edge_info {
   use super::*;

   #[test]
   fn check_if_we_are_getting_general_sys_info(){
      let edge_info = get_edge_info();
      assert_ne!(edge_info, "");
   }
}

#[cfg(test)]
mod test_is_tegra_system {
	use super::*;

   #[test]
   fn check_is_tegra_system(){
   	// we are usually not running test cases on tegra
      assert_eq!(false, is_tegra_system());
   }
}

#[cfg(test)]
mod test_calculate_average {
	use super::*;

   #[test]
   fn check_calculate_average(){
      assert_eq!(2.0, calculate_average(vec![1.0, 2.0, 3.0].as_slice()));
   }
}

#[cfg(test)]
mod test_get_tegra_gpu_status {
	use super::*;

   #[test]
   fn check_get_tegra_gpu_status_success_case(){
   	let test_sample = "[0%@1190,1%@1190,0%@1190,0%@1189,0%@1190,0%@1191,0%@1190,0%@1190] EMC_FREQ 0%@1331 GR3D_FREQ 0%@114 VIC_FREQ 115 APE 150 AUX@36C CPU@36.5C thermal@35.7C Tboard@37C AO@35C GPU@35C Tdiode@38.75C PMIC@50C GPU 467mW/467mW CPU 467mW/467mW SOC 1245mW/1245mW CV 0mW/0mW VDDRQ 311mW/311mW SYS5V 2768mW/2768mW";
      assert_eq!(Some((0.0, 35.0)), get_tegra_gpu_status(test_sample));
   }

   #[test]
   fn check_get_tegra_gpu_status_fail_case(){
   	let test_sample = "[0%@1190,1%@1190,0%@1190,0%@1189,0%@1190,0%@1191,0%@1190,0%@1190]";
      assert_eq!(None, get_tegra_gpu_status(test_sample));
   }
}
