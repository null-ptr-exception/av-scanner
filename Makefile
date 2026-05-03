.PHONY: help build build-deploy deploy clean test-unit test-helm test-molecule test-e2e test-perf test-integration vm-init vm-start vm-stop vm-destroy

IMAGE_NAME ?= av-scanner
DEPLOY_IMAGE_NAME ?= av-scanner-deploy
VERSION ?= $(shell git describe --tags --always --dirty || echo "dev")
COMMIT ?= $(shell git rev-parse --short HEAD || echo "unknown")
IMAGE_TAG ?= $(VERSION)
VM_NAME ?= av-scanner

help:
	@echo "Usage: make <target>"
	@echo ""
	@echo "VM Management:"
	@echo "  vm-init      Create VM (--name, --count, --force supported)"
	@echo "  vm-start     Start existing VM"
	@echo "  vm-stop      Graceful shutdown"
	@echo "  vm-destroy   Destroy VM and remove disk"
	@echo ""
	@echo "Build & Deploy:"
	@echo "  build          Build image containing Go binary (for local dev)"
	@echo "  build-deploy   Build deployer image (binary + ansible + kubectl)"
	@echo "  deploy         Build binary and deploy to VM via ansible"
	@echo "  clean          Remove local images"
	@echo ""
	@echo "Testing:"
	@echo "  test-unit        Run unit tests"
	@echo "  test-helm        Run Helm chart lint and unit tests"
	@echo "  test-molecule    Run Molecule tests (requires VMs: vm-init --name molecule --count 2)"
	@echo "  test-e2e         Run e2e tests (requires VMs: vm-init --name e2e --count 2)"
	@echo "  test-perf        Run k6 load tests with Prometheus metrics report"

# ============================================
# VM Management
# ============================================

vm-init:
	./scripts/vm-init.sh

vm-start:
	./scripts/vm-start.sh $(VM_NAME)

vm-stop:
	virsh --connect qemu:///system shutdown $(VM_NAME) || echo "VM $(VM_NAME) not found"

vm-destroy:
	./scripts/vm-destroy.sh --name $(VM_NAME)

# ============================================
# Build
# ============================================

build:
	podman build \
		--build-arg VERSION=$(VERSION) \
		--build-arg COMMIT=$(COMMIT) \
		-t $(IMAGE_NAME):$(IMAGE_TAG) .

build-deploy:
	podman build \
		-f docker/Dockerfile \
		--build-arg VERSION=$(VERSION) \
		--build-arg COMMIT=$(COMMIT) \
		-t $(DEPLOY_IMAGE_NAME):$(IMAGE_TAG) .

# ============================================
# Deploy
# ============================================

deploy:
	@VM_IP=$$(virsh --connect qemu:///system domifaddr $(VM_NAME) | grep -oP '(\d+\.){3}\d+' | head -1); \
	if [ -z "$$VM_IP" ]; then echo "VM '$(VM_NAME)' not running. Run 'make vm-init' first."; exit 1; fi; \
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build \
		-ldflags="-w -s \
			-X github.com/rophy/av-scanner/internal/version.Version=$(VERSION) \
			-X github.com/rophy/av-scanner/internal/version.Commit=$(COMMIT) \
			-X github.com/rophy/av-scanner/internal/version.BuildTime=$$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		-o /tmp/av-scanner main.go && \
	if [ -f venv/bin/activate ]; then . venv/bin/activate; fi && \
	cd ansible && \
	ansible-playbook playbooks/deploy.yaml -i inventories/inventory.yaml \
		-e ansible_host=$$VM_IP \
		-e ansible_ssh_private_key_file=.vms/id_ed25519 \
		-e binary_path=/tmp/av-scanner

clean:
	podman rmi $(IMAGE_NAME):$(IMAGE_TAG) || true
	podman rmi $(DEPLOY_IMAGE_NAME):$(IMAGE_TAG) || true

# ============================================
# Testing
# ============================================

test-unit:
	go test -race ./...

test-helm:
	helm lint charts/av-scanner
	helm unittest charts/av-scanner

NODE_EXPORTER_VERSION ?= 1.9.0

test-molecule:
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o /tmp/av-scanner main.go
	@if [ ! -f /tmp/node_exporter ]; then \
		echo "Downloading node_exporter $(NODE_EXPORTER_VERSION)..."; \
		curl -fsSL "https://github.com/prometheus/node_exporter/releases/download/v$(NODE_EXPORTER_VERSION)/node_exporter-$(NODE_EXPORTER_VERSION).linux-amd64.tar.gz" | \
			tar xz --strip-components=1 -C /tmp "node_exporter-$(NODE_EXPORTER_VERSION).linux-amd64/node_exporter"; \
	fi
	cd ansible/roles/av-scanner && \
		MOLECULE_SSH_KEY=$(CURDIR)/.vms/id_ed25519 \
		MOLECULE_VM1_IP=$$(virsh --connect qemu:///system domifaddr molecule-1 | grep -oP '(\d+\.){3}\d+' | head -1) \
		MOLECULE_VM2_IP=$$(virsh --connect qemu:///system domifaddr molecule-2 | grep -oP '(\d+\.){3}\d+' | head -1) \
		MOLECULE_AV_SCANNER_BINARY=/tmp/av-scanner \
		MOLECULE_NODE_EXPORTER_BINARY=/tmp/node_exporter \
		molecule test -s default

test-e2e:
	bats --show-output-of-passing-tests test/e2e/

test-perf:
	./scripts/perf-test.sh

test-integration: test-e2e
