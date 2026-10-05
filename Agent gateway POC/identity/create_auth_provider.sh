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
export REGION="${REGION:-${GOOGLE_CLOUD_LOCATION:-us-central1}}"
export AUTH_PROVIDER_NAME="${AUTH_PROVIDER_NAME:-weather-07-oauth-provider}"

# Apigee 2-Legged OAuth Credentials & Token Endpoint
export APIGEE_CLIENT_ID="${APIGEE_CLIENT_ID:-FbpAAqg19gEMnGGCE0GTyZFhgt4egeqfGwkkbGeTNFDK5TRB}"
export APIGEE_CLIENT_SECRET="${APIGEE_CLIENT_SECRET:-Piml5lR7qFRfoklh84GTGk2IOZHycqfKM3v07acxdtrGb2S7MA6tEVSTqvSyak8B}"
export MCP_TOKEN_URL="${MCP_TOKEN_URL:-https://35.244.241.176.nip.io/mcp/token}"

# User & Reasoning Engine (Agent Identity) Configurations
export USER_EMAIL="${USER_EMAIL:-admin@koushalk.altostrat.com}"
export AGENT_NAME="${AGENT_NAME:-Agent weather-05}"
export ENGINE_ID="${1:-${ENGINE_ID:-8597428313499107328}}"

# Project & Org Metadata
ORG_ID=$(gcloud projects describe "${PROJECT_ID}" --format="value(parent.id)")
PROJECT_NUMBER=$(gcloud projects describe "${PROJECT_ID}" --format="value(projectNumber)")

# Full Reasoning Engine Resource Name & Cryptographic SPIFFE Workload ID
export ENGINE_RESOURCE_NAME="projects/${PROJECT_NUMBER}/locations/${REGION}/reasoningEngines/${ENGINE_ID}"
export AGENT_SPIFFE_ID="principal://agents.global.org-${ORG_ID}.system.id.goog/resources/aiplatform/projects/${PROJECT_NUMBER}/locations/${REGION}/reasoningEngines/${ENGINE_ID}"

echo "=========================================================="
echo "==> Setting up Auth Provider & IAM Identity"
echo "    Project:         ${PROJECT_ID} (${PROJECT_NUMBER})"
echo "    Region:          ${REGION}"
echo "    Auth Provider:   ${AUTH_PROVIDER_NAME}"
echo "    Agent Name:      ${AGENT_NAME}"
echo "    Engine ID:       ${ENGINE_ID}"
echo "    Engine Resource: ${ENGINE_RESOURCE_NAME}"
echo "    Agent SPIFFE ID: ${AGENT_SPIFFE_ID}"
echo "    User Email:      ${USER_EMAIL}"
echo "=========================================================="

echo ""
echo "==> Step 1: Creating 2-legged OAuth Auth Provider (${AUTH_PROVIDER_NAME}) using gcloud CLI..."
if gcloud alpha agent-identity connectors describe "${AUTH_PROVIDER_NAME}" --location="${REGION}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  echo "    Auth provider ${AUTH_PROVIDER_NAME} already exists. Continuing with verification..."
else
  gcloud alpha agent-identity connectors create "${AUTH_PROVIDER_NAME}" \
    --project="${PROJECT_ID}" \
    --location="${REGION}" \
    --two-legged-oauth-client-id="${APIGEE_CLIENT_ID}" \
    --two-legged-oauth-client-secret="${APIGEE_CLIENT_SECRET}" \
    --two-legged-oauth-token-endpoint="${MCP_TOKEN_URL}"
fi

echo "==> Step 2: Verifying auth provider in connectors list..."
gcloud alpha agent-identity connectors list \
  --project="${PROJECT_ID}" \
  --location="${REGION}"

if [ -n "${ENGINE_ID}" ]; then
  echo "==> Step 3: Granting Connector User (roles/iamconnectors.user) role to Reasoning Engine (${ENGINE_RESOURCE_NAME})..."
  echo "    Agent SPIFFE ID: ${AGENT_SPIFFE_ID}"
  gcloud alpha agent-identity connectors add-iam-policy-binding "${AUTH_PROVIDER_NAME}" \
    --project="${PROJECT_ID}" \
    --location="${REGION}" \
    --role="roles/iamconnectors.user" \
    --member="${AGENT_SPIFFE_ID}"

  echo "==> Step 4: Granting roles/agentregistry.viewer to the Agent on project ${PROJECT_ID}..."
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="${AGENT_SPIFFE_ID}" \
    --role="roles/agentregistry.viewer" \
    --condition=None

  echo "==> Step 5: Granting roles/iap.egressor to the Agent on project ${PROJECT_ID}..."
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="${AGENT_SPIFFE_ID}" \
    --role="roles/iap.egressor" \
    --condition=None
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="${AGENT_SPIFFE_ID}" \
    --role="roles/iap.httpsResourceAccessor" \
    --condition=None

  echo "==> Step 6: Linking Agent SPIFFE ID to Auth Provider workload-ids..."
  gcloud agent-identity auth-providers update "${AUTH_PROVIDER_NAME}" \
    --location="${REGION}" \
    --project="${PROJECT_ID}" \
    --workload-ids="${AGENT_SPIFFE_ID}"
fi

echo "==> Step 7: Granting Connector User (roles/iamconnectors.user) and IAP Accessor (roles/iap.httpsResourceAccessor) roles to personal user account (${USER_EMAIL})..."
gcloud alpha agent-identity connectors add-iam-policy-binding "${AUTH_PROVIDER_NAME}" \
  --project="${PROJECT_ID}" \
  --location="${REGION}" \
  --role="roles/iamconnectors.user" \
  --member="user:${USER_EMAIL}"

gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="user:${USER_EMAIL}" \
  --role="roles/iap.httpsResourceAccessor" \
  --condition=None

echo "==> Auth provider ${AUTH_PROVIDER_NAME} and IAM bindings setup complete!"
