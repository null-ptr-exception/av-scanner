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

## Running Tests

**Unit tests:** `make test-unit` (or `go test -race ./...`)

**E2e tests** use [BATS](https://github.com/bats-core/bats-core) (bash). Requires `bats`, `curl`, `jq`.

**Scan tests** require a VM with ClamAV running:
1. Set up the VM: `make vm-init && make setup-vm && make deploy`
2. Run tests: `make test-e2e`
3. Or manually: `API_URL=http://<VM_IP>:3000 bats test/e2e/scan.bats`

**Auth tests** (`test/e2e/auth.bats`) — require VM + auto-bootstrap kind cluster:
- Requires a running VM with ClamAV (`make vm-init && make setup-vm`)
- Auto-creates kind cluster `av-scanner-e2e` with kube-federated-auth
- Deploys av-scanner on VM with ClamAV engine + auth enabled
- Leaves everything running for fast re-runs (VM stays auth-enabled)
- Requires: `kind`, `docker`, `kubectl`

```bash
# Run auth tests (requires VM, auto-creates kind cluster)
bats test/e2e/auth.bats

# After auth tests, VM has auth enabled. To restore for scan tests:
make deploy

# Clean up kind cluster when done
kind delete cluster --name av-scanner-e2e
```

The allowlist YAML format:
```yaml
allowlist:
  - namespace/serviceaccount
```

## VM Management

**Before creating a VM, check system resources:**
- RAM: VM needs 4GB, host should have at least 6GB available (`free -h`)
- Disk: VM needs ~12GB (10GB disk + ClamAV databases) (`df -h /`)
- Check for other VMs or heavy processes (minikube, etc.) that may compete for resources

**Before creating a VM:**
1. Check KVM support: `ls /dev/kvm` (exists = KVM available)
2. Check Multipass: `multipass list` (shows existing VMs)
3. Check QEMU VMs: `cat .vm-state` or `ls ~/qemu-vms/`
4. Stop existing VM first: `make vm-stop` and `rm .vm-state`

**Interactive prompts:** `make vm-init` and `./scripts/vm-init.sh` have interactive prompts. When running non-interactively, pipe `echo "y"` or use:
- `HYPERVISOR=multipass make vm-init` - skip hypervisor prompt
- `HYPERVISOR=qemu make vm-init` - skip hypervisor prompt

**Performance:**
- Multipass (KVM): ~1-2 min VM startup, recommended for development
- QEMU (TCG): ~5-10 min VM startup, software emulation fallback when KVM unavailable

**Port conflicts:** Default API_PORT=3000. If occupied, use `API_PORT=3001 make vm-init`

## Container Runtime

This project uses **podman** (not docker) for:
- Building images: `podman build`
- Pushing to registry: `podman push --tls-verify=false`
- Dockerfile must use fully qualified image names (e.g., `docker.io/library/golang:1.23-alpine`)

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
