# dosemu2-container

Docker images of [dosemu2](https://github.com/dosemu2/dosemu2), in
three flavors:

- **`:latest`** — Arch + dosemu2 from upstream git (`devel`), built
  from a prebuilt AUR-package set (`aur-pkgs/`, Git LFS) on top of
  a slim Arch base.
- **`:release`** — Ubuntu + dosemu2 from the official PPA, the
  latest released version.
- **`:build-env`** — the same image `:latest` is built on top of:
  Arch with the full DJGPP toolchain, `fdpp`, `dj64`, `comcom*`,
  `munt`, `libsearpc`, `paru`, etc. preinstalled. Bind-mount your
  dosemu2 source and run `./autogen.sh && ./default-configure &&
  make && sudo make install` — see "Build dosemu2 locally against
  your own source" below.

All three are built and pushed to
[`ghcr.io/theimpossibleastronaut/dosemu2-container`](https://github.com/theimpossibleastronaut/dosemu2-container/pkgs/container/dosemu2-container).

## Docker is the only build dependency

Everything dosemu2 needs to compile — the Arch base, `paru`, the
DJGPP cross-compiler toolchain, `fdpp`, `dj64`, `comcom64`,
`nasm-segelf`, the `libsearpc` runtime, even a `-std=gnu17`-injecting
gcc wrapper — is built and lives inside the container chain. You
need Docker on your host and that's it. No global pacman / apt
install, no Rust toolchain, no AUR helper, no PPA on the host.

## Use the published images

### Pull & run

The runtime images are on GHCR — no compilation needed:

```sh
# Latest dosemu2 from upstream git (devel branch HEAD at last CI build):
docker run --rm -it ghcr.io/theimpossibleastronaut/dosemu2-container:latest

# Latest released dosemu2 from the Ubuntu PPA:
docker run --rm -it ghcr.io/theimpossibleastronaut/dosemu2-container:release
```

The same `:latest`, `:release`, and `:build-env` images are also
published to Docker Hub at
[`andy5995/dosemu2`](https://hub.docker.com/repository/docker/andy5995/dosemu2/general)
— replace `ghcr.io/theimpossibleastronaut/dosemu2-container` with
`andy5995/dosemu2` in any command below.

Pass DOS commands the same way you would to `dosemu` on the host:

```sh
docker run --rm -it ghcr.io/theimpossibleastronaut/dosemu2-container:latest -td -ks -E "ver"
```

### Running graphics-mode DOS programs (games etc.)

Text-mode invocations like the `-E "ver"` example above work with no
extra plumbing, but a graphics-mode program (Commander Keen, Wolf 3D,
DOOM, AM's Mini Golf 3D, …) needs `dosemu` to open an X11 window —
which means the container needs access to your X server. All the X11
plumbing is wired into the `gui` service in `docker-compose.yml`, so
the recipe is two commands:

```sh
xhost +local:docker
docker compose run --rm gui
```

Then from inside the container shell:

```sh
dosemu -T
```

(The raw `docker run` form, if you'd rather not use compose, is in the
"What the flags do" list below — the `gui` service just sets those same
flags for you. Put your game files where the host can reach them by
setting `DOSEMU_HOME=$HOME/.dosemu` in `.env`.)

`dosemu -T` keeps dosemu open after a DOS command exits (without
it, a game finishing or erroring brings down the whole window). At
the DOS prompt, `cd` into your game's directory and run it as
normal — e.g. for the Commander Keen 1 shareware data living under
`~/.dosemu/drive_c/games/keen1/` on the host:

```
C:\> cd \games\keen1
C:\GAMES\KEEN1> keen1
```

What the flags do:

- `xhost +local:docker` — one-time on the host; tells your X server
  to accept connections from any local user. Re-run after a logout
  if you stop allowing local connections.
- `-e DISPLAY=$DISPLAY` + `-v /tmp/.X11-unix:/tmp/.X11-unix` —
  point the container at your X server and give it access to the
  socket.
- `-e XDG_RUNTIME_DIR=/tmp` — SDL3 wants this set; `/tmp` is the
  least-fragile choice inside a container.
- `-v ~/.dosemu:/home/dosuser/.dosemu` — share the host's
  `~/.dosemu` with the container's dosuser. Mounts your existing
  DOS C: drive (`~/.dosemu/drive_c/`), config, and boot log so
  state persists across `docker run` invocations.
- `--entrypoint /bin/bash` — drop into a shell instead of the
  default `dosemu` entrypoint so you can run `dosemu -T`
  interactively.

A one-shot `docker run … -E KEEN1.EXE` doesn't currently work for
games because dosemu's DOS-side CWD stays at `C:\` regardless of
the host's `-w` flag; the game can't find its data files and
exits. The interactive flow above is the recommended pattern.

Wayland hosts can fall back to XWayland and use the same recipe.
macOS / Windows hosts need an external X server (XQuartz, VcXsrv)
and `host.docker.internal` for `DISPLAY` — see your X server's
docker-from-host docs.

If you don't have an X server available (headless CI etc.), the
`-dumb` and `-term` launcher flags fall back to a terminal-only
interface — useful for text-mode DOS programs but not for games.

### Build dosemu2 locally against your own source

Bind-mount your dosemu2 source into the `:build-env` builder image and
build dosemu2 the usual way (autogen / configure / make) inside the
container. The `build-env` service in `docker-compose.yml` does the
mount for you — point `DOSEMU2_SRC` at your source:

```sh
git clone https://github.com/dosemu2/dosemu2.git ~/src/dosemu2

DOSEMU2_SRC=~/src/dosemu2 docker compose run --rm build-env

# Inside the container (already in /workspace):
./autogen.sh
./default-configure
make -j$(nproc)
sudo make install        # if you want to run it inside the container
dosemu                   # try it
```

(Without compose, the equivalent is `docker run --rm -it -v
~/src/dosemu2:/workspace
ghcr.io/theimpossibleastronaut/dosemu2-container:build-env`.)

The container provides every build dep (Arch toolchain, DJGPP cross
compiler, fdpp, dj64, libsearpc, etc.); your host only has Docker.
The bind mount is read-write, so `make`'s `.o` files land in your
host source tree — same as a native build. If you'd rather keep the
host source clean, clone this repo and let Phase 05 untar into an
internal scratch dir:

```sh
git clone https://github.com/theimpossibleastronaut/dosemu2-container.git
cd dosemu2-container
docker buildx build --builder default --load \
    --build-context dosemu2=~/src/dosemu2 \
    -f Dockerfile.05-build \
    -t dosemu2:latest \
    .
```

The Dockerfiles default their `BASE` to the published GHCR images,
so the `:build-env` builder gets pulled automatically — no `docker
pull` or local tag needed.

The image's entrypoint stats the bind-mounted `/workspace` and
remaps the in-container `builder` user's UID/GID to match the host
owner before dropping privileges, so files written from inside the
container land on the host with correct ownership — no `--user`
flag, no post-build chown. The `build-env` compose service passes
`HOSTUID` / `HOSTGID` through, so if the auto-detection ever fails
(a root-owned source dir, a CI matrix), set them in `.env` to your
`id -u` / `id -g`.

## Build from scratch

If you want the whole chain locally (e.g. you're modifying any of
phases 01–04, or you need an audit trail of every step):

```sh
make all          # full chain → dosemu2:latest from git
make release      # PPA-based → dosemu2:release
```

(`make` is universally available on dev hosts; if you don't have it,
read it as "run the docker buildx commands in the order the Makefile
lists.")

## Image map

| Image | Size | Contents |
|---|---|---|
| `dosemu2-builder:01-pacman` | 1.4 GB | Arch base + pacman deps + builder user + parallelism config |
| `dosemu2-builder:04-aur` (also `:build-env`) | 3.1 GB | + the full DJGPP toolchain, `libsearpc`, `dj64-git`, `fdpp`, `comcom64-git`; built `.pkg.tar.zst` files archived to `/opt/aur-pkgs/`. The user-facing name for this image is `:build-env`; `:04-aur` remains as the chain-position checkpoint. |
| `dosemu2:latest` | 3.1 GB | **Runtime only.** Slim `archlinux:latest` + dosemu2 from git HEAD + AUR runtime packages. No build toolchain. |
| `dosemu2:release` | 0.4 GB | **Runtime only.** Slim `ubuntu:24.04` + dosemu2 from the PPA. |

The `dosemu2-builder` images are the *build environment*; the
`dosemu2` images are the *runtime*. Two separate Docker repos by design
so `docker images` makes the distinction obvious.

## Quick start

```sh
# Build the whole git chain (~30–60 min first time; phase 04 is the
# slow one because it compiles the DJGPP cross-compiler from source).
make all

# Run dosemu2 (git build).
docker run --rm -it dosemu2:latest

# Or the released version.
make release && docker run --rm -it dosemu2:release

# Drop into a shell with the host dosemu2 source mounted at
# /home/dosuser/src/dosemu2 (read-only).
make shell
```

The host directory `/home/andy/src/dosemu2` (override with
`DOSEMU2_SRC=...`) is bind-mounted into Phase 05 via BuildKit's
`additional_contexts` so a Phase 05 rebuild always picks up your
current source — no `git clone` inside the container.

## Common workflows

```sh
make all              # build the whole git chain
make 04-aur           # stop at the AUR checkpoint (no dosemu2 build yet)
make release          # build the PPA-based runtime
make rebuild-dosemu2  # redo phase 05 only against current host source
make rebuild-aur      # force-rebuild phase 04 (after AUR upstream bumps)
make shell            # interactive shell in dosemu2:latest
make clean            # remove every tag this Makefile produces
```

## Overrides

All Makefile variables can be set on the command line:

```sh
make all JOBS=8 DOSEMU2_SRC=$HOME/work/dosemu2
make all BUILDER_IMAGE=myorg/dosemu2-builder RUNTIME_IMAGE=myorg/dosemu2
```

| Variable | Default | Purpose |
|---|---|---|
| `BUILDER_IMAGE` | `dosemu2-builder` | Repo for the builder-phase tags (01-04). |
| `RUNTIME_IMAGE` | `dosemu2` | Repo for the runtime tags (`:latest`, `:release`). |
| `DOSEMU2_SRC` | `/home/andy/src/dosemu2` | Host path bind-mounted as the dosemu2 source. Must contain `.git/` — the `getversion` script needs it for the rich version string. |
| `JOBS` | `$(nproc)` on the host | Parallelism. Baked into `/etc/makepkg.conf` `MAKEFLAGS` (for AUR builds), `/etc/profile.d/jobs.sh` and `/etc/dosemu2-jobs.env` (for direct make), and `~/.cargo/config.toml` (for cargo). Covers gcc *and* rust builds. |

## CI / GHCR

- **`.github/workflows/build.yml`** — 5 sequential jobs that build &
  push the git chain. Each phase `needs:` the previous one so the next
  job only starts after the prior image is pushed to GHCR. Triggers on
  push to `trunk` touching any `Dockerfile.0[1-5]*`, monthly cron, and
  manual dispatch.
- **`.github/workflows/build-release.yml`** — independent job for the
  PPA-based `:release`. Triggers on push to `trunk` touching
  `Dockerfile.release`, weekly cron, and manual dispatch.

Both push to `ghcr.io/theimpossibleastronaut/dosemu2-container:*`
using `GITHUB_TOKEN` (no manual secret needed for GHCR push from a
workflow in the same repo).

## Internals worth knowing

- **paru, not paru-bin.** paru-bin's prebuilt binary is pinned to a
  specific `libalpm.so.N` and breaks whenever rolling Arch bumps
  pacman's ABI. The source compile is slower once but stable.
- **`djgpp-djcrx` build cycle.** `djgpp-djcrx` makedepends on
  `djgpp-gcc`, but `djgpp-gcc` runtime-depends on `djgpp-djcrx`. Phase
  03 installs `djgpp-djcrx-bootstrap` (which `provides=djgpp-djcrx`)
  to satisfy `djgpp-gcc`'s dep at build time; Phase 04 then replaces
  it with the full `djgpp-djcrx` after `djgpp-gcc` is up.
- **gcc-14 standard wrapper.** `djgpp-djcrx 2.05` ships K&R-style
  empty-paren function declarations that rolling Arch's gcc 16+
  rejects under C23. Its PKGBUILD strips any `-std=gnu17` we'd add to
  `CFLAGS` via `options=('!buildflags')`. Phase 04 step 2 installs a
  `/usr/local/bin/gcc` wrapper that forces `-std=gnu17`; PATH puts it
  ahead of `/usr/bin/gcc` so anything resolving `gcc` or `cc` picks it
  up.
- **comcom64-git replaces comcom32.** Phase 04 step 1 pulls in `comcom32`
  as a transitive runtime dep of fdpp; step 3 removes it explicitly
  with `pacman -Rdd` before installing `comcom64-git` (they both
  `provide=comcom64` so pacman refuses to coexist).
- **`/opt/aur-pkgs/`** holds the built AUR packages (`.pkg.tar.zst`)
  archived inside the `:04-aur` image. The runtime stage of Phase 05
  copies the archive over and `pacman -U`s them, avoiding any AUR
  rebuild in the slim runtime.
- **Source mount is read-only at build time.** Phase 05 untars the
  source (`.git` included) into `/home/builder/dosemu2` inside the
  builder stage before running `autogen.sh` / `configure` / `make`,
  so your host working tree doesn't get polluted with `.o` files.
- **Why the JOBS/MAKEFLAGS dance.** makepkg overrides `MAKEFLAGS` from
  its own config and ignores the environment, so editing
  `/etc/makepkg.conf` is required for AUR build parallelism. The env
  file + profile script cover direct `make` invocations and cargo
  builds, and `~/.cargo/config.toml` is a fallback for any rust build
  that scrubs the env.

## docker-compose

`docker-compose.yml` runs dosemu2 from a published image — no local
build needed. It pulls from Docker Hub (`andy5995/dosemu2`) by default.
Three services cover the common cases, so you don't have to remember
the long `docker run` flag lists:

```sh
# Latest released dosemu2, text mode (default):
docker compose run --rm dosemu2

# Latest dev build from git (override the tag):
TAG=latest docker compose run --rm dosemu2

# Pass arguments straight to dosemu2:
docker compose run --rm dosemu2 -td -ks -E ver

# Graphics-mode programs / games (needs xhost — see the X11 section):
docker compose run --rm gui

# Build dosemu2 from your own source:
DOSEMU2_SRC=~/src/dosemu2 docker compose run --rm build-env
```

| Service | What it does |
|---|---|
| `dosemu2` | Runs dosemu2 in text mode. Tag is `${TAG}` (default `release`; set `TAG=latest` for the dev build). Extra args pass through to dosemu2. |
| `gui` | Same image with the X11 socket and `DISPLAY` wired in; opens a shell so you can `dosemu -T`. |
| `build-env` | `:build-env` image with your source at `/workspace` (`DOSEMU2_SRC`) for building dosemu2 inside the container. |

Copy `.env.example` to `.env` to set `TAG`, the image repository
(`IMAGE`), the persistence path (`DOSEMU_HOME`), your source
(`DOSEMU2_SRC`), or build UID/GID (`HOSTUID` / `HOSTGID`) without
typing them each time — `docker compose` reads `.env` automatically.
(`.env` is gitignored; `.env.example` is the tracked template.)
