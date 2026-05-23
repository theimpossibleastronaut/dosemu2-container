# dosemu2 builder (Arch + git)

A phased Docker build of [dosemu2](https://github.com/dosemu2/dosemu2)
from upstream git on Arch Linux. Each phase produces a checkpointed
image so re-running the later, more volatile phases (AUR refresh,
dosemu2 source edit) doesn't redo the earlier, expensive ones (pacman
install, paru bootstrap, DJGPP toolchain build).

## Quick start

```sh
make all                    # chain through every phase, ~30–60 min first time
docker compose run --rm shell
# … inside the container:
dosemu                      # run the dosemu2 installed during build
cd /workspace && ./autogen.sh && ./default-configure && make   # rebuild against host source
```

The host directory `/home/andy/src/dosemu2` is bind-mounted into the
container at `/workspace` for in-container iteration.

## Phases

| Phase | Tag | What runs | Why split here |
|---|---|---|---|
| 01 | `:01-pacman` | Arch base + pacman deps + builder user + parallelism config | Stable. Rarely needs rerunning. |
| 02 | `:02-paru` | Source-build paru (rust compile) | Stable. Only rerun when paru / libalpm bumps. |
| 03 | `:03-djcrx` | Install `djgpp-djcrx-bootstrap` | Stable. Breaks the djgpp-djcrx ⇄ djgpp-gcc cycle. |
| 04 | `:04-aur` | Build & install libsearpc, dj64-git, fdpp, comcom64-git + transitive AUR deps; archive `.pkg.tar.zst` to `/opt/aur-pkgs/` | Rerun monthly when AUR updates. |
| 05 | `:05-build`, `:latest` | Bind-mount `/home/andy/src/dosemu2`, build dosemu2 | Rerun every time dosemu2 source changes. |

## Common workflows

```sh
make all              # build the whole chain
make 04-aur           # stop at the AUR checkpoint (no dosemu2 build yet)
make rebuild-dosemu2  # rebuild just phase 05 against current host source
make rebuild-aur      # force-rebuild phase 04 (after AUR upstream bumps)
make shell            # interactive shell in :latest with source mounted RO
make clean            # remove all dosemu2-builder:* tags
```

## Overrides

All Makefile variables can be set on the command line:

```sh
make all IMAGE=myorg/dosemu2-builder JOBS=4 DOSEMU2_SRC=$HOME/work/dosemu2
```

| Variable | Default | Purpose |
|---|---|---|
| `IMAGE` | `dosemu2-builder` | Image repo. Each phase tag = `$(IMAGE):NN-name`. |
| `DOSEMU2_SRC` | `/home/andy/src/dosemu2` | Host path bind-mounted as the dosemu2 source for phase 05. |
| `JOBS` | _(nproc inside the buildkit builder)_ | Parallelism. Baked into `/etc/makepkg.conf` `MAKEFLAGS`, `/etc/profile.d/jobs.sh` (`MAKEFLAGS`, `JOBS`, `CARGO_BUILD_JOBS`), `/etc/dosemu2-jobs.env`, and `~/.cargo/config.toml`. Covers gcc *and* rust builds. |

## Internals worth knowing

- **paru, not paru-bin.** paru-bin's prebuilt binary is pinned to a
  specific `libalpm.so.N` and breaks whenever rolling Arch bumps
  pacman's ABI. The source compile is slower once but stable.
- **`/opt/aur-pkgs/`** holds the built AUR packages (`.pkg.tar.zst`)
  after phase 04. They're not under `~/.cache/paru` (which `paru -Sc`
  would clear) so the layer that produced them is the canonical cache.
- **Source mount is read-only at build time.** Phase 05 untars the
  source into `/home/builder/dosemu2` inside the image before running
  `autogen.sh` / `configure` / `make`, so your host working tree
  doesn't get polluted with `.o` files or generated autoconf output.
- **Why the JOBS/MAKEFLAGS dance.** makepkg overrides `MAKEFLAGS` from
  its own config and ignores the environment, so editing
  `/etc/makepkg.conf` is required for AUR build parallelism. The env
  file + profile script cover direct `make` invocations and cargo
  builds, and `~/.cargo/config.toml` is a fallback for any rust build
  that scrubs the env.

## docker-compose

`docker-compose.yml` defines two services that consume `:latest`:

- `dosemu2` — `ENTRYPOINT ["dosemu"]`; `docker compose run --rm dosemu2` starts dosemu2 in a terminal.
- `shell` — interactive bash with `/workspace` = your host source, for rebuild iteration inside the container.

Both mount the host source RW at `/workspace` (override via `DOSEMU2_SRC` env) and a named volume at `~/.dosemu` for DOS persistence.
