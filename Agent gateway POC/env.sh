#!/bin/bash
export GOOGLE_API_USE_CLIENT_CERTIFICATE="false"
export CLOUDSDK_CONTEXT_AWARE_USE_CLIENT_CERTIFICATE="false"
export CLOUDSDK_AUTH_ACCESS_TOKEN="$(gcloud auth application-default print-access-token 2>/dev/null || true)"

export PROJECT_ID="${GOOGLE_CLOUD_PROJECT:-test-501813}"
export CLOUDSDK_BILLING_QUOTA_PROJECT="${PROJECT_ID}"
export PROJECT_NO="951503373927"
export REGION="${GOOGLE_CLOUD_LOCATION:-us-central1}"
export REGISTRY_LOCATION="${REGISTRY_LOCATION:-global}"

export AGENT_NAME="Agent weather-07"
export ENGINE_ID="${ENGINE_ID:-8597428313499107328}"
export AUTH_PROVIDER_NAME="weather-07-oauth-provider"

# Dual Agent Gateway Configuration (Active Regional Gateways in test-501813)
# 1. Northbound Ingress Gateway (CLIENT_TO_AGENT)
export INGRESS_GATEWAY_NAME="agw-foo-us-central1-cta"
export INGRESS_GATEWAY_URI="projects/${PROJECT_ID}/locations/${REGION}/agentGateways/${INGRESS_GATEWAY_NAME}"

# 2. Southbound Egress Gateway (AGENT_TO_ANYWHERE)
export EGRESS_GATEWAY_NAME="fresh-agent-egress-gateway"
export EGRESS_GATEWAY_URI="projects/${PROJECT_ID}/locations/${REGION}/agentGateways/${EGRESS_GATEWAY_NAME}"

# Security Configuration (Model Armor & IAP)
export MA_TEMPLATE_NAME="fresh-agw-safety-template"

# Ingress Security Policies (attached to Ingress Gateway: agw-foo-us-central1-cta)
export INGRESS_MA_AUTHZ_EXT_NAME="agw-foo-us-central1-cta-svc-ext-authz-modar"
export INGRESS_MA_POLICY_NAME="agw-foo-us-central1-cta-authz-policy-modar"
export INGRESS_IAP_AUTHZ_EXT_NAME="agw-foo-us-central1-cta-svc-ext-authz-iap-enforced"
export INGRESS_IAP_POLICY_NAME="agw-foo-us-central1-cta-authz-policy-profile-iap"

# Egress Security Policies (attached to Egress Gateway: fresh-agent-egress-gateway)
export EGRESS_MA_AUTHZ_EXT_NAME="fresh-agw-ma-authz"
export EGRESS_MA_POLICY_NAME="fresh-agw-ma-policy"
export EGRESS_IAP_AUTHZ_EXT_NAME="fresh-agw-iap-authz"
export EGRESS_IAP_POLICY_NAME="fresh-agw-iap-policy"

# MCP Server in Agent Registry
export MCP_SERVER_NAME="${MCP_SERVER_NAME:-projects/${PROJECT_ID}/locations/${REGISTRY_LOCATION}/mcpServers/agentregistry-00000000-0000-0000-d2d4-1318dbcb3102}"

# Apigee X Endpoints & OAuth 2.0 Credentials (stored in weather-07-oauth-provider)
export APIGEE_HOST="8.233.148.121.nip.io"
export MCP_TOKEN_URL="https://35.244.241.176.nip.io/mcp/token"
export APIGEE_MCP_URL="https://35.244.241.176.nip.io/mcp"
export APIGEE_INGRESS_URL="https://8.233.148.121.nip.io/weather-agent-07"
export APIGEE_LLM_ROUTER_URL="https://8.233.148.121.nip.io/llm-router-07"
export APIGEE_CLIENT_ID="FbpAAqg19gEMnGGCE0GTyZFhgt4egeqfGwkkbGeTNFDK5TRB"
export APIGEE_CLIENT_SECRET="Piml5lR7qFRfoklh84GTGk2IOZHycqfKM3v07acxdtrGb2S7MA6tEVSTqvSyak8B"

export STAGING_BUCKET="gs://${PROJECT_ID}-agent-staging"
