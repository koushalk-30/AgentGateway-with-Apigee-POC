#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Source env.sh if available
if [[ -f "${SCRIPT_DIR}/../env.sh" ]]; then
  source "${SCRIPT_DIR}/../env.sh"
fi

# ==============================================================================
# Configuration & Variable Declarations
# ==============================================================================
export PROJECT_ID="${PROJECT_ID:-${GOOGLE_CLOUD_PROJECT:-test-501813}}"
export REGISTRY_LOCATION="${REGISTRY_LOCATION:-global}"
export SERVICE_ID="${1:-${SERVICE_ID:-weather-mcp-service}}"
export APIGEE_MCP_URL="${APIGEE_MCP_URL:-https://35.244.241.176.nip.io/mcp}"
export SERVICE_DISPLAY_NAME="${SERVICE_DISPLAY_NAME:-Apigee Weather MCP Server}"
export SERVICE_DESCRIPTION="${SERVICE_DESCRIPTION:-Apigee MCP Proxy for National Weather Service (shared by Ayush)}"
export SPEC_TYPE="${SPEC_TYPE:-no-spec}"
export PROTOCOL_BINDING="${PROTOCOL_BINDING:-JSONRPC}"

echo "=========================================================="
echo "==> Registering MCP Server in Google Cloud Agent Registry"
echo "    Project:           ${PROJECT_ID}"
echo "    Registry Location: ${REGISTRY_LOCATION}"
echo "    Service ID:        ${SERVICE_ID}"
echo "    Display Name:      ${SERVICE_DISPLAY_NAME}"
echo "    Apigee MCP URL:    ${APIGEE_MCP_URL}"
echo "    Protocol Binding:  ${PROTOCOL_BINDING}"
echo "=========================================================="

if gcloud agent-registry services describe "${SERVICE_ID}" --location="${REGISTRY_LOCATION}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  echo "    Service ${SERVICE_ID} already exists in Agent Registry. Describing existing resource..."
else
  gcloud agent-registry services create "${SERVICE_ID}" \
    --location="${REGISTRY_LOCATION}" \
    --project="${PROJECT_ID}" \
    --display-name="${SERVICE_DISPLAY_NAME}" \
    --description="${SERVICE_DESCRIPTION}" \
    --mcp-server-spec-type="${SPEC_TYPE}" \
    --interfaces="url=${APIGEE_MCP_URL},protocolBinding=${PROTOCOL_BINDING}"
fi

echo "==> Describing registered service in Agent Registry..."
gcloud agent-registry services describe "${SERVICE_ID}" \
  --location="${REGISTRY_LOCATION}" \
  --project="${PROJECT_ID}"

echo ""
echo "==> Fetching projected MCP Server Resource ID for use in Agent configuration..."
PROJECTED_SERVER=$(gcloud agent-registry services describe "${SERVICE_ID}" \
  --location="${REGISTRY_LOCATION}" \
  --project="${PROJECT_ID}" \
  --format="value(registryResource)")

echo "Projected MCP Server Name: ${PROJECTED_SERVER}"
echo "Add this to env.sh as MCP_SERVER_NAME:"
echo "export MCP_SERVER_NAME=\"${PROJECTED_SERVER}\""
