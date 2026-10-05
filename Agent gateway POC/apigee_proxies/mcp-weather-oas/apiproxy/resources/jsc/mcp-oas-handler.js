var contentStr = context.getVariable("request.content");
try {
    var body = JSON.parse(contentStr);
    var id = (body.id !== undefined && body.id !== null) ? body.id : 1;
    var method = body.method;

    if (method === "initialize") {
        var initResponse = {
            "jsonrpc": "2.0",
            "id": id,
            "result": {
                "protocolVersion": "2024-11-05",
                "capabilities": { "tools": {} },
                "serverInfo": { "name": "apigee-nws-mcp-server", "version": "1.0.0" }
            }
        };
        context.setVariable("response.content", JSON.stringify(initResponse));
        context.setVariable("response.header.Content-Type", "application/json");

    } else if (method === "tools/list") {
        var listResponse = {
            "jsonrpc": "2.0",
            "id": id,
            "result": {
                "tools": [
                    {
                        "name": "point",
                        "description": "Returns metadata about a given latitude/longitude point including forecast office, grid coordinates, and observation stations.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "latitude": { "type": "string", "description": "Latitude in decimal degrees (e.g. '39.7456')" },
                                "longitude": { "type": "string", "description": "Longitude in decimal degrees (e.g. '-97.0892')" }
                            },
                            "required": ["latitude", "longitude"]
                        }
                    },
                    {
                        "name": "office",
                        "description": "Returns metadata about a specific National Weather Service forecast office.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "officeId": { "type": "string", "description": "Three-letter NWS forecast office ID (e.g. 'TOP', 'OKX', 'BOX')" }
                            },
                            "required": ["officeId"]
                        }
                    },
                    {
                        "name": "obs_station",
                        "description": "Returns metadata about a specific weather observation station.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "stationId": { "type": "string", "description": "Four-letter weather station identifier (e.g. 'KOKC', 'KJFK', 'KORD')" }
                            },
                            "required": ["stationId"]
                        }
                    },
                    {
                        "name": "radar_servers",
                        "description": "Returns a list of National Weather Service radar servers.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "reportingHost": { "type": "string", "description": "Optional reporting host name" }
                            }
                        }
                    },
                    {
                        "name": "glossary",
                        "description": "Returns definitions of weather terms from the National Weather Service glossary.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "term": { "type": "string", "description": "Optional weather term to look up (e.g. 'blizzard', 'tornado', 'flood')" }
                            }
                        }
                    }
                ]
            }
        };
        context.setVariable("response.content", JSON.stringify(listResponse));
        context.setVariable("response.header.Content-Type", "application/json");

    } else if (method === "tools/call") {
        var params = body.params || {};
        var toolName = params.name || "";
        var args = params.arguments || {};
        var resultData = {};

        if (toolName === "point") {
            var lat = args.latitude || "39.7456";
            var lon = args.longitude || "-97.0892";
            resultData = {
                "id": "https://api.weather.gov/points/" + lat + "," + lon,
                "type": "Feature",
                "geometry": { "type": "Point", "coordinates": [parseFloat(lon), parseFloat(lat)] },
                "properties": {
                    "cwa": "TOP",
                    "forecastOffice": "https://api.weather.gov/offices/TOP",
                    "gridId": "TOP",
                    "gridX": 31,
                    "gridY": 80,
                    "forecast": "https://api.weather.gov/gridpoints/TOP/31,80/forecast",
                    "forecastHourly": "https://api.weather.gov/gridpoints/TOP/31,80/forecast/hourly",
                    "timeZone": "America/Chicago",
                    "radarStation": "KTWX",
                    "source": "Apigee OpenAPI MCP Server"
                }
            };
        } else if (toolName === "office") {
            var offId = (args.officeId || "TOP").toUpperCase();
            resultData = {
                "id": offId,
                "name": offId + " Forecast Office",
                "address": { "addressLocality": "Topeka", "addressRegion": "KS" },
                "telephone": "785-234-2592",
                "email": "w-top.webmaster@noaa.gov",
                "source": "Apigee OpenAPI MCP Server"
            };
        } else if (toolName === "obs_station") {
            var stId = (args.stationId || "KOKC").toUpperCase();
            resultData = {
                "stationIdentifier": stId,
                "name": stId + " Regional Airport Observation Station",
                "timeZone": "America/Chicago",
                "elevation": { "unitCode": "wmoUnit:m", "value": 394.0 },
                "source": "Apigee OpenAPI MCP Server"
            };
        } else if (toolName === "radar_servers") {
            resultData = {
                "servers": [
                    { "id": "KTLX", "name": "Oklahoma City Radar", "status": "active" },
                    { "id": "KTWX", "name": "Topeka Radar", "status": "active" },
                    { "id": "KOKX", "name": "New York Radar", "status": "active" }
                ],
                "source": "Apigee OpenAPI MCP Server"
            };
        } else if (toolName === "glossary") {
            var termQuery = (args.term || "").toLowerCase();
            var definitions = {
                "blizzard": "A severe snowstorm characterized by strong sustained winds of at least 35 mph (56 km/h) and lasting for a prolonged period of time—typically three hours or more—with significant falling or blowing snow reducing visibility to less than 1/4 mile.",
                "tornado": "A violently rotating column of air touching the ground, usually attached to the base of a thunderstorm.",
                "flood": "An overflow of water onto lands that are normally dry.",
                "hurricane": "A tropical cyclone in the Atlantic, Caribbean Sea, Gulf of Mexico, or eastern Pacific, which the maximum sustained surface wind is 64 knots (74 mph) or greater."
            };
            var defText = definitions[termQuery] || "Severe weather phenomenon defined in the National Weather Service Glossary.";
            resultData = {
                "term": args.term || "Glossary",
                "definition": defText,
                "source": "Apigee OpenAPI MCP Server"
            };
        } else {
            resultData = { "message": "Tool executed successfully", "source": "Apigee OpenAPI MCP Server" };
        }

        var callResponse = {
            "jsonrpc": "2.0",
            "id": id,
            "result": {
                "content": [
                    {
                        "type": "text",
                        "text": JSON.stringify(resultData, null, 2)
                    }
                ]
            }
        };
        context.setVariable("response.content", JSON.stringify(callResponse));
        context.setVariable("response.header.Content-Type", "application/json");

    } else {
        context.setVariable("response.content", JSON.stringify({
            "jsonrpc": "2.0",
            "id": id,
            "result": {}
        }));
        context.setVariable("response.header.Content-Type", "application/json");
    }
} catch (e) {
    context.setVariable("response.content", JSON.stringify({
        "jsonrpc": "2.0",
        "error": { "code": -32700, "message": "Error handling MCP JSON-RPC: " + e.toString() }
    }));
    context.setVariable("response.header.Content-Type", "application/json");
}
