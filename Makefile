IG_VERSION := $(shell cat IG_VERSION)
GADGETS    := trace_sni trace_tcp

IMAGE_BASE ?= ghcr.io/strekol/ig-gadgets
# The patched build's source: the image's org.opencontainers.image.source, which ghcr uses to
# link the package to its repository (upstream's gadget.yaml points to upstream).
SOURCE_URL ?= https://github.com/strekol/ig-gadgets
TAG        ?= $(IG_VERSION)-dev

IG         ?= ig
COSIGN     ?= cosign
# cosign key reference: the CI secret through env://, or a key file path.
COSIGN_KEY ?= env://COSIGN_PRIVATE_KEY
BUILD      := build
UPSTREAM   := $(BUILD)/upstream
OCI        := $(BUILD)/oci
TARBALL    := https://github.com/inspektor-gadget/inspektor-gadget/archive/refs/tags/$(IG_VERSION).tar.gz

# `ig` runs the upstream builder container it pins for its own version (digest), through the
# docker daemon: same toolchain on a workstation and in CI.
BUILD_FLAGS ?= --builder-image-pull missing

# A string the metadata layer of the built image carries only once its patch is in.
VERIFY_trace_sni := template: l4endpoint
VERIFY_trace_tcp := bytes_received:

.PHONY: all fetch check patch build verify push sign verify-signature clean

all: build

$(UPSTREAM)/.done: IG_VERSION
	rm -rf $(UPSTREAM) && mkdir -p $(UPSTREAM)
	curl -fsSL $(TARBALL) | tar -xz -C $(UPSTREAM) --strip-components=1 $(foreach g,$(GADGETS),--wildcards '*/gadgets/$(g)/*')
	touch $@

fetch: $(UPSTREAM)/.done

# `git apply` inside this repo resolves patch paths from the repo root and silently drops
# the ones outside the current directory, so it runs from the root with --directory: the
# patched tree is then addressed by its path, and a missing file is an error, not a skip.
define apply_patches
	set -- patches/$(1)-*.patch; [ -e "$$1" ] || { echo "no patch for $(1)" >&2; exit 1; }; \
	for p in "$$@"; do echo "$(3) $$p"; git apply $(3) --directory=$(2) -p1 "$$p" || exit 1; done
endef

## Patches must apply cleanly on the pinned upstream: the CI gate for a version bump.
check: fetch
	@$(foreach g,$(GADGETS),$(call apply_patches,$(g),$(UPSTREAM)/gadgets,--check);)

patch: fetch
	@rm -rf $(BUILD)/gadgets && mkdir -p $(BUILD)/gadgets && cp -r $(foreach g,$(GADGETS),$(UPSTREAM)/gadgets/$(g)) $(BUILD)/gadgets/
	@$(foreach g,$(GADGETS),$(call apply_patches,$(g),$(BUILD)/gadgets,);)
	@sed -i 's|^sourceURL:.*|sourceURL: $(SOURCE_URL)|' $(foreach g,$(GADGETS),$(BUILD)/gadgets/$(g)/gadget.yaml)

build: patch
	@for g in $(GADGETS); do \
	  $(IG) image build $(BUILD_FLAGS) -t $(IMAGE_BASE)/$$g:$(TAG) $(BUILD)/gadgets/$$g || exit 1; \
	done
	@$(MAKE) --no-print-directory verify

## The built image must expose its patched fields (catches a patch that applied to nothing) and
## this repo as its source (catches an upstream gadget.yaml without the sourceURL line).
## Read from the exported layout (`ig image inspect` loads the eBPF program, so needs root).
verify:
	@$(foreach g,$(GADGETS), \
	  rm -rf $(OCI)/$(g) && mkdir -p $(OCI)/$(g) \
	    && $(IG) image export $(IMAGE_BASE)/$(g):$(TAG) $(OCI)/$(g).tar >/dev/null \
	    && tar -xf $(OCI)/$(g).tar -C $(OCI)/$(g) && rm $(OCI)/$(g).tar \
	    && grep -a -q -r '$(VERIFY_$(g))' $(OCI)/$(g)/blobs \
	    && grep -q '"org.opencontainers.image.source":"$(SOURCE_URL)"' $(OCI)/$(g)/index.json \
	    && echo "verify $(g): ok" || { echo "verify $(g): '$(VERIFY_$(g))' or source $(SOURCE_URL) missing from $(IMAGE_BASE)/$(g):$(TAG)" >&2; exit 1; };)

## Credentials: AUTH_FILE (docker-style config.json), else ig's /var/lib/ig/config.json, else
## ~/.docker/config.json (`docker login`). ig ignores REGISTRY_AUTH_FILE despite its --help.
## Records each pushed index digest under build/<gadget>.digest, for `sign` (ig reports it on
## stderr, hence 2>&1).
push:
	@mkdir -p $(BUILD) && rm -f $(foreach g,$(GADGETS),$(BUILD)/$(g).digest) && for g in $(GADGETS); do \
	  out=$$($(IG) image push $(if $(AUTH_FILE),--authfile $(AUTH_FILE)) $(IMAGE_BASE)/$$g:$(TAG) 2>&1); rc=$$?; \
	  echo "$$out"; [ $$rc -eq 0 ] || exit 1; \
	  echo "$$out" | sed -n 's/.*@\(sha256:[0-9a-f]\{64\}\).*/\1/p' > $(BUILD)/$$g.digest; \
	  [ -s $(BUILD)/$$g.digest ] || { echo "no digest in the ig image push output for $$g" >&2; exit 1; }; \
	done

## Signs by digest what `push` sent (a tag can move in between). --recursive also signs the
## per-arch manifests; legacy .sig format, the one IG looks up first, as upstream signs its own.
## Registry credentials: cosign reads $$DOCKER_CONFIG/config.json.
sign:
	@for g in $(GADGETS); do \
	  [ -s $(BUILD)/$$g.digest ] || { echo "$(BUILD)/$$g.digest missing: run make push first" >&2; exit 1; }; \
	  $(COSIGN) sign --new-bundle-format=false --use-signing-config=false --key $(COSIGN_KEY) --yes --recursive \
	    $(IMAGE_BASE)/$$g@$$(cat $(BUILD)/$$g.digest) || exit 1; \
	done

## The images must verify against the committed cosign.pub, the key the IG daemons trust.
verify-signature:
	@for g in $(GADGETS); do \
	  out=$$($(COSIGN) verify --key cosign.pub $(IMAGE_BASE)/$$g:$(TAG) 2>&1 >/dev/null) \
	    && echo "signature $$g: ok" || { echo "$$out" >&2; echo "signature $$g: $(IMAGE_BASE)/$$g:$(TAG) not signed with cosign.pub" >&2; exit 1; }; \
	done

clean:
	rm -rf $(BUILD)
