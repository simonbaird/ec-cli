MAKEFLAGS+=-j --no-print-directory
VERSION_FILE=./VERSION
VERSION:=v$$(cat $(VERSION_FILE)).$$(git rev-list --count HEAD)-$$(git rev-parse --short HEAD)
# a list of "dist/ec_{platform}_{arch}" that we support
ALL_SUPPORTED_OS_ARCH:=$(shell go tool dist list -json|jq -r '.[] | select((.FirstClass == true or .GOARCH == "ppc64le") and .GOARCH != "386") | "dist/ec_\(.GOOS)_\(.GOARCH)"')
# a list of image_* targets that we do not support
UNSUPPORTED_OS_ARCH_IMG:=image_windows_amd64 image_darwin_amd64 image_darwin_arm64 image_linux_arm
# a list of image_* targets that we do support generated from
# ALL_SUPPORTED_OS_ARCH by replacing "dist/ec_" with "image_"
ALL_SUPPORTED_IMG_OS_ARCH:=$(filter-out $(UNSUPPORTED_OS_ARCH_IMG),$(subst dist/ec_,image_,$(ALL_SUPPORTED_OS_ARCH)))
_SHELL := bash
SHELL=$(if $@,$(info ❱ [1m$@[0m))$(_SHELL)
ROOT_DIR:=$(shell dirname $(realpath $(firstword $(MAKEFILE_LIST))))
COPY:=The Enterprise Contract Contributors
COSIGN_VERSION=$(shell go list -f '{{.Version}}' -m github.com/sigstore/cosign/v2)

##@ Information

.PHONY: help
help: ## Display this help
	@awk 'function ww(s) {\
		if (length(s) < 59) {\
			return s;\
		}\
		else {\
			r="";\
			l="";\
			split(s, arr, " ");\
			for (w in arr) {\
				if (length(l " " arr[w]) > 59) {\
					r=r l "\n                     ";\
					l="";\
				}\
				l=l " " arr[w];\
			}\
			r=r l;\
			return r;\
		}\
	} BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9%/_-]+:.*?##/ { printf "  \033[36m%-18s\033[0m %s\n", "make " $$1, ww($$2) } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

##@ Building

.PHONY: generate
generate: ## Code-generate files
	go generate ./...

.PHONY: $(ALL_SUPPORTED_OS_ARCH)
$(ALL_SUPPORTED_OS_ARCH): generate ## Build binaries for specific platform/architecture, e.g. make dist/ec_linux_amd64
	@GOOS=$(word 2,$(subst _, ,$(notdir $@))); \
	GOARCH=$(word 3,$(subst _, ,$(notdir $@))); \
	GOOS=$${GOOS} GOARCH=$${GOARCH} CGO_ENABLED=0 go build -trimpath -ldflags="-s -w -X github.com/enterprise-contract/ec-cli/internal/version.Version=$(VERSION)" -o dist/ec_$${GOOS}_$${GOARCH}; \
	sha256sum -b dist/ec_$${GOOS}_$${GOARCH} > dist/ec_$${GOOS}_$${GOARCH}.sha256

.PHONY: dist
dist: $(ALL_SUPPORTED_OS_ARCH) ## Build binaries for all supported operating systems and architectures

# Dockerfile.dist is used by the Konflux build pipeline where it's built using
# buildah not podman. This is for testing that build locally.
# Todo: Don't hard code the platform here. Should probably do multi-arch builds similar
# to dist-image. Also, why not use buildah here for consistency with the Konflux build?
.PHONY: dist-container
dist-container: clean
	podman build . --file Dockerfile.dist --tag dist-container --platform linux/amd64 # --no-cache

# For local debugging of the above
dist-container-run:
	podman run --rm -it --entrypoint=/bin/bash dist-container

BUILD_LOCAL_ARCH:=$(shell go env GOOS)_$(shell go env GOARCH)
.PHONY: build
build: dist/ec_$(BUILD_LOCAL_ARCH) ## Build the ec binary for the current platform
	@ln -sf ec_$(BUILD_LOCAL_ARCH) dist/ec

BUILD_IMG_ARCH:=$(shell podman version -f {{.Server.OsArch}} | awk -F/ '{print $$1}')_$(shell podman version -f {{.Server.OsArch}} | awk -F/ '{print $$2}')
.PHONY: build-for-test
build-for-test: dist/ec_$(BUILD_IMG_ARCH)

.PHONY: clean
clean: ## Delete build output
	@rm -f dist/*

##@ Testing

.PHONY: test
test: ## Run all unit tests
	@echo "Unit tests:"
	@go test -race -covermode=atomic -coverprofile=coverage-unit.out -timeout 1s -tags=unit ./...
	@echo "Integration tests:"
	@go test -race -covermode=atomic -coverprofile=coverage-integration.out -timeout 15s -tags=integration ./... | grep -v '\[no test files\]'
# Given the nature of generative tests the test timeout is increased from 500ms
# to 30s to accommodate many samples being generated and test cases being run.
	@echo "Generative tests:"
	@go test -race -covermode=atomic -coverprofile=coverage-generative.out -timeout 30s -tags=generative ./... | grep -v '\[no test files\]'

ACCEPTANCE_TIMEOUT:=20m
.ONESHELL:
.SHELLFLAGS=-e -c
.PHONY: acceptance
acceptance: ## Run all acceptance tests
	@ACCEPTANCE_WORKDIR="$$(mktemp -d)"
	@function cleanup() {
	  cp "$${ACCEPTANCE_WORKDIR}"/features/__snapshots__/* "$(ROOT_DIR)"/features/__snapshots__/
	  #rm -rf "$${ACCEPTANCE_WORKDIR}"
	}
	@trap cleanup EXIT
	@cp -R . "$${ACCEPTANCE_WORKDIR}"
	@cd "$${ACCEPTANCE_WORKDIR}"
	@go run acceptance/coverage/coverage.go
	@$(MAKE) build
	@export COVERAGE_FILEPATH="$${ACCEPTANCE_WORKDIR}"
	@export COVERAGE_FILENAME="-acceptance"
	@cd acceptance && go test -timeout $(ACCEPTANCE_TIMEOUT) ./...
	@go run -modfile "$${ACCEPTANCE_WORKDIR}/tools/go.mod" github.com/wadey/gocovmerge "$${ACCEPTANCE_WORKDIR}"/coverage-acceptance*.out > "$(ROOT_DIR)/coverage-acceptance.out"

# Add @focus above the feature you're hacking on to use this
# (Mainly for use with the feature-% target below)
.PHONY: focus-acceptance
focus-acceptance: build ## Run acceptance tests with @focus tag
	@cd acceptance && go test -tags=acceptance . -args -tags=@focus

# Uses sed hackery to insert a @focus tag and then remove it afterwards.
# (There might be a nicer way to run all scenarios in a single feature.)
# The `|| true` here is so the @focus tag still gets removed after a failure.
feature_%: ## Run acceptance tests for a single feature file, e.g. make feature_validate_image
	@echo "Testing feature '$*'"
	@sed -i '1i@focus' features/$*.feature
	@$(MAKE) focus-acceptance || true
	@sed -i '1d' features/$*.feature

# (Replace spaces with underscores in the scenario name.)
scenario_%: build ## Run acceptance tests for a single scenario, e.g. make scenario_inline_policy
	@cd acceptance && go test -test.run 'TestFeatures/$*'

.PHONY: ci
ci: test lint-fix acceptance ## Run the usual required CI tasks

##@ Linters

LICENSE_IGNORE=\
-ignore 'dist/cli-reference/*.yaml' \
-ignore 'acceptance/examples/*.yaml' \
-ignore 'configs/*/*.yaml' \
-ignore 'node_modules/**' \
-ignore 'hack/**/charts/**' \
-ignore '.tekton/*.yaml'

LINT_TO_GITHUB_ANNOTATIONS='map(map(.)[])[][] as $$d | $$d.posn | split(":") as $$posn | "::warning file=\($$posn[0]),line=\($$posn[1]),col=\($$posn[2])::\($$d.message)"'

.PHONY: lint
lint: tekton-lint go-mod-lint ## Run linter
# addlicense doesn't give us a nice explanation so we prefix it with one
	@go run -modfile tools/go.mod github.com/google/addlicense -c '$(COPY)' -y '' -s -check $(LICENSE_IGNORE) . | sed 's/^/Missing license header in: /g'
# piping to sed above looses the exit code, luckily addlicense is fast so we invoke it for the second time to exit 1 in case of issues
	@go run -modfile tools/go.mod github.com/google/addlicense -c '$(COPY)' -y '' -s -check $(LICENSE_IGNORE) . >/dev/null 2>&1
	@go run -modfile tools/go.mod github.com/golangci/golangci-lint/cmd/golangci-lint run --sort-results $(if $(GITHUB_ACTIONS), --out-format=github-actions --timeout=10m0s)
	@(cd acceptance && go run -modfile ../tools/go.mod github.com/golangci/golangci-lint/cmd/golangci-lint run --path-prefix acceptance --sort-results $(if $(GITHUB_ACTIONS), --out-format=github-actions --timeout=10m0s))

.PHONY: lint-fix
lint-fix: ## Fix linting issues automagically
	@go run -modfile tools/go.mod github.com/google/addlicense -c '$(COPY)' -y '' -s $(LICENSE_IGNORE) .
	@go run -modfile tools/go.mod github.com/golangci/golangci-lint/cmd/golangci-lint run --fix
	@(cd acceptance && go run -modfile ../tools/go.mod github.com/golangci/golangci-lint/cmd/golangci-lint run --path-prefix acceptance --fix)
# We don't apply the fixes from the internal (error handling) linter.
# TODO: fix the outstanding error handling lint issues and enable the fixer
#	@go run -modfile tools/go.mod ./internal/lint -fix $$(go list ./... | grep -v '/acceptance/')
	@go run -modfile tools/go.mod github.com/daixiang0/gci write -s standard -s default -s "prefix(github.com/enterprise-contract/ec-cli)" .

node_modules: package-lock.json
	@npm ci

TEKTON_LINT_TO_GITHUB_ANNOTATIONS='.[] | "::error file=\(.path),line=\(.loc.startLine),endLine=\(.loc.endLine),col=\(.loc.startColumn),endColumn=\(.loc.endColumn)::\(.message)"'
# wildcard matches `tasks/<task_name>/<version>/*.yaml`
tekton-lint: node_modules $(wildcard tasks/*/*/*.yaml) ## Run tekton-lint for 'tasks' subdirectory.
# We execute tekton-lint for all yaml files contained within the tasks subdirectory, it's smart enough to ignore non-Tekton yaml files.
# All warnings are currently considered errors.
# When running on GitHub Actions, reformat to annotations
	@npm exec tekton-lint -- --max-warnings=0 --format=$(if $(GITHUB_ACTIONS),json,stylish) $(filter-out node_modules,$^)$(if $(GITHUB_ACTIONS), | jq -r $(TEKTON_LINT_TO_GITHUB_ANNOTATIONS))

.PHONY: go-mod-lint
go-mod-lint:
	@echo "Scanning for go.mod files and performing tidy..."
	@find . -name "go.mod" -execdir go mod tidy >/dev/null 2>&1 \;
	@echo "Checking for modified go.mod or go.sum files..."
	@if git status --porcelain | grep -q -e "go.mod" -e "go.sum"; then \
		echo "Ensure the following go.mod or go.sum files are added to the git commit:"; \
		git status --porcelain | grep -e "go.mod" -e "go.sum"; \
	else \
		echo "No go.mod or go.sum files need to be added to the git commit."; \
	fi

##@ Pushing images

IMAGE_TAG ?= latest
IMAGE_REPO ?= quay.io/enterprise-contract/ec-cli
.PHONY: build-image
build-image: image_$(BUILD_IMG_ARCH) ## Build container image with ec-cli

.PHONY: push-image
push-image: push_image_$(BUILD_IMG_ARCH) ## Push ec-cli container image to default location

.PHONY: build-snapshot-image
build-snapshot-image: push-image ## Build the ec-cli image and tag it with "snapshot"
	@podman tag $(IMAGE_REPO):$(IMAGE_TAG) $(IMAGE_REPO):snapshot

.PHONY: push-snapshot-image
push-snapshot-image: build-snapshot-image ## Push the ec-cli image with the "snapshot" tag
	@podman push $(PODMAN_OPTS) $(IMAGE_REPO):snapshot

.PHONY: $(ALL_SUPPORTED_IMG_OS_ARCH)
# Targets are in the form of "image_{platform}_{arch}", we set
# TARGETOS={platform}, and TARGETARCH={arch}.
$(ALL_SUPPORTED_IMG_OS_ARCH): TARGETOS=$(word 2,$(subst _, ,$@))
$(ALL_SUPPORTED_IMG_OS_ARCH): TARGETARCH=$(word 3,$(subst _, ,$@))
$(ALL_SUPPORTED_IMG_OS_ARCH):
	@podman build -t $(IMAGE_REPO):$(IMAGE_TAG)-$(TARGETOS)-$(TARGETARCH) -f Dockerfile --platform $(TARGETOS)/$(TARGETARCH) --volume "$$(go env GOCACHE)":/go/cache:Z --volume "$$(go env GOMODCACHE)":/go/mod:Z --env GOCACHE=/go/cache --env GOMODCACHE=/go/mod

# Currently it shows the following:
#  image_linux_amd64
#  image_linux_arm64
#  image_linux_ppc64le
show-supported-builds:
	@for b in $(ALL_SUPPORTED_IMG_OS_ARCH); do echo $$b; done

.PHONY: $(subst image_,push_image_,$(ALL_SUPPORTED_IMG_OS_ARCH))
# Ref: https://www.gnu.org/software/make/manual/make.html#Secondary-Expansion
.SECONDEXPANSION:
# Targets are in the form of "push_image_{platform}_{arch}", we set
# TARGETOS={platform}, and TARGETARCH={arch}. This target depends on the
# "image_{platform}_{arch}" target
$(subst image_,push_image_,$(ALL_SUPPORTED_IMG_OS_ARCH)): TARGETOS=$(word 3,$(subst _, ,$@))
$(subst image_,push_image_,$(ALL_SUPPORTED_IMG_OS_ARCH)): TARGETARCH=$(word 4,$(subst _, ,$@))
$(subst image_,push_image_,$(ALL_SUPPORTED_IMG_OS_ARCH)): image_$$(TARGETOS)_$$(TARGETARCH)
	@podman push $(PODMAN_OPTS) $(IMAGE_REPO):$(IMAGE_TAG)-$(TARGETOS)-$(TARGETARCH)

.PHONY: dist-image
# Depends on targets in the form of "image_{platform}_{arch}"
dist-image: $(ALL_SUPPORTED_IMG_OS_ARCH) ## Build images for all supported platforms/architectures

.PHONY: dist-image-push
# Generates a list of image references in the form of
# "$(IMAGE_REPO):$(IMAGE_TAG)-{platform}-{arch}" generated from a list of "image_{platform}_{arch}"
ALL_IMAGE_REFS=$(subst image-,$(IMAGE_REPO):$(IMAGE_TAG)-,$(subst _,-,$(ALL_SUPPORTED_IMG_OS_ARCH)))
# Depends on "push_image_{platform}_{arch}" targets
dist-image-push: dist-image  $(subst image_,push_image_,$(ALL_SUPPORTED_IMG_OS_ARCH)) ## Push images and image manifest for all supported platforms
# Push all built images from the "image_{platform}_{arch}" target
	@for img in $(ALL_IMAGE_REFS); do podman push $(PODMAN_OPTS) $$img; done
# If the manifest with the same tag exists we need to remove it first, otherwise
# podman manifest create fails
	@2>/dev/null 1>/dev/null podman manifest rm $(IMAGE_REPO):$(IMAGE_TAG) || true
	@podman manifest create $(IMAGE_REPO):$(IMAGE_TAG)
# We set the TARGETOS and TARGETARCH from the image reference, given the
# convention of having the image reference be tagged with "{tag}-{platform}-{arch}"
	@for img in $(ALL_IMAGE_REFS); do TARGETOS=$$(echo $$img | sed -e 's/.*:[^-]\+-\([^-]\+\).*/\1/'); TARGETARCH=$${img/*-}; podman manifest add $(IMAGE_REPO):$(IMAGE_TAG) $(PODMAN_OPTS) $$img --os $${TARGETOS} --arch $${TARGETARCH}; done
	@podman manifest push $(IMAGE_REPO):$(IMAGE_TAG) $(IMAGE_REPO):$(IMAGE_TAG)
ifdef ADD_IMAGE_TAG
	@for tag in $(ADD_IMAGE_TAG); do
	  @podman manifest push $(IMAGE_REPO):$(IMAGE_TAG) $(IMAGE_REPO):$${tag}
	done
endif

.PHONY: dev
dev: REGISTRY_PORT=5000
dev: IMAGE_REPO=localhost:$(REGISTRY_PORT)/ec
dev: PODMAN_OPTS=--tls-verify=false
dev: TASK_REPO=localhost:$(REGISTRY_PORT)/ec-task-bundle
dev: SKOPEO_ARGS=--src-tls-verify=false --dest-tls-verify=false
dev: TASKS:=$(shell T=$$(mktemp) && yq e ".spec.steps[].image? = \"localhost:$(REGISTRY_PORT)/ec\"" tasks/verify-enterprise-contract/*/verify-enterprise-contract.yaml tasks/verify-definition/*/verify-definition.yaml | yq 'select(. != null)' > "$${T}" && echo "$${T}")
dev: push-image task-bundle ## Push the ec-cli and v-e-c Task Bundle to the kind cluster setup via hack/setup-dev-environment.sh
	@rm "$(TASKS)"

TASK_TAG ?= latest
TASK_REPO ?= quay.io/enterprise-contract/ec-task-bundle
TASK_VERSION ?= 0.1
TASKS ?= tasks/verify-enterprise-contract/$(TASK_VERSION)/verify-enterprise-contract.yaml tasks/verify-definition/$(TASK_VERSION)/verify-definition.yaml
ifneq (,$(findstring localhost:,$(TASK_REPO)))
SKOPEO_ARGS=--src-tls-verify=false --dest-tls-verify=false
endif
.PHONY: task-bundle
task-bundle: ## Push the Tekton Task bundle an image repository
	@go run -modfile tools/go.mod github.com/tektoncd/cli/cmd/tkn bundle push $(TASK_REPO):$(TASK_TAG) $(addprefix -f ,$(TASKS)) --annotate org.opencontainers.image.revision="$(TASK_TAG)"

.PHONY: task-bundle-snapshot
task-bundle-snapshot: task-bundle ## Push task bundle and then tag with "snapshot"
	@skopeo copy "docker://$(TASK_REPO):$(TASK_TAG)" "docker://$(TASK_REPO):snapshot" $(SKOPEO_ARGS)
	echo Tagged $(TASK_REPO):$(TASK_TAG) with snapshot tag
ifdef ADD_TASK_TAG
	@for tag in $(ADD_TASK_TAG); do
	  @skopeo copy "docker://$(TASK_REPO):$(TASK_TAG)" "docker://$(TASK_REPO):$${tag}"
	done
endif

# Useful to compare the `ec test` command source with the `conftest test`
# command source. They should be almost identical.
ifndef DIFF_TOOL
  # I like to use vimdiff for this
  DIFF_TOOL=diff --color=always
endif
.PHONY: conftest-test-cmd-diff
conftest-test-cmd-diff:
	@CONFTEST_VER=$$( go list -m -f '{{ .Version }}' github.com/open-policy-agent/conftest ) && \
	$(DIFF_TOOL) \
	  <(curl -s https://raw.githubusercontent.com/open-policy-agent/conftest/$${CONFTEST_VER}/internal/commands/test.go) \
	  cmd/test/test.go

# Useful while hacking on build numbers and versions
debug-version:
	@echo $(VERSION)
