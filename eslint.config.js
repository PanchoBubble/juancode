// @ts-check
import js from "@eslint/js";
import tseslint from "typescript-eslint";

export default tseslint.config(
  {
    ignores: [
      "**/dist/**",
      "**/node_modules/**",
      "**/*.config.js",
      "**/*.config.ts",
      // The Swift native app: no lintable JS of ours; its SwiftPM build dir
      // (apps/native/.build) vendors third-party JS (e.g. GRDB's bundled
      // sqlite wasm tests) that must not be linted.
      "apps/native/**",
      // Agent-session worktrees are full repo copies (including their own
      // SwiftPM .build dirs) — never lint into them.
      ".claude/worktrees/**",
    ],
  },
  js.configs.recommended,
  ...tseslint.configs.recommended,
  {
    // Plain JS tooling scripts run on Node.
    files: ["**/*.{js,mjs,cjs}"],
    languageOptions: {
      globals: { console: "readonly", process: "readonly" },
    },
  },
  {
    rules: {
      "@typescript-eslint/no-unused-vars": [
        "error",
        { argsIgnorePattern: "^_", varsIgnorePattern: "^_" },
      ],
      "@typescript-eslint/consistent-type-imports": "error",
    },
  },
);
