# aur-pkgs/

A directory of **prebuilt Arch packages** the container chain needs
(DJGPP toolchain, `fdpp`, `dj64-git`, `comcom*-git`, `munt`,
`libsearpc`, `paru`, etc.). The chain installs them straight from
here via `pacman -U` instead of compiling them via `paru` on every
rebuild — collapses Phase 04 from a ~30-minute djgpp-gcc build to a
few-second `pacman -U`.

## Not a pacman repo, just a dir of .zst files

Earlier iterations of this tried to maintain a `repo-add` index
(`dosemu2-deps.db.tar.gz` etc.) here, but pacman only needs that for
`pacman -S` resolution against a configured `[reponame]` in
`pacman.conf`. We always install via `pacman -U <path>.pkg.tar.zst`,
which reads files by path — no database needed. So this is just a
plain directory of `.pkg.tar.zst` files, tracked in Git LFS.

The Dockerfiles bind-mount this directory at `/tmp/aur-pkgs` for the
duration of the install (`RUN --mount=type=bind,source=aur-pkgs,
target=/tmp/aur-pkgs pacman -U ...`), so the files never get baked
into a Docker layer.

## Scope: internal to this repo's build chain

External Arch users should still go through the AUR directly
(`paru -S fdpp dj64-git ...`) — this isn't a publicly-consumable
repo. Pacman doesn't follow Git LFS pointer redirects, and we don't
publish the `.pkg.tar.zst` to a flat HTTP endpoint.

## Updating an existing package

Drop the new `.pkg.tar.zst` into this directory, delete the old one,
commit:

```sh
mv ~/Downloads/fdpp-1.10-1-x86_64.pkg.tar.zst aur-pkgs/
rm aur-pkgs/fdpp-1.9-1-x86_64.pkg.tar.zst
git add aur-pkgs/
git commit -m "aur-pkgs: bump fdpp to 1.10-1"
```

## Adding a new package (workflow path)

For new AUR deps you don't have prebuilt locally, the easiest path is
the `build-aur-pkg.yml` workflow:

1. **Actions → "Build an AUR package" → Run workflow**, enter the
   AUR package name (e.g. `dj64-git`).
2. When the run finishes, **download the workflow artifact**. You'll
   get one or more `.pkg.tar.zst` (handles split PKGBUILDs that
   produce multiple subpackages).
3. **Drop the file(s) into `aur-pkgs/`** and commit + push.
4. The next `build.yml` run picks up the new file via the
   `aur-pkgs/**` path trigger and republishes `:build-env` / `:latest`.

The workflow deliberately doesn't auto-commit — keeps the human in
the loop on what enters the binary repo and avoids feedback loops
with `build.yml`.

## Adding a new package (local path)

If you'd rather build locally:

```sh
docker run --rm -v "$PWD/aur-pkgs:/out" \
    ghcr.io/theimpossibleastronaut/dosemu2-container:build-env \
    bash -c 'paru -S --noconfirm --rebuild --mflags=--nocheck <pkg> \
             && cp /home/builder/.cache/paru/clone/**/*.pkg.tar.zst /out/'

git add aur-pkgs/
git commit -m "aur-pkgs: add <pkg>"
```
