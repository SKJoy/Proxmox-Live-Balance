#!/usr/bin/env bash

# check.sh (CSV-driven HTTP API version)
# ------------------------------------------------------------
# Reads a CSV file with VM IDs and memory thresholds, checks current usage via the Proxmo x REST API,
# and raises memory allocation if usage exceeds the specified threshold.
# ------------------------------------------------------------
#
# Usage:
#   ./check.sh [-c CSV_FILE] [-e ENV_FILE] [-o]
#
# Options:
#   -c CSV_FILE   Path to CSV file (default: item.csv in script directory)
#   -e ENV_FILE   Path to environment file (default: default.env in script directory)
#   -o            Optimize memory: if usage below threshold, decrease memory by 10% (rounded up to nearest 128 MB)
#
# Example:
#   ./check.sh -c mydata.csv -e myenv.env

set -euo pipefail

# Load environment variables (if a .env file exists in the same directory)
if [[ -f "$(dirname \"$0\")/default.env" ]]; then
	# shellcheck source=/dev/null
	source "$(dirname \"$0\")/default.env"
fi

# Ensure required variables are set
: "${PROXMOX_HOST:?Missing PROXMOX_HOST}"
: "${PROXMOX_NODE:?Missing PROXMOX_NODE}"
: "${PROXMOX_TOKEN_ID:?Missing PROXMOX_TOKEN_ID}"
: "${PROXMOX_TOKEN_SECRET:?Missing PROXMOX_TOKEN_SECRET}"

# Parse command-line options
CSV_FILE="$(dirname \"$0\")/item.csv"
while getopts ":c:e:o" opt; do
	case $opt in
	c)
		CSV_FILE="$OPTARG"
		;;
	e)
		ENV_FILE="$OPTARG"
		;;
	o)
		OPT_OPTIMIZE=1
		;;
	\?)
		echo "Invalid option: -$OPTARG" >&2
		exit 1
		;;
	:)
		echo "Option -$OPTARG requires an argument." >&2
		exit 1
		;;
	esac

	done
OPT_OPTIMIZE=${OPT_OPTIMIZE:-0}

# Load environment variables from the selected file (default: default.env)
if [[ -z "$ENV_FILE" ]]; then
	ENV_FILE="$(dirname \"$0\")/default.env"
fi
if [[ -f "$ENV_FILE" ]]; then
	# shellcheck source=/dev/null
	source "$ENV_FILE"
else
	echo "Error: Environment file '$ENV_FILE' not found."
	exit 1
fi

# Ensure required variables are set
: "${PROXMOX_HOST:?Missing PROXMOX_HOST}"
: "${PROXMOX_NODE:?Missing PROXMOX_NODE}"
: "${PROXMOX_TOKEN_ID:?Missing PROXMOX_TOKEN_ID}"
: "${PROXMOX_TOKEN_SECRET:?Missing PROXMOX_TOKEN_SECRET}"

# Parse command-line options
CSV_FILE="$(dirname \"$0\")/item.csv"
# (the getopts loop above has already processed -c and -e)


# Function to fetch current and total memory usage (in MB) for a VM via API
get_mem_info_mb() {
	local vmid="$1"
	local url="${PROXMOX_HOST}/api2/json/nodes/${PROXMOX_NODE}/qemu/${vmid}/status/current"
	local resp=$(curl -s -k -X GET "${url}" \
		-H "Authorization: PVEAPIToken=${PROXMOX_TOKEN_ID}=${PROXMOX_TOKEN_SECRET}")
	# Extract current "mem" and total "maxmem" (in KiB) from JSON and convert to MB
	local mem_kib=$(echo "$resp" | grep -o '"mem": *[0-9]*' | head -n1 | awk -F: '{print $2}' | tr -d ' ')
	local maxmem_kib=$(echo "$resp" | grep -o '"maxmem": *[0-9]*' | head -n1 | awk -F: '{print $2}' | tr -d ' ')
	local mem_mb=0
	local maxmem_mb=0
	[[ -n "$mem_kib" ]] && mem_mb=$((mem_kib / 1024))
	[[ -n "$maxmem_kib" ]] && maxmem_mb=$((maxmem_kib / 1024))
	echo "$mem_mb $maxmem_mb"
}

# Function to fetch current storage usage (in MB) for a VM via API
get_current_storage_mb() {
	local vmid="$1"
	local url="${PROXMOX_HOST}/api2/json/nodes/${PROXMOX_NODE}/qemu/${vmid}/status/current"
	local resp=$(curl -s -k -X GET "${url}" \
		-H "Authorization: PVEAPIToken=${PROXMOX_TOKEN_ID}=${PROXMOX_TOKEN_SECRET}")
	# Extract "disk" (in KiB) from JSON and convert to MB; fallback to 0 if not found
	local disk_kib=$(echo "$resp" | grep -o '"disk": *[0-9]*' | head -n1 | awk -F: '{print $2}' | tr -d ' ')
	if [[ -z "$disk_kib" ]]; then
		echo "0"
	else
		echo $((disk_kib / 1024))
	fi
}

# Function to fetch VM hostname
get_vm_name() {
	local vmid="$1"
	local url="${PROXMOX_HOST}/api2/json/nodes/${PROXMOX_NODE}/qemu/${vmid}/status/current"
	local resp=$(curl -s -k -X GET "${url}" \
		-H "Authorization: PVEAPIToken=${PROXMOX_TOKEN_ID}=${PROXMOX_TOKEN_SECRET}")
	local name=$(echo "$resp" | grep -o '"name": *"[^\"]*"' | head -n1 | cut -d'"' -f4)
	echo "$name"
}

# Initialize counters for summary
TOTAL_ITEMS=0
HEALTHY_ITEMS=0
MEMORY_EXCEEDED=0
STORAGE_EXCEEDED=0

# Iterate over each line in the CSV
while IFS=',' read -r vmid RESOURCE_MEMORY_CONSUMPTION_ALERT_THRESHOLD RESOURCE_STORAGE_CONSUMPTION_ALERT_THRESHOLD; do
	# Skip empty lines or lines starting with #
	[[ -z "$vmid" ]] && continue
	[[ "$vmid" =~ ^# ]] && continue

	TOTAL_ITEMS=$((TOTAL_ITEMS + 1))

	# Validate numeric values
	if ! [[ "$vmid" =~ ^[0-9]+$ ]] || ! [[ "$RESOURCE_MEMORY_CONSUMPTION_ALERT_THRESHOLD" =~ ^[0-9]+$ ]] || ! [[ "$RESOURCE_STORAGE_CONSUMPTION_ALERT_THRESHOLD" =~ ^[0-9]+$ ]]; then
		echo "⛔ Invalid entry in CSV – vmid and thresholds must be numeric. Skipping."
		continue
	fi

	# Memory check
	read -r current_mem_mb total_mem_mb <<< "$(get_mem_info_mb \"$vmid\")"
	if (( total_mem_mb > 0 )); then
		mem_usage_percent=$(( current_mem_mb * 100 / total_mem_mb ))
	else
		mem_usage_percent=0
	fi

	MEMORY_INCREASED=""
	if (( mem_usage_percent > RESOURCE_MEMORY_CONSUMPTION_ALERT_THRESHOLD )); then
		MEMORY_EXCEEDED=$((MEMORY_EXCEEDED + 1))
		new_mem=$current_mem_mb
		MEMORY_INCREASED="Memory increased"
		echo "Memory usage exceeds threshold. Setting VM $vmid memory to ${new_mem}MB via API."
		api_url="${PROXMOX_HOST}/api2/json/nodes/${PROXMOX_NODE}/qemu/${vmid}/config"
		response=$(curl -s -k -X POST "${api_url}" \
			-H "Authorization: PVEAPIToken=${PROXMOX_TOKEN_ID}=${PROXMOX_TOKEN_SECRET}" \
			-d "memory=${new_mem}")
		if echo "$response" | grep -q '"errors"'; then
			echo "Error updating memory for VM $vmid"
			echo "$response"
		else
			echo "Successfully updated memory for VM $vmid to ${new_mem}MB"
		fi
	elif (( OPT_OPTIMIZE == 1 )) && (( mem_usage_percent < RESOURCE_MEMORY_CONSUMPTION_ALERT_THRESHOLD )); then
		# Optimize: decrease memory by 10% and round up to nearest 128 MB
		new_mem_raw=$(( (current_mem_mb * 9 + 9) / 10 ))
		new_mem=$(( ( (new_mem_raw + 127) / 128 ) * 128 ))
		MEMORY_INCREASED="Memory optimized"
		echo "Optimizing memory for VM $vmid: decreasing to ${new_mem}MB via API."
		api_url="${PROXMOX_HOST}/api2/json/nodes/${PROXMOX_NODE}/qemu/${vmid}/config"
		response=$(curl -s -k -X POST "${api_url}" \
			-H "Authorization: PVEAPIToken=${PROXMOX_TOKEN_ID}=${PROXMOX_TOKEN_SECRET}" \
			-d "memory=${new_mem}")
		if echo "$response" | grep -q '"errors"'; then
			echo "Error optimizing memory for VM $vmid"
			echo "$response"
		else
			echo "Successfully optimized memory for VM $vmid to ${new_mem}MB"
		fi
	fi

	# Storage check
	current_storage=$(get_current_storage_mb "$vmid")
	# Assume total storage equals current usage (no max info)
	total_storage_mb=$((current_storage))
	if (( total_storage_mb > 0 )); then
		storage_usage_percent=$(( current_storage * 100 / total_storage_mb ))
	else
		storage_usage_percent=0
	fi

	if (( storage_usage_percent > RESOURCE_STORAGE_CONSUMPTION_ALERT_THRESHOLD )); then
		STORAGE_EXCEEDED=$((STORAGE_EXCEEDED + 1))
		echo "🔔 ALERT: Storage consumption (${storage_usage_percent}%) exceeds threshold (${RESOURCE_STORAGE_CONSUMPTION_ALERT_THRESHOLD}%) for VM $vmid"
	fi

	# Determine health for this item
	if (( mem_usage_percent <= RESOURCE_MEMORY_CONSUMPTION_ALERT_THRESHOLD && storage_usage_percent <= RESOURCE_STORAGE_CONSUMPTION_ALERT_THRESHOLD )); then
		HEALTHY_ITEMS=$((HEALTHY_ITEMS + 1))
	fi

	# Output line as requested
	vm_name=$(get_vm_name "$vmid")
	echo "- VM ${vm_name}#${vmid}; Memory usage: ${mem_usage_percent}% ; Storage usage: ${storage_usage_percent}% ; ${MEMORY_INCREASED}"
done < "$CSV_FILE"

# Summary

echo ""
echo "Summary:"
echo "- Total items checked: ${TOTAL_ITEMS}"
echo "- Healthy items: ${HEALTHY_ITEMS}"
echo "- Items exceeding memory threshold: ${MEMORY_EXCEEDED}"
echo "- Items exceeding storage threshold: ${STORAGE_EXCEEDED}"