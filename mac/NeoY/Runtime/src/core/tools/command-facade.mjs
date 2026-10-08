function typeMatches(value, type) {
  if (type === "null") return value === null;
  if (type === "object") return value !== null && typeof value === "object" && !Array.isArray(value);
  if (type === "array") return Array.isArray(value);
  if (type === "integer") return Number.isInteger(value);
  if (type === "number") return typeof value === "number" && Number.isFinite(value);
  return typeof value === type;
}

function validateSchema(value, schema, path) {
  if (!schema || typeof schema !== "object") return;
  const types = Array.isArray(schema.type) ? schema.type : schema.type ? [schema.type] : [];
  if (types.length && !types.some((type) => typeMatches(value, type))) {
    throw new Error(`${path} must be ${types.join(" or ")}`);
  }
  if (schema.enum && !schema.enum.some((candidate) => Object.is(candidate, value))) {
    throw new Error(`${path} must be one of: ${schema.enum.join(", ")}`);
  }
  if (typeof value === "string") {
    if (schema.minLength !== undefined && value.length < schema.minLength) throw new Error(`${path} must contain at least ${schema.minLength} characters`);
    if (schema.maxLength !== undefined && value.length > schema.maxLength) throw new Error(`${path} must contain at most ${schema.maxLength} characters`);
  }
  if (typeof value === "number") {
    if (schema.minimum !== undefined && value < schema.minimum) throw new Error(`${path} must be at least ${schema.minimum}`);
    if (schema.maximum !== undefined && value > schema.maximum) throw new Error(`${path} must be at most ${schema.maximum}`);
  }
  if (Array.isArray(value)) {
    if (schema.minItems !== undefined && value.length < schema.minItems) throw new Error(`${path} must contain at least ${schema.minItems} items`);
    if (schema.maxItems !== undefined && value.length > schema.maxItems) throw new Error(`${path} must contain at most ${schema.maxItems} items`);
    value.forEach((item, index) => validateSchema(item, schema.items, `${path}[${index}]`));
  }
  if (value !== null && typeof value === "object" && !Array.isArray(value)) {
    for (const key of schema.required || []) {
      if (value[key] === undefined) throw new Error(`${path}.${key} is required`);
    }
    const properties = schema.properties || {};
    for (const [key, nested] of Object.entries(value)) {
      if (!Object.hasOwn(properties, key)) {
        if (schema.additionalProperties === false) throw new Error(`${path}.${key} is not supported; use command='help' to inspect the accepted arguments`);
        if (schema.additionalProperties && typeof schema.additionalProperties === "object") validateSchema(nested, schema.additionalProperties, `${path}.${key}`);
        continue;
      }
      validateSchema(nested, properties[key], `${path}.${key}`);
    }
  }
}

const FACADE_SCHEMA = (commands) => ({
  type: "object",
  properties: {
    command: { type: "string", minLength: 1, enum: ["help", ...commands], description: "Subcommand name, or 'help'." },
    args: { type: "object", description: "Arguments for the selected subcommand. Use help for the exact schema." },
  },
  required: ["command"],
  additionalProperties: false,
});

export function commandFacade({ name, description, commands, commandName, examples = [] }) {
  const entries = new Map(commands.map((tool) => [commandName(tool.name), tool]));
  const commandNames = [...entries.keys()].sort((a, b) => a.localeCompare(b));
  return {
    tool: {
      name,
      description: `${description} Use command='help' to list subcommands or inspect one subcommand's exact args schema.`,
      inputSchema: { ...FACADE_SCHEMA(commandNames), examples },
    },
    async execute(input, handler) {
      if (!input || typeof input !== "object" || Array.isArray(input)) throw new Error("arguments must be an object");
      const requested = typeof input.command === "string" ? input.command.trim() : "";
      if (!requested) throw new Error("command is required");
      const args = input.args === undefined ? {} : input.args;
      if (!args || typeof args !== "object" || Array.isArray(args)) throw new Error("args must be an object");
      if (requested === "help") {
        const named = typeof args.command === "string" ? args.command.trim() : "";
        if (named) {
          const tool = entries.get(named);
          if (!tool) throw new Error(`Unknown ${name} command '${named}'. Use command='help' to list valid commands.`);
          return { command: named, description: tool.description || "", schema: tool.inputSchema || { type: "object" }, ...(tool.examples ? { examples: tool.examples } : {}) };
        }
        return {
          commands: [...entries.entries()].sort(([a], [b]) => a.localeCompare(b)).map(([command, tool]) => ({
            command,
            description: tool.description || "",
            schema: tool.inputSchema || { type: "object" },
            ...(tool.examples ? { examples: tool.examples } : {}),
          })),
          examples,
        };
      }
      const tool = entries.get(requested);
      if (!tool) throw new Error(`Unknown ${name} command '${requested}'. Use command='help' to list valid commands.`);
      validateSchema(args, tool.inputSchema, `args for ${name}.${requested}`);
      return handler(tool.name, args);
    },
  };
}
