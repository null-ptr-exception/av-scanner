#!/bin/bash
set -euo pipefail

SA_NAME="${SA_NAME:-av-scanner}"
SA_NAMESPACE="${SA_NAMESPACE:-av-scanner}"
TOKEN_DURATION="${TOKEN_DURATION:-24h}"

echo "Creating SA token for ${SA_NAMESPACE}/${SA_NAME} (duration: ${TOKEN_DURATION})..."
TOKEN_FILE="/tmp/sa-token"
umask 077
kubectl create token "$SA_NAME" \
    --namespace "$SA_NAMESPACE" \
    --duration "$TOKEN_DURATION" \
    > "$TOKEN_FILE"
chmod 600 "$TOKEN_FILE"
echo "Token created."

echo "Running ansible deploy..."
ansible-playbook deploy.yaml -i inventory.yaml \
    -e "binary_path=/app/av-scanner" \
    -e "token_file=${TOKEN_FILE}" \
    "$@"
echo "Deploy complete."
