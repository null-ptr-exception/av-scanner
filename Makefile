.PHONY: help env deploy clean test-unit test-helm test-molecule test-e2e test-perf

MINIKUBE_PROFILE ?= av-scanner

help: ## Show this help
	@grep -E '^[a-zA-Z0-9_-]+:.*## ' $(MAKEFILE_LIST) | sed 's/:.*## /\t/' | awk -F '\t' '{printf "  %-16s %s\n", $$1, $$2}'

# ============================================
# Environment
# ============================================

env: ## Create VMs + minikube + Istio + kfa (full dev environment)
	@if virsh --connect qemu:///system dominfo e2e-1 >/dev/null 2>&1 && \
	    virsh --connect qemu:///system dominfo e2e-2 >/dev/null 2>&1; then \
		echo "VMs e2e-1 and e2e-2 already exist"; \
	else \
		./scripts/vm-init.sh --name e2e --count 2 --force; \
	fi
	@if minikube status --profile $(MINIKUBE_PROFILE) >/dev/null 2>&1; then \
		echo "Minikube profile $(MINIKUBE_PROFILE) already running"; \
	else \
		minikube start --profile $(MINIKUBE_PROFILE) \
			--driver=docker \
			--kubernetes-version=v1.24.17 \
			--ports=30080:30080,30082:30082,30090:30090 \
			--wait=apiserver \
			--force; \
	fi
	kubectl config use-context $(MINIKUBE_PROFILE)
	@kubectl --context $(MINIKUBE_PROFILE) create namespace av-scanner 2>/dev/null || true
	@kubectl --context $(MINIKUBE_PROFILE) -n av-scanner get secret av-scanner-ssh-key >/dev/null 2>&1 || \
		kubectl --context $(MINIKUBE_PROFILE) -n av-scanner create secret generic av-scanner-ssh-key \
			--from-file=id_ed25519=.vms/id_ed25519
	@VM1_IP=$$(virsh --connect qemu:///system domifaddr e2e-1 | grep -oP '(\d+\.){3}\d+' | head -1); \
	VM2_IP=$$(virsh --connect qemu:///system domifaddr e2e-2 | grep -oP '(\d+\.){3}\d+' | head -1); \
	printf '%s\n' \
		"sshKey:" \
		"  existingSecret: av-scanner-ssh-key" \
		"" \
		"controller:" \
		"  extraEnv:" \
		"    - name: AV_SCANNER_VM1_IP" \
		"      value: \"$$VM1_IP\"" \
		"    - name: AV_SCANNER_VM2_IP" \
		"      value: \"$$VM2_IP\"" \
		"" \
		"inventory: |" \
		"  all:" \
		"    vars:" \
		'      ansible_ssh_common_args: "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"' \
		"      ansible_ssh_private_key_file: /ssh/id_ed25519" \
		"    children:" \
		"      av_scanner:" \
		"        hosts:" \
		"          vm1:" \
		"            ansible_host: $$VM1_IP" \
		"            ansible_user: ubuntu" \
		"          vm2:" \
		"            ansible_host: $$VM2_IP" \
		"            ansible_user: ubuntu" \
		> skaffold-values.yaml; \
	echo "  Generated skaffold-values.yaml"
	# --- Istio ---
	@if ! kubectl --context $(MINIKUBE_PROFILE) get ns istio-system >/dev/null 2>&1; then \
		echo "Installing Istio..."; \
		istioctl install --context $(MINIKUBE_PROFILE) --set profile=default \
			--set values.gateways.istio-ingressgateway.type=NodePort -y; \
	else \
		echo "Istio already installed"; \
	fi
	@HTTP_IDX=$$(kubectl --context $(MINIKUBE_PROFILE) -n istio-system get svc istio-ingressgateway -o json \
		| jq '.spec.ports | map(.port) | index(80)'); \
	if [ "$$HTTP_IDX" != "null" ] && [ -n "$$HTTP_IDX" ]; then \
		kubectl --context $(MINIKUBE_PROFILE) -n istio-system patch svc istio-ingressgateway --type=json \
			-p="[{\"op\":\"replace\",\"path\":\"/spec/ports/$$HTTP_IDX/nodePort\",\"value\":30080}]"; \
	else \
		echo "ERROR: HTTP port 80 not found on istio-ingressgateway"; exit 1; \
	fi
	kubectl --context $(MINIKUBE_PROFILE) -n istio-system rollout status deployment/istio-ingressgateway --timeout=60s
	kubectl --context $(MINIKUBE_PROFILE) apply -f test/istio-gateway.yaml
	# --- virbr0 route (minikube node → VMs) ---
	@VIRBR0_SUBNET=$$(ip -4 route show dev virbr0 proto kernel | awk '{print $$1}'); \
	if [ -n "$$VIRBR0_SUBNET" ]; then \
		HOST_GW=$$(docker exec $(MINIKUBE_PROFILE) ip route | awk '/default/{print $$3}'); \
		if [ -n "$$HOST_GW" ]; then \
			docker exec $(MINIKUBE_PROFILE) ip route show "$$VIRBR0_SUBNET" | grep -q "via $$HOST_GW" \
				|| docker exec $(MINIKUBE_PROFILE) ip route add "$$VIRBR0_SUBNET" via "$$HOST_GW"; \
			docker exec $(MINIKUBE_PROFILE) iptables -t nat -C POSTROUTING -d "$$VIRBR0_SUBNET" -j MASQUERADE 2>/dev/null \
				|| docker exec $(MINIKUBE_PROFILE) iptables -t nat -A POSTROUTING -d "$$VIRBR0_SUBNET" -j MASQUERADE; \
			echo "  Route: $$VIRBR0_SUBNET via $$HOST_GW in minikube node"; \
		fi; \
	fi
	# --- kube-federated-auth ---
	@KFA_IMAGE="ghcr.io/rophy/kube-federated-auth:3.4.2"; \
	if ! docker image inspect "$$KFA_IMAGE" >/dev/null 2>&1; then \
		if [ -d "../kube-federated-auth" ]; then \
			echo "Building $$KFA_IMAGE from local source..."; \
			docker build -t "$$KFA_IMAGE" ../kube-federated-auth; \
		else \
			echo "Pulling $$KFA_IMAGE..."; \
			docker pull "$$KFA_IMAGE"; \
		fi; \
	fi; \
	minikube image load "$$KFA_IMAGE" --profile $(MINIKUBE_PROFILE)
	kubectl --context $(MINIKUBE_PROFILE) apply -f test/kube-federated-auth.yaml
	kubectl --context $(MINIKUBE_PROFILE) rollout status deployment/kube-federated-auth -n kube-federated-auth --timeout=120s
	# --- Summary ---
	@VM1_IP=$$(virsh --connect qemu:///system domifaddr e2e-1 | grep -oP '(\d+\.){3}\d+' | head -1); \
	VM2_IP=$$(virsh --connect qemu:///system domifaddr e2e-2 | grep -oP '(\d+\.){3}\d+' | head -1); \
	echo ""; \
	echo "Environment ready:"; \
	echo "  kubectl context: $(MINIKUBE_PROFILE)"; \
	echo "  e2e-1: $$VM1_IP"; \
	echo "  e2e-2: $$VM2_IP"

deploy: ## Build deployer image and deploy via Helm (skaffold run)
	skaffold run --kube-context $(MINIKUBE_PROFILE)

clean: ## Delete minikube cluster and VMs
	minikube delete --profile $(MINIKUBE_PROFILE) || true
	./scripts/vm-destroy.sh --name e2e --count 2 || true
	rm -f skaffold-values.yaml .e2e-values.yaml

# ============================================
# Testing
# ============================================

test-unit: ## Run Go unit tests
	go test ./...

test-helm: ## Helm lint + unittest
	helm lint charts/av-scanner --set sshKey.existingSecret=test
	helm unittest charts/av-scanner

test-molecule: ## Run Molecule tests in controller pod (requires: make deploy)
	kubectl --context $(MINIKUBE_PROFILE) -n av-scanner exec deploy/av-scanner-controller -- \
		bash -c "cd /app/ansible/roles/av-scanner && molecule test"

test-e2e: ## Run BATS e2e tests (requires: make env)
	mkdir -p test-results
	bats --formatter tap --report-formatter junit --output test-results \
		--print-output-on-failure --show-output-of-passing-tests --verbose-run -x test/e2e/

test-perf: ## Run k6 load tests
	./scripts/perf-test.sh
