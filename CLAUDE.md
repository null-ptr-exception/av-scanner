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

**"Regression tests" means running ALL of the following:** unit, helm, molecule, and e2e.

**Unit tests:** `go test ./...`

**Helm tests:** `helm unittest charts/av-scanner` and `helm lint charts/av-scanner --set sshKey.existingSecret=test`

**Molecule tests** (ansible roles): run from the role directory, requires VMs running.
```bash
cd ansible/roles/clamav
MOLECULE_VM1_IP=<ip> MOLECULE_SSH_KEY=<path> molecule test
```

**E2e tests** use [BATS](https://github.com/bats-core/bats-core) (bash). Requires `bats`, `curl`, `jq`.

**Scan tests** (`test/e2e/01_scan.bats`):
- Deploys av-scanner on VM with no-auth (via ansible) in setup_file
- Requires: VM running (`make vm-init && make setup-vm`)

**Auth tests** (`test/e2e/02_auth.bats`):
- Deploys av-scanner on VM with auth enabled (via ansible) in setup_file
- Auto-creates kind cluster `av-scanner-e2e` with kube-federated-auth
- Each test suite reconciles its own config, so ordering doesn't matter
- Requires: VM running, `kind`, `docker`, `kubectl`

```bash
# Run all e2e tests
make test-e2e

# Run individually
bats test/e2e/01_scan.bats
bats test/e2e/02_auth.bats

# Clean up kind cluster when done
kind delete cluster --name av-scanner-e2e
```

The allowlist YAML format:
```yaml
allowlist:
  - namespace/serviceaccount
```

## VM Management

VMs are managed via **libvirt/virsh** (`qemu:///system`). VMs get real IPs on the default NAT network (virbr0).

**Before creating a VM, check system resources:**
- RAM: VM needs 4GB, host should have at least 6GB available (`free -h`)
- Disk: VM needs ~12GB (10GB disk + ClamAV databases) (`df -h /`)
- Check for existing VMs: `virsh list --all`

**VM init supports `--name`, `--count`, `--force`:**
```bash
./scripts/vm-init.sh                              # 1 VM named "av-scanner"
./scripts/vm-init.sh --name molecule --count 2     # molecule-1, molecule-2
./scripts/vm-init.sh --name av-scanner-e2e --force # destroy+recreate
```

**No state files** — virsh is the source of truth for VM existence and IPs.

**Prerequisites:** `virsh`, `virt-install`, `qemu-img`, `cloud-localds`

## Releasing

See `docs/development.md` § Releasing for full steps. Key points:
- Bump `Chart.yaml` version + appVersion before merging
- After merge: `git tag <appVersion> && git push origin <appVersion>`
- appVersion format: `YYYYMMDD-rN` (e.g. `20260505-r3`)

## Shell Scripts Policy

**NEVER suppress stderr** in scripts or tests (`2>/dev/null`, `>/dev/null 2>&1`, `&>/dev/null`).
Errors must always be visible so failures are diagnosable.

- Redirecting stdout only (`>/dev/null`) is OK for exit-code-only checks (e.g. health polls, `command -v`, `docker image inspect`)
- `|| true` is OK for idempotent cleanup (e.g. `virsh destroy` on an already-stopped VM) but do NOT combine with stderr suppression

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
