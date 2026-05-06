# Development Guide

## Quick start

```bash
make env      # Create VMs + minikube cluster + kubectl context + skaffold-values.yaml
make deploy   # Build deployer image and deploy via Helm
```

`make env` creates two VMs via libvirt, a minikube cluster (profile `av-scanner`, K8s 1.24), the SSH key secret, and generates `skaffold-values.yaml` with VM IPs. Idempotent — safe to run repeatedly.

`make deploy` runs `skaffold run` which builds the deployer image and deploys via the Helm chart.

For a live-reload dev loop, use `skaffold dev` instead — it watches for changes, rebuilds, and redeploys automatically.

## Testing

```bash
make test-unit      # Go unit tests
make test-helm      # Helm lint + unittest
make test-molecule  # Molecule tests inside controller pod (requires: make deploy)
make test-e2e       # BATS e2e tests (requires: make env)
make test-perf      # k6 load tests
```

| Test | What it covers |
|------|----------------|
| Unit | Go packages (server, scanner, auth) |
| Helm | Chart rendering, values, RBAC, hooks |
| Molecule | Ansible roles against real VMs (converge, idempotence, verify) |
| E2E | Full pipeline: skaffold build+deploy → molecule → scan/auth via Istio gateway |
| Performance | Load test: 80% clean / 20% EICAR, verifies 100% correct results |

### Running molecule interactively

```bash
kubectl -n av-scanner exec -it deploy/av-scanner-controller -- \
    bash -c "cd /app/ansible/roles/av-scanner && molecule test"
```

VM IPs and SSH key are available in the pod via env vars (`AV_SCANNER_VM1_IP`, `AV_SCANNER_VM2_IP`) and volume mount (`/ssh/id_ed25519`).

## Project structure

```text
├── main.go                      # Go entrypoint
├── internal/                    # Go packages (server, scanner, auth)
├── ansible/
│   ├── playbooks/               # deploy.yaml, token-refresh.yaml, restart.yaml, test-api.yaml
│   └── roles/
│       ├── av-scanner/          # Installs binary, systemd service, config
│       └── clamav/              # Installs and configures ClamAV
├── charts/av-scanner/           # Helm chart
│   ├── templates/               # K8s manifests (controller, cronjob, hooks)
│   └── tests/                   # helm-unittest test files
├── docker/Dockerfile            # Deployer image
├── skaffold.yaml                # Skaffold config (build + deploy)
├── scripts/                     # VM init, destroy, perf-test
└── test/
    ├── e2e/                     # BATS end-to-end tests
    └── perf/                    # k6 load test scripts
```

## Inventory

The Ansible inventory uses an `av_scanner` group for VM hosts:

```yaml
all:
  vars:
    ansible_ssh_common_args: "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
    ansible_ssh_private_key_file: /ssh/id_ed25519
  children:
    av_scanner:
      hosts:
        vm1:
          ansible_host: 192.168.122.213
          ansible_user: ubuntu
```

All playbooks target `hosts: av_scanner` (not `hosts: all`) to avoid conflicts with localhost plays. The inventory is set via Helm values and mounted as a ConfigMap at `/etc/ansible/hosts` in all pods.

`make env` generates `skaffold-values.yaml` (gitignored) with the inventory populated from actual VM IPs.

## VM management

VMs are managed via libvirt/virsh. Each VM gets a real IP on the default NAT network (`virbr0`). No state files — virsh is the source of truth.

```bash
# Create/destroy via make
make env    # creates e2e-1, e2e-2
make clean  # destroys VMs + minikube

# Direct script usage
./scripts/vm-init.sh --name e2e --count 2 --force
./scripts/vm-destroy.sh --name e2e --count 2
```

Prerequisites: `virsh`, `virt-install`, `qemu-img`, `cloud-localds`

## Building

The deployer image (`docker/Dockerfile`) bundles the Go binary, Ansible, kubectl, molecule, and node_exporter. It is used by the Helm chart's controller Deployment, CronJob, and hooks.

`make deploy` (via skaffold) handles the build automatically. To build manually:

```bash
docker build -f docker/Dockerfile -t av-scanner-deploy:dev .
```

Dockerfile must use fully qualified image names (e.g., `docker.io/library/golang:1.23-alpine`).

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
