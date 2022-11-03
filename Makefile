SHELL ?= /bin/bash

OS := $(shell uname -s | tr '[:upper:]' '[:lower:]')
ARCH := $(shell uname -m | sed 's/x86_64/amd64/')

LOCALBIN ?= ${PWD}/bin
export PATH := $(LOCALBIN):$(PATH)

##@ Install kcp

KCP_VERSION ?= 0.9.1
KCP_DOWNLOAD_URL ?= https://github.com/kcp-dev/kcp/releases/download/v$(KCP_VERSION)/kcp_$(KCP_VERSION)_linux_amd64.tar.gz
KCP_PLUGIN_DOWNLOAD_URL ?= https://github.com/kcp-dev/kcp/releases/download/v$(KCP_VERSION)/kubectl-kcp-plugin_$(KCP_VERSION)_linux_amd64.tar.gz
KCP_BIN ?= $(LOCALBIN)/kcp
KCP_PLUGIN_BIN ?= $(LOCALBIN)/kubectl-kcp-plugin

bin:
	mkdir -p $(LOCALBIN)

tmp:
	mkdir -p tmp

kcp: $(KCP_BIN)
$(KCP_BIN): bin
	curl -sL $(KCP_DOWNLOAD_URL) | tar xvz bin/kcp

kubectl-kcp-plugin: $(KCP_PLUGIN_BIN)
$(KCP_PLUGIN_BIN): bin
	curl -sL $(KCP_PLUGIN_DOWNLOAD_URL) | tar xvz

##@ Install kind and kcp
KIND ?= $(LOCALBIN)/kind
KIND_VERSION ?= v0.16.0
K8S_VERSION ?= 1.23.12

.PHONY: kind
KIND = $(shell pwd)/bin/kind
kind: $(KIND) ## Download kind locally if necessary
$(KIND):
	test -s $(KIND) || GOBIN=$(LOCALBIN) go install sigs.k8s.io/kind@$(KIND_VERSION)

KCP_ADMIN_KUBECONFIG ?= $(PWD)/.kcp/admin.kubeconfig
KIND_ADMIN_KUBECONFIG ?= $(PWD)/.kind/kubeconfig
start: tmp kcp kubectl-kcp-plugin kind
	nohup kcp start > tmp/kcp.log 2>&1 &
	mkdir -p .kind
	KUBECONFIG=$(KIND_ADMIN_KUBECONFIG) $(KIND) create cluster --wait 5m --config kind.yaml --image kindest/node:v${K8S_VERSION}
	KUBECONFIG=$(KCP_ADMIN_KUBECONFIG) kubectl kcp workspace create test --type universal --enter
	KUBECONFIG=$(KCP_ADMIN_KUBECONFIG) kubectl kcp workload sync test \
		--resources deployments.apps,pods \
		--syncer-image ghcr.io/kcp-dev/kcp/syncer:v${KCP_VERSION} -o tmp/syncer-test.yaml
	KUBECONFIG=$(KIND_ADMIN_KUBECONFIG) kubectl apply -f tmp/syncer-test.yaml
	KUBECONFIG=$(KCP_ADMIN_KUBECONFIG) kubectl annotate --overwrite synctarget test \
		featuregates.experimental.workload.kcp.dev/advancedscheduling='true'

stop:
	kind delete cluster --name=kind || true
	pkill -TERM kcp || true
	rm -rf .kcp

clean:
	rm -rf tmp bin .kind .kcp

##@ Install argocd and configure the root:test workspace
ARGOCD ?= $(LOCALBIN)/argocd
ARGOCD_VERSION ?= v2.4.12
ARGOCD_DOWNLOAD_URL ?= https://github.com/argoproj/argo-cd/releases/download/v2.4.13/argocd-$(OS)-$(ARCH)
argocd: $(ARGOCD) ## Download argocd CLI locally if necessary
$(ARGOCD):
	curl -sL $(ARGOCD_DOWNLOAD_URL) -o $(ARGOCD)
	chmod +x $(ARGOCD)

KUSTOMIZE ?= $(LOCALBIN)/kustomize
KUSTOMIZE_VERSION ?= v4.5.4
KUSTOMIZE_INSTALL_SCRIPT ?= "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh"
.PHONY: kustomize
kustomize: $(KUSTOMIZE) ## Download kustomize locally if necessary.
$(KUSTOMIZE):
	curl -s $(KUSTOMIZE_INSTALL_SCRIPT) | bash -s -- $(subst v,,$(KUSTOMIZE_VERSION)) $(LOCALBIN)

YQ_VERSION ?= v4.28.1
YQ ?= $(LOCALBIN)/yq
YQ_DOWNLOAD_URL ?= https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_$(OS)_$(ARCH)
yq: $(YQ) ## Download yq locally if necessary
$(YQ):
	curl -sL $(YQ_DOWNLOAD_URL) -o $(YQ)
	chmod +x $(YQ)

ARGOCD_PASSWD = $(shell kubectl --kubeconfig=$(KIND_ADMIN_KUBECONFIG) -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
argocd-password:
	@echo $(ARGOCD_PASSWD)
argocd-login:
	$(ARGOCD) login localhost:8080 --insecure --username admin --password $(ARGOCD_PASSWD)

argocd-setup: export KUBECONFIG=$(KIND_ADMIN_KUBECONFIG)
argocd-setup: kustomize
	$(KUSTOMIZE) build argocd/argocd-install | kubectl apply -f -
	kubectl -n argocd wait deployment argocd-server --for condition=Available=True --timeout=90s
	kubectl port-forward svc/argocd-server -n argocd 8080:80 > /dev/null  2>&1 &
	make argocd-login
	$(ARGOCD) cluster add workspace.kcp.dev/current --name root:test --kubeconfig $(KCP_ADMIN_KUBECONFIG) --system-namespace default --yes
	pkill kubectl

argocd-port-forward:
	kubectl --kubeconfig $(KIND_ADMIN_KUBECONFIG) port-forward svc/argocd-server -n argocd 8080:80

argocd-test-resource-customizations: kustomize yq argocd
	cd argocd/argocd-install/resource-customizations && go test
