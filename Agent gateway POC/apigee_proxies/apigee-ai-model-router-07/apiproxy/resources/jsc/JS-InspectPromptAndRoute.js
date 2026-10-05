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
