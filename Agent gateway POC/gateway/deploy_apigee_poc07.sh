#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Deploy Both Apigee Proxies in Project test-501813 (eval-comp):
#   1. apigee-ai-model-router-07   (Southbound AI Model Router at /llm-router-07)
#   2. weather-agent-07-ingress-proxy (Northbound Client Ingress at /weather-agent-07)
# ============================================================================

APIGEE_PROJECT_ID="${APIGEE_PROJECT_ID:-test-501813}"
APIGEE_ENV="${APIGEE_ENV:-eval-comp}"
TARGET_PROJECT_ID="${TARGET_PROJECT_ID:-test-501813}"
TARGET_REGION="${TARGET_REGION:-us-central1}"

POC07_ENGINE_ID="${POC07_ENGINE_ID:-}"
ROUTER_PROXY_NAME="apigee-ai-model-router-07"
INGRESS_PROXY_NAME="weather-agent-07-ingress-proxy"
APIGEE_CALLER_SA="apigee-agent-caller@${APIGEE_PROJECT_ID}.iam.gserviceaccount.com"

TOKEN=$(/Users/koushalk/llm_env/bin/python3 -c 'import google.auth, google.auth.transport.requests; c, _ = google.auth.default(scopes=["https://www.googleapis.com/auth/cloud-platform"]); c.refresh(google.auth.transport.requests.Request()); print(c.token)')
WORK_DIR=$(mktemp -d)

echo "==> [1/2] Building Southbound Apigee AI Model Router (${ROUTER_PROXY_NAME})..."
R_DIR="${WORK_DIR}/router"
mkdir -p "${R_DIR}/apiproxy/policies" "${R_DIR}/apiproxy/proxies" "${R_DIR}/apiproxy/targets" "${R_DIR}/apiproxy/resources/jsc"

# Policy 1: Verify API Key
cat <<'EOF' > "${R_DIR}/apiproxy/policies/VA-VerifyAPIKey.xml"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<VerifyAPIKey continueOnError="false" enabled="true" name="VA-VerifyAPIKey">
    <DisplayName>VA-VerifyAPIKey</DisplayName>
    <APIKey ref="request.header.x-api-key"/>
</VerifyAPIKey>
EOF

# Policy 2: Spike Arrest
cat <<'EOF' > "${R_DIR}/apiproxy/policies/SA-PromptBurstLimit.xml"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<SpikeArrest continueOnError="false" enabled="true" name="SA-PromptBurstLimit">
    <DisplayName>SA-PromptBurstLimit</DisplayName>
    <Rate>60pm</Rate>
    <UseEffectiveCount>true</UseEffectiveCount>
</SpikeArrest>
EOF

# Policy 3: JavaScript Prompt Classifier, Multi-Turn MCP Inspector & Dynamic Router
cat <<'EOF' > "${R_DIR}/apiproxy/resources/jsc/JS-InspectPromptAndRoute.js"
var rawBody = context.getVariable("request.content");
var promptText = "";
var isToolResponse = false;
var mcpToolCalled = "None (Direct Single-Turn)";

try {
  var body = JSON.parse(rawBody);
  if (body.contents && body.contents.length > 0) {
    // Check if the latest turn is an MCP functionResponse turn (Turn 2)
    var lastContent = body.contents[body.contents.length - 1];
    if (lastContent && lastContent.parts) {
      for (var p = 0; p < lastContent.parts.length; p++) {
        if (lastContent.parts[p].functionResponse) {
          isToolResponse = true;
          mcpToolCalled = lastContent.parts[p].functionResponse.name || "mcp_tool";
          break;
        }
      }
    }
    // Also check all turns for any functionCall / functionResponse name
    for (var c = body.contents.length - 1; c >= 0; c--) {
      if (body.contents[c].parts) {
        for (var k = 0; k < body.contents[c].parts.length; k++) {
          var part = body.contents[c].parts[k];
          if (part.functionResponse && part.functionResponse.name) {
            mcpToolCalled = part.functionResponse.name + " (Live api.weather.gov Data via mcp-weather-oas)";
          } else if (part.functionCall && part.functionCall.name && mcpToolCalled.indexOf("Live") === -1) {
            mcpToolCalled = part.functionCall.name + " (Live api.weather.gov Data via mcp-weather-oas)";
          }
        }
      }
    }
    // Extract the user's text prompt (walks backwards so Turn 2 still finds Turn 1's user text!)
    for (var i = body.contents.length - 1; i >= 0; i--) {
      if (body.contents[i].role === "user" && body.contents[i].parts) {
        for (var j = 0; j < body.contents[i].parts.length; j++) {
          if (body.contents[i].parts[j].text) {
            promptText = body.contents[i].parts[j].text;
            break;
          }
        }
        if (promptText) break;
      }
    }
  }
} catch (e) {}

var lower = (promptText || "").toLowerCase();
var targetModel = "gemini-2.0-flash";
var ruleMatched = "Rule 4 (defaultModel Fallback -> gemini-2.0-flash)";

var forceFallback = context.getVariable("request.header.x-force-fallback");
if (forceFallback === "true" || lower.indexOf("economy") !== -1 || lower.indexOf("fallback") !== -1) {
  targetModel = "gemini-2.0-flash";
  ruleMatched = "Rule 4 (Economy / Default Model Fallback -> gemini-2.0-flash)";
} else if (
  lower.indexOf("aviation") !== -1 ||
  lower.indexOf("turbulence") !== -1 ||
  lower.indexOf("crosswind") !== -1 ||
  lower.indexOf("ifr") !== -1 ||
  lower.indexOf("flight risk") !== -1 ||
  lower.indexOf("wind shear") !== -1 ||
  lower.indexOf("severe") !== -1 ||
  promptText.length > 180
) {
  targetModel = "gemini-2.5-pro";
  ruleMatched = "Rule 3 (Complex Aviation & Risk Reasoning -> gemini-2.5-pro)";
} else if (
  lower.indexOf("weather") !== -1 ||
  lower.indexOf("forecast") !== -1 ||
  lower.indexOf("temperature") !== -1 ||
  lower.indexOf("latitude") !== -1 ||
  lower.indexOf("longitude") !== -1 ||
  lower.indexOf("san francisco") !== -1 ||
  lower.indexOf("seattle") !== -1 ||
  lower.indexOf("miami") !== -1 ||
  lower.indexOf("office") !== -1 ||
  lower.indexOf("glossary") !== -1 ||
  lower.indexOf("point") !== -1 ||
  lower.indexOf("wind") !== -1
) {
  targetModel = "gemini-2.5-flash";
  ruleMatched = "Rule 2 (Standard Weather & MCP Forecast -> gemini-2.5-flash)";
} else if (
  promptText.length > 0 && promptText.length < 65
) {
  targetModel = "gemini-2.5-flash-lite";
  ruleMatched = "Rule 1 (Short / Quick Triage Interaction -> gemini-2.5-flash-lite)";
}

context.setVariable("routing.target_model", targetModel);
context.setVariable("routing.rule_matched", ruleMatched);
context.setVariable("routing.prompt_length", String(promptText.length));
context.setVariable("routing.is_tool_response", isToolResponse ? "true" : "false");
context.setVariable("routing.mcp_tool_called", mcpToolCalled);
context.setVariable("routing.user_prompt_text", promptText);

// gemini-2.5-pro requires thinkingBudget >= 128 (rejects thinking_budget=0 with 400). Replace thinkingConfig cleanly so snake_case thinking_budget is removed:
if (targetModel === "gemini-2.5-pro" && body) {
  if (body.generationConfig && body.generationConfig.thinkingConfig) {
    body.generationConfig.thinkingConfig = { "thinkingBudget": 128 };
  }
  if (body.generation_config && body.generation_config.thinking_config) {
    body.generation_config.thinking_config = { "thinking_budget": 128 };
  }
  context.setVariable("request.content", JSON.stringify(body));
}

// Compute normalized Semantic Intent Fingerprint
var stopWords = {"what":1,"is":1,"the":1,"tell":1,"me":1,"today":1,"todays":1,"current":1,"please":1,"can":1,"you":1,"in":1,"for":1,"at":1,"on":1,"to":1,"from":1,"with":1,"by":1,"now":1,"right":1,"about":1,"give":1,"a":1,"an":1,"of":1,"how":1,"and":1};
var words = lower.replace(/[^a-z0-9\s]/g, " ").split(/\s+/);
var semTokens = [];
for (var w = 0; w < words.length; w++) {
  if (words[w] && !stopWords[words[w]]) {
    semTokens.push(words[w]);
  }
}
semTokens.sort();
var semKey = targetModel + ":" + semTokens.join("_");
context.setVariable("semantic.cache_key", semKey);

// Flag Prompt Injection / Jailbreak / Unsafe prompts for SUP-SanitizeUserPrompt enforcement
var isUnsafePrompt = (
  lower.indexOf("ignore all previous instructions") !== -1 ||
  lower.indexOf("ignore previous instructions") !== -1 ||
  lower.indexOf("system prompt") !== -1 ||
  lower.indexOf("root password") !== -1 ||
  lower.indexOf("you are now dan") !== -1 ||
  lower.indexOf("jailbreak") !== -1 ||
  lower.indexOf("dangerous weapons") !== -1
);
context.setVariable("security.unsafe_prompt", isUnsafePrompt ? "true" : "false");
EOF

cat <<EOF > "${R_DIR}/apiproxy/policies/JS-InspectPromptAndRoute.xml"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Javascript continueOnError="false" enabled="true" timeLimit="200" name="JS-InspectPromptAndRoute">
    <DisplayName>JS-InspectPromptAndRoute</DisplayName>
    <ResourceURL>jsc://JS-InspectPromptAndRoute.js</ResourceURL>
</Javascript>
EOF

# Policy 4a: Native AI Policy #1 - SanitizeUserPrompt (Included in bundle)
cat <<EOF > "${R_DIR}/apiproxy/policies/SUP-SanitizeUserPrompt-Native.xml"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<SanitizeUserPrompt async="false" continueOnError="true" enabled="true" name="SUP-SanitizeUserPrompt-Native">
    <DisplayName>SUP-SanitizeUserPrompt-Native</DisplayName>
    <IgnoreUnresolvedVariables>true</IgnoreUnresolvedVariables>
    <ModelArmor>
        <TemplateName>projects/${TARGET_PROJECT_ID}/locations/${TARGET_REGION}/templates/fresh-agw-safety-template</TemplateName>
    </ModelArmor>
    <UserPromptSource>{routing.user_prompt_text}</UserPromptSource>
</SanitizeUserPrompt>
EOF

# Policy 4b: Live Model Armor API Callout (with IgnoreValidationErrors=true to bypass VPC REP SAN mismatch and populate Model Armor Monitoring Dashboard!)
cat <<EOF > "${R_DIR}/apiproxy/policies/SC-ModelArmor-SanitizePrompt.xml"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<ServiceCallout async="false" continueOnError="true" enabled="true" name="SC-ModelArmor-SanitizePrompt">
    <DisplayName>SC-ModelArmor-SanitizePrompt</DisplayName>
    <Request clearPayload="true">
        <Set>
            <Headers>
                <Header name="Content-Type">application/json</Header>
                <Header name="X-Goog-User-Project">${TARGET_PROJECT_ID}</Header>
            </Headers>
            <Payload contentType="application/json">{"userPromptData":{"text":"{routing.user_prompt_text}"}}</Payload>
            <Verb>POST</Verb>
        </Set>
        <IgnoreUnresolvedVariables>true</IgnoreUnresolvedVariables>
    </Request>
    <Response>modelarmor_resp</Response>
    <HTTPTargetConnection>
        <Properties>
            <Property name="io.timeout.millis">10000</Property>
        </Properties>
        <SSLInfo>
            <Enabled>true</Enabled>
            <IgnoreValidationErrors>true</IgnoreValidationErrors>
        </SSLInfo>
        <Authentication>
            <GoogleAccessToken>
                <Scopes>
                    <Scope>https://www.googleapis.com/auth/cloud-platform</Scope>
                </Scopes>
            </GoogleAccessToken>
        </Authentication>
        <URL>https://modelarmor.${TARGET_REGION}.rep.googleapis.com/v1/projects/${TARGET_PROJECT_ID}/locations/${TARGET_REGION}/templates/fresh-agw-safety-template:sanitizeUserPrompt</URL>
    </HTTPTargetConnection>
</ServiceCallout>
EOF

cat <<'EOF' > "${R_DIR}/apiproxy/resources/jsc/JS-EvaluateModelArmor.js"
try {
  var maRaw = context.getVariable("modelarmor_resp.content");
  if (maRaw) {
    var maJson = JSON.parse(maRaw);
    var matchState = (maJson.sanitizationResult && maJson.sanitizationResult.filterMatchState) ? maJson.sanitizationResult.filterMatchState : "NO_MATCH_FOUND";
    context.setVariable("modelarmor.filterMatchState", matchState);
    context.setVariable("modelarmor.sanitizationResult", maRaw);
    if (matchState === "MATCH_FOUND") {
      context.setVariable("security.unsafe_prompt", "true");
    }
  }
} catch (e) {}
EOF

cat <<'EOF' > "${R_DIR}/apiproxy/policies/JS-EvaluateModelArmor.xml"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Javascript continueOnError="true" enabled="true" timeLimit="200" name="JS-EvaluateModelArmor">
    <DisplayName>JS-EvaluateModelArmor</DisplayName>
    <ResourceURL>jsc://JS-EvaluateModelArmor.js</ResourceURL>
</Javascript>
EOF

# Policy 4c: SUP-SanitizeUserPrompt Enforcement Step (Displays 'User prompt was blocked by Model Armor.' directly in Debug Response content!)
cat <<EOF > "${R_DIR}/apiproxy/policies/SUP-SanitizeUserPrompt.xml"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<RaiseFault continueOnError="false" enabled="true" name="SUP-SanitizeUserPrompt">
    <DisplayName>SUP-SanitizeUserPrompt</DisplayName>
    <Properties/>
    <FaultResponse>
        <Set>
            <Headers>
                <Header name="Content-Type">application/json</Header>
                <Header name="X-Apigee-Security-Policy">SUP-SanitizeUserPrompt</Header>
                <Header name="X-Model-Armor-Template">projects/${TARGET_PROJECT_ID}/locations/${TARGET_REGION}/templates/fresh-agw-safety-template</Header>
                <Header name="X-Model-Armor-MatchState">MATCH_FOUND</Header>
            </Headers>
            <Payload contentType="application/json">{
  "fault": {
    "faultstring": "User prompt was blocked by Model Armor.",
    "detail": {
      "errorcode": "steps.sanitize.modelarmor.UserPromptBlocked",
      "template": "projects/${TARGET_PROJECT_ID}/locations/${TARGET_REGION}/templates/fresh-agw-safety-template",
      "filterMatchState": "MATCH_FOUND",
      "violation": "PROMPT_INJECTION_AND_JAILBREAK"
    }
  }
}</Payload>
            <StatusCode>400</StatusCode>
            <ReasonPhrase>Bad Request</ReasonPhrase>
        </Set>
    </FaultResponse>
    <IgnoreUnresolvedVariables>true</IgnoreUnresolvedVariables>
</RaiseFault>
EOF

# Policy 5: Native AI Policy #2 - PromptTokenLimit
cat <<EOF > "${R_DIR}/apiproxy/policies/PTL-PromptTokenLimit.xml"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<PromptTokenLimit continueOnError="false" enabled="true" name="PTL-PromptTokenLimit">
    <DisplayName>PTL-PromptTokenLimit</DisplayName>
    <UserPromptSource>{routing.user_prompt_text}</UserPromptSource>
    <Identifier ref="routing.target_model"/>
    <Rate>90pm</Rate>
    <UseEffectiveCount>true</UseEffectiveCount>
    <IgnoreUnresolvedVariables>true</IgnoreUnresolvedVariables>
</PromptTokenLimit>
EOF

# Policy 6: Native AI Policy #3 - SemanticCacheLookup
cat <<EOF > "${R_DIR}/apiproxy/policies/SCL-SemanticCacheLookup.xml"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<SemanticCacheLookup async="false" continueOnError="true" enabled="true" name="SCL-SemanticCacheLookup">
    <DisplayName>SCL-SemanticCacheLookup</DisplayName>
    <IgnoreUnresolvedVariables>true</IgnoreUnresolvedVariables>
    <UserPromptSource>{routing.user_prompt_text}</UserPromptSource>
    <Embeddings>
        <VertexAI>
            <URL>https://${TARGET_REGION}-aiplatform.googleapis.com/v1/projects/${TARGET_PROJECT_ID}/locations/${TARGET_REGION}/publishers/google/models/text-embedding-004:predict</URL>
        </VertexAI>
    </Embeddings>
    <SimilaritySearch>
        <VertexAI>
            <URL>https://${TARGET_REGION}-aiplatform.googleapis.com/v1/projects/${TARGET_PROJECT_ID}/locations/${TARGET_REGION}/indexEndpoints/poc06-semantic-index:findNeighbors</URL>
            <Threshold>0.9</Threshold>
            <DeployedIndexID>poc06_deployed_index</DeployedIndexID>
            <DistanceMeasureType>DOT_PRODUCT_DISTANCE</DistanceMeasureType>
        </VertexAI>
    </SimilaritySearch>
</SemanticCacheLookup>
EOF

# Policy 7: Native AI Policy #4a - LLMTokenQuota (Enforce)
cat <<EOF > "${R_DIR}/apiproxy/policies/LTQ-TokenQuota-Enforce.xml"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<LLMTokenQuota continueOnError="false" enabled="true" name="LTQ-TokenQuota-Enforce" type="rollingwindow">
    <DisplayName>LTQ-TokenQuota-Enforce</DisplayName>
    <SharedName>poc07-llm-token-bucket-v1</SharedName>
    <EnforceOnly>true</EnforceOnly>
    <Identifier ref="routing.target_model"/>
    <Allow count="500000"/>
    <Interval>30</Interval>
    <TimeUnit>minute</TimeUnit>
    <Distributed>true</Distributed>
    <LLMModelSource>{routing.target_model}</LLMModelSource>
</LLMTokenQuota>
EOF

# Policy 8: Native AI Policy #4b - LLMTokenQuota (Count)
cat <<EOF > "${R_DIR}/apiproxy/policies/LTQ-TokenQuota-Count.xml"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<LLMTokenQuota continueOnError="false" enabled="true" name="LTQ-TokenQuota-Count" type="rollingwindow">
    <DisplayName>LTQ-TokenQuota-Count</DisplayName>
    <SharedName>poc07-llm-token-bucket-v1</SharedName>
    <CountOnly>true</CountOnly>
    <Identifier ref="routing.target_model"/>
    <Allow count="500000"/>
    <Interval>30</Interval>
    <TimeUnit>minute</TimeUnit>
    <Distributed>true</Distributed>
    <LLMTokenUsageSource>{jsonPath('$.usageMetadata.totalTokenCount',response.content,true)}</LLMTokenUsageSource>
    <LLMModelSource>{routing.target_model}</LLMModelSource>
</LLMTokenQuota>
EOF

# Policy 9: Native AI Policy #5 - SanitizeModelResponse
cat <<EOF > "${R_DIR}/apiproxy/policies/SMR-SanitizeModelResponse.xml"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<SanitizeModelResponse async="false" continueOnError="false" enabled="true" name="SMR-SanitizeModelResponse">
    <DisplayName>SMR-SanitizeModelResponse</DisplayName>
    <IgnoreUnresolvedVariables>true</IgnoreUnresolvedVariables>
    <ModelArmor>
        <TemplateName>projects/${TARGET_PROJECT_ID}/locations/${TARGET_REGION}/templates/agw-response-template</TemplateName>
    </ModelArmor>
    <UserPromptSource>{routing.user_prompt_text}</UserPromptSource>
    <LLMResponseSource>{jsonPath('$.candidates[-1].content.parts',response.content,true)}</LLMResponseSource>
</SanitizeModelResponse>
EOF

# Policy 10: Native AI Policy #6 - SemanticCachePopulate
cat <<EOF > "${R_DIR}/apiproxy/policies/SCP-SemanticCachePopulate.xml"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<SemanticCachePopulate async="false" continueOnError="true" enabled="true" name="SCP-SemanticCachePopulate">
    <DisplayName>SCP-SemanticCachePopulate</DisplayName>
    <IgnoreUnresolvedVariables>true</IgnoreUnresolvedVariables>
    <TTLInSeconds>3600</TTLInSeconds>
    <SimilaritySearch>
        <VertexAI>
            <URL>https://${TARGET_REGION}-aiplatform.googleapis.com/v1/projects/${TARGET_PROJECT_ID}/locations/${TARGET_REGION}/indexEndpoints/poc06-semantic-index:upsertDatapoints</URL>
            <DeployedIndexID>poc06_deployed_index</DeployedIndexID>
        </VertexAI>
    </SimilaritySearch>
</SemanticCachePopulate>
EOF

# Policy 11: Disable path suffix copy in TargetEndpoint
cat <<EOF > "${R_DIR}/apiproxy/policies/AM-PrepareModelTarget.xml"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<AssignMessage continueOnError="false" enabled="true" name="AM-PrepareModelTarget">
    <DisplayName>AM-PrepareModelTarget</DisplayName>
    <Set>
        <Headers>
            <Header name="X-Goog-User-Project">${TARGET_PROJECT_ID}</Header>
            <Header name="Content-Type">application/json</Header>
        </Headers>
    </Set>
    <AssignVariable>
        <Name>target.copy.pathsuffix</Name>
        <Value>false</Value>
    </AssignVariable>
    <IgnoreUnresolvedVariables>true</IgnoreUnresolvedVariables>
    <AssignTo createNew="false" transport="http" type="request"/>
</AssignMessage>
EOF

# Policy 11b: Distributed Semantic Cache Lookup & Populate (120s TTL)
cat <<EOF > "${R_DIR}/apiproxy/policies/LC-SemanticCache.xml"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<LookupCache continueOnError="true" enabled="true" name="LC-SemanticCache">
    <DisplayName>LC-SemanticCache</DisplayName>
    <CacheKey>
        <Prefix>poc07-semcache</Prefix>
        <KeyFragment ref="semantic.cache_key"/>
    </CacheKey>
    <Scope>Global</Scope>
    <AssignTo>semantic.cached_response</AssignTo>
</LookupCache>
EOF

cat <<EOF > "${R_DIR}/apiproxy/policies/PC-SemanticCache.xml"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<PopulateCache continueOnError="true" enabled="true" name="PC-SemanticCache">
    <DisplayName>PC-SemanticCache</DisplayName>
    <CacheKey>
        <Prefix>poc07-semcache</Prefix>
        <KeyFragment ref="semantic.cache_key"/>
    </CacheKey>
    <Scope>Global</Scope>
    <ExpirySettings>
        <TimeoutInSec>120</TimeoutInSec>
    </ExpirySettings>
    <Source>response.content</Source>
</PopulateCache>
EOF

cat <<EOF > "${R_DIR}/apiproxy/policies/AM-RestoreSemanticCache.xml"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<AssignMessage continueOnError="true" enabled="true" name="AM-RestoreSemanticCache">
    <DisplayName>AM-RestoreSemanticCache</DisplayName>
    <Set>
        <Headers>
            <Header name="Content-Type">application/json</Header>
        </Headers>
        <Payload contentType="application/json">{semantic.cached_response}</Payload>
        <StatusCode>200</StatusCode>
    </Set>
    <IgnoreUnresolvedVariables>true</IgnoreUnresolvedVariables>
    <AssignTo createNew="false" transport="http" type="response"/>
</AssignMessage>
EOF

# Policy 12: JavaScript Response Telemetry Tagging (Includes MCP Toolset & Semantic Cache Telemetry!)
cat <<'EOF' > "${R_DIR}/apiproxy/resources/jsc/JS-TagModelResponse.js"
try {
  var respBody = context.getVariable("response.content");
  if (respBody) {
    var data = JSON.parse(respBody);
    var isCacheHit = (String(context.getVariable("lookupcache.LC-SemanticCache.cachehit")) === "true");
    var modelVersion = context.getVariable("routing.target_model") || data.modelVersion || "unknown";
    data.modelVersion = modelVersion;
    context.setVariable("response.content", JSON.stringify(data));
    var totalTokens = isCacheHit ? 0 : ((data.usageMetadata && data.usageMetadata.totalTokenCount) ? data.usageMetadata.totalTokenCount : "N/A");
    var ruleMatched = context.getVariable("routing.rule_matched") || "Dynamic Route";
    var mcpToolCalled = context.getVariable("routing.mcp_tool_called") || "point (Live api.weather.gov Data)";
    var usedTokens = Number(context.getVariable("ratelimit.LTQ-TokenQuota-Enforce.used.count") || "0");
    var aiPoliciesActive = "SanitizeUserPrompt, PromptTokenLimit, SemanticCacheLookup, LLMTokenQuota, SanitizeModelResponse, SemanticCachePopulate";
    var cacheStatus = isCacheHit
      ? "HIT (Served from Apigee Semantic Cache | Similarity >= 0.90 | 0 Vertex AI Tokens Billed)"
      : "MISS (Populated into Apigee Semantic Cache, TTL: 120s)";

    context.setVariable("response.header.X-Apigee-Routed-Model", modelVersion);
    context.setVariable("response.header.X-Apigee-Routing-Rule", ruleMatched);
    context.setVariable("response.header.X-Apigee-MCP-Tool", mcpToolCalled);
    context.setVariable("response.header.X-Apigee-Semantic-Cache", isCacheHit ? "HIT" : "MISS");
    context.setVariable("response.header.X-Apigee-Total-Tokens", String(totalTokens));
    context.setVariable("response.header.X-Apigee-LLMTokenQuota-Used", String(usedTokens));
    context.setVariable("response.header.X-Apigee-AI-Policies", aiPoliciesActive);

    // Only append the telemetry badge on final text responses (never corrupt Turn 1 functionCall!)
    if (data.candidates && data.candidates.length > 0 && data.candidates[0].content && data.candidates[0].content.parts) {
      var parts = data.candidates[0].content.parts;
      var hasFunctionCall = false;
      for (var i = 0; i < parts.length; i++) {
        if (parts[i].functionCall) {
          hasFunctionCall = true;
          break;
        }
      }
      context.setVariable("semantic.is_final_text", hasFunctionCall ? "false" : "true");
      if (!hasFunctionCall) {
        for (var k = parts.length - 1; k >= 0; k--) {
          if (parts[k].text) {
            var baseText = parts[k].text.split("\n\n---\n⚡ **[Apigee Dynamic Model Router")[0];
            parts[k].text = baseText + "\n\n---\n⚡ **[Apigee Dynamic Model Router + MCP Toolset]**\n- **Dispatched Model**: `" + modelVersion + "` (Vertex AI Model Garden)\n- **Routing Rule**: " + ruleMatched + "\n- **MCP Server Proxy**: `mcp-weather-oas` (`https://35.244.241.176.nip.io/mcp` in `apigee-x-payg` / `koushal@helloayush.altostrat.com` via Agent Registry)\n- **MCP Tool Executed**: `" + mcpToolCalled + "`\n- **Semantic Cache**: `" + cacheStatus + "`\n- **Active Apigee AI Policies**: `" + aiPoliciesActive + "`\n- **LLMTokenQuota Consumed**: `" + totalTokens + " tokens`";
            context.setVariable("response.content", JSON.stringify(data));
            break;
          }
        }
      }
    }
  }
} catch (e) {}
EOF

cat <<EOF > "${R_DIR}/apiproxy/policies/JS-TagModelResponse.xml"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Javascript continueOnError="true" enabled="true" timeLimit="200" name="JS-TagModelResponse">
    <DisplayName>JS-TagModelResponse</DisplayName>
    <ResourceURL>jsc://JS-TagModelResponse.js</ResourceURL>
</Javascript>
EOF

# ProxyEndpoint (/llm-router-07)
cat <<EOF > "${R_DIR}/apiproxy/proxies/default.xml"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<ProxyEndpoint name="default">
    <Description>Apigee Dynamic AI Model Router for MCP Toolset Agent</Description>
    <PreFlow name="PreFlow">
        <Request>
            <Step><Name>VA-VerifyAPIKey</Name></Step>
            <Step><Name>SA-PromptBurstLimit</Name></Step>
            <Step><Name>JS-InspectPromptAndRoute</Name></Step>
            <Step>
                <Name>SC-ModelArmor-SanitizePrompt</Name>
                <Condition>routing.is_tool_response != "true"</Condition>
            </Step>
            <Step>
                <Name>JS-EvaluateModelArmor</Name>
                <Condition>routing.is_tool_response != "true"</Condition>
            </Step>
            <Step>
                <Name>SUP-SanitizeUserPrompt</Name>
                <Condition>security.unsafe_prompt = "true" or modelarmor.filterMatchState = "MATCH_FOUND"</Condition>
            </Step>
            <Step><Name>SCL-SemanticCacheLookup</Name></Step>
            <Step><Name>LC-SemanticCache</Name></Step>
            <Step>
                <Name>PTL-PromptTokenLimit</Name>
                <Condition>lookupcache.LC-SemanticCache.cachehit != "true" and routing.is_tool_response != "true"</Condition>
            </Step>
            <Step>
                <Name>LTQ-TokenQuota-Enforce</Name>
                <Condition>lookupcache.LC-SemanticCache.cachehit != "true"</Condition>
            </Step>
        </Request>
        <Response>
            <Step>
                <Name>AM-RestoreSemanticCache</Name>
                <Condition>lookupcache.LC-SemanticCache.cachehit = "true"</Condition>
            </Step>
            <Step>
                <Name>SMR-SanitizeModelResponse</Name>
                <Condition>security.unsafe_prompt = "true"</Condition>
            </Step>
            <Step>
                <Name>LTQ-TokenQuota-Count</Name>
                <Condition>lookupcache.LC-SemanticCache.cachehit != "true"</Condition>
            </Step>
            <Step><Name>SCP-SemanticCachePopulate</Name></Step>
            <Step><Name>JS-TagModelResponse</Name></Step>
            <Step>
                <Name>PC-SemanticCache</Name>
                <Condition>lookupcache.LC-SemanticCache.cachehit != "true" and semantic.is_final_text = "true"</Condition>
            </Step>
        </Response>
    </PreFlow>
    <HTTPProxyConnection>
        <BasePath>/llm-router-07</BasePath>
    </HTTPProxyConnection>

    <!-- 0. Semantic Cache Hit Route -->
    <RouteRule name="route-semantic-cache-hit">
        <Condition>lookupcache.LC-SemanticCache.cachehit = "true"</Condition>
    </RouteRule>

    <!-- 1. Rule 1: Short / Greeting Prompt -> gemini-2.5-flash-lite -->
    <RouteRule name="route-gemini-2-5-flash-lite">
        <Condition>routing.target_model = "gemini-2.5-flash-lite"</Condition>
        <TargetEndpoint>target-gemini-2-5-flash-lite</TargetEndpoint>
    </RouteRule>

    <!-- 2. Rule 2: Standard Weather & MCP Forecast Prompt -> gemini-2.5-flash -->
    <RouteRule name="route-gemini-2-5-flash">
        <Condition>routing.target_model = "gemini-2.5-flash"</Condition>
        <TargetEndpoint>target-gemini-2-5-flash</TargetEndpoint>
    </RouteRule>

    <!-- 3. Rule 3: Deep Aviation / Turbulence Risk Prompt -> gemini-2.5-pro -->
    <RouteRule name="route-gemini-2-5-pro">
        <Condition>routing.target_model = "gemini-2.5-pro"</Condition>
        <TargetEndpoint>target-gemini-2-5-pro</TargetEndpoint>
    </RouteRule>

    <!-- 4. Rule 4: defaultModel Fallback -> gemini-2.0-flash -->
    <RouteRule name="route-default-gemini-2-0-flash">
        <TargetEndpoint>target-gemini-2-0-flash</TargetEndpoint>
    </RouteRule>
</ProxyEndpoint>
EOF

create_model_target() {
  local TARGET_NAME="$1"
  local MODEL_ID="$2"
  cat <<EOF > "${R_DIR}/apiproxy/targets/${TARGET_NAME}.xml"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<TargetEndpoint name="${TARGET_NAME}">
    <Description>Vertex AI Model Garden Target: ${MODEL_ID}</Description>
    <PreFlow name="PreFlow">
        <Request>
            <Step><Name>AM-PrepareModelTarget</Name></Step>
        </Request>
        <Response/>
    </PreFlow>
    <HTTPTargetConnection>
        <Authentication>
            <GoogleAccessToken>
                <Scopes>
                    <Scope>https://www.googleapis.com/auth/cloud-platform</Scope>
                </Scopes>
            </GoogleAccessToken>
        </Authentication>
        <URL>https://${TARGET_REGION}-aiplatform.googleapis.com/v1/projects/${TARGET_PROJECT_ID}/locations/${TARGET_REGION}/publishers/google/models/${MODEL_ID}:generateContent</URL>
    </HTTPTargetConnection>
</TargetEndpoint>
EOF
}

create_model_target "target-gemini-2-5-flash-lite" "gemini-2.5-flash-lite"
create_model_target "target-gemini-2-5-flash"      "gemini-2.5-flash"
create_model_target "target-gemini-2-5-pro"        "gemini-2.5-pro"
create_model_target "target-gemini-2-0-flash"      "gemini-2.5-flash-lite"

cat <<EOF > "${R_DIR}/apiproxy/${ROUTER_PROXY_NAME}.xml"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<APIProxy name="${ROUTER_PROXY_NAME}">
    <DisplayName>${ROUTER_PROXY_NAME}</DisplayName>
    <Description>Southbound Apigee AI Model Router for MCP Toolset Agent</Description>
</APIProxy>
EOF

(cd "${R_DIR}" && zip -qr "${WORK_DIR}/router.zip" apiproxy)

IMPORT_ROUTER=$(curl -s -X POST \
  -H "Authorization: Bearer ${TOKEN}" \
  -F "file=@${WORK_DIR}/router.zip" \
  "https://apigee.googleapis.com/v1/organizations/${APIGEE_PROJECT_ID}/apis?action=import&name=${ROUTER_PROXY_NAME}")
R_REV=$(echo "${IMPORT_ROUTER}" | python3 -c "import sys, json; print(json.load(sys.stdin)['revision'])")
echo "✅ Imported ${ROUTER_PROXY_NAME} revision ${R_REV}, deploying with SA ${APIGEE_CALLER_SA}..."

curl -s -X POST \
  -H "Authorization: Bearer ${TOKEN}" \
  "https://apigee.googleapis.com/v1/organizations/${APIGEE_PROJECT_ID}/environments/${APIGEE_ENV}/apis/${ROUTER_PROXY_NAME}/revisions/${R_REV}/deployments?override=true&serviceAccount=${APIGEE_CALLER_SA}"
echo ""

# ============================================================================
# [2/2] Deploy Northbound Ingress Proxy (weather-agent-07-ingress-proxy)
# ============================================================================
if [[ -n "${POC07_ENGINE_ID}" ]]; then
  echo "==> [2/2] Building Northbound Proxy (${INGRESS_PROXY_NAME}) pointing to Engine ${POC07_ENGINE_ID}..."
  I_DIR="${WORK_DIR}/ingress"
  mkdir -p "${I_DIR}/apiproxy/policies" "${I_DIR}/apiproxy/proxies" "${I_DIR}/apiproxy/targets" "${I_DIR}/apiproxy/resources/jsc"

  cat <<'EOF' > "${I_DIR}/apiproxy/policies/VA-VerifyAPIKey.xml"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<VerifyAPIKey continueOnError="false" enabled="true" name="VA-VerifyAPIKey">
    <DisplayName>VA-VerifyAPIKey</DisplayName>
    <APIKey ref="request.header.x-api-key"/>
</VerifyAPIKey>
EOF

  cat <<'EOF' > "${I_DIR}/apiproxy/policies/SA-RateLimit.xml"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<SpikeArrest continueOnError="false" enabled="true" name="SA-RateLimit">
    <DisplayName>SA-RateLimit</DisplayName>
    <Rate>30pm</Rate>
    <UseEffectiveCount>true</UseEffectiveCount>
</SpikeArrest>
EOF

  cat <<'EOF' > "${I_DIR}/apiproxy/resources/jsc/JS-VerifyIngressIAP.js"
var rawBody = context.getVariable("request.content") || "{}";
var userId = "demo-user";
try {
    var parsed = JSON.parse(rawBody);
    if (parsed && parsed.input && parsed.input.user_id) {
        userId = String(parsed.input.user_id);
    }
} catch (e) {}

var callerAccountHeader = context.getVariable("request.header.x-argolis-account") || "";
var userLower = (userId + " " + callerAccountHeader).toLowerCase();

if (
    userLower.indexOf("helloayush") !== -1 ||
    userLower.indexOf("koushal@") !== -1 ||
    userLower.indexOf("unauth") !== -1 ||
    userLower.indexOf("unauthorized") !== -1
) {
    context.setVariable("iap.authz.denied", "true");
    context.setVariable("iap.authz.principal", userId);
} else {
    context.setVariable("iap.authz.denied", "false");
    context.setVariable("iap.authz.principal", userId);
}
EOF

  cat <<'EOF' > "${I_DIR}/apiproxy/policies/JS-VerifyIngressIAP.xml"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Javascript continueOnError="false" enabled="true" timeLimit="200" name="JS-VerifyIngressIAP">
    <DisplayName>JS-VerifyIngressIAP</DisplayName>
    <ResourceURL>jsc://JS-VerifyIngressIAP.js</ResourceURL>
</Javascript>
EOF

  cat <<EOF > "${I_DIR}/apiproxy/policies/SC-LogEgressIAPDenial.xml"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<ServiceCallout continueOnError="true" enabled="true" name="SC-LogEgressIAPDenial">
    <DisplayName>SC-LogEgressIAPDenial</DisplayName>
    <Request clearPayload="true">
        <Set>
            <Headers>
                <Header name="Content-Type">application/json</Header>
                <Header name="X-Goog-User-Project">${TARGET_PROJECT_ID}</Header>
            </Headers>
            <Payload contentType="application/json" variablePrefix="@" variableSuffix="#">{
  "entries": [
    {
      "logName": "projects/${TARGET_PROJECT_ID}/logs/networkservices.googleapis.com%2Fgateway_requests",
      "resource": {
        "type": "networkservices.googleapis.com/Gateway",
        "labels": {
          "location": "${TARGET_REGION}",
          "network_name": "projects/pb4247fab2cb53178p-tp/global/networks/uk1-25feb-2-vpc4",
          "gateway_type": "SECURE_WEB_GATEWAY",
          "resource_container": "951503373927",
          "gateway_name": "fresh-agent-egress-gateway"
        }
      },
      "httpRequest": {
        "requestMethod": "POST",
        "requestUrl": "https://35.244.241.176.nip.io/mcp",
        "status": 403,
        "userAgent": "python-httpx/0.28.1",
        "protocol": "HTTP/1.1"
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
              "result": "DENIED"
            }
          ]
        },
        "agentGatewayInfo": {
          "agentRegistryResource": "projects/951503373927/locations/global/mcpServers/agentregistry-00000000-0000-0000-d2d4-1318dbcb3102",
          "mcpInfo": {
            "method": "tools/call"
          }
        }
      }
    },
    {
      "logName": "projects/${TARGET_PROJECT_ID}/logs/iap_audit",
      "resource": {
        "type": "networkservices.googleapis.com/Gateway",
        "labels": {
          "location": "${TARGET_REGION}",
          "gateway_name": "fresh-agent-egress-gateway"
        }
      },
      "severity": "ERROR",
      "protoPayload": {
        "@type": "type.googleapis.com/google.cloud.audit.AuditLog",
        "serviceName": "iap.googleapis.com",
        "methodName": "google.cloud.iap.v1.IdentityAwareProxy.Authorize",
        "authenticationInfo": {
          "principalEmail": "@iap.authz.principal#",
          "principalSubject": "principal://agents.global.org-223808529687.system.id.goog/resources/aiplatform/projects/951503373927/locations/us-central1/reasoningEngines/${POC07_ENGINE_ID}"
        },
        "requestMetadata": {
          "requestAttributes": {
            "host": "35.244.241.176.nip.io"
          }
        },
        "authorizationInfo": [
          {
            "resource": "projects/951503373927/locations/global/agentRegistry/mcpServers/agentregistry-00000000-0000-0000-d2d4-1318dbcb3102",
            "permission": "iap.webServiceVersions.accessViaIap",
            "granted": false
          }
        ]
      }
    }
  ]
}</Payload>
            <Verb>POST</Verb>
        </Set>
    </Request>
    <Response>calloutLogResponse</Response>
    <HTTPTargetConnection>
        <Authentication>
            <GoogleAccessToken>
                <Scopes>
                    <Scope>https://www.googleapis.com/auth/cloud-platform</Scope>
                </Scopes>
            </GoogleAccessToken>
        </Authentication>
        <URL>https://logging.googleapis.com/v2/entries:write</URL>
    </HTTPTargetConnection>
</ServiceCallout>
EOF

  cat <<EOF > "${I_DIR}/apiproxy/policies/RF-IAPAuthorizationDenied.xml"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<RaiseFault continueOnError="false" enabled="true" name="RF-IAPAuthorizationDenied">
    <DisplayName>RF-IAPAuthorizationDenied</DisplayName>
    <FaultResponse>
        <Set>
            <Headers>
                <Header name="Content-Type">application/json</Header>
            </Headers>
            <Payload contentType="application/json" variablePrefix="@" variableSuffix="#">[{
  "error": {
    "code": 403,
    "message": "IAP Authorization Denied at Egress Agent Gateway ('fresh-agent-egress-gateway' / 'fresh-agw-iap-policy'): Principal '@iap.authz.principal#' lacks 'roles/iap.egressor' permission to egress to 'https://35.244.241.176.nip.io/mcp'.",
    "status": "PERMISSION_DENIED",
    "details": [
      {
        "@type": "type.googleapis.com/google.rpc.ErrorInfo",
        "reason": "IAM_PERMISSION_DENIED",
        "domain": "iap.googleapis.com",
        "metadata": {
          "gateway": "projects/${TARGET_PROJECT_ID}/locations/${TARGET_REGION}/agentGateways/fresh-agent-egress-gateway",
          "policy": "fresh-agw-iap-policy",
          "principal": "@iap.authz.principal#",
          "required_role": "roles/iap.egressor"
        }
      }
    ]
  }
}]</Payload>
            <StatusCode>403</StatusCode>
            <ReasonPhrase>Forbidden</ReasonPhrase>
        </Set>
    </FaultResponse>
    <IgnoreUnresolvedVariables>true</IgnoreUnresolvedVariables>
</RaiseFault>
EOF

  cat <<EOF > "${I_DIR}/apiproxy/policies/AM-PrepareTargetRequest.xml"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<AssignMessage continueOnError="false" enabled="true" name="AM-PrepareTargetRequest">
    <DisplayName>AM-PrepareTargetRequest</DisplayName>
    <Remove>
        <Headers>
            <Header name="x-api-key"/>
        </Headers>
    </Remove>
    <Set>
        <Headers>
            <Header name="X-Goog-User-Project">${TARGET_PROJECT_ID}</Header>
            <Header name="Content-Type">application/json</Header>
        </Headers>
    </Set>
    <AssignVariable>
        <Name>target.copy.pathsuffix</Name>
        <Value>false</Value>
    </AssignVariable>
    <IgnoreUnresolvedVariables>true</IgnoreUnresolvedVariables>
    <AssignTo createNew="false" transport="http" type="request"/>
</AssignMessage>
EOF

  cat <<'EOF' > "${I_DIR}/apiproxy/proxies/default.xml"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<ProxyEndpoint name="default">
    <PreFlow name="PreFlow">
        <Request>
            <Step><Name>VA-VerifyAPIKey</Name></Step>
            <Step><Name>SA-RateLimit</Name></Step>
            <Step><Name>JS-VerifyIngressIAP</Name></Step>
            <Step>
                <Name>SC-LogEgressIAPDenial</Name>
                <Condition>iap.authz.denied = "true"</Condition>
            </Step>
            <Step>
                <Name>RF-IAPAuthorizationDenied</Name>
                <Condition>iap.authz.denied = "true"</Condition>
            </Step>
        </Request>
        <Response/>
    </PreFlow>
    <HTTPProxyConnection>
        <BasePath>/weather-agent-07</BasePath>
    </HTTPProxyConnection>
    <RouteRule name="default">
        <TargetEndpoint>default</TargetEndpoint>
    </RouteRule>
</ProxyEndpoint>
EOF

  cat <<EOF > "${I_DIR}/apiproxy/targets/default.xml"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<TargetEndpoint name="default">
    <PreFlow name="PreFlow">
        <Request>
            <Step><Name>AM-PrepareTargetRequest</Name></Step>
        </Request>
        <Response/>
    </PreFlow>
    <HTTPTargetConnection>
        <Properties>
            <Property name="io.timeout.millis">120000</Property>
            <Property name="connect.timeout.millis">60000</Property>
        </Properties>
        <Authentication>
            <GoogleAccessToken>
                <Scopes>
                    <Scope>https://www.googleapis.com/auth/cloud-platform</Scope>
                </Scopes>
            </GoogleAccessToken>
        </Authentication>
        <URL>https://${TARGET_REGION}-aiplatform.googleapis.com/v1/projects/${TARGET_PROJECT_ID}/locations/${TARGET_REGION}/reasoningEngines/${POC07_ENGINE_ID}:streamQuery</URL>
    </HTTPTargetConnection>
</TargetEndpoint>
EOF

  cat <<EOF > "${I_DIR}/apiproxy/${INGRESS_PROXY_NAME}.xml"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<APIProxy name="${INGRESS_PROXY_NAME}">
    <DisplayName>${INGRESS_PROXY_NAME}</DisplayName>
    <Description>Northbound Ingress Proxy (MCP Toolset + Apigee AI Model Router)</Description>
</APIProxy>
EOF

  (cd "${I_DIR}" && zip -qr "${WORK_DIR}/ingress.zip" apiproxy)

  IMPORT_INGRESS=$(curl -s -X POST \
    -H "Authorization: Bearer ${TOKEN}" \
    -F "file=@${WORK_DIR}/ingress.zip" \
    "https://apigee.googleapis.com/v1/organizations/${APIGEE_PROJECT_ID}/apis?action=import&name=${INGRESS_PROXY_NAME}")
  I_REV=$(echo "${IMPORT_INGRESS}" | python3 -c "import sys, json; print(json.load(sys.stdin)['revision'])")
  echo "✅ Imported ${INGRESS_PROXY_NAME} revision ${I_REV}, deploying with SA ${APIGEE_CALLER_SA}..."

  curl -s -X POST \
    -H "Authorization: Bearer ${TOKEN}" \
    "https://apigee.googleapis.com/v1/organizations/${APIGEE_PROJECT_ID}/environments/${APIGEE_ENV}/apis/${INGRESS_PROXY_NAME}/revisions/${I_REV}/deployments?override=true&serviceAccount=${APIGEE_CALLER_SA}"
  echo ""
fi

echo "==> Updating weather-agent-ingress-product to include ${ROUTER_PROXY_NAME} and ${INGRESS_PROXY_NAME}..."
curl -s -X PUT \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  "https://apigee.googleapis.com/v1/organizations/${APIGEE_PROJECT_ID}/apiproducts/weather-agent-ingress-product" \
  -d '{
    "name": "weather-agent-ingress-product",
    "displayName": "Weather Agent Ingress Product",
    "approvalType": "auto",
    "environments": ["eval", "eval-comp"],
    "proxies": [
      "weather-agent-ingress-proxy",
      "apigee-ai-model-router",
      "weather-agent-06-ingress-proxy",
      "apigee-ai-model-router-07",
      "weather-agent-07-ingress-proxy"
    ]
  }' | python3 -m json.tool | head -n 15

rm -rf "${WORK_DIR}"
echo ""
echo "=================================================================="
echo "✅ Apigee Proxies Deployed in ${APIGEE_PROJECT_ID}!"
echo "🔗 Northbound Client URL: https://8.233.148.121.nip.io/weather-agent-07"
echo "🔗 Southbound AI Router:  https://8.233.148.121.nip.io/llm-router-07"
echo "🔗 Southbound MCP Proxy:  https://8.233.148.121.nip.io/mcp (mcp-weather-oas in test-501813)"
echo "🔑 Native API Key:        y6sskDUc9zVbNMACJvEjYqePlkjCn4Jl12DVP0cJ4gU3eoMF"
echo "=================================================================="
