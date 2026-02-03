# Technical Decisions Log

## 2026-02-03: claude-flow v3 Security Review

- The security module uses a defense-in-depth approach with separate components for each CVE.
- Rejection sampling in CredentialGenerator is the correct approach for unbiased random generation, but TokenGenerator lacks the same rigor.
- Global Zod error map side effects should be avoided in library code; use schema-level error maps instead.
- Module-level singletons (workerManager) that perform I/O at import time should be avoided; use lazy initialization patterns.
