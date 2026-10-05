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
