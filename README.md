# dosemu2-container

Docker images of [dosemu2](https://github.com/dosemu2/dosemu2), in
four flavors:

- **`:latest`** — Alpine + dosemu2 from upstream git (`devel`), built
  with GUI (SDL3/X11) support.
- **`:latest-headless`** — the same source compiled without GUI
  support; much smaller, text-mode only.
- **`:release`** — Ubuntu + dosemu2 from the official PPA, the
  latest released version.
- **`:build-env`** — the toolchain `:latest`/`:latest-headless` are
  built on top of: Alpine with binutils, `dj64dev`, `comcom64`,
  `fdpp`, `libsearpc`, etc. preinstalled. Bind-mount your dosemu2
  source and run `./autogen.sh && ./configure && make && make
  install` — see "Build dosemu2 locally against your own source"
  below.

All four are built and pushed to
[`ghcr.io/theimpossibleastronaut/dosemu2-container`](https://github.com/theimpossibleastronaut/dosemu2-container/pkgs/container/dosemu2-container).

The Alpine build chain (`:latest`, `:latest-headless`, `:build-env`)
is adapted from dosemu2 upstream's own
[`Dockerfile.alpine`](https://github.com/dosemu2/dosemu2/blob/devel/Dockerfile.alpine),
written by Stas Sergeev ([stsp](https://github.com/stsp)) — see
[issue #10](https://github.com/theimpossibleastronaut/dosemu2-container/issues/10).
Credit to him for the toolchain recipe (binutils targeting
`i686-unknown-linux-gnu`, `dj64dev`, `comcom64`, `fdpp`, `thunk_gen`,
`smallerc`, `djstub`, `libsearpc`, all built from source) that gets
this down to a fraction of the old Arch-based image size. This repo
splits his single Dockerfile into a cacheable phase chain and adds
back GUI (SDL3/X11) support as an option.

## Docker is the only build dependency

Everything dosemu2 needs to compile — the Alpine base, binutils, the
`dj64dev`/`comcom64`/`fdpp`/`libsearpc` toolchain — is built and lives
inside the container chain. You need Docker on your host and that's
it. No global apk/apt install on the host.

## Use the published images

### Pull & run

The runtime images are on GHCR — no compilation needed:

```sh
# Latest dosemu2 from upstream git (devel branch HEAD at last CI build):
docker run --rm -it ghcr.io/theimpossibleastronaut/dosemu2-container:latest

# Latest released dosemu2 from the Ubuntu PPA:
docker run --rm -it ghcr.io/theimpossibleastronaut/dosemu2-container:release
```

The same `:latest`, `:latest-headless`, `:release`, and `:build-env`
images are also published to Docker Hub at
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
games. dosemu's DOS-side CWD stays at `C:\` regardless of the
host's `-w` flag, so the game can't find its data files and
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
./configure
make -j$(nproc)
make install        # if you want to run it inside the container
dosemu               # try it
```

(Without compose, the equivalent is `docker run --rm -it -v
~/src/dosemu2:/workspace
ghcr.io/theimpossibleastronaut/dosemu2-container:build-env`.)

The container provides every build dep (binutils, `dj64dev`,
`comcom64`, `fdpp`, `libsearpc`, etc.); your host only has Docker.
The bind mount is read-write, so `make`'s `.o` files land in your
host source tree — same as a native build. If you'd rather keep the
host source clean, clone this repo and let Phase 04 untar into an
internal scratch dir:

```sh
git clone https://github.com/theimpossibleastronaut/dosemu2-container.git
cd dosemu2-container
docker buildx build --builder default --load --target runtime \
    --build-context dosemu2=~/src/dosemu2 \
    -f Dockerfile.04-build \
    -t dosemu2:latest \
    .
```

The Dockerfiles default their `BASE` to the published GHCR images,
so the `:build-env` builder gets pulled automatically — no `docker
pull` or local tag needed.

The image's entrypoint stats the bind-mounted `/workspace`, remaps
the in-container `builder` user's UID/GID to match the host owner,
then drops privileges. Files written from inside the container land
on the host with correct ownership — no `--user` flag, no post-build
chown. The `build-env` compose service passes
`HOSTUID` / `HOSTGID` through, so if the auto-detection ever fails
(a root-owned source dir, a CI matrix), set them in `.env` to your
`id -u` / `id -g`.

`docker exec` skips the entrypoint, so it lands in the container as
root and none of the above applies to it. Pass `--user builder` for
anything that writes to `/workspace` or runs a build:

```sh
docker exec --user builder -w /workspace <container> make
```

Building as root there leaves root-owned objects in your source tree,
and dosemu2's own test suite behaves differently: it refuses `exec`
under root, so `test_serial_simple_read_echo` fails for a reason that
has nothing to do with the code under test.

## Build from scratch

If you want the whole chain locally (e.g. you're modifying any
phase, or you need an audit trail of every step):

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
| `dosemu2-builder:01-base` | 1.1 GB | Alpine base + apk build deps (incl. GUI build deps) |
| `dosemu2-builder:02-binutils` | 1.3 GB | + `binutils-gdb` built for `i686-unknown-linux-gnu` |
| `dosemu2-builder:03-toolchain` (also `:build-env`) | 1.3 GB | + `thunk_gen`, `fdpp`, `smallerc`, `djstub`, `dj64dev`, `comcom64`, `libsearpc`, all built from source. The user-facing name for this image is `:build-env`; `:03-toolchain` remains as the chain-position checkpoint. |
| `dosemu2:latest` | 118 MB | **Runtime only.** Slim `alpine:3.21` + dosemu2 from git HEAD, with SDL3/X11 GUI support. No build toolchain. |
| `dosemu2:latest-headless` | 73 MB | **Runtime only.** Compiled without SDL3/X11/audio — text mode only, smallest image. |
| `dosemu2:release` | 0.4 GB | **Runtime only.** Slim `ubuntu:24.04` + dosemu2 from the PPA. |

The `dosemu2-builder` images are the *build environment*; the
`dosemu2` images are the *runtime*. Two separate Docker repos by design
so `docker images` makes the distinction obvious.

## Quick start

```sh
# Build the whole git chain (phase 02, building binutils from source,
# is the slow one — everything after it is fast).
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
`DOSEMU2_SRC=...`) is bind-mounted into Phase 04 via BuildKit's
`additional_contexts` so a Phase 04 rebuild always picks up your
current source — no `git clone` inside the container.

## Common workflows

```sh
make all               # build the whole git chain → dosemu2:latest
make build-env         # stop at the toolchain checkpoint
make headless          # build only dosemu2:latest-headless
make release           # build the PPA-based runtime
make rebuild-dosemu2   # redo phase 04 only against current host source
make rebuild-toolchain # force-rebuild phase 03 (after a toolchain component bumps)
make shell             # interactive shell in dosemu2:latest
make clean             # remove every tag this Makefile produces
```

## Overrides

All Makefile variables can be set on the command line:

```sh
make all DOSEMU2_SRC=$HOME/work/dosemu2
make all BUILDER_IMAGE=myorg/dosemu2-builder RUNTIME_IMAGE=myorg/dosemu2
```

| Variable | Default | Purpose |
|---|---|---|
| `BUILDER_IMAGE` | `dosemu2-builder` | Repo for the builder-phase tags (01-03). |
| `RUNTIME_IMAGE` | `dosemu2` | Repo for the runtime tags (`:latest`, `:latest-headless`, `:release`). |
| `DOSEMU2_SRC` | `/home/andy/src/dosemu2` | Host path bind-mounted as the dosemu2 source. Must contain `.git/` — the `getversion` script needs it for the rich version string. |

## CI / GHCR

- **`.github/workflows/build.yml`** — sequential jobs that build &
  push the chain (01 → 02 → 03 → latest/latest-headless). Each phase
  `needs:` the previous one, so the next job only starts after the
  prior image is pushed to GHCR. `:03-toolchain` / `:build-env` is
  built locally first and published only if
  `test/entrypoint-perms.sh` passes against it. Triggers on push to
  `trunk` touching the Dockerfiles or `entrypoint.sh`, weekly cron,
  and manual dispatch.
- **`.github/workflows/build-release.yml`** — independent job for the
  PPA-based `:release`. Triggers on push to `trunk` touching
  `Dockerfile.release`, weekly cron, and manual dispatch.
- **`.github/workflows/ghcr-cleaner.yml`** — monthly cron and manual
  dispatch. Deletes untagged GHCR versions using
  `Chizkiyahu/delete-untagged-ghcr-action`.

Both build workflows push to
`ghcr.io/theimpossibleastronaut/dosemu2-container:*` using
`GITHUB_TOKEN` (no manual secret needed for GHCR push from a workflow
in the same repo), and mirror the user-facing tags to Docker Hub.

## Internals worth knowing

- **SDL3 and `libb64` come from Alpine's `edge` repos.** Alpine 3.21
  stable doesn't package SDL3 (dosemu2 needs SDL3, not SDL2) or
  `libb64`; both get pulled from `edge/community` and `edge/testing`
  respectively via an explicit `--repository=` flag on top of the
  3.21 base, same as upstream's Dockerfile.alpine does for `libb64`.
- **`:latest` and `:latest-headless` are compiled separately.**
  dosemu2's `configure` decides which plugins to build by autodetecting
  libs, and the resulting binary calls `load_plugin()` for every plugin
  it was compiled with. Reusing one build for both images therefore
  made the headless one `dlopen` sdl/X/XKmaps/alsa/fluidsynth at every
  startup and print an `ERROR` per failure, since those libs aren't
  installed there. Deleting the plugin files doesn't help —
  `load_plugin()` reports a missing file just as loudly. So Phase 04
  has a second builder stage that removes the GUI/audio `-dev` packages
  before `./configure`, which drops those plugins from the build
  entirely. It costs a second dosemu2 compile and yields a headless
  image that starts clean.
- **Source mount is read-only at build time.** Phase 04 untars the
  source (`.git` included) into `/root/dosemu2` inside the builder
  stage before running `autogen.sh` / `configure` / `make`, so your
  host working tree doesn't get polluted with `.o` files.
- **binutils gets its own phase.** Building `binutils-gdb` from a live
  sourceware.org clone is the slowest and most network-fragile step in
  the chain, so it's isolated in Phase 02 — a failure there doesn't
  force Phase 01 or the rest of the toolchain (Phase 03) to redo any
  work.
- **Every toolchain component is pinned.** Upstream's
  `Dockerfile.alpine` clones each one at its default-branch `HEAD`,
  which makes a build unreproducible and lets an unrelated upstream
  push break `:build-env` and every image below it. Phase 02 pins
  binutils to a release tag (`BINUTILS_REF`); Phase 03 pins the seven
  GitHub components to commit SHAs (`FDPP_REF`, `DJ64DEV_REF`, …).
  Each is an overridable `ARG`, so testing a newer one is a
  `--build-arg` away:

  ```sh
  docker buildx build --build-arg FDPP_REF=<sha> -f Dockerfile.03-toolchain .
  ```

  These components move with dosemu2 itself, so building `:latest`
  from a much newer dosemu2 `devel` may need several bumped together.
- **`/usr/local` gets pruned before the runtime `COPY`.** `:03-toolchain`
  keeps its full `/usr/local` — binutils cross-tools, `dj64dev`/smallerc
  headers and static archives, locale/info/man data — because
  `:build-env` users need all of it. Phase 04's `builder` stage deletes
  that build-only bulk (~160 MB) right after `make install`, before
  either runtime stage's `COPY --from=builder /usr/local /usr/local`,
  since none of it is loaded at runtime. This is why `:latest-headless`
  is 73 MB instead of the ~250 MB a naive copy of the whole tree
  produces.

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
