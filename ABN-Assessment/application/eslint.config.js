// Flat config (ESLint 9). The Validate stage of the pipeline runs `npx eslint src`.
//
// Deliberately minimal: this is a ~200 line service and the assessment asks for
// simple application logic. The rules that are here are the ones that catch real
// bugs rather than style opinions.
export default [
  {
    files: ["src/**/*.js"],
    languageOptions: {
      ecmaVersion: 2023,
      sourceType: "module",
      globals: {
        process: "readonly",
        console: "readonly",
        fetch: "readonly",
        Buffer: "readonly",
        AbortController: "readonly",
        setTimeout: "readonly",
        clearTimeout: "readonly",
        URL: "readonly",
      },
    },
    rules: {
      "no-unused-vars": ["error", { argsIgnorePattern: "^_" }],
      "no-undef": "error",
      "no-console": "off",
      eqeqeq: ["error", "smart"],
      "prefer-const": "error",
      "no-var": "error",
    },
  },
];
