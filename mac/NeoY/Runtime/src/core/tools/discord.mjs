const DEFAULT_ENDPOINT = "http://127.0.0.1:43118/discord/reply";

export const DISCORD_TOOLS = [{
  name: "discord_reply",
  description: "Deliver the current Family Tutor turn to its verified originating Discord message. The correlationId is supplied by the Gateway; never infer a channel.",
  inputSchema: {
    type: "object",
    additionalProperties: false,
    properties: {
      correlationId: { type: "string", minLength: 20, maxLength: 128 },
      text: { type: "string", minLength: 1, maxLength: 18000 },
    },
    required: ["correlationId", "text"],
  },
}];

export async function handleDiscord(name, args, { fetchImpl = fetch, endpoint = process.env.NEO_DISCORD_REPLY_URL || DEFAULT_ENDPOINT } = {}) {
  if (name !== "discord_reply") throw new Error("unsupported Discord action");
  const url = new URL(endpoint);
  if (url.protocol !== "http:" || !["127.0.0.1", "localhost", "[::1]"].includes(url.hostname)) {
    throw new Error("Discord delivery endpoint must be local loopback");
  }
  const response = await fetchImpl(url, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(args),
    signal: AbortSignal.timeout(12000),
  });
  const result = await response.json();
  if (!response.ok || !result?.ok || !result.messageId) {
    throw new Error(result?.error || "Discord delivery failed");
  }
  return result;
}
