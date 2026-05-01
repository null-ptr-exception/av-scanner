#!/bin/bash
# Shared virsh helper functions for VM management.
#
# All VMs use qemu:///system with the default NAT network.
# VMs get real IPs on virbr0 — no port forwarding needed.

VIRSH_CONNECT="qemu:///system"
UBUNTU_IMAGE_URL="https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"

_virsh() {
    virsh --connect "$VIRSH_CONNECT" "$@"
}

# Get or download the base cloud image.
# Uses get-cloud-image if available, otherwise downloads to $cache_dir.
virsh_base_image() {
    local cache_dir="${1:-/tmp}"
    if command -v get-cloud-image &>/dev/null; then
        get-cloud-image "$UBUNTU_IMAGE_URL"
        return
    fi
    local img="${cache_dir}/ubuntu-22.04-base.img"
    if [[ ! -f "$img" ]]; then
        echo "Downloading Ubuntu 22.04 cloud image..." >&2
        wget -q --show-progress -O "$img" "$UBUNTU_IMAGE_URL"
    fi
    echo "$img"
}

# Ensure SSH key exists at the given path.
virsh_ensure_ssh_key() {
    local key="$1"
    if [[ ! -f "$key" ]]; then
        mkdir -p "$(dirname "$key")"
        ssh-keygen -t ed25519 -f "$key" -N "" -C "av-scanner-vm" >/dev/null
    fi
}

# Create a cloud-init ISO for a VM.
# Args: <vm_name> <ssh_pub_key> <output_dir>
virsh_create_seed() {
    local vm_name="$1"
    local ssh_pub_key="$2"
    local output_dir="$3"
    local seed="${output_dir}/${vm_name}-seed.img"

    if [[ -f "$seed" ]]; then
        echo "$seed"
        return
    fi

    cat > "${output_dir}/${vm_name}-user-data" <<EOF
#cloud-config
hostname: ${vm_name}
users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: true
    ssh_authorized_keys:
      - ${ssh_pub_key}
ssh_pwauth: false
packages:
  - python3
  - python3-apt
EOF

    cat > "${output_dir}/${vm_name}-meta-data" <<EOF
instance-id: ${vm_name}
local-hostname: ${vm_name}
EOF

    cloud-localds "$seed" "${output_dir}/${vm_name}-user-data" "${output_dir}/${vm_name}-meta-data"
    echo "$seed"
}

# Create and start a VM via virsh.
# Args: <vm_name> <base_image> <seed_iso> <disk_dir> [memory_mb] [cpus] [disk_size]
virsh_create_vm() {
    local vm_name="$1"
    local base_image="$2"
    local seed_iso="$3"
    local disk_dir="$4"
    local memory="${5:-4096}"
    local cpus="${6:-2}"
    local disk_size="${7:-10}"

    local disk="${disk_dir}/${vm_name}.qcow2"

    if _virsh dominfo "$vm_name" &>/dev/null; then
        _virsh destroy "$vm_name" 2>/dev/null || true
        _virsh undefine "$vm_name" --remove-all-storage 2>/dev/null || true
    fi

    rm -f "$disk"
    qemu-img create -f qcow2 -b "$base_image" -F qcow2 "$disk" "${disk_size}G" >/dev/null

    virt-install \
        --connect "$VIRSH_CONNECT" \
        --name "$vm_name" \
        --memory "$memory" \
        --vcpus "$cpus" \
        --disk "path=${disk},format=qcow2" \
        --disk "path=${seed_iso},device=cdrom" \
        --os-variant ubuntu22.04 \
        --network network=default \
        --graphics none \
        --console pty,target_type=serial \
        --noautoconsole \
        --import \
        >/dev/null 2>&1
}

# Wait for a VM to get an IP address.
# Returns the IP on stdout.
virsh_wait_ip() {
    local vm_name="$1"
    local timeout="${2:-120}"
    local elapsed=0

    while [[ $elapsed -lt $timeout ]]; do
        local ip
        ip=$(_virsh domifaddr "$vm_name" 2>/dev/null \
            | grep -oP '(\d+\.){3}\d+' | head -1)
        if [[ -n "$ip" ]]; then
            echo "$ip"
            return 0
        fi
        sleep 3
        elapsed=$((elapsed + 3))
    done
    echo "ERROR: VM $vm_name did not get an IP after ${timeout}s" >&2
    return 1
}

# Wait for SSH to be ready on a VM.
virsh_wait_ssh() {
    local ip="$1"
    local ssh_key="$2"
    local timeout="${3:-300}"
    local elapsed=0

    while [[ $elapsed -lt $timeout ]]; do
        if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=5 -o BatchMode=yes \
            -i "$ssh_key" "ubuntu@${ip}" "echo ok" &>/dev/null; then
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done
    echo "ERROR: SSH not ready on $ip after ${timeout}s" >&2
    return 1
}

# Stop and remove a VM.
virsh_destroy_vm() {
    local vm_name="$1"
    if _virsh dominfo "$vm_name" &>/dev/null; then
        _virsh destroy "$vm_name" 2>/dev/null || true
        _virsh undefine "$vm_name" --remove-all-storage 2>/dev/null || true
    fi
}

# Get the IP of a running VM.
virsh_get_ip() {
    local vm_name="$1"
    _virsh domifaddr "$vm_name" 2>/dev/null \
        | grep -oP '(\d+\.){3}\d+' | head -1
}

# List VM names matching a prefix (any state).
virsh_list_by_prefix() {
    local prefix="$1"
    _virsh list --all --name 2>/dev/null | grep "^${prefix}" | sort
}

# Check if a VM is running.
virsh_is_running() {
    local vm_name="$1"
    local state
    state=$(_virsh domstate "$vm_name" 2>/dev/null)
    [[ "$state" == "running" ]]
}
