#!/bin/bash
set -euo pipefail
export GOOGLE_API_USE_CLIENT_CERTIFICATE="false"
export CLOUDSDK_CONTEXT_AWARE_USE_CLIENT_CERTIFICATE="false"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/../env.sh" ]]; then
  source "${SCRIPT_DIR}/../env.sh"
fi

# ==============================================================================
# Configuration & Variable Declarations
# ==============================================================================
export PROJECT_ID="${PROJECT_ID:-${GOOGLE_CLOUD_PROJECT:-test-501813}}"
export PROJECT_NO="${PROJECT_NO:-951503373927}"
export REGION="${REGION:-${GOOGLE_CLOUD_LOCATION:-us-central1}}"

# 1. Ingress Agent Gateway (CLIENT_TO_AGENT)
export INGRESS_GATEWAY_NAME="${INGRESS_GATEWAY_NAME:-agw-foo-us-central1-cta}"
export INGRESS_MA_AUTHZ_EXT_NAME="${INGRESS_MA_AUTHZ_EXT_NAME:-agw-foo-us-central1-cta-svc-ext-authz-modar}"
export INGRESS_MA_POLICY_NAME="${INGRESS_MA_POLICY_NAME:-agw-foo-us-central1-cta-authz-policy-modar}"
export INGRESS_IAP_AUTHZ_EXT_NAME="${INGRESS_IAP_AUTHZ_EXT_NAME:-agw-foo-us-central1-cta-svc-ext-authz-iap-enforced}"
export INGRESS_IAP_POLICY_NAME="${INGRESS_IAP_POLICY_NAME:-agw-foo-us-central1-cta-authz-policy-profile-iap}"

# 2. Egress Agent Gateway (AGENT_TO_ANYWHERE)
export EGRESS_GATEWAY_NAME="${EGRESS_GATEWAY_NAME:-fresh-agent-egress-gateway}"
export EGRESS_MA_AUTHZ_EXT_NAME="${EGRESS_MA_AUTHZ_EXT_NAME:-fresh-agw-ma-authz}"
export EGRESS_MA_POLICY_NAME="${EGRESS_MA_POLICY_NAME:-fresh-agw-ma-policy}"
export EGRESS_IAP_AUTHZ_EXT_NAME="${EGRESS_IAP_AUTHZ_EXT_NAME:-fresh-agw-iap-authz}"
export EGRESS_IAP_POLICY_NAME="${EGRESS_IAP_POLICY_NAME:-fresh-agw-iap-policy}"

# Common Security Template & Apigee Host
export MA_TEMPLATE_NAME="${MA_TEMPLATE_NAME:-fresh-agw-safety-template}"
export APIGEE_HOST="${APIGEE_HOST:-35.244.241.176.nip.io}"

echo "=================================================================="
echo "==> Setting up Dual Agent Gateways, Model Armor & IAP"
echo "    Project:          ${PROJECT_ID} (${PROJECT_NO})"
echo "    Region:           ${REGION}"
echo "    Ingress Gateway:  ${INGRESS_GATEWAY_NAME} (Ingress Gateway | CLIENT_TO_AGENT)"
echo "    Egress Gateway:   ${EGRESS_GATEWAY_NAME} (Egress Gateway | AGENT_TO_ANYWHERE)"
echo "    Safety Template:  ${MA_TEMPLATE_NAME}"
echo "=================================================================="

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

# ==============================================================================
# Step 1: Configure Weather-Specific Cloud DLP (SDP) & Model Armor Safety Template
# ==============================================================================
export SDP_INSPECT_TEMPLATE_ID="${SDP_INSPECT_TEMPLATE_ID:-weather-agw-sdp-inspect-template}"
export SDP_DEID_TEMPLATE_ID="${SDP_DEID_TEMPLATE_ID:-weather-agw-sdp-deid-template}"
export SDP_INSPECT_TEMPLATE_NAME="projects/${PROJECT_ID}/locations/${REGION}/inspectTemplates/${SDP_INSPECT_TEMPLATE_ID}"
export SDP_DEID_TEMPLATE_NAME="projects/${PROJECT_ID}/locations/${REGION}/deidentifyTemplates/${SDP_DEID_TEMPLATE_ID}"

echo ""
echo "==> Step 1a: Configuring Weather & Aviation Cloud DLP (SDP) Templates (${SDP_INSPECT_TEMPLATE_ID})..."
ACCESS_TOKEN="${CLOUDSDK_AUTH_ACCESS_TOKEN:-$(gcloud auth application-default print-access-token 2>/dev/null || true)}"

if [[ -n "${ACCESS_TOKEN}" ]]; then
  cat <<EOF > "${TMP_DIR}/sdp-inspect.json"
{
  "templateId": "${SDP_INSPECT_TEMPLATE_ID}",
  "inspectTemplate": {
    "displayName": "Weather & Aviation Agent SDP Inspect Template",
    "description": "Detects PII (Street Addresses, Phone, Email), Cloud/Apigee OAuth Credentials, High-Precision Pinpoint GPS Coordinates, and Restricted Aviation Station IDs",
    "inspectConfig": {
      "minLikelihood": "POSSIBLE",
      "infoTypes": [
        {"name": "GCP_API_KEY"},
        {"name": "AUTH_TOKEN"},
        {"name": "JSON_WEB_TOKEN"},
        {"name": "CREDIT_CARD_NUMBER"},
        {"name": "US_SOCIAL_SECURITY_NUMBER"},
        {"name": "STREET_ADDRESS"},
        {"name": "PHONE_NUMBER"},
        {"name": "EMAIL_ADDRESS"}
      ],
      "customInfoTypes": [
        {
          "infoType": {"name": "HIGH_PRECISION_GPS_COORDINATES"},
          "regex": {"pattern": "\\\\b-?\\\\d{1,2}\\\\.\\\\d{5,}\\\\s*,\\\\s*-?\\\\d{1,3}\\\\.\\\\d{5,}\\\\b"},
          "likelihood": "VERY_LIKELY"
        },
        {
          "infoType": {"name": "APIGEE_OAUTH_CREDENTIAL"},
          "dictionary": {
            "wordList": {
              "words": [
                "FbpAAqg19gEMnGGCE0GTyZFhgt4egeqfGwkkbGeTNFDK5TRB",
                "Piml5lR7qFRfoklh84GTGk2IOZHycqfKM3v07acxdtrGb2S7MA6tEVSTqvSyak8B"
              ]
            }
          },
          "likelihood": "VERY_LIKELY"
        },
        {
          "infoType": {"name": "RESTRICTED_AVIATION_STATION_ID"},
          "dictionary": {
            "wordList": {
              "words": ["KXTA", "KEDW-RESTRICTED", "AREA51-WX"]
            }
          },
          "likelihood": "VERY_LIKELY"
        }
      ]
    }
  }
}
EOF

  cat <<EOF > "${TMP_DIR}/sdp-deid.json"
{
  "templateId": "${SDP_DEID_TEMPLATE_ID}",
  "deidentifyTemplate": {
    "displayName": "Weather & Aviation Agent SDP De-identify Template",
    "description": "Redacts detected PII, High-Precision GPS Coordinates, and Apigee/GCP Secrets with [REDACTED] tags",
    "deidentifyConfig": {
      "infoTypeTransformations": {
        "transformations": [
          {
            "primitiveTransformation": {
              "replaceWithInfoTypeConfig": {}
            }
          }
        ]
      }
    }
  }
}
EOF

  curl -s -X POST "https://dlp.googleapis.com/v2/projects/${PROJECT_ID}/locations/${REGION}/inspectTemplates" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" \
    -H "X-Goog-User-Project: ${PROJECT_ID}" \
    -d @"${TMP_DIR}/sdp-inspect.json" >/dev/null 2>&1 || \
  curl -s -X PATCH "https://dlp.googleapis.com/v2/${SDP_INSPECT_TEMPLATE_NAME}" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" \
    -H "X-Goog-User-Project: ${PROJECT_ID}" \
    -d "$(jq '.inspectTemplate' "${TMP_DIR}/sdp-inspect.json")" >/dev/null 2>&1 || true

  curl -s -X POST "https://dlp.googleapis.com/v2/projects/${PROJECT_ID}/locations/${REGION}/deidentifyTemplates" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" \
    -H "X-Goog-User-Project: ${PROJECT_ID}" \
    -d @"${TMP_DIR}/sdp-deid.json" >/dev/null 2>&1 || \
  curl -s -X PATCH "https://dlp.googleapis.com/v2/${SDP_DEID_TEMPLATE_NAME}" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" \
    -H "X-Goog-User-Project: ${PROJECT_ID}" \
    -d "$(jq '.deidentifyTemplate' "${TMP_DIR}/sdp-deid.json")" >/dev/null 2>&1 || true
fi

echo ""
echo "==> Step 1b: Configuring Model Armor Safety Template (${MA_TEMPLATE_NAME}) with Weather RAI & SDP Filters..."
RAI_FILTERS='[{"filterType":"DANGEROUS","confidenceLevel":"LOW_AND_ABOVE"},{"filterType":"HATE_SPEECH","confidenceLevel":"MEDIUM_AND_ABOVE"},{"filterType":"HARASSMENT","confidenceLevel":"MEDIUM_AND_ABOVE"},{"filterType":"SEXUALLY_EXPLICIT","confidenceLevel":"MEDIUM_AND_ABOVE"}]'

if ! gcloud model-armor templates describe "${MA_TEMPLATE_NAME}" --location="${REGION}" --project="${PROJECT_ID}" --billing-project="${PROJECT_ID}" >/dev/null 2>&1; then
  echo "    Creating Model Armor template: ${MA_TEMPLATE_NAME}"
  gcloud model-armor templates create "${MA_TEMPLATE_NAME}" \
    --location="${REGION}" \
    --project="${PROJECT_ID}" \
    --billing-project="${PROJECT_ID}" \
    --advanced-config-inspect-template="${SDP_INSPECT_TEMPLATE_NAME}" \
    --advanced-config-deidentify-template="${SDP_DEID_TEMPLATE_NAME}" \
    --malicious-uri-filter-settings-enforcement=ENABLED \
    --pi-and-jailbreak-filter-settings-enforcement=ENABLED \
    --pi-and-jailbreak-filter-settings-confidence-level=LOW_AND_ABOVE \
    --rai-settings-filters="${RAI_FILTERS}" || \
  gcloud model-armor templates create "${MA_TEMPLATE_NAME}" \
    --location="${REGION}" \
    --project="${PROJECT_ID}" \
    --billing-project="${PROJECT_ID}" \
    --basic-config-filter-enforcement=ENABLED \
    --malicious-uri-filter-settings-enforcement=ENABLED \
    --pi-and-jailbreak-filter-settings-enforcement=ENABLED \
    --pi-and-jailbreak-filter-settings-confidence-level=LOW_AND_ABOVE \
    --rai-settings-filters="${RAI_FILTERS}"
else
  echo "    Updating existing Model Armor template (${MA_TEMPLATE_NAME}) with DANGEROUS RAI & Weather SDP filters..."
  gcloud model-armor templates update "${MA_TEMPLATE_NAME}" \
    --location="${REGION}" \
    --project="${PROJECT_ID}" \
    --billing-project="${PROJECT_ID}" \
    --advanced-config-inspect-template="${SDP_INSPECT_TEMPLATE_NAME}" \
    --advanced-config-deidentify-template="${SDP_DEID_TEMPLATE_NAME}" \
    --malicious-uri-filter-settings-enforcement=ENABLED \
    --pi-and-jailbreak-filter-settings-enforcement=ENABLED \
    --pi-and-jailbreak-filter-settings-confidence-level=LOW_AND_ABOVE \
    --rai-settings-filters="${RAI_FILTERS}" 2>/dev/null || \
  gcloud model-armor templates update "${MA_TEMPLATE_NAME}" \
    --location="${REGION}" \
    --project="${PROJECT_ID}" \
    --billing-project="${PROJECT_ID}" \
    --basic-config-filter-enforcement=ENABLED \
    --malicious-uri-filter-settings-enforcement=ENABLED \
    --pi-and-jailbreak-filter-settings-enforcement=ENABLED \
    --pi-and-jailbreak-filter-settings-confidence-level=LOW_AND_ABOVE \
    --rai-settings-filters="${RAI_FILTERS}"
fi

# ==============================================================================
# Step 2: Configure Service Extensions (Authz Extensions for Model Armor & IAP)
# ==============================================================================
echo ""
echo "==> Step 2: Checking Service Extensions Authz Extensions (Model Armor & IAP)..."

# 2a. Egress Model Armor Authz Extension
if ! gcloud service-extensions authz-extensions describe "${EGRESS_MA_AUTHZ_EXT_NAME}" --location="${REGION}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  echo "    - Creating Egress Model Armor Authz Extension (${EGRESS_MA_AUTHZ_EXT_NAME})..."
  cat <<EOF > "${TMP_DIR}/egress-ma-authz-ext.yaml"
name: projects/${PROJECT_ID}/locations/${REGION}/authzExtensions/${EGRESS_MA_AUTHZ_EXT_NAME}
service: modelarmor.${REGION}.rep.googleapis.com
failOpen: true
timeout: 2s
metadata:
  model_armor_settings: '[{"request_template_id":"projects/${PROJECT_ID}/locations/${REGION}/templates/${MA_TEMPLATE_NAME}","response_template_id":"projects/${PROJECT_ID}/locations/${REGION}/templates/${MA_TEMPLATE_NAME}"}]'
EOF
  gcloud service-extensions authz-extensions import "${EGRESS_MA_AUTHZ_EXT_NAME}" \
    --source="${TMP_DIR}/egress-ma-authz-ext.yaml" \
    --location="${REGION}" \
    --project="${PROJECT_ID}"
else
  echo "    - Egress Model Armor Authz Extension (${EGRESS_MA_AUTHZ_EXT_NAME}) already exists."
fi

# 2b. Egress IAP Authz Extension
if ! gcloud service-extensions authz-extensions describe "${EGRESS_IAP_AUTHZ_EXT_NAME}" --location="${REGION}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  echo "    - Creating Egress IAP Authz Extension (${EGRESS_IAP_AUTHZ_EXT_NAME})..."
  cat <<EOF > "${TMP_DIR}/egress-iap-authz-ext.yaml"
name: projects/${PROJECT_ID}/locations/${REGION}/authzExtensions/${EGRESS_IAP_AUTHZ_EXT_NAME}
service: iap.googleapis.com
failOpen: true
timeout: 1s
metadata:
  iamEnforcementMode: "ENFORCE"
  iapPolicyVersion: "V1"
EOF
  gcloud service-extensions authz-extensions import "${EGRESS_IAP_AUTHZ_EXT_NAME}" \
    --source="${TMP_DIR}/egress-iap-authz-ext.yaml" \
    --location="${REGION}" \
    --project="${PROJECT_ID}"
else
  echo "    - Egress IAP Authz Extension (${EGRESS_IAP_AUTHZ_EXT_NAME}) already exists."
fi

# 2c. Ingress Model Armor Authz Extension
if ! gcloud service-extensions authz-extensions describe "${INGRESS_MA_AUTHZ_EXT_NAME}" --location="${REGION}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  echo "    - Creating Ingress Model Armor Authz Extension (${INGRESS_MA_AUTHZ_EXT_NAME})..."
  cat <<EOF > "${TMP_DIR}/ingress-ma-authz-ext.yaml"
name: projects/${PROJECT_ID}/locations/${REGION}/authzExtensions/${INGRESS_MA_AUTHZ_EXT_NAME}
service: modelarmor.${REGION}.rep.googleapis.com
failOpen: true
timeout: 2s
metadata:
  model_armor_settings: '[{"request_template_id":"projects/${PROJECT_ID}/locations/${REGION}/templates/${MA_TEMPLATE_NAME}","response_template_id":"projects/${PROJECT_ID}/locations/${REGION}/templates/${MA_TEMPLATE_NAME}"}]'
EOF
  gcloud service-extensions authz-extensions import "${INGRESS_MA_AUTHZ_EXT_NAME}" \
    --source="${TMP_DIR}/ingress-ma-authz-ext.yaml" \
    --location="${REGION}" \
    --project="${PROJECT_ID}"
else
  echo "    - Ingress Model Armor Authz Extension (${INGRESS_MA_AUTHZ_EXT_NAME}) already exists."
fi

# 2d. Ingress IAP Authz Extension
if ! gcloud service-extensions authz-extensions describe "${INGRESS_IAP_AUTHZ_EXT_NAME}" --location="${REGION}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  echo "    - Creating Ingress IAP Authz Extension (${INGRESS_IAP_AUTHZ_EXT_NAME})..."
  cat <<EOF > "${TMP_DIR}/ingress-iap-authz-ext.yaml"
name: projects/${PROJECT_ID}/locations/${REGION}/authzExtensions/${INGRESS_IAP_AUTHZ_EXT_NAME}
service: iap.googleapis.com
failOpen: true
timeout: 1s
metadata:
  iamEnforcementMode: "ENFORCE"
  iapPolicyVersion: "V1"
EOF
  gcloud service-extensions authz-extensions import "${INGRESS_IAP_AUTHZ_EXT_NAME}" \
    --source="${TMP_DIR}/ingress-iap-authz-ext.yaml" \
    --location="${REGION}" \
    --project="${PROJECT_ID}"
else
  echo "    - Ingress IAP Authz Extension (${INGRESS_IAP_AUTHZ_EXT_NAME}) already exists."
fi

# ==============================================================================
# Step 3: Configure Dual Agent Gateways (Ingress + Egress)
# ==============================================================================
echo ""
echo "==> Step 3: Configuring Ingress Gateway & Egress Gateway..."

# 3a. Ingress Agent Gateway (CLIENT_TO_AGENT)
echo "    - Updating Ingress Gateway (${INGRESS_GATEWAY_NAME}) [CLIENT_TO_AGENT]..."
cat <<EOF > "${TMP_DIR}/ingress-gateway.yaml"
description: "Ingress Gateway"
protocols:
  - MCP
googleManaged:
  governedAccessPath: CLIENT_TO_AGENT
registries:
  - //agentregistry.googleapis.com/projects/${PROJECT_ID}/locations/us-central1
  - //agentregistry.googleapis.com/projects/${PROJECT_ID}/locations/global
EOF
gcloud network-services agent-gateways import "${INGRESS_GATEWAY_NAME}" \
  --source="${TMP_DIR}/ingress-gateway.yaml" \
  --location="${REGION}" \
  --project="${PROJECT_ID}"

# 3b. Egress Agent Gateway (AGENT_TO_ANYWHERE)
echo "    - Updating Egress Gateway (${EGRESS_GATEWAY_NAME}) [AGENT_TO_ANYWHERE]..."
cat <<EOF > "${TMP_DIR}/egress-gateway.yaml"
description: "Egress Gateway"
protocols:
  - MCP
googleManaged:
  governedAccessPath: AGENT_TO_ANYWHERE
registries:
  - //agentregistry.googleapis.com/projects/${PROJECT_ID}/locations/us-central1
  - //agentregistry.googleapis.com/projects/${PROJECT_ID}/locations/global
EOF
gcloud network-services agent-gateways import "${EGRESS_GATEWAY_NAME}" \
  --source="${TMP_DIR}/egress-gateway.yaml" \
  --location="${REGION}" \
  --project="${PROJECT_ID}"

# ==============================================================================
# Step 4: Configure Security Authz Policies (Model Armor & IAP)
# ==============================================================================
echo ""
echo "==> Step 4: Attaching Model Armor (CONTENT_AUTHZ) & IAP (REQUEST_AUTHZ) Policies..."

# 4a. Egress Model Armor Policy (scoped to Apigee host)
echo "    - Ensuring Egress Model Armor Policy (${EGRESS_MA_POLICY_NAME})..."
cat <<EOF > "${TMP_DIR}/egress-ma-policy.yaml"
name: projects/${PROJECT_ID}/locations/${REGION}/authzPolicies/${EGRESS_MA_POLICY_NAME}
policyProfile: CONTENT_AUTHZ
action: CUSTOM
customProvider:
  authzExtension:
    resources:
    - projects/${PROJECT_NO}/locations/${REGION}/authzExtensions/${EGRESS_MA_AUTHZ_EXT_NAME}
target:
  resources:
  - projects/${PROJECT_NO}/locations/${REGION}/agentGateways/${EGRESS_GATEWAY_NAME}
httpRules:
- to:
    operations:
    - hosts:
      - exact: ${APIGEE_HOST}
EOF
gcloud network-security authz-policies import "${EGRESS_MA_POLICY_NAME}" \
  --source="${TMP_DIR}/egress-ma-policy.yaml" \
  --location="${REGION}" \
  --project="${PROJECT_ID}"

# 4b. Egress IAP Policy (scoped to Apigee host)
echo "    - Ensuring Egress IAP Policy (${EGRESS_IAP_POLICY_NAME})..."
cat <<EOF > "${TMP_DIR}/egress-iap-policy.yaml"
name: projects/${PROJECT_ID}/locations/${REGION}/authzPolicies/${EGRESS_IAP_POLICY_NAME}
policyProfile: REQUEST_AUTHZ
action: CUSTOM
customProvider:
  authzExtension:
    resources:
    - projects/${PROJECT_NO}/locations/${REGION}/authzExtensions/${EGRESS_IAP_AUTHZ_EXT_NAME}
target:
  resources:
  - projects/${PROJECT_NO}/locations/${REGION}/agentGateways/${EGRESS_GATEWAY_NAME}
httpRules:
- to:
    operations:
    - hosts:
      - exact: ${APIGEE_HOST}
EOF
gcloud network-security authz-policies import "${EGRESS_IAP_POLICY_NAME}" \
  --source="${TMP_DIR}/egress-iap-policy.yaml" \
  --location="${REGION}" \
  --project="${PROJECT_ID}"

# 4c. Ingress Model Armor Policy (protecting incoming requests to the Agent)
echo "    - Ensuring Ingress Model Armor Policy (${INGRESS_MA_POLICY_NAME})..."
cat <<EOF > "${TMP_DIR}/ingress-ma-policy.yaml"
name: projects/${PROJECT_ID}/locations/${REGION}/authzPolicies/${INGRESS_MA_POLICY_NAME}
policyProfile: CONTENT_AUTHZ
action: CUSTOM
customProvider:
  authzExtension:
    resources:
    - projects/${PROJECT_NO}/locations/${REGION}/authzExtensions/${INGRESS_MA_AUTHZ_EXT_NAME}
target:
  resources:
  - projects/${PROJECT_NO}/locations/${REGION}/agentGateways/${INGRESS_GATEWAY_NAME}
EOF
gcloud network-security authz-policies import "${INGRESS_MA_POLICY_NAME}" \
  --source="${TMP_DIR}/ingress-ma-policy.yaml" \
  --location="${REGION}" \
  --project="${PROJECT_ID}"

# 4d. Ingress IAP Policy (protecting incoming requests to the Agent)
echo "    - Ensuring Ingress IAP Policy (${INGRESS_IAP_POLICY_NAME})..."
cat <<EOF > "${TMP_DIR}/ingress-iap-policy.yaml"
name: projects/${PROJECT_ID}/locations/${REGION}/authzPolicies/${INGRESS_IAP_POLICY_NAME}
policyProfile: REQUEST_AUTHZ
action: CUSTOM
customProvider:
  authzExtension:
    resources:
    - projects/${PROJECT_NO}/locations/${REGION}/authzExtensions/${INGRESS_IAP_AUTHZ_EXT_NAME}
target:
  resources:
  - projects/${PROJECT_NO}/locations/${REGION}/agentGateways/${INGRESS_GATEWAY_NAME}
EOF
gcloud network-security authz-policies import "${INGRESS_IAP_POLICY_NAME}" \
  --source="${TMP_DIR}/ingress-iap-policy.yaml" \
  --location="${REGION}" \
  --project="${PROJECT_ID}"

echo ""
echo "✅ Dual Agent Gateways (Ingress & Egress) and Model Armor + IAP Policies setup complete!"
