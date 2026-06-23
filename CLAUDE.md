# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A phased Docker build of [dosemu2](https://github.com/dosemu2/dosemu2)
from upstream git on Arch Linux, plus a parallel Ubuntu+PPA build of
the latest released version. Outputs:

- **`dosemu2:latest`** — slim Arch runtime + dosemu2 from git HEAD (multi-stage)
- **`dosemu2:release`** — slim Ubuntu runtime + dosemu2 from the PPA (multi-stage)
- **`dosemu2-builder:01-pacman` / `:04-aur`** — intermediate builder images

These also push to `ghcr.io/theimpossibleastronaut/dosemu2-container:*`
on the same names. The `:04-aur` image additionally pushes under the
user-facing alias `:build-env` (same digest) — that's the tag the
README points users at when they want to bind-mount their dosemu2
source and build inside the container. Keep `:04-aur` referenced from
the chain-position docs (Makefile target, phase tables); use
`:build-env` in user-facing prose and examples.

The three **user-facing** tags (`:latest`, `:release`, `:build-env`)
are also mirrored to **Docker Hub** at `docker.io/andy5995/dosemu2`
(secrets `DOCKER_HUB_USERNAME` / `DOCKER_PAT_TOKEN`, `DH_IMAGE` env in
the workflows). The intermediate checkpoints `:01-pacman` / `:04-aur`
stay GHCR-only — they're only ever pulled as `BASE` from GHCR
(hardcoded in the Dockerfiles), so Docker Hub doesn't need them.

## Two image namespaces, intentionally

| Repo | Purpose |
|---|---|
| `dosemu2-builder:*` | Build environment. Has the full toolchain (Arch base-devel, paru, DJGPP cross compiler, etc.) |
| `dosemu2:*` | Runtime. Multi-stage final stage with ONLY the binary + runtime libs. No toolchain. |

`docker images` then makes the distinction obvious. The Makefile uses
`BUILDER_IMAGE` and `RUNTIME_IMAGE` variables (both overridable) so
forks can publish under their own namespaces.

## The build chain (01 → 04 → 05)

The chain is **three phases**: `:01-pacman → :04-aur → :latest`, in
both CI and the Makefile. Phase 04 builds directly on `:01-pacman`.

The `01 → 04` numbering gap is historical: phases 02 (paru bootstrap)
and 03 (djgpp-djcrx bootstrap) were removed once their outputs moved
into the prebuilt `aur-pkgs/` set (refactor commits `928dc5c` /
`cb57d0a` / `d326df4`; the `Dockerfile.02-paru` / `Dockerfile.03-djcrx`
files and their Makefile targets were deleted afterward). The
surviving tags kept their numbers because they're published GHCR
identities.

| Phase | Tag | Cost | What |
|---|---|---|---|
| 01 | `:01-pacman` | ~3 min | Arch base + pacman deps + builder user + parallelism config |
| 04 | `:04-aur` (= `:build-env`) | **seconds** | `pacman -U` the vendored `aur-pkgs/` on top of `:01`. No source builds |
| 05 | `:latest` | ~3-10 min | Multi-stage: builder bind-mounts dosemu2 source, runtime is slim Arch |

The ~30-min cost that used to live in Phase 04 (compiling djgpp-gcc,
fdpp, etc.) now happens **out of band** when refreshing a vendored
package — see "The aur-pkgs/ vendored set" below. The image chain
itself no longer compiles any AUR package, and (since Phase 03 is
gone) no longer fetches anything from delorie.com.

`make all` runs `01 → 04 → 05` and is the normal local validation
path. `Dockerfile.release` is a parallel, single-Dockerfile path
(Ubuntu + PPA), independent of the Arch chain.

## The aur-pkgs/ vendored package set

`aur-pkgs/` holds **prebuilt** Arch packages (`.pkg.tar.zst`, tracked
in Git LFS): the full DJGPP toolchain (`djgpp-gcc`, `djgpp-binutils`,
`djgpp-djcrx`), `paru`, `fdpp`, `dj64-git`, `comcom*-git`, `munt`,
`libsearpc`, `nasm-segelf-git`, etc. Phase 04 bind-mounts this dir and
`pacman -U`'s the whole glob — no compiling. See `aur-pkgs/README.md`.

Refreshing a package (build out of band, then vendor):

- The `build-aur-pkg.yml` workflow (Actions → "Build an AUR package")
  builds it inside `:build-env` and uploads the `.zst` as an artifact;
  or build locally in `:build-env` (paru is present). Add the `.zst`
  to `aur-pkgs/`, remove the old one, commit. The next `build.yml` run
  picks it up via the `aur-pkgs/**` path trigger.
- This out-of-band build is where the **old Phase-04 gotchas now
  live**: the gcc-14 `-std=gnu17` wrapper for `djgpp-djcrx 2.05`'s
  K&R declarations under rolling Arch's gcc 16+/C23; the `comcom32`
  vs `comcom64-git` `pacman -Rdd` dance (both `provide=comcom64`);
  the djgpp-djcrx ⇄ djgpp-gcc bootstrap cycle; and
  `--mflags=--nocheck` to skip check() phases that trip on perl
  5.40+ / makepkg trap regressions. They matter when (re)building a
  vendored `.zst`, **not** when running the image chain.

## fdpp must install into libdir (post-#294)

dosemu2 git HEAD (PR #2887) removed the fdpp rpath; fdpp PR #294
("move to libdir") correspondingly installs `libfdpp.so` /
`libfdldr.so` into `${libdir}` (`/usr/lib`, which ldconfig searches)
instead of `/usr/lib/fdpp`. **The two changes must move together.**

The AUR *release* `fdpp` (1.9) predates #294 and installs to
`/usr/lib/fdpp`; pairing it with current dosemu2 gives a clean build
that crashes at runtime with `libfdpp.so.35: cannot open shared
object file` (the soname didn't change across the move, so there's no
build-time guard). Fix: vendor **`fdpp-git`** (HEAD, post-#294) rather
than release `fdpp`. Caveat when building `fdpp-git`: its AUR PKGBUILD
still lists `nasm-segelf` as a makedep though upstream HEAD switched
to plain `nasm`, so the build needs `pacman -S nasm` plus a `-Syu` to
dodge a stale-db 404.

## Cross-cutting gotchas (Phase 05 / runtime)

These broke during development and have a comment at the source
call-site:

- **`/usr/local/share/man` symlink.** archlinux:latest ships it as a
  symlink to `../man`. dosemu2's `make install` lays down a real
  directory there, so Phase 05's runtime stage `rm`s the symlink
  before the `COPY --from=builder /install /`.
- **`.git` is included in the source untar.** dosemu2's `getversion`
  script falls back to the static `VERSION` file when there's no git
  history. We tar in `.git` so the built binary reports the rich
  `2.0pre9-dev-DATE-N-gSHA` string rather than just `2.0pre9`.

## Parallelism (JOBS / MAKEFLAGS)

`JOBS` defaults to `$(shell nproc)` at make-time. Phase 01 bakes the
resolved value into three places:

- `/etc/makepkg.conf` MAKEFLAGS (the **only** place makepkg honors;
  it overrides env MAKEFLAGS from its own config)
- `/etc/profile.d/jobs.sh` (interactive shells)
- `/etc/dosemu2-jobs.env` (sourced by every later RUN: `. /etc/dosemu2-jobs.env && export MAKEFLAGS CARGO_BUILD_JOBS && ...`)

Plus `/home/builder/.cargo/config.toml` `[build] jobs` as fallback
for any rust build that scrubs the env.

## ARG BASE default

Each Dockerfile has `ARG BASE=ghcr.io/.../dosemu2-container:<prev>`
pointing at the GHCR-published phase it builds on — **Dockerfile.04-aur
defaults to `:01-pacman`** (not `:03`), matching CI. So `docker build
-f Dockerfile.04-aur .` with no `--build-arg` pulls `:01-pacman` from
GHCR and works out of the box. The Makefile overrides `BASE` with
local tags for chained builds (Phase 04 on `TAG_01`).

## How the local source gets in

Phase 05 uses BuildKit's `additional_contexts`:

```yaml
# Makefile:
--build-context dosemu2=$(DOSEMU2_SRC)
```

```dockerfile
# Dockerfile.05-build:
RUN --mount=type=bind,from=dosemu2,target=/src,readonly \
    ... tar /src into a scratch dir, build there ...
```

This keeps the host source tree clean (no `.o` files leak back).
`DOSEMU2_SRC` defaults to `/home/andy/src/dosemu2`.

## Workflows

| File | Trigger | Builds |
|---|---|---|
| `.github/workflows/build.yml` | trunk push to `Dockerfile.01-pacman` / `.04-aur` / `.05-build` or `aur-pkgs/**`, weekly cron, dispatch | 3 sequential jobs **01→04→latest**, each `needs:` the previous; Phase 04 builds with `BASE=:01-pacman` |
| `.github/workflows/build-release.yml` | trunk push to Dockerfile.release, weekly cron, dispatch | Just `:release` |
| `.github/workflows/build-aur-pkg.yml` | dispatch (pkg name input) | Builds one AUR pkg in `:build-env`, uploads the `.zst` as an artifact to vendor into `aur-pkgs/` |
| `.github/workflows/ghcr-prune.yml` | weekly cron, dispatch | Deletes untagged GHCR versions via `gh api` (no third-party action) |

All push to GHCR using `GITHUB_TOKEN` with `permissions: packages: write`.
`build.yml` and `build-release.yml` additionally log in to Docker Hub
(`DOCKER_HUB_USERNAME` / `DOCKER_PAT_TOKEN`) and mirror the user-facing
tags (`:build-env`, `:latest`, `:release`) to `andy5995/dosemu2`.

## Key files quick reference

| Path | What |
|---|---|
| `Dockerfile.01-pacman` | Base + pacman packages + builder user + parallelism config |
| `Dockerfile.04-aur` | Single `FROM :01-pacman`; bind-mounts `aur-pkgs/` and `pacman -U`'s it, then sets the UID-remap entrypoint. Fast. (= `:build-env`) |
| `Dockerfile.05-build` | Multi-stage. Builder builds dosemu2; runtime is slim Arch + AUR pkgs from `/opt/aur-pkgs` + `/install` from builder |
| `Dockerfile.release` | Multi-stage Ubuntu + PPA build of `:release` |
| `aur-pkgs/` | Prebuilt `.pkg.tar.zst` set (Git LFS) installed by Phase 04. See its README |
| `Makefile` | `make all` (01→04→05) / `release` / `rebuild-aur` / `rebuild-dosemu2` / `shell` / `clean` |
| `docker-compose.yml` | Run-time conveniences (interactive dosemu, shell with source mounted) |
| `.github/workflows/build.yml` | Main chain (01→04→latest) |
| `.github/workflows/build-aur-pkg.yml` | Build a vendored AUR pkg artifact |
| `.github/workflows/build-release.yml` | Release path |
| `.github/workflows/ghcr-prune.yml` | Cleanup |

## When making changes

- **Editing Phase 01** invalidates Phase 04's base, so it cascades
  01→04→05 — but Phase 04 is now a fast `pacman -U`, so the cascade is
  cheap unless `aur-pkgs/` also changed.
- **Editing Phase 04** is just the `pacman -U` step (fast). The real
  ~30-min cost is rebuilding a *vendored package* out of band (see
  "The aur-pkgs/ vendored set") — that's where AUR-upstream quirks and
  the old gotchas land.
- **Editing Phase 05** is the dosemu2 build (~3-10 min). Iterate freely
  with `make rebuild-dosemu2`.
- **Adding a runtime-only dep** belongs in Phase 05's runtime stage's
  pacman list, NOT Phase 01.
- **Validating locally before push.** `make all` (01→04→05) + a smoke
  test `docker run --rm dosemu2:latest -td -ks -E exitemu`. Or iterate
  faster with `make rebuild-aur` (after an `aur-pkgs/` swap) or
  `make rebuild-dosemu2` (after editing the dosemu2 source).
