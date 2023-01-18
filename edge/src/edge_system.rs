use log::{debug};
use std::convert::{TryFrom};
use sysinfo::{NetworkExt, System, SystemExt, DiskExt, ComponentExt, CpuExt};
use serde::{Deserialize, Serialize};

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

pub fn get_edge_status() -> String {
	let mut sys = System::new_all();
	sys.refresh_all();

	let edge_memory = EdgeMemory {
   	total_memory: get_mb_value(sys.total_memory()),
   	used_memory: get_mb_value(sys.used_memory()),
   	total_swap: get_mb_value(sys.total_swap()),
   	used_swap: get_mb_value(sys.used_swap()),
   };

	let edge_status = EdgeStatus {
      disk: get_disk_status(sys.disks()),
      network: get_network_status(sys.networks()),
      temperature: get_temperature_status(sys.components()),
      cpu: get_cpu_status(sys.cpus()),
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
