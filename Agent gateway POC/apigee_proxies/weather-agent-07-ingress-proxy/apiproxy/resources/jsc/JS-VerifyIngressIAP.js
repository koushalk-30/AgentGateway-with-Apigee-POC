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
