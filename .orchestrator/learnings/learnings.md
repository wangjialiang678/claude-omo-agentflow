# Learnings Log

## 2026-02-03: Lazy Loading Anti-Pattern

When a module declares lazy loading infrastructure but also synchronously imports all the same modules, the lazy loading becomes dead code and the startup cost remains. Always verify that lazy-loaded modules are NOT also imported synchronously in the same file.

## 2026-02-03: exec() vs execFile() in Node.js

Even in contexts where the command string is hardcoded (not user input), using exec() (which spawns a shell) sets a bad precedent. The git worker in hooks uses exec() while the SafeExecutor in security explicitly avoids it. Consistency matters for security posture.

## 2026-02-03: claude-code-router Code Review

- The project uses `require()` with user-configurable paths in two locations (custom router and transformer loading), which is a common pattern in plugin systems but a critical security risk without path validation.
- The error handler in `middleware.ts` has an operator precedence bug: `error.message + error.stack || "Internal Server Error"` always concatenates stack traces because `+` binds tighter than `||`.
- Server initialization has a race condition: `TransformerService.initialize().finally()` is used to chain `ProviderService` creation, but `.finally()` is not awaited, so the server can accept requests before providers are ready.

## 2026-02-03: claude-flow Security Module Review

- **Finding**: Projects that build dedicated security modules (SafeExecutor, PathValidator) often bypass their own protections elsewhere in the codebase. In claude-flow, the CLI commands use raw `execSync` with shell=true while SafeExecutor was designed to prevent exactly this.
- **Pattern**: Always grep for `execSync`, `exec(`, `spawn.*shell.*true` across the entire codebase when reviewing projects with security modules - the module's protections are only effective if actually used.
- **Lesson**: Test import paths in monorepos break silently. claude-flow has 90+ test files but many fail due to relative import resolution. Always run tests as part of review.
