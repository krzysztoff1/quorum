export function selfCommand(
  args: string[],
  execPath: string = process.execPath,
  script: string | null = process.argv[1] ?? null,
): { command: string; args: string[] } {
  const compiled = !script || script === execPath || script.startsWith("/$bunfs/") || script.startsWith("B:\\~BUN");
  return compiled ? { command: execPath, args } : { command: execPath, args: [script, ...args] };
}
