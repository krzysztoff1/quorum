export class MissingKeyError extends Error {
  constructor(public readonly provider: string, public readonly envVar?: string) {
    super(envVar ? `Missing API key for ${provider} (set ${envVar})` : `Missing API key for ${provider}`);
    this.name = "MissingKeyError";
  }
}

export class UnpricedModelError extends Error {
  constructor(public readonly model: string) {
    super(`No price table entry for model "${model}" — refusing to run blind. Add it to QUORUM_PRICE_TABLE_PATH.`);
    this.name = "UnpricedModelError";
  }
}

export class ClaudeNotFoundError extends Error {
  constructor() {
    super(`Could not find the "claude" CLI. Install it or set QUORUM_CLAUDE_BIN to its path.`);
    this.name = "ClaudeNotFoundError";
  }
}
