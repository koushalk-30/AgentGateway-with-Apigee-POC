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
