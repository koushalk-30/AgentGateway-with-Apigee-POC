import os
os.environ["IS_LOCAL_DEPLOYMENT"] = "true"
os.environ["GOOGLE_API_USE_CLIENT_CERTIFICATE"] = "false"
os.environ["CLOUDSDK_CONTEXT_AWARE_USE_CLIENT_CERTIFICATE"] = "false"
import subprocess
import vertexai
from vertexai.agent_engines import AdkApp
from google.adk.plugins.base_plugin import BasePlugin
from google.adk.auth.credential_manager import CredentialManager
from google.adk.integrations.agent_identity import GcpAuthProvider

PROJECT_ID = os.environ.get("GOOGLE_CLOUD_PROJECT", "test-501813")
os.environ["CLOUDSDK_BILLING_QUOTA_PROJECT"] = PROJECT_ID
PROJECT_NO = os.environ.get("PROJECT_NO", "951503373927")
LOCATION = os.environ.get("GOOGLE_CLOUD_LOCATION", "us-central1")
REGISTRY_LOCATION = os.environ.get("REGISTRY_LOCATION", "global")

# POC-05 Cross-Project Apigee MCP Proxy in apigee-x-payg (Argolis account: koushal@helloayush.altostrat.com)
AUTH_PROVIDER_NAME = os.environ.get("AUTH_PROVIDER_NAME", "weather-07-oauth-provider")
REGISTRY_SERVICE_ID = os.environ.get("REGISTRY_SERVICE_ID", "weather-mcp-service")
POC05_APIGEE_MCP_URL = "https://35.244.241.176.nip.io/mcp"
POC05_APIGEE_TOKEN_URL = "https://35.244.241.176.nip.io/mcp/token"
POC05_APIGEE_CLIENT_ID = "FbpAAqg19gEMnGGCE0GTyZFhgt4egeqfGwkkbGeTNFDK5TRB"
POC05_APIGEE_CLIENT_SECRET = "Piml5lR7qFRfoklh84GTGk2IOZHycqfKM3v07acxdtrGb2S7MA6tEVSTqvSyak8B"

INGRESS_GATEWAY_NAME = os.environ.get("INGRESS_GATEWAY_NAME", "agw-foo-us-central1-cta")
EGRESS_GATEWAY_NAME = os.environ.get("EGRESS_GATEWAY_NAME", "fresh-agent-egress-gateway")
ENGINE_ID = os.environ.get("POC07_ENGINE_ID", "8597428313499107328")
STAGING_BUCKET = os.environ.get("STAGING_BUCKET", f"gs://{PROJECT_ID}-agent-staging")
APIGEE_LLM_ROUTER_URL = os.environ.get("APIGEE_LLM_ROUTER_URL", "https://8.233.148.121.nip.io/llm-router-07")
APIGEE_API_KEY = os.environ.get("APIGEE_API_KEY", "y6sskDUc9zVbNMACJvEjYqePlkjCn4Jl12DVP0cJ4gU3eoMF")

INGRESS_GATEWAY_RESOURCE = f"projects/{PROJECT_ID}/locations/{LOCATION}/agentGateways/{INGRESS_GATEWAY_NAME}"
EGRESS_GATEWAY_RESOURCE = f"projects/{PROJECT_ID}/locations/{LOCATION}/agentGateways/{EGRESS_GATEWAY_NAME}"

# ---------------------------------------------------------------------------
# Step 1: Ensure weather-mcp-service (https://35.244.241.176.nip.io/mcp) is in Agent Registry
# ---------------------------------------------------------------------------
print(f"==> Ensuring Agent Registry service '{REGISTRY_SERVICE_ID}' points to {POC05_APIGEE_MCP_URL} (apigee-x-payg / koushal@helloayush.altostrat.com)...")
MCP_SERVER_NAME = f"projects/{PROJECT_NO}/locations/{REGISTRY_LOCATION}/mcpServers/agentregistry-00000000-0000-0000-d2d4-1318dbcb3102"
print(f"    Resolved MCP_SERVER_NAME in {PROJECT_ID}: {MCP_SERVER_NAME}")
os.environ["MCP_SERVER_NAME"] = MCP_SERVER_NAME
os.environ["AUTH_PROVIDER_NAME"] = AUTH_PROVIDER_NAME
print(f"==> Ensuring Auth Provider '{AUTH_PROVIDER_NAME}' points to {POC05_APIGEE_TOKEN_URL} in {PROJECT_ID}...")

from agent import root_agent


class GcpAuthPlugin(BasePlugin):
    """ADK Plugin that ensures GcpAuthProvider is registered inside the remote Reasoning Engine worker."""

    def __init__(self):
        super().__init__(name="gcp_auth_plugin")

    async def before_run_callback(self, *, invocation_context):
        CredentialManager.register_auth_provider(GcpAuthProvider())
        return None


print(f"==> Initializing Vertex AI in project: {PROJECT_ID}, region: {LOCATION}")
vertexai.init(project=PROJECT_ID, location=LOCATION, staging_bucket=STAGING_BUCKET)

client = vertexai.Client(project=PROJECT_ID, location=LOCATION)
app = AdkApp(agent=root_agent, plugins=[GcpAuthPlugin()])

engine_config = {
    "display_name": "Agent weather-07 (POC-05 MCP Proxy + Apigee AI Model Router)",
    "staging_bucket": STAGING_BUCKET,
    "requirements": [
        "google-cloud-aiplatform[agent_engines,adk]>=1.149.0",
        "google-adk[a2a,agent-identity,mcp]==2.5.0",
        "a2a-sdk<2,>=0.3.4",
        "json-rpc>=1.15.0",
        "google-cloud-iamconnectorcredentials>=0.1.1",
        "google-cloud-agentidentitycredentials>=0.1.1",
        "google-api-core>=2.34.0",
        "google-auth",
        "cloudpickle",
        "pydantic",
        "requests",
        "httpx",
        "aiohttp",
        "mcp",
    ],
    "extra_packages": ["agent"],
    "identity_type": "AGENT_IDENTITY",
    "agent_gateway_config": {
        "client_to_agent_config": {
            "agent_gateway": INGRESS_GATEWAY_RESOURCE
        },
        "agent_to_anywhere_config": {
            "agent_gateway": EGRESS_GATEWAY_RESOURCE
        },
    },
    "env_vars": {
        "GOOGLE_GENAI_USE_VERTEXAI": "TRUE",
        "NO_PROXY": "googleapis.com,.googleapis.com,8.233.148.121.nip.io,127.0.0.1,localhost",
        "no_proxy": "googleapis.com,.googleapis.com,8.233.148.121.nip.io,127.0.0.1,localhost",
        "AUTH_PROVIDER_NAME": AUTH_PROVIDER_NAME,
        "MCP_SERVER_NAME": MCP_SERVER_NAME,
        "APIGEE_MCP_URL": POC05_APIGEE_MCP_URL,
        "APIGEE_MCP_TOKEN_URL": POC05_APIGEE_TOKEN_URL,
        "APIGEE_MCP_CLIENT_ID": POC05_APIGEE_CLIENT_ID,
        "APIGEE_MCP_CLIENT_SECRET": POC05_APIGEE_CLIENT_SECRET,
        "APIGEE_LLM_ROUTER_URL": APIGEE_LLM_ROUTER_URL,
        "APIGEE_API_KEY": APIGEE_API_KEY,
    },
}

if ENGINE_ID:
    print(f"==> Updating existing Reasoning Engine ({ENGINE_ID})...")
    engine_name = f"projects/{PROJECT_NO}/locations/{LOCATION}/reasoningEngines/{ENGINE_ID}"
    remote_app = client.agent_engines.update(
        name=engine_name,
        agent=app,
        config=engine_config,
    )
    engine_id = ENGINE_ID
else:
    print(f"==> Deploying new 'Agent weather-07' bound to Ingress ({INGRESS_GATEWAY_NAME}) & Egress ({EGRESS_GATEWAY_NAME})...")
    remote_app = client.agent_engines.create(
        agent=app,
        config=engine_config,
    )
    engine_id = remote_app.api_resource.name.split("/")[-1]

print("\n✅ Deployment of Agent weather-07 complete!")
print(f"🔗 Reasoning Engine ID: {engine_id}")

org_id = "223808529687"
agent_spiffe_id = f"principal://agents.global.org-{org_id}.system.id.goog/resources/aiplatform/projects/{PROJECT_NO}/locations/{LOCATION}/reasoningEngines/{engine_id}"
print(f"==> SPIFFE ID bound to Connector, Agent Registry & IAP: {agent_spiffe_id}")

print("==> Deploying Northbound & Southbound Apigee Proxies with Engine ID...")
env = os.environ.copy()
env["POC07_ENGINE_ID"] = engine_id
subprocess.run(["bash", "./gateway/deploy_apigee_poc07.sh"], env=env, check=True)
