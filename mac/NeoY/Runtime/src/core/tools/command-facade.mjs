const FACADE_SCHEMA = {
  type: "object",
  properties: {
    command: { type: "string", minLength: 1, description: "Subcommand name, or 'help'." },
    args: { type: "object", description: "Arguments for the selected subcommand. Use help for the exact schema." },
  },
  required: ["command"],
  additionalProperties: false,
};

export function commandFacade({ name, description, commands, commandName }) {
  const entries = new Map(commands.map((tool) => [commandName(tool.name), tool]));
  return {
    tool: {
      name,
      description: `${description} Use command='help' to list subcommands or inspect one subcommand's exact args schema.`,
      inputSchema: FACADE_SCHEMA,
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
          if (!tool) throw new Error(`Unknown ${name} command '${named}'`);
          return { command: named, description: tool.description || "", schema: tool.inputSchema || { type: "object" } };
        }
        return {
          commands: [...entries.entries()].sort(([a], [b]) => a.localeCompare(b)).map(([command, tool]) => ({
            command,
            description: tool.description || "",
          })),
        };
      }
      const tool = entries.get(requested);
      if (!tool) throw new Error(`Unknown ${name} command '${requested}'`);
      return handler(tool.name, args);
    },
  };
}
