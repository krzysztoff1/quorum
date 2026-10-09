export interface ParsedArgs {
  command: "research" | "mcp-serve" | "run" | "version";
  prompt?: string;
  model?: string;
  effort?: string;
  maxBudgetUsd?: number;
  maxTurns?: number;
  tools?: string[];
  appendSystemPrompt?: string;
}

const VALUE_FLAGS: Record<string, keyof ParsedArgs> = {
  "-p": "prompt",
  "--model": "model",
  "--effort": "effort",
  "--max-budget-usd": "maxBudgetUsd",
  "--max-turns": "maxTurns",
  "--tools": "tools",
  "--append-system-prompt": "appendSystemPrompt",
};

function finiteNumber(raw: string): number | undefined {
  const n = Number(raw);
  return Number.isFinite(n) ? n : undefined;
}

function commandOf(first: string | undefined): ParsedArgs["command"] {
  if (first === "mcp-serve") return "mcp-serve";
  if (first === "run") return "run";
  if (first === "version") return "version";
  return "research";
}

export function parseArgs(argv: string[]): ParsedArgs {
  const args: ParsedArgs = { command: commandOf(argv[0]) };

  for (let i = 0; i < argv.length; i++) {
    const token = argv[i]!;
    let flag = token;
    let inlineValue: string | undefined;
    const eq = token.startsWith("--") ? token.indexOf("=") : -1;
    if (eq !== -1) {
      flag = token.slice(0, eq);
      inlineValue = token.slice(eq + 1);
    }

    const key = VALUE_FLAGS[flag];
    if (key) {
      const value = inlineValue ?? argv[++i];
      if (value === undefined) continue;
      assign(args, key, value);
      continue;
    }

    // ponytail: unknown flag heuristic — consume its value only if the next token isn't itself a flag.
    if (flag.startsWith("-") && inlineValue === undefined) {
      const next = argv[i + 1];
      if (next !== undefined && !next.startsWith("-")) i++;
    }
  }

  return args;
}

function assign(args: ParsedArgs, key: keyof ParsedArgs, value: string): void {
  switch (key) {
    case "maxBudgetUsd":
      args.maxBudgetUsd = finiteNumber(value);
      break;
    case "maxTurns": {
      const n = finiteNumber(value);
      args.maxTurns = n === undefined ? undefined : Math.trunc(n);
      break;
    }
    case "tools":
      args.tools = value.split(",").map((t) => t.trim()).filter(Boolean);
      break;
    default:
      (args as unknown as Record<string, string>)[key] = value;
  }
}
