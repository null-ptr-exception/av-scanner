.PHONY: help build push deploy clean test-unit test-e2e test-integration vm-init vm-start vm-stop setup-vm

IMAGE_NAME ?= av-scanner
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
	@echo "  setup-vm   Install ClamAV and registry on VM via Ansible"
	@echo ""
	@echo "Build & Deploy:"
	@echo "  build      Build Docker image containing Go binary"
	@echo "  push       Build and push image to VM registry"
	@echo "  deploy     Build, push, and deploy to VM"
	@echo "  clean      Remove local Docker image"
	@echo ""
	@echo "Testing:"
	@echo "  test-unit        Run unit tests"
	@echo "  test-e2e         Run e2e tests (requires API_URL or VM)"

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

# Install ClamAV on VM via Ansible
setup-vm:
	@if [ ! -f $(STATE_FILE) ]; then echo "Run 'make vm-init' first"; exit 1; fi
	@. ./$(STATE_FILE) && \
	if [ -f venv/bin/activate ]; then . venv/bin/activate; fi && \
	cd ansible && \
	if [ "$$HYPERVISOR" = "multipass" ]; then \
		ansible-playbook setup-vm.yaml -i inventory.yaml \
			-e ansible_host=$$VM_IP; \
	else \
		ansible-playbook setup-vm.yaml -i inventory.yaml \
			-e ansible_host=$$VM_IP \
			-e ansible_port=$$SSH_PORT \
			-e ansible_ssh_private_key_file=$(CURDIR)/.ssh/id_ed25519; \
	fi

# ============================================
# Build
# ============================================

# Build the container image (contains Go binary)
build:
	podman build \
		--build-arg VERSION=$(VERSION) \
		--build-arg COMMIT=$(COMMIT) \
		-t $(IMAGE_NAME):$(IMAGE_TAG) .

# Push image to VM registry
push: build
	@if [ ! -f $(STATE_FILE) ]; then echo "Run 'make vm-init' first"; exit 1; fi
	@. ./$(STATE_FILE) && \
	if [ "$$HYPERVISOR" = "multipass" ]; then \
		REGISTRY=$$VM_IP:5000; \
	else \
		REGISTRY=localhost:$$REGISTRY_PORT; \
	fi && \
	echo "Pushing to $$REGISTRY..." && \
	podman push --tls-verify=false $(IMAGE_NAME):$(IMAGE_TAG) $$REGISTRY/$(IMAGE_NAME):$(IMAGE_TAG)

# ============================================
# Deploy
# ============================================

# Deploy to VM using Ansible (pulls from registry)
deploy: push
	@if [ ! -f $(STATE_FILE) ]; then echo "Run 'make vm-init' first"; exit 1; fi
	@. ./$(STATE_FILE) && \
	if [ -f venv/bin/activate ]; then . venv/bin/activate; fi && \
	cd ansible && \
	if [ "$$HYPERVISOR" = "multipass" ]; then \
		ansible-playbook deploy.yaml -i inventory.yaml \
			-e ansible_host=$$VM_IP \
			-e image_name=$(IMAGE_NAME) \
			-e image_tag=$(IMAGE_TAG); \
	else \
		ansible-playbook deploy.yaml -i inventory.yaml \
			-e ansible_host=$$VM_IP \
			-e ansible_port=$$SSH_PORT \
			-e ansible_ssh_private_key_file=$(CURDIR)/.ssh/id_ed25519 \
			-e image_name=$(IMAGE_NAME) \
			-e image_tag=$(IMAGE_TAG); \
	fi

# Clean up build artifacts
clean:
	podman rmi $(IMAGE_NAME):$(IMAGE_TAG) 2>/dev/null || true

# ============================================
# Testing
# ============================================

# Run unit tests
test-unit:
	go test -race ./...

# Run e2e tests (requires running server)
test-e2e:
	bats test/e2e/

# Alias for backwards compat
test-integration: test-e2e

