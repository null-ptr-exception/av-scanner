# AV Scanner Deployer
# Bundles: Go binary + ansible + kubectl + molecule
# Runs as a K8s CronJob or controller Deployment

FROM docker.io/library/golang:1.23-alpine AS builder

ARG VERSION=dev
ARG COMMIT=unknown

WORKDIR /app

RUN apk add --no-cache git

COPY . .

RUN go mod tidy
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build \
    -ldflags="-w -s \
        -X github.com/rophy/av-scanner/internal/version.Version=${VERSION} \
        -X github.com/rophy/av-scanner/internal/version.Commit=${COMMIT} \
        -X github.com/rophy/av-scanner/internal/version.BuildTime=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    -o av-scanner \
    main.go

FROM docker.io/library/python:3.12-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    openssh-client curl ca-certificates && \
    rm -rf /var/lib/apt/lists/*

ARG ANSIBLE_CORE_VERSION=2.20.5
ARG ANSIBLE_POSIX_VERSION=2.1.0
ARG KUBECTL_VERSION=v1.36.0
ARG NODE_EXPORTER_VERSION=1.9.0

RUN pip install --no-cache-dir "ansible-core==${ANSIBLE_CORE_VERSION}" molecule && \
    ansible-galaxy collection install -p /usr/share/ansible/collections "ansible.posix:${ANSIBLE_POSIX_VERSION}"

RUN curl -fsSLO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" && \
    curl -fsSLO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl.sha256" && \
    echo "$(cat kubectl.sha256)  kubectl" | sha256sum -c - && \
    chmod +x kubectl && mv kubectl /usr/local/bin/ && \
    rm kubectl.sha256

RUN curl -fsSL "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz" | \
    tar xz --strip-components=1 -C /usr/local/bin "node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64/node_exporter"

WORKDIR /app

COPY --from=builder /app/av-scanner /app/av-scanner
RUN cp /usr/local/bin/node_exporter /app/node_exporter
COPY ansible/ansible.cfg /app/ansible/
COPY ansible/playbooks/ /app/ansible/playbooks/
COPY ansible/roles/ /app/ansible/roles/
COPY docker/entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

WORKDIR /app/ansible
ENTRYPOINT ["/app/entrypoint.sh"]
