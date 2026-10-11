# Development Guide

## Quick start

```bash
make env      # Create VMs + minikube cluster + kubectl context + skaffold-values.yaml
make deploy   # Build deployer image and deploy via Helm
```

`make env` creates two ClamAV VMs via libvirt (see [Engines in e2e](#engines-in-e2e) to make the second one Trend Micro), a minikube cluster (profile `av-scanner`, K8s 1.24), the SSH key secret, and generates `skaffold-values.yaml` with VM IPs. Idempotent — safe to run repeatedly.

Minikube NodePorts are mapped to host ports `GATEWAY_PORT` (Istio gateway, default 31080), `KFA_PORT` (kube-federated-auth, default 31082), and `PROM_PORT` (Prometheus, default 31090). Override them if they clash with other services, e.g. `make env test-e2e GATEWAY_PORT=32080`. The port mapping is fixed when the minikube profile is created, so changing it requires `minikube delete --profile av-scanner` first.

`make deploy` runs `skaffold run` which builds the deployer image and deploys via the Helm chart.

For a live-reload dev loop, use `skaffold dev` instead — it watches for changes, rebuilds, and redeploys automatically.

## Testing

```bash
make test-unit      # Go unit tests
make test-helm      # Helm lint + unittest
make test-molecule  # Molecule tests inside controller pod (requires: make deploy)
make test-e2e       # BATS e2e tests (requires: make env)
make test-perf      # k6 load test against one VM (see Performance testing)
```

| Test | What it covers |
|------|----------------|
| Unit | Go packages (server, scanner, auth) |
| Helm | Chart rendering, values, RBAC, hooks |
| Molecule | Ansible roles against real VMs (converge, idempotence, verify) |
| E2E | Full pipeline: skaffold build+deploy → molecule → scan/auth via Istio gateway |
| Performance | Load test: 80% clean / 20% EICAR, verifies 100% correct results |

### Engines in e2e

The e2e environment has two VMs. `vm1` is always `e2e-1` running ClamAV. `vm2` depends on `E2E_TM_VM`:

- **Unset (default):** `vm2` is `e2e-2`, a second ClamAV VM. Everything runs except `11_trendmicro.bats`, which is skipped. No Trend Micro account needed.
- **Set to a VM name:** `vm2` is that pre-installed Trend Micro VM, so both engines are tested. CI does this on its self-hosted runner.

```bash
make env test-e2e                    # ClamAV only
make env test-e2e E2E_TM_VM=e2e-tm   # ClamAV + Trend Micro
```

Use the same `E2E_TM_VM` for `make env` and `make test-e2e`, and run `make clean` when switching.

| File | Covers |
|------|--------|
| `01_e2e.bats` | Engine-agnostic: scans on each VM directly (checking its engine), auth, rate limits, metrics, load balancing through the gateway |
| `02_hooks.bats` | Helm hook deploys to both VMs, each with its configured engine |
| `10_clamav.bats` | ClamAV only: `Heuristics.Limits.Exceeded` for an over-limit archive |
| `11_trendmicro.bats` | Trend Micro only (skipped without `E2E_TM_VM`): `dsa_scan` allowed, RTS log path, detections logged in `ds_am.log` |

The Trend Micro VM is never created or destroyed by `make`, CI or the tests, since it needs a registered agent. `scripts/tm-vm.sh prepare [--revert]` boots it or reverts it to its `tm-base` snapshot, authorizes `.vms/id_ed25519` on it, and waits until `dsa_scan` works. `scripts/tm-vm.sh stop` shuts it down. The agent is billed while the VM is on, so CI stops it after a successful run and leaves it up after a failure for debugging.

| Variable | Default | Meaning |
|----------|---------|---------|
| `E2E_TM_VM` | (unset) | libvirt name of the Trend Micro VM; unset means ClamAV only |
| `E2E_TM_SSH_KEY` | `.vms/id_ed25519` | Key the VM was built with, if it was built from another checkout |

To build the Trend Micro VM (once per host), from a checkout that CI does not wipe. It needs a Trend Vision One account with Server & Workload Protection (a trial works):

1. `./scripts/vm-init.sh --name e2e-tm`
2. Run the agent install script from the Trend Micro console on it. Never commit that script: it holds the tenant's activation token.
3. In the console, make sure the endpoint uses a policy with Anti-Malware on and "Allow agent to trigger or cancel a manual scan" enabled (Anti-Malware → General). Otherwise `dsa_scan` exits 251 or 249.
4. When `sudo /opt/ds_agent/dsa_scan --target <file> --json` exits 0, snapshot it: `source scripts/lib/virsh.sh && virsh_snapshot_create e2e-tm tm-base`.

### Performance testing

`scripts/perf-test.sh` runs k6 from this host against one VM, with 1 MB zips (clean or with EICAR):

```bash
make test-perf                                    # load: 5 clean + 2 EICAR users for 30s, on e2e-1
make test-perf PERF_MODE=sweep                    # fixed scans/s steps until p95 > 5s; prints the max rate with p95 <= 1s
make test-perf PERF_MODE=sweep PERF_VM=e2e-tm     # the same against the Trend Micro VM
```

Each step also reports the VM's CPU use. Set `AUTH_TOKEN` when the VM has auth enabled (the e2e deploy does; `make deploy` does not). `PERF_RATES` and `PERF_P95_MS` change the steps and the latency limit. Needs `k6`, `python3` and `jq`.

### Debugging a failed e2e run

`./scripts/e2e-logs.sh` prints the av-scanner journal and the engine logs from each e2e VM (clamd/clamonacc, or the Trend Micro agent's `ds_am.log`). CI runs it automatically when the e2e job fails, before the VMs are destroyed. Set `E2E_TM_VM` as for the tests.

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
make env    # creates e2e-1 and e2e-2 (ClamAV), or e2e-1 + prepares $E2E_TM_VM
make clean  # destroys the ClamAV VMs + minikube (never the Trend Micro VM)

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
