#!/bin/bash
set -euo pipefail

SA_NAME="${SA_NAME:-av-scanner}"
SA_NAMESPACE="${SA_NAMESPACE:-av-scanner}"
TOKEN_DURATION="${TOKEN_DURATION:-24h}"
PLAYBOOK="${PLAYBOOK:-playbooks/deploy.yaml}"

if [ -z "${INVENTORY_PATH:-}" ]; then
    echo "Error: INVENTORY_PATH is required" >&2
    exit 1
fi

echo "Creating SA token for ${SA_NAMESPACE}/${SA_NAME} (duration: ${TOKEN_DURATION})..."
TOKEN_FILE="/tmp/sa-token"
umask 077
kubectl create token "$SA_NAME" \
    --namespace "$SA_NAMESPACE" \
    --duration "$TOKEN_DURATION" \
    > "$TOKEN_FILE"
chmod 600 "$TOKEN_FILE"
echo "Token created."

echo "Running playbook: ${PLAYBOOK}..."
ansible-playbook "$PLAYBOOK" -i "$INVENTORY_PATH" \
    -e "binary_path=/app/av-scanner" \
    -e "node_exporter_path=/app/node_exporter" \
    -e "token_file=${TOKEN_FILE}" \
    "$@"
echo "Done."
