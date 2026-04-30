.PHONY: help build build-deploy deploy clean test-unit test-e2e test-perf test-integration vm-init vm-start vm-stop setup-node-exporter

IMAGE_NAME ?= av-scanner
DEPLOY_IMAGE_NAME ?= av-scanner-deploy
VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo "dev")
COMMIT ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo "unknown")
IMAGE_TAG ?= $(VERSION)
VM_NAME ?= av-scanner
STATE_FILE ?= .vm-state

help:
	@echo "Usage: make <target>"
	@echo ""
	@echo "VM Management:"
	@echo "  vm-init    Create VM (prompts for hypervisor if both available)"
	@echo "             Use HYPERVISOR=qemu or HYPERVISOR=multipass to skip prompt"
	@echo "  vm-start   Start existing VM"
	@echo "  vm-stop    Stop VM"
	@echo "  setup-node-exporter  Install Prometheus node_exporter on VM"
	@echo ""
	@echo "Build & Deploy:"
	@echo "  build          Build image containing Go binary (for local dev)"
	@echo "  build-deploy   Build deployer image (binary + ansible + kubectl)"
	@echo "  deploy         Build binary and deploy to VM via ansible"
	@echo "  clean          Remove local images"
	@echo ""
	@echo "Testing:"
	@echo "  test-unit        Run unit tests"
	@echo "  test-e2e         Run e2e tests (requires API_URL or VM)"
	@echo "  test-perf        Run k6 load tests with Prometheus metrics report"

# ============================================
# VM Management
# ============================================

# Create VM (auto-detects hypervisor, or use HYPERVISOR=qemu|multipass)
vm-init:
ifdef HYPERVISOR
	./scripts/vm-init.sh --hypervisor $(HYPERVISOR)
else
	./scripts/vm-init.sh
endif

# Start existing VM
vm-start:
	./scripts/vm-start.sh

# Stop VM
vm-stop:
	@if [ -f $(STATE_FILE) ]; then \
		. ./$(STATE_FILE) || { echo "Error: malformed .vm-state file"; exit 1; }; \
		if [ -z "$$HYPERVISOR" ] || [ -z "$$VM_NAME" ]; then \
			echo "Error: invalid .vm-state (missing HYPERVISOR or VM_NAME)"; exit 1; \
		fi; \
		if [ "$$HYPERVISOR" = "multipass" ]; then \
			multipass stop $$VM_NAME; \
		else \
			if [ -f "$$QEMU_DIR/$$VM_NAME.pid" ]; then \
				pkill -F "$$QEMU_DIR/$$VM_NAME.pid" 2>/dev/null || true; \
				rm -f "$$QEMU_DIR/$$VM_NAME.pid"; \
			fi; \
		fi; \
		echo "VM stopped"; \
	else \
		echo "No VM state found"; \
	fi

# Install node_exporter on VM
setup-node-exporter:
	@if [ ! -f $(STATE_FILE) ]; then echo "Run 'make vm-init' first"; exit 1; fi
	@. ./$(STATE_FILE) && \
	if [ -f venv/bin/activate ]; then . venv/bin/activate; fi && \
	cd ansible && \
	if [ "$$HYPERVISOR" = "multipass" ]; then \
		ansible-playbook node-exporter.yaml -i inventory.yaml \
			-e ansible_host=$$VM_IP; \
	else \
		ansible-playbook node-exporter.yaml -i inventory.yaml \
			-e ansible_host=$$VM_IP \
			-e ansible_port=$$SSH_PORT \
			-e ansible_ssh_private_key_file=$(CURDIR)/.ssh/id_ed25519; \
	fi

# ============================================
# Build
# ============================================

# Build the binary-only image (for local dev / extraction)
build:
	podman build \
		--build-arg VERSION=$(VERSION) \
		--build-arg COMMIT=$(COMMIT) \
		-t $(IMAGE_NAME):$(IMAGE_TAG) .

# Build the deployer image (binary + ansible + kubectl)
build-deploy:
	podman build \
		-f deploy/Dockerfile \
		--build-arg VERSION=$(VERSION) \
		--build-arg COMMIT=$(COMMIT) \
		-t $(DEPLOY_IMAGE_NAME):$(IMAGE_TAG) .

# ============================================
# Deploy
# ============================================

# Build Go binary locally and deploy to VM via ansible
deploy:
	@if [ ! -f $(STATE_FILE) ]; then echo "Run 'make vm-init' first"; exit 1; fi
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build \
		-ldflags="-w -s \
			-X github.com/rophy/av-scanner/internal/version.Version=$(VERSION) \
			-X github.com/rophy/av-scanner/internal/version.Commit=$(COMMIT) \
			-X github.com/rophy/av-scanner/internal/version.BuildTime=$$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		-o /tmp/av-scanner main.go
	@. ./$(STATE_FILE) && \
	if [ -f venv/bin/activate ]; then . venv/bin/activate; fi && \
	cd ansible && \
	if [ "$$HYPERVISOR" = "multipass" ]; then \
		ansible-playbook deploy.yaml -i inventory.yaml \
			-e ansible_host=$$VM_IP \
			-e binary_path=/tmp/av-scanner; \
	else \
		ansible-playbook deploy.yaml -i inventory.yaml \
			-e ansible_host=$$VM_IP \
			-e ansible_port=$$SSH_PORT \
			-e ansible_ssh_private_key_file=$(CURDIR)/.ssh/id_ed25519 \
			-e binary_path=/tmp/av-scanner; \
	fi

# Clean up build artifacts
clean:
	podman rmi $(IMAGE_NAME):$(IMAGE_TAG) 2>/dev/null || true
	podman rmi $(DEPLOY_IMAGE_NAME):$(IMAGE_TAG) 2>/dev/null || true

# ============================================
# Testing
# ============================================

# Run unit tests
test-unit:
	go test -race ./...

# Run e2e tests (requires running server)
test-e2e:
	bats test/e2e/

# Run k6 load tests with Prometheus metrics report
test-perf:
	./scripts/perf-test.sh

# Alias for backwards compat
test-integration: test-e2e

