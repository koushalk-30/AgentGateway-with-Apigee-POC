# Apigee as an AI Gateway and Agent Gateway POC

End-to-end reference implementation demonstrating **Google Cloud Apigee X as an AI Gateway** alongside **Agent Gateway**, **Agent Registry**, **Agent Identity Auth Manager**, and **Google Cloud Model Armor** to secure, govern, and optimize enterprise AI agents on **Vertex AI Agent Engine (ADK)**.

---

## Architecture Overview

1. **Northbound Ingress Perimeter (`weather-agent-07-ingress-proxy` + Northbound Agent Gateway)**
   - Exposes the Vertex AI ADK Agent (`Agent weather-07`) via an Apigee Ingress Proxy (`/weather-agent-07`) governed by **Apigee API Products**, `VerifyAPIKey`, `SpikeArrest`, and **Identity-Aware Proxy (IAP)** / `AuthzPolicy` verification.
   - Connects through the Northbound `CLIENT_TO_AGENT` **Agent Gateway** (`agw-foo-us-central1-cta`).

2. **Autonomous Agent Runtime & Cryptographic Identity (`agent/agent.py` + `identity/create_auth_provider.sh`)**
   - Runs a Google ADK (`LlmAgent`) on **Vertex AI Agent Engine** with a cryptographic **SPIFFE Workload Identity** (`principal://agents.global.org-...`).
   - Dynamically discovers MCP tools from **Agent Registry** (`registry/register_mcp_service.sh`) and authenticates via **Agent Identity Auth Manager** (`GcpAuthProviderScheme` 2-legged OAuth connector) without hardcoding static credentials in agent code.

3. **Southbound Smart Egress — Apigee AI Model Router (`apigee-ai-model-router-07`)**
   - Routes agent LLM requests through `/llm-router-07` with 6 native Apigee AI & security policies:
     - **Dynamic Model Routing**: Routes across `gemini-2.5-flash-lite` (Rule 1: Quick Triage), `gemini-2.5-flash` (Rule 2: Standard Weather & MCP Forecast), `gemini-2.5-pro` (Rule 3: Complex Aviation & Turbulence Reasoning), and `gemini-2.0-flash` (Rule 4: Economy Fallback).
     - **Model Armor Inline Safety**: Enforces `SanitizeUserPrompt` and `SanitizeModelResponse` (`fresh-agw-safety-template`) to block prompt injection, jailbreaks, and PII leakage.
     - **FinOps & Tokenomics**: Enforces `PromptTokenLimit` and rolling-window `LLMTokenQuota`.
     - **Semantic Caching**: Enforces `SemanticCacheLookup` & `SemanticCachePopulate` (plus distributed cache) to serve semantically similar queries in sub-100ms with zero duplicate Vertex AI token billing.

4. **Zero-Code REST-to-MCP Tool Server (`apigee_proxies/mcp-weather-oas`)**
   - Exposes National Weather Service (`api.weather.gov`) OpenAPI endpoints (`point`, `gridpoint_forecast`, `alerts_active_zone`, `office`, `glossary`) as standardized JSON-RPC 2.0 **MCP Tools** secured by Apigee OAuth 2.0 and federated into **Agent Registry**.

---

## Repository Structure

```text
├── env.sh                                      # Central environment & project configuration
├── deploy.py                                   # Vertex AI Agent Engine deployment & smoke test script
├── agent/
│   ├── __init__.py
│   └── agent.py                                # ADK LlmAgent wired to Apigee AI Model Router & Agent Registry MCP Toolset
├── apigee_proxies/
│   ├── apigee-ai-model-router-07/              # Southbound Apigee AI Model Router bundle (/llm-router-07)
│   ├── weather-agent-07-ingress-proxy/         # Northbound Apigee Ingress Proxy bundle (/weather-agent-07)
│   └── mcp-weather-oas/                        # Apigee OAuth2-protected REST-to-MCP Server proxy (/mcp)
├── gateway/
│   ├── setup_gateways.sh                       # Provisions Northbound & Southbound Agent Gateways
│   └── deploy_apigee_poc07.sh                  # Builds & deploys Apigee AI Model Router + Ingress Proxy
├── identity/
│   └── create_auth_provider.sh                 # Configures Agent Identity 2-legged OAuth Connector & SPIFFE IAM bindings
├── registry/
│   └── register_mcp_service.sh                 # Registers the Apigee MCP Server in Google Cloud Agent Registry
└── security_policies/
    ├── model_armor_templates.yaml              # Model Armor prompt & response sanitization templates
    └── authz_policies_and_extensions.yaml      # Agent Gateway AuthzPolicies for Model Armor & IAP
```

---

## Prerequisites

- **Google Cloud SDK (`gcloud`)** with `alpha` and `beta` components installed
- **Python 3.10+** with `google-adk`, `google-cloud-aiplatform`, and `google-auth` installed
- Active **Google Cloud Project** with **Apigee X**, **Vertex AI Agent Engine**, **Agent Registry**, **Agent Gateway**, and **Model Armor** enabled

---

## Step-by-Step Deployment Guide

### 1. Configure Environment Variables
Edit `env.sh` with your Google Cloud Project ID, Region, and Apigee X hostname, then source it:
```bash
source ./env.sh
```

### 2. Deploy the Apigee MCP Server Proxy & Register in Agent Registry
```bash
./apigee_proxies/mcp-weather-oas/deploy_mcp_proxy.sh
./registry/register_mcp_service.sh
```

### 3. Configure Agent Gateways & Security Policies (Model Armor + IAP)
```bash
./gateway/setup_gateways.sh
```

### 4. Deploy the ADK Agent to Vertex AI Agent Engine
```bash
python3 deploy.py
```

### 5. Bind Agent SPIFFE Workload Identity & OAuth Auth Provider
Pass the deployed Reasoning Engine ID to `create_auth_provider.sh`:
```bash
./identity/create_auth_provider.sh "${ENGINE_ID}"
```

### 6. Deploy the Apigee AI Model Router & Northbound Ingress Proxy
```bash
POC07_ENGINE_ID="${ENGINE_ID}" ./gateway/deploy_apigee_poc07.sh
```
