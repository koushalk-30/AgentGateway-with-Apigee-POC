#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

echo "==> Packaging Apigee Proxy Bundle..."
cd "${SCRIPT_DIR}"
rm -f mcp-weather-oas-bundle.zip
zip -r mcp-weather-oas-bundle.zip apiproxy/ -x "*.DS_Store"

TOKEN=$(gcloud auth application-default print-access-token)

echo "==> Importing Proxy Bundle to Apigee Org: ${APIGEE_ORG}..."
IMPORT_RESP=$(curl -s -X POST \
  "https://apigee.googleapis.com/v1/organizations/${APIGEE_ORG}/apis?name=mcp-weather-oas&action=import" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/octet-stream" \
  --data-binary @mcp-weather-oas-bundle.zip)

REV=$(echo "${IMPORT_RESP}" | jq -r '.revision // empty')
if [ -z "${REV}" ]; then
  echo "Import failed or returned unexpected response:"
  echo "${IMPORT_RESP}"
  exit 1
fi
echo "Imported as Revision: ${REV}"

echo "==> Deploying Revision ${REV} to Environment: ${APIGEE_ENV}..."
curl -s -X POST \
  "https://apigee.googleapis.com/v1/organizations/${APIGEE_ORG}/environments/${APIGEE_ENV}/apis/mcp-weather-oas/revisions/${REV}/deployments?override=true" \
  -H "Authorization: Bearer ${TOKEN}" > /dev/null
echo "Deployed revision ${REV}."

echo "==> Ensuring API Product 'mcp-weather-product' exists..."
curl -s -X POST \
  "https://apigee.googleapis.com/v1/organizations/${APIGEE_ORG}/apiproducts" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "mcp-weather-product",
    "displayName": "MCP Weather Product",
    "approvalType": "auto",
    "environments": ["'"${APIGEE_ENV}"'"],
    "proxies": ["mcp-weather-oas"]
  }' > /dev/null 2>&1 || true

echo "==> Ensuring Developer 'mcp-agent-dev@example.com' exists..."
curl -s -X POST \
  "https://apigee.googleapis.com/v1/organizations/${APIGEE_ORG}/developers" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "email": "mcp-agent-dev@example.com",
    "firstName": "MCP",
    "lastName": "Agent",
    "userName": "mcp-agent-dev"
  }' > /dev/null 2>&1 || true

echo "==> Ensuring Developer App 'fresh-mcp-weather-app' exists..."
APP_RESP=$(curl -s -X GET \
  "https://apigee.googleapis.com/v1/organizations/${APIGEE_ORG}/developers/mcp-agent-dev@example.com/apps/fresh-mcp-weather-app" \
  -H "Authorization: Bearer ${TOKEN}" || true)

if echo "${APP_RESP}" | jq -e '.credentials' >/dev/null 2>&1; then
  echo "Developer app already exists."
else
  APP_RESP=$(curl -s -X POST \
    "https://apigee.googleapis.com/v1/organizations/${APIGEE_ORG}/developers/mcp-agent-dev@example.com/apps" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{
      "name": "fresh-mcp-weather-app",
      "apiProducts": ["mcp-weather-product"]
    }')
fi

CLIENT_ID=$(echo "${APP_RESP}" | jq -r '.credentials[0].consumerKey')
CLIENT_SECRET=$(echo "${APP_RESP}" | jq -r '.credentials[0].consumerSecret')

cat << CRED_EOF > "${SCRIPT_DIR}/.apigee_credentials"
export APIGEE_CLIENT_ID="${CLIENT_ID}"
export APIGEE_CLIENT_SECRET="${CLIENT_SECRET}"
CRED_EOF

echo "=========================================================="
echo " Apigee Setup Completed!"
echo " Proxy:          mcp-weather-oas (Rev ${REV})"
echo " Consumer Key:    ${CLIENT_ID}"
echo " Consumer Secret: ${CLIENT_SECRET}"
echo " Saved to:       .apigee_credentials"
echo "=========================================================="
