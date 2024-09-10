#!/bin/bash

# Load environment variables from the .env file
if [ -f .env ]; then
  export $(grep -v '^#' .env | xargs)
fi

# Timestamp of script execution
timestamp=$(date --iso-8601=seconds)

# EC2 Instance ID
if command -v curl > /dev/null; then
  instance_id=$(curl -s http://169.254.169.254/latest/meta-data/instance-id || echo "null")
else
  instance_id="null"
fi

# Private IP
private_ip=$(hostname -I | awk '{print $1}')

# CPU Usage
cpu_usage=$(top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print 100 - $1}')
cpu_usage=${cpu_usage:-0}

# Memory Usage
mem_total=$(free -h | awk '/^Mem/ {print $2}')
mem_used=$(free -h | awk '/^Mem/ {print $3}')

# Calculate percentage memory usage
mem_total_bytes=$(free | awk '/^Mem/ {print $2 * 1024}')
mem_used_bytes=$(free | awk '/^Mem/ {print $3 * 1024}')
if [[ -n "$mem_total_bytes" && "$mem_total_bytes" -ne 0 ]]; then
  memory_percent=$(echo "scale=2; ($mem_used_bytes / $mem_total_bytes) * 100" | bc 2>/dev/null)
else
  memory_percent=0
fi
memory_percent=${memory_percent:-0}

# Disk Usage
disk_usage=$(df -h | grep '^/dev/' | awk '{print "\"" $1 "\": {\"used\": \"" $3 "\", \"available\": \"" $4 "\", \"used_percent\": \"" $5 "\"}"}' | paste -sd, -)
root_disk_percent=$(df -h | grep '^/dev/root' | awk '{print $5}' | sed 's/%//')
root_disk_percent=${root_disk_percent:-0}

# Network Throughput on ens5
network_throughput=$(ifconfig ens5 | awk '
  /RX packets/ {rx_packets=$3; rx_bytes=$5}
  /TX packets/ {tx_packets=$3; tx_bytes=$5}
  END {
    print "\"rx_packets\": " rx_packets ", \"rx_bytes\": " rx_bytes ", \"tx_packets\": " tx_packets ", \"tx_bytes\": " tx_bytes
  }' | sed 's/^\([^{]*\)$/\{\1\}/')
network_throughput=${network_throughput:-"{\"rx_packets\": 0, \"rx_bytes\": 0, \"tx_packets\": 0, \"tx_bytes\": 0}"}

# System Uptime
uptime=$(uptime -p | sed 's/up //')

# GPU Stats
if command -v nvidia-smi > /dev/null; then
  gpu_memory=$(nvidia-smi --query-gpu=memory.used,memory.total --format=csv,nounits,noheader | awk -F, '{print "{\"used\": " $1 ", \"total\": " $2 "}"}')
  gpu_utilization=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,nounits,noheader | awk '{print $1}')
  encoder_utilization=$(nvidia-smi --query-gpu=utilization.encoder --format=csv,nounits,noheader | awk '{print $1}')
  encoder_sessions=$(nvidia-smi --query-gpu=encoder.stats.sessionCount --format=csv,nounits,noheader | awk '{print $1}')
  gpu_memory_used=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | awk '{print $1}')
  gpu_memory_total=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | awk '{print $1}')
  if [[ -n "$gpu_memory_total" && "$gpu_memory_total" -ne 0 ]]; then
    gpu_memory_percent=$(echo "scale=2; ($gpu_memory_used / $gpu_memory_total) * 100" | bc 2>/dev/null)
  else
    gpu_memory_percent=0
  fi
else
  gpu_memory="{\"used\": 0, \"total\": 0}"
  gpu_utilization=0
  encoder_sessions=0
  gpu_memory_percent=0
fi

# Ant Media Service Status
antmedia_status=$(systemctl show antmedia --no-pager)
active_status=$(echo "$antmedia_status" | grep -E '^ActiveState=' | cut -d= -f2)
state_change=$(echo "$antmedia_status" | grep -E '^StateChangeTimestamp=' | cut -d= -f2)
memory_bytes=$(echo "$antmedia_status" | grep -E '^MemoryCurrent=' | cut -d= -f2)
cpu_nsec=$(echo "$antmedia_status" | grep -E '^CPUUsageNSec=' | cut -d= -f2)

# Convert MemoryCurrent (in bytes) to GiB using bc
if [[ -n "$memory_bytes" && "$memory_bytes" != "null" ]]; then
  memory_gib=$(echo "scale=2; $memory_bytes / (1024^3)" | bc 2>/dev/null)
else
  memory_gib=0
fi

# Convert CPUUsageNSec (in nanoseconds) to seconds using bc
if [[ -n "$cpu_nsec" && "$cpu_nsec" != "null" ]]; then
  cpu_sec=$(echo "scale=2; $cpu_nsec / 1000000000" | bc 2>/dev/null)
else
  cpu_sec=0
fi

# Determine Status
if [[ "$(echo "$gpu_utilization >= 80" | bc)" -eq 1 || "$(echo "$cpu_usage >= 80" | bc)" -eq 1 || "$(echo "$memory_percent >= 80" | bc)" -eq 1 || "$(echo "$root_disk_percent >= 80" | bc)" -eq 1 || "$(echo "$gpu_memory_percent >= 80" | bc)" -eq 1 || "$(echo "$encoder_utilization >= 80" | bc)" -eq 1 ]]; then
  status="unhealthy"
elif [[ "$(echo "$gpu_utilization >= 60 && $gpu_utilization < 80" | bc)" -eq 1 || "$(echo "$cpu_usage >= 60 && $cpu_usage < 80" | bc)" -eq 1 || "$(echo "$memory_percent >= 60 && $memory_percent < 80" | bc)" -eq 1 || "$(echo "$root_disk_percent >= 60 && $root_disk_percent < 80" | bc)" -eq 1 || "$(echo "$gpu_memory_percent >= 60 && $gpu_memory_percent < 80" | bc)" -eq 1 || "$(echo "$encoder_utilization >= 60 && $encoder_utilization < 80" | bc)" -eq 1 ]]; then
  status="warning"
elif [[ "$(echo "$gpu_utilization < 60" | bc)" -eq 1 && "$(echo "$cpu_usage < 60" | bc)" -eq 1 && "$(echo "$memory_percent < 60" | bc)" -eq 1 && "$(echo "$root_disk_percent < 60" | bc)" -eq 1 && "$(echo "$gpu_memory_percent < 60" | bc)" -eq 1 && "$(echo "$encoder_utilization < 60" | bc)" -eq 1 && "$active_status" == "active" ]]; then
  status="healthy"
else
  status="unhealthy"
fi

# JSON Output
json_output=$(cat <<DELIM
{
  "ec2_instance_id": "${instance_id}",
  "status": "${status}",
  "timestamp": "${timestamp}",
  "system_uptime": "${uptime}",
  "private_ip": "${private_ip}",
  "cpu_usage": ${cpu_usage},
  "memory_usage": {
    "used": "${mem_used}",
    "total": "${mem_total}",
    "used_percent": "${memory_percent}"
  },
  "disk_usage": {
    ${disk_usage}
  },
  "network_throughput": ${network_throughput},
  "gpu_stats": {
    "memory_usage": ${gpu_memory},
    "memory_usage_percent": ${gpu_memory_percent},
    "gpu_utilization_percent": ${gpu_utilization},
    "encoder_utilization_percent": ${encoder_utilization},
    "encoder_sessions": ${encoder_sessions}
  },
  "antmedia_service": {
    "active_status": "${active_status:-0}",
    "state_change": "${state_change:-0}",
    "memory": "${memory_gib}GiB",
    "cpu": "${cpu_sec}s"
  }
}
DELIM
)

# Send POST request
curl -X POST https://${SERVER_IP}/api/v1/system/stream-service/status\
     -H "Content-Type: application/json" \
     -d "${json_output}"
