const CROCKFORD = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
const TIME_CHARS = 10;
const RANDOM_CHARS = 16;

export type IdFactory = () => string;

export function ulid(nowMs: number = Date.now(), random: () => number = Math.random): string {
  let time = "";
  let remaining = Math.max(0, Math.floor(nowMs));
  for (let i = 0; i < TIME_CHARS; i++) {
    time = CROCKFORD[remaining % 32] + time;
    remaining = Math.floor(remaining / 32);
  }
  let tail = "";
  for (let i = 0; i < RANDOM_CHARS; i++) tail += CROCKFORD[Math.min(31, Math.floor(random() * 32))];
  return time + tail;
}
