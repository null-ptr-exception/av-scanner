# Development Guide

## Quick start

```bash
make env      # Create VMs + minikube cluster + kubectl context + skaffold-values.yaml
make deploy   # Build deployer image and deploy via Helm
```

`make env` creates two VMs via libvirt, a minikube cluster (profile `av-scanner`, K8s 1.24), the SSH key secret, and generates `skaffold-values.yaml` with VM IPs. Idempotent — safe to run repeatedly.

Minikube NodePorts are mapped to host ports `GATEWAY_PORT` (Istio gateway, default 31080), `KFA_PORT` (kube-federated-auth, default 31082), and `PROM_PORT` (Prometheus, default 31090). Override them if they clash with other services, e.g. `make env test-e2e GATEWAY_PORT=32080`. The port mapping is fixed when the minikube profile is created, so changing it requires `minikube delete --profile av-scanner` first.

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

### Engines in e2e

The e2e environment has one VM per engine: `e2e-1` runs ClamAV (`vm1`) and a pre-installed Trend Micro VM runs Trend Micro (`vm2`).

| File | Covers |
|------|--------|
| `01_e2e.bats` | Engine-agnostic: scans on each VM directly (checking its engine), auth, rate limits, metrics, load balancing through the gateway |
| `02_hooks.bats` | Helm hook deploys to both VMs, each with its configured engine |
| `10_clamav.bats` | ClamAV only: `Heuristics.Limits.Exceeded` for an over-limit archive |
| `11_trendmicro.bats` | Trend Micro only: `dsa_scan` allowed, RTS log path, detections logged in `ds_am.log` |

The Trend Micro VM is never created or destroyed by `make`, CI or the tests, since it needs a registered agent. `scripts/tm-vm.sh prepare [--revert]` reverts it to its `tm-base` snapshot, authorizes `.vms/id_ed25519` on it, and waits until `dsa_scan` works.

| Variable | Default | Meaning |
|----------|---------|---------|
| `E2E_TM_VM` | `e2e-tm` | libvirt name of the Trend Micro VM |
| `E2E_TM_SSH_KEY` | `.vms/id_ed25519` | Key the VM was built with, if it was built from another checkout |
| `TM_RTS_LOG_PATH` | `/var/opt/ds_agent/diag/ds_am.log` | Agent log with RTS detections (agent 20.x) |

To build the Trend Micro VM (once per host), from a checkout that CI does not wipe:

1. `./scripts/vm-init.sh --name e2e-tm`
2. Run the agent install script from the Trend Micro console on it. Never commit that script: it holds the tenant's activation token.
3. In the console, make sure the endpoint uses a policy with Anti-Malware on and "Allow agent to trigger or cancel a manual scan" enabled (Anti-Malware → General). Otherwise `dsa_scan` exits 251 or 249.
4. When `sudo /opt/ds_agent/dsa_scan --target <file> --json` exits 0, snapshot it: `source scripts/lib/virsh.sh && virsh_snapshot_create e2e-tm tm-base`.

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
make env    # creates e2e-1 (ClamAV), prepares the Trend Micro VM
make clean  # destroys VMs + minikube

# Direct script usage
./scripts/vm-init.sh --name e2e-1 --force
./scripts/vm-destroy.sh --name e2e-1
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
