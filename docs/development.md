# Development Guide

## Quick start

```bash
# Create a VM
make vm-init

# Build binary and deploy to VM
make deploy
```

`make deploy` cross-compiles the Go binary for linux/amd64, then runs the Ansible deploy playbook which installs ClamAV, copies the binary, creates a systemd service, and waits for the health check.

## VM management

VMs are managed via libvirt/virsh. Each VM gets a real IP on the default NAT network (`virbr0`). No state files — virsh is the source of truth.

```bash
# Create 1 VM (default name: av-scanner)
./scripts/vm-init.sh

# Create multiple VMs with a prefix
./scripts/vm-init.sh --name molecule --count 2

# Force-recreate
./scripts/vm-init.sh --name av-scanner --force
```

Prerequisites: `virsh`, `virt-install`, `qemu-img`, `cloud-localds`

## Building

### Go binary

```bash
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o av-scanner main.go
```

### Container images

This project uses **podman** for container builds:

```bash
# Scanner binary image
make build

# Deployer image (binary + Ansible + kubectl)
make build-deploy
```

The deployer image (`docker/Dockerfile`) bundles the Go binary, Ansible, kubectl, and node_exporter. It is used by the Helm chart's controller Deployment, CronJob, and hooks.

Dockerfile must use fully qualified image names (e.g., `docker.io/library/golang:1.23-alpine`).

### Helm chart

```bash
helm lint charts/av-scanner --set sshKey.existingSecret=test
helm package charts/av-scanner
```

## Project structure

```text
├── main.go                      # Go entrypoint
├── internal/                    # Go packages (server, scanner, auth)
├── ansible/
│   ├── playbooks/               # deploy.yaml, token-refresh.yaml, restart.yaml
│   └── roles/
│       ├── av-scanner/          # Installs binary, systemd service, config
│       └── clamav/              # Installs and configures ClamAV
├── charts/av-scanner/           # Helm chart
│   ├── templates/               # K8s manifests (controller, cronjob, hooks)
│   └── tests/                   # helm-unittest test files
├── docker/Dockerfile            # Deployer image
├── scripts/                     # VM init, destroy, perf-test
└── test/
    ├── e2e/                     # BATS end-to-end tests
    └── perf/                    # k6 load test scripts
```

## Testing

| Test | Command | Prerequisites |
|------|---------|---------------|
| Unit | `make test-unit` | None |
| Helm | `make test-helm` | `helm`, `helm-unittest` plugin |
| Molecule | `make test-molecule` | VMs: `vm-init --name molecule --count 2` |
| E2E | `make test-e2e` | VMs: `vm-init --name e2e --count 2`, `kind`, `docker`, `bats` |
| Performance | `make test-perf` | VM with av-scanner deployed, `k6` |

### Unit tests

```bash
go test -race ./...
```

### Helm tests

```bash
helm lint charts/av-scanner --set sshKey.existingSecret=test
helm unittest charts/av-scanner
```

### Molecule tests

Tests the Ansible roles against real VMs:

```bash
cd ansible/roles/av-scanner
MOLECULE_SSH_KEY=../../.vms/id_ed25519 \
MOLECULE_VM1_IP=<ip1> \
MOLECULE_VM2_IP=<ip2> \
molecule test
```

### E2E tests

Uses [BATS](https://github.com/bats-core/bats-core) with a kind cluster + libvirt VMs. Tests the full deployment path: Helm install → controller pod → Ansible deploy → scan/auth verification.

```bash
# Create e2e VMs
./scripts/vm-init.sh --name e2e --count 2

# Run all e2e tests
make test-e2e

# Run individually
bats test/e2e/01_e2e.bats

# Clean up
kind delete cluster --name av-scanner-e2e
```

### Performance tests

```bash
# Default: 10 VUs for 30 seconds
make test-perf

# Custom load
k6 run -e API_URL=http://<VM_IP>:3000 test/perf/loadtest.js
```

Sends 80% clean / 20% infected (EICAR) files and verifies 100% correct scan results. If Prometheus is running, reports VM resource usage metrics after the test.

## Releasing

### Versioning scheme

- **Chart version** (`version` in Chart.yaml): semver. Bump minor for new features or breaking value changes, patch for fixes.
- **App version / image tag** (`appVersion` in Chart.yaml): `YYYYMMDD-rN` format (date + revision number). This is the Docker image tag.

### Release steps

1. Bump `version` and `appVersion` in `charts/av-scanner/Chart.yaml`
2. Commit, push, merge PR
3. Tag and push to trigger Docker image build:
   ```bash
   git tag <appVersion>
   git push origin <appVersion>
   ```
4. The Docker workflow (`.github/workflows/docker.yaml`) builds and pushes the image on any tag push
5. The Helm chart workflow (`.github/workflows/helm.yaml`) publishes the chart on push to master

### When to bump

- **appVersion (image tag)**: any change to Go code, Ansible roles/playbooks, Dockerfile, or anything bundled in the deployer image
- **Chart version**: any change to Helm templates, values.yaml, or chart metadata

If only docs or CI scripts change, no version bump is needed.

## Makefile targets

| Target | Description |
|--------|-------------|
| `make vm-init` | Create VM via libvirt/virsh |
| `make vm-start` | Start existing VM |
| `make vm-stop` | Graceful shutdown |
| `make vm-destroy` | Destroy VM and remove disk |
| `make build` | Build scanner image |
| `make build-deploy` | Build deployer image |
| `make deploy` | Build binary and deploy to VM |
| `make test-unit` | Run Go unit tests |
| `make test-helm` | Helm lint + unittest |
| `make test-molecule` | Molecule tests |
| `make test-e2e` | BATS e2e tests |
| `make test-perf` | k6 load tests |
| `make clean` | Remove local images |
