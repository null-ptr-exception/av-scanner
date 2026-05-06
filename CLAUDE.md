## Git Commit Policy (MANDATORY)

**Commit message format:**
```
<type>: <short description>

[optional body explaining why/what changed]
```

**RULES:**
- NO "Generated with Claude Code" footer
- NO "Co-Authored-By: Claude" line
- NO mention of "Claude" or "Happy" anywhere
- Keep messages short (1-5 lines preferred)
- Types: feat, fix, refactor, chore, docs, build, test

## Development

See `docs/development.md` for setup, testing, building, and releasing.

Key commands: `make env`, `make deploy`, `make test-*`, `make clean`. kubectl context: `av-scanner`.

**"Regression tests" means:** `make test-unit test-helm test-molecule test-e2e`

## Shell Scripts Policy

**NEVER suppress stderr** in scripts or tests (`2>/dev/null`, `>/dev/null 2>&1`, `&>/dev/null`).
Errors must always be visible so failures are diagnosable.

- Redirecting stdout only (`>/dev/null`) is OK for exit-code-only checks (e.g. health polls, `command -v`, `docker image inspect`)
- `|| true` is OK for idempotent cleanup (e.g. `virsh destroy` on an already-stopped VM) but do NOT combine with stderr suppression

## Container Images

Dockerfile must use fully qualified image names (e.g., `docker.io/library/golang:1.23-alpine`).

## EICAR Test String

**NEVER** store the EICAR test string directly in source files - it will trigger local AV scanners (including TrendMicro which detects base64-encoded EICAR).

Store with one character replaced, fix at runtime:
```go
// 'O' at position 2 replaced with 'x'
broken := "X5x!P%@AP[4\\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*"
eicar := strings.Replace(broken, "x", "O", 1)
```

```bash
echo 'X5x!P%@AP[4\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*' | sed 's/x/O/'
```
