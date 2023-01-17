use log::{debug, info};
use std::collections::HashMap;
use std::convert::{TryFrom};
use sysinfo::{NetworkExt, System, SystemExt, DiskExt, ComponentExt, CpuExt};
use serde::{Deserialize, Serialize};
use serde_json::Result;

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
struct EdgeStatus {
	disk: Vec<EdgeDisk>,
	network: Vec<EdgeNetwork>,
	temperature: Vec<EdgeTemperature>,
	cpu: Vec<EdgeCpu>,
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

	let edge_status = EdgeStatus {
      disk: get_disk_status(sys.disks()),
      network: get_network_status(sys.networks()),
      temperature: get_temperature_status(sys.components()),
      cpu: get_cpu_status(sys.cpus()),
   };

   let json_edge_status = serde_json::to_string(&edge_status).unwrap();
   debug!("current edge status is: {json_edge_status}");

	// // get memory data
	// let mut memory_status: HashMap<String, String> = HashMap::new();
	// memory_status.insert("total_memory".to_string(), sys.total_memory().to_string());
	// memory_status.insert("used_memory".to_string(), sys.used_memory().to_string());
	// memory_status.insert("total_swap".to_string(), sys.total_swap().to_string());
	// memory_status.insert("used_swap".to_string(), sys.used_swap().to_string());

	// current_status.insert("memory".to_string(), memory_status);

	// // get process count
	// let mut process_status: HashMap<String, String> = HashMap::new();
	// process_status.insert("process_count".to_string(), sys.processes().len().to_string());
	// current_status.insert("process".to_string(), process_status);

	return json_edge_status;
}

pub fn get_edge_info() -> HashMap<String, String> {
	let mut sys = System::new_all();
	sys.refresh_all();
	let mut edge_info: HashMap<String, String> = HashMap::new();

	edge_info.insert("cpu_count".to_string(), sys.cpus().len().to_string());
	edge_info.insert("sys_name".to_string(), sys.name().unwrap_or_default().to_string());
	edge_info.insert("kernel_version".to_string(), sys.kernel_version().unwrap_or_default().to_string());
	edge_info.insert("os_version".to_string(), sys.os_version().unwrap_or_default().to_string());
	edge_info.insert("host_name".to_string(), sys.host_name().unwrap_or_default().to_string());

	return edge_info;
}

// #[cfg(test)]
// mod tests_get_edge_status {
//    use super::*;

//    #[test]
//    fn check_if_we_are_getting_data_like_designed(){
//       let edge_status = get_edge_status();
//       assert_eq!(edge_status.len(), 6);
//    }
// }

// #[cfg(test)]
// mod tests_get_edge_info {
//    use super::*;

//    #[test]
//    fn check_if_we_are_getting_general_sys_info(){
//       let edge_info = get_edge_info();
//       assert_eq!(edge_info.len(), 5);
//    }
// }
