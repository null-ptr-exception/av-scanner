# Load Balancing with Istio Gateway

## Rationale

av-scanner runs on bare VMs (not inside Kubernetes), but clients are Kubernetes workloads that authenticate via ServiceAccount tokens. Without a load balancer, clients must pick a specific VM IP, losing redundancy and requiring client-side discovery.

Since production already runs Istio on K8s 1.24, we use the existing Istio ingress gateway as a load balancer in front of the av-scanner VMs. This gives us:

- **Single endpoint** for clients (the gateway) instead of individual VM IPs
- **Round-robin load balancing** across all VMs
- **No additional infrastructure** — reuses the existing Istio installation

## Design

### Resource Placement

The Istio Gateway resource must live in the same namespace as the ingress gateway pods. It is managed outside the Helm chart, typically by the platform team or provisioning scripts.

All other resources are deployed by the Helm chart into the release namespace:

| Resource | Namespace | Purpose |
|---|---|---|
| **Gateway** | Same as ingress gateway pods | Binds the ingress gateway listener on port 80 |
| **ServiceEntry** | Release namespace | Registers external VMs as a mesh service |
| **WorkloadEntry** | Release namespace | Maps each VM IP as an endpoint (one per VM) |
| **VirtualService** | Release namespace | Routes gateway traffic to the ServiceEntry host; references the Gateway cross-namespace via `istio.gatewayRef` |
| **DestinationRule** | Release namespace | Configures round-robin load balancing |

### Host-Based Routing

The Gateway accepts traffic for a wildcard domain (e.g. `*.corp.localhost`), and the VirtualService declares the specific host it serves (e.g. `av-scanner.corp.localhost`). Clients connect using the FQDN, which provides proper host-based routing without custom `Host:` headers.

In testing, `.localhost` domains (RFC 6761) resolve to `127.0.0.1` without DNS configuration:

```bash
curl -4 http://av-scanner.corp.localhost:30080/api/v1/health
```

### Traffic Flow

```text
Client --> http://av-scanner.corp.localhost
               |
               v
         Istio IngressGateway
               |
               v
         Gateway (ingress gateway namespace, hosts: *.corp.localhost)
               |
               v
         VirtualService (release namespace, host: av-scanner.corp.localhost)
               |
               v
         ServiceEntry + WorkloadEntry (release namespace)
               |
               +---> VM1:3000
               +---> VM2:3000
```

### Helm Values

Istio routing is off by default. Enable with:

```yaml
istio:
  enabled: true
  gatewayRef: <gateway-namespace>/av-scanner   # cross-namespace reference to the Gateway
  port: 3000
  serviceHost: av-scanner.corp.localhost        # must match Gateway hosts pattern
  workloadEntries:
  - name: vm1
    address: 192.168.122.178
  - name: vm2
    address: 192.168.122.45
```

The `gatewayRef` value must match `<namespace>/<name>` of the Gateway resource, wherever the platform team has deployed it. The `serviceHost` must match the Gateway's host pattern.

## Implementation

### Gateway (managed separately)

The Gateway must be deployed in the same namespace as the ingress gateway pods. The namespace and selector labels depend on your Istio installation.

```yaml
apiVersion: networking.istio.io/v1beta1
kind: Gateway
metadata:
  name: av-scanner
  namespace: <ingress-gateway-namespace>
spec:
  selector:
    istio: ingressgateway       # must match your ingress gateway pod labels
  servers:
  - port:
      number: 80
      name: http
      protocol: HTTP
    hosts:
    - "*.corp.localhost"          # or your domain pattern
```

### Helm Chart

The chart template (`templates/istio.yaml`) creates ServiceEntry, WorkloadEntry, VirtualService, and DestinationRule when `istio.enabled` is true. WorkloadEntries are generated from the `istio.workloadEntries` list, creating one per VM.

## Verification Results

### Each resource is load-bearing

Tested by deleting each resource individually and observing the result:

| Resource Deleted | HTTP Status | Error |
|---|---|---|
| VirtualService | 404 | No route configured on the gateway |
| ServiceEntry | 503 | Gateway cannot resolve backend service |
| WorkloadEntry (all) | 503 | "no healthy upstream" — no endpoints |

All resources restored successfully after each test.

### Load balancing distributes traffic

10 requests sent through the gateway, counted via `journalctl` on each VM:

| VM | Requests |
|---|---|
| VM1 | 4 |
| VM2 | 6 |

### Auth works through the gateway

| Scenario | Expected | Actual |
|---|---|---|
| Allowed SA token | 200 | 200 |
| No token | 401 | 401 |
| Denied SA token | 403 | 403 |

### Functional endpoints

| Endpoint | Result |
|---|---|
| `GET /api/v1/health` | `{"status":"healthy"}` |
| `POST /api/v1/scan` (clean file) | `{"status":"clean"}` |
| `GET /api/v1/live` (no auth) | `{"alive":true}` |

## Compatibility

- Kubernetes 1.24
- Istio 1.16 (classic Gateway API, not K8s Gateway API)
- Tested with kind cluster and libvirt VMs
