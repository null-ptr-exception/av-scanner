#!/bin/bash
# VM lifecycle helpers for BATS e2e tests
#
# Uses qcow2 overlays for fast snapshot/revert:
#   - Base image: downloaded once via get-cloud-image, never modified
#   - Overlay: throwaway qcow2 on top of base, recreated each run
#
# Environment variables:
#   E2E_VM_DIR       - directory for VM artifacts (default: .e2e-vms under project root)
#   E2E_CLEAN_ALL    - set to "1" to destroy everything including base artifacts in teardown
#   E2E_VM_MEMORY    - VM memory in MB (default: 4096)
#   E2E_VM_CPUS      - VM CPUs (default: 2)
#   E2E_SSH_PORT     - host port forwarded to VM SSH (default: 2222)
#   E2E_API_PORT     - host port forwarded to VM 3000 (default: 3000)

UBUNTU_IMAGE_URL="https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"

_e2e_project_root() {
    cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd
}

_e2e_vm_dir() {
    echo "${E2E_VM_DIR:-$(_e2e_project_root)/.e2e-vms}"
}

_e2e_ssh_key() {
    echo "$(_e2e_vm_dir)/id_ed25519"
}

# Ensure SSH key exists for VM access
_e2e_ensure_ssh_key() {
    local key="$(_e2e_ssh_key)"
    if [[ ! -f "$key" ]]; then
        mkdir -p "$(_e2e_vm_dir)"
        ssh-keygen -t ed25519 -f "$key" -N "" -C "av-scanner-e2e" >/dev/null
    fi
}

# Get or download the base cloud image
_e2e_base_image() {
    if command -v get-cloud-image &>/dev/null; then
        get-cloud-image "$UBUNTU_IMAGE_URL"
    else
        local vm_dir="$(_e2e_vm_dir)"
        local img="${vm_dir}/ubuntu-22.04-base.img"
        if [[ ! -f "$img" ]]; then
            mkdir -p "$vm_dir"
            echo "# Downloading Ubuntu 22.04 cloud image..." >&2
            wget -q -O "$img" "$UBUNTU_IMAGE_URL"
        fi
        echo "$img"
    fi
}

# Create cloud-init seed ISO
_e2e_create_seed() {
    local vm_dir="$(_e2e_vm_dir)"
    local seed="${vm_dir}/seed.img"

    if [[ -f "$seed" ]]; then
        echo "$seed"
        return
    fi

    _e2e_ensure_ssh_key
    local ssh_pub
    ssh_pub=$(cat "$(_e2e_ssh_key).pub")

    cat > "${vm_dir}/user-data" <<EOF
#cloud-config
hostname: av-scanner-e2e
users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: true
    ssh_authorized_keys:
      - ${ssh_pub}
ssh_pwauth: false
packages:
  - python3
  - python3-apt
EOF

    cat > "${vm_dir}/meta-data" <<EOF
instance-id: av-scanner-e2e-001
local-hostname: av-scanner-e2e
EOF

    cloud-localds "$seed" "${vm_dir}/user-data" "${vm_dir}/meta-data"
    echo "$seed"
}

# Try SSH connection
_e2e_try_ssh() {
    local port="${1:-${E2E_SSH_PORT:-2222}}"
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=5 -o BatchMode=yes \
        -i "$(_e2e_ssh_key)" \
        -p "$port" ubuntu@localhost "${2:-echo ok}" &>/dev/null
}

# Create a fresh overlay from the base image
_e2e_create_overlay() {
    local vm_dir="$(_e2e_vm_dir)"
    local overlay="${vm_dir}/overlay.qcow2"
    local base_img
    base_img=$(_e2e_base_image)

    rm -f "$overlay"
    qemu-img create -f qcow2 -b "$base_img" -F qcow2 "$overlay" 20G >/dev/null
    echo "$overlay"
}

# Boot the VM from overlay
_e2e_boot_vm() {
    local vm_dir="$(_e2e_vm_dir)"
    local overlay="${vm_dir}/overlay.qcow2"
    local seed
    seed=$(_e2e_create_seed)

    local memory="${E2E_VM_MEMORY:-4096}"
    local cpus="${E2E_VM_CPUS:-2}"
    local ssh_port="${E2E_SSH_PORT:-2222}"
    local api_port="${E2E_API_PORT:-3000}"

    local accel_flag="-machine accel=tcg"
    if [[ -e /dev/kvm && -r /dev/kvm && -w /dev/kvm ]]; then
        accel_flag="-machine accel=kvm"
    fi

    qemu-system-x86_64 \
        -name av-scanner-e2e \
        $accel_flag \
        -cpu qemu64 \
        -m "$memory" \
        -smp "$cpus" \
        -drive file="$overlay",format=qcow2 \
        -drive file="$seed",format=raw \
        -netdev user,id=net0,hostfwd=tcp::${ssh_port}-:22,hostfwd=tcp::${api_port}-:3000 \
        -device virtio-net-pci,netdev=net0 \
        -nographic \
        -pidfile "${vm_dir}/vm.pid" \
        > "${vm_dir}/vm.log" 2>&1 &

    echo $! > "${vm_dir}/vm.pid"
}

# Wait for VM to be SSH-ready
_e2e_wait_ssh() {
    local ssh_port="${E2E_SSH_PORT:-2222}"
    local attempt=0
    while [[ $attempt -lt 60 ]]; do
        if _e2e_try_ssh "$ssh_port"; then
            return 0
        fi
        sleep 5
        attempt=$((attempt + 1))
    done
    echo "# ERROR: VM did not become SSH-ready after 5 minutes" >&2
    return 1
}

# Kill the running VM process
_e2e_kill_vm() {
    local vm_dir="$(_e2e_vm_dir)"
    local pidfile="${vm_dir}/vm.pid"
    if [[ -f "$pidfile" ]]; then
        local pid
        pid=$(cat "$pidfile")
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        rm -f "$pidfile"
    fi
}

# ============================================
# Public API — call these from BATS
# ============================================

# Create VM if no overlay exists, otherwise revert by recreating overlay.
# Exports E2E_VM_IP, E2E_SSH_PORT, E2E_API_PORT, E2E_SSH_KEY for use in tests.
e2e_vm_setup() {
    local vm_dir
    vm_dir="$(_e2e_vm_dir)"
    mkdir -p "$vm_dir"

    local ssh_port="${E2E_SSH_PORT:-2222}"
    local api_port="${E2E_API_PORT:-3000}"

    # Kill any existing VM
    _e2e_kill_vm

    # Create fresh overlay (revert to clean state)
    echo "# Creating VM overlay..."
    _e2e_create_overlay >/dev/null

    # Boot
    echo "# Booting VM (ssh_port=${ssh_port}, api_port=${api_port})..."
    _e2e_boot_vm

    # Wait for SSH
    echo "# Waiting for SSH..."
    _e2e_wait_ssh

    # Wait for cloud-init
    echo "# Waiting for cloud-init..."
    _e2e_try_ssh "$ssh_port" "cloud-init status --wait" || true

    # Export connection info
    export E2E_VM_IP="localhost"
    export E2E_SSH_PORT="$ssh_port"
    export E2E_API_PORT="$api_port"
    export E2E_SSH_KEY="$(_e2e_ssh_key)"
    export API_URL="http://localhost:${api_port}"

    echo "# VM ready: API_URL=${API_URL}"
}

# Stop VM and delete overlay. Base image and seed are kept for next run.
# Set E2E_CLEAN_ALL=1 to also delete base artifacts.
e2e_vm_teardown() {
    _e2e_kill_vm

    local vm_dir
    vm_dir="$(_e2e_vm_dir)"

    # Always remove overlay
    rm -f "${vm_dir}/overlay.qcow2"

    if [[ "${E2E_CLEAN_ALL:-0}" == "1" ]]; then
        echo "# Cleaning all VM artifacts..."
        rm -rf "$vm_dir"
    fi
}
