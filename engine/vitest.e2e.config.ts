import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    include: ["e2e/**/*.e2e.ts"],
    testTimeout: 90_000,
    hookTimeout: 120_000,
  },
});
