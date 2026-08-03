# Phased build of a dosemu2 builder image.
#
# Each phase produces a tagged image; later phases FROM the previous
# tag. Rebuilding a downstream phase doesn't re-run upstream ones as
# long as their layers stay cached.
#
# The chain is 01 -> 02 -> 03 -> 04, all Alpine-based, adapted from
# dosemu2 upstream's Dockerfile.alpine (by Stas Sergeev / stsp):
# https://github.com/dosemu2/dosemu2/blob/devel/Dockerfile.alpine
#
# Targets:
#   make all            — chain through every phase, ending at :latest
#   make build-env       — stop at the toolchain checkpoint
#   make headless        — build only the :latest-headless target
#   make shell           — drop into an interactive shell in :latest
#   make clean           — remove all dosemu2-builder:* tags
#
# Overridable from the command line:
#   IMAGE        — image repo (default dosemu2-builder)
#   DOSEMU2_SRC  — path on host bind-mounted as the dosemu2 source

# Builder phases (01-03) live under $(BUILDER_IMAGE) — they carry the
# full build toolchain. The runtime image (phase 04) lives under
# $(RUNTIME_IMAGE) and contains only the binary + runtime deps. Two
# different image repos to make the distinction obvious in `docker
# images` output.
BUILDER_IMAGE ?= dosemu2-builder
RUNTIME_IMAGE ?= dosemu2
DOSEMU2_SRC   ?= /home/andy/src/dosemu2

# Each builder-phase tag also serves as the FROM base of the next.
TAG_01 := $(BUILDER_IMAGE):01-base
TAG_02 := $(BUILDER_IMAGE):02-binutils
TAG_03 := $(BUILDER_IMAGE):03-toolchain
TAG_04 := $(RUNTIME_IMAGE):latest
TAG_04_HEADLESS := $(RUNTIME_IMAGE):latest-headless

# Use the `default` buildx builder (which is just the host Docker
# daemon). The `docker-container` driver — often the active default —
# runs buildx in its own container and can't see the host's image
# store, so `FROM dosemu2-builder:NN-prev` can't resolve the previous
# phase's local tag and tries to pull from Docker Hub instead.
#
# --load makes the resulting image land in Docker's image store rather
# than buildx's internal cache.
DOCKER_BUILD := docker buildx build --builder default --load

.PHONY: all 01-base 02-binutils 03-toolchain build-env 04-build headless \
        release shell clean rebuild-toolchain rebuild-dosemu2

# `make all` builds the git chain. The PPA-based release image is
# independent and built on demand via `make release`.
all: 04-build

01-base:
	$(DOCKER_BUILD) \
	  -f Dockerfile.01-base \
	  -t $(TAG_01) \
	  .

02-binutils: 01-base
	$(DOCKER_BUILD) \
	  --build-arg BASE=$(TAG_01) \
	  -f Dockerfile.02-binutils \
	  -t $(TAG_02) \
	  .

03-toolchain: 02-binutils
	$(DOCKER_BUILD) \
	  --build-arg BASE=$(TAG_02) \
	  -f Dockerfile.03-toolchain \
	  -t $(TAG_03) \
	  .

# User-facing alias for the toolchain checkpoint.
build-env: 03-toolchain

# Phase 04 takes the dosemu2 source as a named build context. The
# Dockerfile mounts it read-only via RUN --mount=type=bind. The
# `runtime` target is the default GUI-capable :latest; `headless`
# builds the same source against the `runtime-headless` target.
04-build: build-env
	$(DOCKER_BUILD) \
	  --target runtime \
	  --build-arg BASE=$(TAG_03) \
	  --build-context dosemu2=$(DOSEMU2_SRC) \
	  -f Dockerfile.04-build \
	  -t $(TAG_04) \
	  .

headless: build-env
	$(DOCKER_BUILD) \
	  --target runtime-headless \
	  --build-arg BASE=$(TAG_03) \
	  --build-context dosemu2=$(DOSEMU2_SRC) \
	  -f Dockerfile.04-build \
	  -t $(TAG_04_HEADLESS) \
	  .

# PPA-based release image. Independent of the Alpine chain — Ubuntu
# base, apt-installs dosemu2 + comcom32 from the dosemu2 PPA.
# Multi-stage to drop the PPA bootstrap tools. Fast (~2 min).
release:
	$(DOCKER_BUILD) \
	  -f Dockerfile.release \
	  -t $(RUNTIME_IMAGE):release \
	  .

# Convenience: rebuild only the toolchain phase on top of :01-base,
# e.g. after bumping a component's git ref. --no-cache forces every
# source clone in Phase 03 to refetch.
rebuild-toolchain:
	$(DOCKER_BUILD) \
	  --no-cache \
	  --build-arg BASE=$(TAG_02) \
	  -f Dockerfile.03-toolchain \
	  -t $(TAG_03) \
	  .

# Convenience: rebuild only the dosemu2 phase against the current host
# source. Use this after editing /home/andy/src/dosemu2.
rebuild-dosemu2:
	$(DOCKER_BUILD) \
	  --no-cache \
	  --target runtime \
	  --build-arg BASE=$(TAG_03) \
	  --build-context dosemu2=$(DOSEMU2_SRC) \
	  -f Dockerfile.04-build \
	  -t $(TAG_04) \
	  .

# Drop into a bash shell in the runtime image. For poking around the
# build environment instead, run with $(TAG_03) or earlier.
shell:
	docker run --rm -it \
	  -v $(DOSEMU2_SRC):/home/dosuser/src/dosemu2:ro \
	  --entrypoint /bin/bash \
	  $(RUNTIME_IMAGE):latest

clean:
	-docker rmi $(TAG_01) $(TAG_02) $(TAG_03) $(TAG_04) $(TAG_04_HEADLESS) $(RUNTIME_IMAGE):release 2>/dev/null
