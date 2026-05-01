#!/bin/bash
#
# vm-destroy.sh - Destroy VMs by name
#
# Usage:
#   ./scripts/vm-destroy.sh                              # destroy "av-scanner"
#   ./scripts/vm-destroy.sh --name molecule --count 2    # destroy molecule-1, molecule-2
#   ./scripts/vm-destroy.sh --name molecule --all        # destroy all VMs matching "molecule*"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/virsh.sh"

PREFIX="av-scanner"
COUNT=1
ALL=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --name)   PREFIX="$2"; shift 2 ;;
        --count)  COUNT="$2"; shift 2 ;;
        --all)    ALL=1; shift ;;
        *) echo "Usage: $0 [--name PREFIX] [--count N | --all]"; exit 1 ;;
    esac
done

if [[ $ALL -eq 1 ]]; then
    vms=$(virsh_list_by_prefix "$PREFIX")
    if [[ -z "$vms" ]]; then
        echo "No VMs found matching prefix '$PREFIX'"
        exit 0
    fi
    while IFS= read -r name; do
        virsh_destroy_vm "$name"
        echo "Destroyed $name"
    done <<< "$vms"
else
    vm_names=()
    if [[ $COUNT -eq 1 ]]; then
        vm_names+=("$PREFIX")
    else
        for i in $(seq 1 "$COUNT"); do
            vm_names+=("${PREFIX}-${i}")
        done
    fi

    for name in "${vm_names[@]}"; do
        if _virsh dominfo "$name" &>/dev/null; then
            virsh_destroy_vm "$name"
            echo "Destroyed $name"
        else
            echo "$name: not found (skipped)"
        fi
    done
fi
