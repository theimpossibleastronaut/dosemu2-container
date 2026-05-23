# Phased build of a dosemu2 builder image.
#
# Each phase produces a tagged image; later phases FROM the previous
# tag. Rebuilding a downstream phase doesn't re-run upstream ones as
# long as their layers stay cached.
#
# Targets:
#   make all            — chain through every phase, ending at :latest
#   make 04-aur         — stop at the AUR-pkgs-installed checkpoint
#   make 05-build       — rebuild only the dosemu2 phase against current source
#   make shell          — drop into an interactive shell in :latest
#   make clean          — remove all dosemu2-builder:* tags
#
# Overridable from the command line:
#   IMAGE        — image repo (default dosemu2-builder)
#   DOSEMU2_SRC  — path on host bind-mounted as the dosemu2 source
#   JOBS         — parallelism; empty = nproc inside the buildkit builder

# Builder phases (01-04) live under $(BUILDER_IMAGE) — they carry the
# full build toolchain. The runtime image (phase 05) lives under
# $(RUNTIME_IMAGE) and contains only the binary + runtime deps. Two
# different image repos to make the distinction obvious in `docker
# images` output.
BUILDER_IMAGE ?= dosemu2-builder
RUNTIME_IMAGE ?= dosemu2
DOSEMU2_SRC   ?= /home/andy/src/dosemu2
JOBS          ?=

# Each builder-phase tag also serves as the FROM base of the next.
TAG_01 := $(BUILDER_IMAGE):01-pacman
TAG_02 := $(BUILDER_IMAGE):02-paru
TAG_03 := $(BUILDER_IMAGE):03-djcrx
TAG_04 := $(BUILDER_IMAGE):04-aur
TAG_05 := $(RUNTIME_IMAGE):latest

# Use the `default` buildx builder (which is just the host Docker
# daemon). The `docker-container` driver — often the active default —
# runs buildx in its own container and can't see the host's image
# store, so `FROM dosemu2-builder:NN-prev` can't resolve the previous
# phase's local tag and tries to pull from Docker Hub instead.
#
# --load makes the resulting image land in Docker's image store rather
# than buildx's internal cache.
DOCKER_BUILD := docker buildx build --builder default --load

.PHONY: all 01-pacman 02-paru 03-djcrx 04-aur 05-build release shell clean rebuild-aur rebuild-dosemu2

# `make all` builds the git chain. The PPA-based release image is
# independent and built on demand via `make release`.
all: 05-build

01-pacman:
	$(DOCKER_BUILD) \
	  --build-arg JOBS=$(JOBS) \
	  -f Dockerfile.01-pacman \
	  -t $(TAG_01) \
	  .

02-paru: 01-pacman
	$(DOCKER_BUILD) \
	  --build-arg BASE=$(TAG_01) \
	  -f Dockerfile.02-paru \
	  -t $(TAG_02) \
	  .

03-djcrx: 02-paru
	$(DOCKER_BUILD) \
	  --build-arg BASE=$(TAG_02) \
	  -f Dockerfile.03-djcrx \
	  -t $(TAG_03) \
	  .

04-aur: 03-djcrx
	$(DOCKER_BUILD) \
	  --build-arg BASE=$(TAG_03) \
	  -f Dockerfile.04-aur \
	  -t $(TAG_04) \
	  .

# Phase 05 takes the dosemu2 source as a named build context. The
# Dockerfile mounts it read-only via RUN --mount=type=bind. The result
# is the slim runtime — tagged as $(RUNTIME_IMAGE):latest, NOT under
# the builder repo (it has no build tools).
05-build: 04-aur
	$(DOCKER_BUILD) \
	  --build-arg BASE=$(TAG_04) \
	  --build-context dosemu2=$(DOSEMU2_SRC) \
	  -f Dockerfile.05-build \
	  -t $(TAG_05) \
	  .

# PPA-based release image. Independent of the Arch chain — Ubuntu base,
# apt-installs dosemu2 + comcom32 from the dosemu2 PPA. Multi-stage to
# drop the PPA bootstrap tools. Fast (~2 min).
release:
	$(DOCKER_BUILD) \
	  -f Dockerfile.release \
	  -t $(RUNTIME_IMAGE):release \
	  .

# Convenience: rebuild only the AUR phase (e.g. after the AUR upstream
# bumps a pkg) without re-running paru bootstrap or pacman install.
rebuild-aur:
	$(DOCKER_BUILD) \
	  --no-cache \
	  --build-arg BASE=$(TAG_03) \
	  -f Dockerfile.04-aur \
	  -t $(TAG_04) \
	  .

# Convenience: rebuild only the dosemu2 phase against the current host
# source. Use this after editing /home/andy/src/dosemu2.
rebuild-dosemu2:
	$(DOCKER_BUILD) \
	  --no-cache \
	  --build-arg BASE=$(TAG_04) \
	  --build-context dosemu2=$(DOSEMU2_SRC) \
	  -f Dockerfile.05-build \
	  -t $(TAG_05) \
	  .

# Drop into a bash shell in the runtime image. For poking around the
# build environment instead, run with $(TAG_04) or earlier.
shell:
	docker run --rm -it \
	  -v $(DOSEMU2_SRC):/home/dosuser/src/dosemu2:ro \
	  --entrypoint /bin/bash \
	  $(RUNTIME_IMAGE):latest

clean:
	-docker rmi $(TAG_01) $(TAG_02) $(TAG_03) $(TAG_04) $(TAG_05) $(RUNTIME_IMAGE):release 2>/dev/null
