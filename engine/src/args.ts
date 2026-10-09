export interface ParsedArgs {
  command: "research" | "mcp-serve" | "run" | "version" | "check" | "export" | "doctor" | "scope" | "cancel" | "list" | "migrate";
  prompt?: string;
  model?: string;
  effort?: string;
  maxBudgetUsd?: number;
  maxTurns?: number;
  tools?: string[];
  appendSystemPrompt?: string;
  replay?: string;
  replayDelayMs?: number;
  runDir?: string;
  runId?: string;
  store?: string;
  detach?: boolean;
  json?: boolean;
  markdown?: boolean;
  out?: string;
}

const VALUE_FLAGS: Record<string, keyof ParsedArgs> = {
  "-p": "prompt",
  "--model": "model",
  "--effort": "effort",
  "--max-budget-usd": "maxBudgetUsd",
  "--max-turns": "maxTurns",
  "--tools": "tools",
  "--append-system-prompt": "appendSystemPrompt",
  "--replay": "replay",
  "--replay-delay-ms": "replayDelayMs",
  "--store": "store",
};

function finiteNumber(raw: string): number | undefined {
  const n = Number(raw);
  return Number.isFinite(n) ? n : undefined;
}

function commandOf(first: string | undefined): ParsedArgs["command"] {
  if (first === "mcp-serve") return "mcp-serve";
  if (first === "run") return "run";
  if (first === "version") return "version";
  if (first === "check") return "check";
  if (first === "export") return "export";
  if (first === "doctor") return "doctor";
  if (first === "scope") return "scope";
  if (first === "cancel") return "cancel";
  if (first === "list") return "list";
  if (first === "migrate") return "migrate";
  return "research";
}

export function parseArgs(argv: string[]): ParsedArgs {
  const args: ParsedArgs = { command: commandOf(argv[0]) };
  if (args.command === "export") {
    const rest = argv.slice(1);
    const outAt = rest.indexOf("--out");
    args.out = outAt === -1 ? undefined : rest[outAt + 1];
    args.markdown = rest.includes("--md");
    args.runDir = rest.find((token, i) => !token.startsWith("-") && (outAt === -1 || i !== outAt + 1));
    return args;
  }
  if (args.command === "check") {
    args.runDir = argv.slice(1).find((token) => !token.startsWith("-"));
    args.json = argv.includes("--json");
    return args;
  }
  if (args.command === "cancel") {
    const rest = argv.slice(1);
    const storeAt = rest.indexOf("--store");
    args.store = storeAt === -1 ? undefined : rest[storeAt + 1];
    args.runId = rest.find((token, i) => !token.startsWith("-") && (storeAt === -1 || i !== storeAt + 1));
    return args;
  }
  if (args.command === "doctor") args.json = argv.includes("--json");
  if (argv.includes("--detach")) args.detach = true;

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
    case "replayDelayMs":
      args.replayDelayMs = finiteNumber(value);
      break;
    case "tools":
      args.tools = value.split(",").map((t) => t.trim()).filter(Boolean);
      break;
    default:
      (args as unknown as Record<string, string>)[key] = value;
  }
}
