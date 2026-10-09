export type RefusalKind = "not_logged_in";

export interface Refusal {
  kind: RefusalKind;
  reason: string;
}

export const NOT_LOGGED_IN: Refusal = {
  kind: "not_logged_in",
  reason: "The Claude CLI is not logged in. Run `claude` in a terminal, sign in with /login, then try again.",
};

export function isLoggedOutMessage(message: { type?: string; error?: unknown; is_error?: unknown; result?: unknown }): boolean {
  if (message.type === "assistant") return message.error === "authentication_failed";
  if (message.type === "result") {
    return message.is_error === true && typeof message.result === "string" && /not logged in/i.test(message.result);
  }
  return false;
}
