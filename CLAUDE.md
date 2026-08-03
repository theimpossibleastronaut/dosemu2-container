# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A phased Docker build of [dosemu2](https://github.com/dosemu2/dosemu2)
from upstream git on Alpine Linux, plus a parallel Ubuntu+PPA build of
the latest released version. Outputs:

- **`dosemu2:latest`** — slim Alpine runtime + dosemu2 from git HEAD,
  with SDL3/X11 GUI support (multi-stage)
- **`dosemu2:latest-headless`** — same build, without SDL3/X11 —
  smallest, text-mode only
- **`dosemu2:release`** — slim Ubuntu runtime + dosemu2 from the PPA
- **`dosemu2-builder:01-base` / `:03-toolchain`** — intermediate builder images

These also push to `ghcr.io/theimpossibleastronaut/dosemu2-container:*`
on the same names. The `:03-toolchain` image additionally pushes under
the user-facing alias `:build-env` (same digest) — that's the tag the
README points users at when they want to bind-mount their dosemu2
source and build inside the container. Keep `:03-toolchain` referenced
from the chain-position docs (Makefile target, phase tables); use
`:build-env` in user-facing prose and examples.

The Alpine chain is adapted from dosemu2 upstream's own
[`Dockerfile.alpine`](https://github.com/dosemu2/dosemu2/blob/devel/Dockerfile.alpine),
written by Stas Sergeev (stsp) — see
[issue #10](https://github.com/theimpossibleastronaut/dosemu2-container/issues/10).
Credit him in any user-facing docs that describe the toolchain build.

The three **user-facing** tags (`:latest`, `:latest-headless`,
`:release`, `:build-env`) are also mirrored to **Docker Hub** at
`docker.io/andy5995/dosemu2` (secrets `DOCKER_HUB_USERNAME` /
`DOCKER_PAT_TOKEN`, `DH_IMAGE` env in the workflows). The intermediate
checkpoints `:01-base` / `:02-binutils` / `:03-toolchain` stay
GHCR-only — they're only ever pulled as `BASE` from GHCR (hardcoded
in the Dockerfiles), so Docker Hub doesn't need them.

## Two image namespaces, intentionally

| Repo | Purpose |
|---|---|
| `dosemu2-builder:*` | Build environment. Has the full toolchain (binutils, dj64dev, comcom64, fdpp, etc.) |
| `dosemu2:*` | Runtime. Multi-stage final stage with ONLY the binary + runtime libs. No toolchain. |

`docker images` then makes the distinction obvious. The Makefile uses
`BUILDER_IMAGE` and `RUNTIME_IMAGE` variables (both overridable) so
forks can publish under their own namespaces.

## The build chain (01 → 02 → 03 → 04)

| Phase | Tag | What |
|---|---|---|
| 01 | `:01-base` | Alpine base + apk build deps (incl. GUI build deps) |
| 02 | `:02-binutils` | + `binutils-gdb` built for `i686-unknown-linux-gnu` — the slowest, most network-fragile step, isolated so a failure here doesn't force Phase 01 or 03 to redo work |
| 03 | `:03-toolchain` (= `:build-env`) | + `thunk_gen`, `fdpp`, `smallerc`, `djstub`, `dj64dev`, `comcom64`, `libsearpc`, each in its own `RUN` so one component's cache doesn't invalidate the others |
| 04 | `dosemu2:latest` / `:latest-headless` | Multi-stage: builder bind-mounts dosemu2 source and builds once; two runtime stages (`runtime` / `runtime-headless`) copy the same `/install` tree into different Alpine bases |

`make all` runs `01 → 02 → 03 → 04` (target `runtime`) and is the
normal local validation path. `make headless` builds just the
`runtime-headless` target. `Dockerfile.release` is a parallel,
single-Dockerfile path (Ubuntu + PPA), independent of the Alpine
chain.

Alpine has no AUR-equivalent binary repo for this toolchain, so unlike
the old Arch chain, nothing here is vendored — every phase compiles
its piece from source. That's why the chain exists at all (vs. one
big Dockerfile like upstream's): splitting it into cacheable phases
means a failure partway through a rebuild doesn't discard earlier
phases' work.

## :latest and :latest-headless are compiled separately

dosemu2's `configure` picks its plugin set by autodetecting libs, and
the binary then calls `load_plugin()` for every plugin it was compiled
with. **Sharing one build between the two images does not work.** The
first cut did, and the headless image dlopen'd sdl/X/XKmaps/alsa/
fluidsynth on every startup, printing an `ERROR` per failure because
those libs are absent there. Deleting the plugin `.so` files is not a
fix either — `load_plugin()` reports a missing file just as loudly.

So Phase 04 has two builder stages:

- `builder` — full toolchain, GUI/audio autodetected. Feeds `runtime`
  (`:latest`).
- `builder-headless` — runs `apk del` on the GUI/audio `-dev` packages
  before `./configure`, so `PLUGINSUBDIRS` omits X, Xkmaps, sdl, sdl3,
  alsa, ladspa, gpm, libao and fluidsynth. Feeds `runtime-headless`
  (`:latest-headless`).

The cost is a second dosemu2 compile; the benefit is a headless image
that starts without error spam. Pick the image with `--target runtime`
/ `--target runtime-headless`.

`runtime-common` holds everything the two share (base libs,
`/usr/local`, the `dosuser` account, `ENTRYPOINT`) so they can't drift
apart — a drift bug that already bit once, when the GUI stage listed
`gpm` (the daemon) instead of `gpm-libs` (which actually ships
`libgpm.so.2`) and left `libplugin_gpm.so` orphaned in `:latest`.

**Verifying a runtime image after changing deps or plugins:**

```sh
docker run --rm --entrypoint sh dosemu2:latest-headless -c \
  'for so in /usr/local/lib/dosemu/*.so; do ldd "$so" 2>&1 \
   | grep -o "Error loading shared library [^:]*" | sed "s|^|$so: |"; done'
```

Any output is an orphaned plugin. Also run `docker run --rm IMAGE -td
-ks -E ver` **without** `-dumb` and check for `ERROR:` lines — `-dumb`
skips the video/sound plugin path and hides exactly this class of bug.
Only `/dev/kvm`, X-display, sound-device and `kbd: EOF from stdin`
errors are expected in a container.

## SDL3 and libb64 come from Alpine's edge repos

Alpine 3.21 stable doesn't package SDL3 (dosemu2 needs SDL3, not
SDL2) or `libb64`. Both get pulled from `edge/community` and
`edge/testing` respectively via an explicit `--repository=` flag
layered on top of the 3.21 base — same pattern upstream's
Dockerfile.alpine uses for `libb64`. Phase 01 does this for the
`-dev` packages (build time); Phase 04's `runtime` stage does it again
for the non-dev runtime packages.

## Cross-cutting gotchas (Phase 04)

- **`.git` is included in the source untar.** dosemu2's `getversion`
  script falls back to the static `VERSION` file when there's no git
  history. We tar in `.git` so the built binary reports the rich
  `2.0pre9-dev-DATE-N-gSHA` string rather than just `2.0pre9`.
- **Source mount is read-only.** Phase 04 untars the bind-mounted host
  source into `/root/dosemu2` inside the builder stage before running
  `autogen.sh` / `configure` / `make`, so the host working tree
  doesn't get polluted with `.o` files. `git clean -dfx` runs first to
  strip any in-tree artifacts the host tree carries (e.g. a
  `config.status` with `/workspace` paths left by an in-tree configure
  in the `:build-env` container).
- **`/usr/local` is pruned in the `builder` stage, not `:03-toolchain`.**
  Right after `make install DESTDIR=/install`, a `RUN rm -rf` strips
  the binutils cross-tools, dj64dev/smallerc headers and static
  archives, and locale/info/man/doc data — none of it is loaded at
  runtime, but `:03-toolchain`/`:build-env` needs all of it, so the
  prune happens on the `builder` stage's own copy, after which both
  runtime stages `COPY --from=builder /usr/local /usr/local`. Cuts
  `:latest-headless` from ~250 MB to ~77 MB. If a future toolchain
  component adds a new runtime-needed file under a pruned path (e.g.
  a new `.so` under `/usr/local/i386-pc-dj64/lib64`), the prune list
  needs a matching exception or the file silently disappears from the
  runtime images.

## ARG BASE default

Each Dockerfile has `ARG BASE=ghcr.io/.../dosemu2-container:<prev>`
pointing at the GHCR-published phase it builds on — e.g.
Dockerfile.02-binutils defaults to `:01-base`, Dockerfile.03-toolchain
to `:02-binutils`, Dockerfile.04-build to `:03-toolchain`. So `docker
build -f Dockerfile.0N-... .` with no `--build-arg` pulls the right
previous phase from GHCR and works out of the box. The Makefile
overrides `BASE` with local tags for chained builds.

## How the local source gets in

Phase 04 uses BuildKit's `additional_contexts`:

```yaml
# Makefile:
--build-context dosemu2=$(DOSEMU2_SRC)
```

```dockerfile
# Dockerfile.04-build:
RUN --mount=type=bind,from=dosemu2,target=/src,readonly \
    ... tar /src into a scratch dir, build there ...
```

This keeps the host source tree clean (no `.o` files leak back).
`DOSEMU2_SRC` defaults to `/home/andy/src/dosemu2`.

## Workflows

| File | Trigger | Builds |
|---|---|---|
| `.github/workflows/build.yml` | trunk push to any `Dockerfile.0[1-4]-*` or `entrypoint.sh`, weekly cron, dispatch | 4 sequential jobs **01→02→03→latest**, each `needs:` the previous; the last job builds both `:latest` and `:latest-headless` targets; `:03-toolchain` / `:build-env` publishes only if `test/entrypoint-perms.sh` passes |
| `.github/workflows/build-release.yml` | trunk push to Dockerfile.release, weekly cron, dispatch | Just `:release` |
| `.github/workflows/ghcr-cleaner.yml` | monthly cron (22nd), trunk push to itself, dispatch | Deletes untagged GHCR versions via `Chizkiyahu/delete-untagged-ghcr-action` |

All push to GHCR using `GITHUB_TOKEN` with `permissions: packages: write`.
`build.yml` and `build-release.yml` additionally log in to Docker Hub
(`DOCKER_HUB_USERNAME` / `DOCKER_PAT_TOKEN`) and mirror the user-facing
tags (`:build-env`, `:latest`, `:latest-headless`, `:release`) to
`andy5995/dosemu2`.

## Key files quick reference

| Path | What |
|---|---|
| `Dockerfile.01-base` | Alpine base + apk build deps (incl. SDL3/X11 GUI build deps) |
| `Dockerfile.02-binutils` | Single `FROM :01-base`; builds `binutils-gdb` for `i686-unknown-linux-gnu` |
| `Dockerfile.03-toolchain` | Single `FROM :02-binutils`; builds `thunk_gen`/`fdpp`/`smallerc`/`djstub`/`dj64dev`/`comcom64`/`libsearpc`, then adds the UID-remap entrypoint. (= `:build-env`) |
| `Dockerfile.04-build` | Multi-stage. Builder builds dosemu2; two runtime stages (`runtime` / `runtime-headless`) copy `/usr/local` (toolchain runtime libs) + `/install` from the builder into fresh Alpine bases |
| `Dockerfile.release` | Multi-stage Ubuntu + PPA build of `:release` |
| `Makefile` | `make all` (01→02→03→04) / `headless` / `release` / `rebuild-toolchain` / `rebuild-dosemu2` / `shell` / `clean` |
| `docker-compose.yml` | Three services from published images: `dosemu2` (text, tag `${TAG:-release}`), `gui` (X11 wired in), `build-env` (source at `/workspace` via `DOSEMU2_SRC`). Defaults to Docker Hub `andy5995/dosemu2` |
| `.env.example` | Tracked template for compose vars (`TAG`/`IMAGE`/`DOSEMU_HOME`/`DOSEMU2_SRC`/`HOSTUID`/`HOSTGID`); copy to `.env` (gitignored) |
| `entrypoint.sh` | `:build-env` UID-remap entrypoint: stats `/workspace` owner, remaps `builder`, honors `HOSTUID`/`HOSTGID`. Warns (doesn't fail) on a root-owned non-empty workdir. `groupmod`/`usermod` come from the `shadow` apk package, `runuser` from `util-linux` — both installed in Phase 01 |
| `.github/workflows/build.yml` | Main chain (01→02→03→latest/latest-headless) |
| `.github/workflows/build-release.yml` | Release path |
| `.github/workflows/ghcr-cleaner.yml` | Cleanup |
| `test/entrypoint-perms.sh` | Gates the `:03-toolchain` / `:build-env` publish; checks the UID remap |

## When making changes

- **Editing Phase 01** invalidates every later phase — it's the base
  every source build runs against.
- **Editing Phase 02** only affects `binutils-gdb`; rarely needs
  touching.
- **Editing Phase 03** is where a toolchain component version bump
  happens. Every component is pinned to a commit SHA in an overridable
  `ARG` (`FDPP_REF`, `DJ64DEV_REF`, `COMCOM64_REF`, …), fetched with
  `git init` + `git fetch --depth 1 <sha>` because `clone --branch`
  only takes branch/tag names. Phase 02 pins binutils to a release tag
  (`BINUTILS_REF`) instead, which `clone --branch` handles directly.
  To bump one, edit the `ARG` default; to test first, pass
  `--build-arg <NAME>_REF=<sha>`. Because these track dosemu2 itself,
  a `:latest` built from much newer dosemu2 `devel` may need several
  bumped together — that's the tradeoff pinning buys against an
  unrelated upstream push breaking the chain.
- **Editing Phase 04** is the dosemu2 build itself. Iterate freely
  with `make rebuild-dosemu2`.
- **Adding a runtime-only dep** belongs in Phase 04's runtime stage(s)
  apk list, NOT Phase 01 (Phase 01 is build-time only).
- **A GUI dep is a build-time (Phase 01) *and* runtime (Phase 04
  `runtime` stage) change** — dosemu2's configure needs the `-dev`
  package to detect and build the feature; the runtime stage needs the
  non-dev package for the resulting `.so` to actually load.
- **Validating locally before push.** `make all` (01→02→03→04) + a
  smoke test `docker run --rm dosemu2:latest -td -ks -E exitemu`. Or
  iterate faster with `make rebuild-toolchain` (after a toolchain
  component bump) or `make rebuild-dosemu2` (after editing the dosemu2
  source).
