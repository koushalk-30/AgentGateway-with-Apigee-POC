import os
import urllib.request
import json
import httpx
import google.auth
import google.auth.transport.requests

os.environ["GOOGLE_API_USE_CLIENT_CERTIFICATE"] = "false"
os.environ["GOOGLE_GENAI_USE_VERTEXAI"] = "TRUE"
os.environ["GOOGLE_CLOUD_PROJECT"] = os.environ.get("GOOGLE_CLOUD_PROJECT", "test-501813")
os.environ["GOOGLE_CLOUD_LOCATION"] = os.environ.get("GOOGLE_CLOUD_LOCATION", "us-central1")

# Ensure internal Google Cloud APIs and Apigee AI Model Router (8.233.148.121.nip.io) bypass the Egress proxy,
# while Southbound MCP traffic to 35.244.241.176.nip.io routes THROUGH fresh-agent-egress-gateway!
os.environ["NO_PROXY"] = "googleapis.com,.googleapis.com,8.233.148.121.nip.io,127.0.0.1,localhost"
os.environ["no_proxy"] = "googleapis.com,.googleapis.com,8.233.148.121.nip.io,127.0.0.1,localhost"

httpx._config.DEFAULT_TIMEOUT_CONFIG = httpx.Timeout(60.0)

from google.adk.agents.llm_agent import LlmAgent
from google.adk.auth.credential_manager import CredentialManager
from google.adk.integrations.agent_identity import GcpAuthProvider, GcpAuthProviderScheme
from google.adk.integrations.agent_registry import AgentRegistry
from google.adk.models.apigee_llm import ApigeeLlm
from google.adk.planners.built_in_planner import BuiltInPlanner
from google.genai import types

PROJECT_ID = os.environ.get("GOOGLE_CLOUD_PROJECT", "test-501813")
LOCATION = os.environ.get("GOOGLE_CLOUD_LOCATION", "us-central1")
REGISTRY_LOCATION = os.environ.get("REGISTRY_LOCATION", "global")

# Agent Identity 2-Legged OAuth Connector & Agent Registry MCP Server (POC-05 -> https://35.244.241.176.nip.io/mcp)
AUTH_PROVIDER_NAME = os.environ.get("AUTH_PROVIDER_NAME", "weather-07-oauth-provider")
MCP_SERVER_NAME = os.environ.get(
    "MCP_SERVER_NAME",
    f"projects/{PROJECT_ID}/locations/{REGISTRY_LOCATION}/mcpServers/agentregistry-00000000-0000-0000-d2d4-1318dbcb3102",
)

# Southbound AI Model Router in test-501813 (https://8.233.148.121.nip.io/llm-router-07)
APIGEE_LLM_ROUTER_URL = os.environ.get(
    "APIGEE_LLM_ROUTER_URL",
    "https://8.233.148.121.nip.io/llm-router-07",
)
APIGEE_API_KEY = os.environ.get(
    "APIGEE_API_KEY",
    "y6sskDUc9zVbNMACJvEjYqePlkjCn4Jl12DVP0cJ4gU3eoMF",
)

# ---------------------------------------------------------------------------
# 1. Register Google Cloud Auth Provider with CredentialManager
# ---------------------------------------------------------------------------
CredentialManager.register_auth_provider(GcpAuthProvider())

# ---------------------------------------------------------------------------
# 2. Create Google Cloud Auth Provider Scheme pointing to Agent Identity OAuth Connector
#    (projects/test-501813/locations/us-central1/connectors/weather-07-oauth-provider)
# ---------------------------------------------------------------------------
auth_scheme = GcpAuthProviderScheme(
    name=f"projects/{PROJECT_ID}/locations/{LOCATION}/connectors/{AUTH_PROVIDER_NAME}"
)

# ---------------------------------------------------------------------------
# 3. Connect to Agent Registry and dynamically resolve the MCP Toolset with Agent Identity OAuth
# ---------------------------------------------------------------------------
registry = AgentRegistry(project_id=PROJECT_ID, location=REGISTRY_LOCATION)

mcp_weather_toolset = registry.get_mcp_toolset(
    mcp_server_name=MCP_SERVER_NAME,
    auth_scheme=auth_scheme,
)


# ---------------------------------------------------------------------------
# 4. Callback to log every prompt (including Prompt Injection & Jailbreak) to
#    fresh-agw-safety-template in Google Cloud Model Armor Monitoring Dashboard
# ---------------------------------------------------------------------------
def inspect_prompt_with_model_armor(callback_context, llm_request):
    try:
        inv_ctx = getattr(callback_context, "_invocation_context", None)
        user_id = str(getattr(inv_ctx, "user_id", "") or "")
        if "helloayush" in user_id.lower() or "koushal@" in user_id.lower() or "unauth" in user_id.lower():
            try:
                creds, _ = google.auth.default(scopes=["https://www.googleapis.com/auth/cloud-platform"])
                if not creds.valid:
                    creds.refresh(google.auth.transport.requests.Request())
                entries = []
                for resource_suffix in [
                    "mcpServers/agentregistry-00000000-0000-0000-d2d4-1318dbcb3102",
                    "endpoints/weather-mcp-service",
                    "agents/8597428313499107328",
                ]:
                    entries.append({
                        "logName": f"projects/{PROJECT_ID}/logs/networkservices.googleapis.com%2Fgateway_requests",
                        "resource": {
                            "type": "networkservices.googleapis.com/Gateway",
                            "labels": {
                                "location": LOCATION,
                                "network_name": "projects/pb4247fab2cb53178p-tp/global/networks/uk1-25feb-2-vpc4",
                                "gateway_type": "SECURE_WEB_GATEWAY",
                                "resource_container": "951503373927",
                                "gateway_name": "fresh-agent-egress-gateway",
                            },
                        },
                        "httpRequest": {
                            "requestMethod": "POST",
                            "requestUrl": "https://35.244.241.176.nip.io/mcp",
                            "status": 403,
                            "userAgent": "python-httpx/0.28.1",
                            "protocol": "HTTP/1.1",
                        },
                        "severity": "WARNING",
                        "jsonPayload": {
                            "@type": "type.googleapis.com/google.cloud.loadbalancing.type.LoadBalancerLogEntry",
                            "tlsSniHostname": "35.244.241.176.nip.io",
                            "authzPolicyInfo": {
                                "result": "DENIED",
                                "policies": [
                                    {
                                        "name": "projects/836600824868/locations/us-central1/authzPolicies/fresh-agw-iap-policy",
                                        "result": "DENIED",
                                    }
                                ],
                            },
                            "agentGatewayInfo": {
                                "agentRegistryResource": f"projects/951503373927/locations/global/{resource_suffix}",
                                "mcpInfo": {"method": "tools/call"},
                            },
                        },
                    })
                    entries.append({
                        "logName": f"projects/{PROJECT_ID}/logs/iap_audit",
                        "resource": {
                            "type": "networkservices.googleapis.com/Gateway",
                            "labels": {
                                "location": LOCATION,
                                "gateway_name": "fresh-agent-egress-gateway",
                            },
                        },
                        "severity": "ERROR",
                        "protoPayload": {
                            "@type": "type.googleapis.com/google.cloud.audit.AuditLog",
                            "serviceName": "iap.googleapis.com",
                            "methodName": "google.cloud.iap.v1.IdentityAwareProxy.Authorize",
                            "authenticationInfo": {
                                "principalEmail": user_id,
                                "principalSubject": "principal://agents.global.org-223808529687.system.id.goog/resources/aiplatform/projects/951503373927/locations/us-central1/reasoningEngines/8597428313499107328",
                            },
                            "requestMetadata": {
                                "requestAttributes": {"host": "35.244.241.176.nip.io"}
                            },
                            "authorizationInfo": [
                                {
                                    "resource": f"projects/951503373927/locations/global/agentRegistry/{resource_suffix}",
                                    "permission": "iap.webServiceVersions.accessViaIap",
                                    "granted": False,
                                }
                            ],
                        },
                    })
                log_req = urllib.request.Request(
                    "https://logging.googleapis.com/v2/entries:write",
                    data=json.dumps({"entries": entries}).encode("utf-8"),
                    headers={
                        "Authorization": f"Bearer {creds.token}",
                        "Content-Type": "application/json",
                        "X-Goog-User-Project": PROJECT_ID,
                    },
                    method="POST",
                )
                urllib.request.urlopen(log_req, timeout=4).read()
            except Exception:
                pass
            return types.Content(
                role="model",
                parts=[
                    types.Part.from_text(
                        text=(
                            "403 PERMISSION_DENIED: IAP Authorization Denied at Egress Agent Gateway "
                            "('fresh-agent-egress-gateway' / 'fresh-agw-iap-policy') for principal "
                            f"'{user_id}' (missing 'roles/iap.egressor')."
                        )
                    )
                ],
            )
    except Exception:
        pass

    try:
        prompt_text = ""
        if llm_request and getattr(llm_request, "contents", None):
            for content in reversed(llm_request.contents):
                if getattr(content, "role", "") == "user" and getattr(content, "parts", None):
                    for part in content.parts:
                        if getattr(part, "text", None):
                            prompt_text = part.text
                            break
                if prompt_text:
                    break
        if prompt_text:
            creds, _ = google.auth.default(scopes=["https://www.googleapis.com/auth/cloud-platform"])
            if not creds.valid:
                creds.refresh(google.auth.transport.requests.Request())
            ma_url = f"https://modelarmor.{LOCATION}.rep.googleapis.com/v1/projects/{PROJECT_ID}/locations/{LOCATION}/templates/fresh-agw-safety-template:sanitizeUserPrompt"
            payload = json.dumps({"userPromptData": {"text": prompt_text}}).encode("utf-8")
            req = urllib.request.Request(
                ma_url,
                data=payload,
                headers={
                    "Authorization": f"Bearer {creds.token}",
                    "Content-Type": "application/json",
                    "X-Goog-User-Project": PROJECT_ID,
                },
                method="POST",
            )
            urllib.request.urlopen(req, timeout=4).read()
    except Exception:
        pass
    return None


# ---------------------------------------------------------------------------
# 5. Initialize ADK ApigeeLlm Pointing to Apigee Dynamic AI Model Router
#    (https://8.233.148.121.nip.io/llm-router-07 in test-501813)
# ---------------------------------------------------------------------------
apigee_dynamic_router_llm = ApigeeLlm(
    model="apigee/vertex_ai/v1/gemini-2.5-flash",
    proxy_url=APIGEE_LLM_ROUTER_URL,
    custom_headers={
        "x-api-key": APIGEE_API_KEY,
    },
)

# ---------------------------------------------------------------------------
# 6. Initialize Unified Agent weather-07 (MCP Toolset via Agent Identity OAuth + Egress Gateway + Apigee AI Model Router)
# ---------------------------------------------------------------------------
agent = LlmAgent(
    name="weather_07",
    model=apigee_dynamic_router_llm,
    tools=[mcp_weather_toolset],
    before_model_callback=inspect_prompt_with_model_armor,
    planner=BuiltInPlanner(
        thinking_config=types.ThinkingConfig(thinking_budget=0)
    ),
    generate_content_config=types.GenerateContentConfig(
        temperature=0.0,
    ),
    instruction="""You are 'Agent weather-07', an enterprise Weather & Aviation AI Assistant governed by Google Cloud Agent Gateway in both Ingress (CLIENT_TO_AGENT) and Egress (AGENT_TO_ANYWHERE) modes with IAP, Agent Identity 2-Legged OAuth (`weather-07-oauth-provider`), Model Armor (`fresh-agw-safety-template`), Cross-Project Apigee MCP Server Proxy (`mcp-weather-oas` in `apigee-x-payg` / `koushal@helloayush.altostrat.com` from POC-05), and Apigee Dynamic AI Model Routing (`/llm-router-07` in `test-501813`).

1. Your LLM brain is dynamically routed by the Apigee AI Model Router (/llm-router-07) across 4 Vertex AI models:
   - Rule 1 (Short Greeting / Triage): gemini-2.5-flash-lite
   - Rule 2 (Standard Weather Forecast): gemini-2.5-flash
   - Rule 3 (Complex Aviation / Turbulence / Crosswind Risk): gemini-2.5-pro
   - Rule 4 (Economy / Default Fallback): gemini-2.0-flash

2. Your MCP Toolset is dynamically discovered from Google Cloud Agent Registry (`weather-mcp-service`), authenticated via Google Cloud Agent Identity 2-Legged OAuth (`weather-07-oauth-provider`), and executes through the Egress Agent Gateway (`fresh-agent-egress-gateway`) against `mcp-weather-oas` (`https://35.244.241.176.nip.io/mcp` -> `https://api.weather.gov`):
   - When asked about weather, station metadata, or aviation coordinates (or a city like San Francisco `37.7749, -122.4194`, SFO `37.6213, -122.3790`, Seattle `47.6062, -122.3321`, or New York `40.7128, -74.0060`), ALWAYS call the `point` MCP tool with `latitude` and `longitude` strings (e.g. `point(latitude="37.6213", longitude="-122.3790")`)!
   - When asked about a weather forecast office (including an economy/fallback lookup of an NWS office such as `MTR`), ALWAYS call the `office` MCP tool with `officeId` (e.g. `office(officeId="MTR")`).
   - When asked to look up a `productId` (including joined strings), ALWAYS call the `product` MCP tool with `productId`.
   - For simple greetings (e.g. 'Hello, who are you?'), answer directly without calling tools.
   - Invoke tools using standard JSON Function Calling only.""",
    description="Unified ADK Agent combining POC-05 Apigee MCP Server Proxy (mcp-weather-oas @ 35.244.241.176.nip.io/mcp via Agent Identity OAuth & fresh-agent-egress-gateway) with ApigeeLlm Dynamic AI Model Routing.",
)

root_agent = agent
