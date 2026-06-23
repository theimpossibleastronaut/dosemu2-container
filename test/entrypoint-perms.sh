#!/bin/bash
# Tests the :build-env entrypoint UID-remap behaviour (entrypoint.sh).
#
# The entrypoint stats /workspace and remaps the in-container `builder`
# user to the host owner so build artifacts stay owned by you. This
# script exercises that across the cases that matter for permissions.
#
# Builds nothing — point IMAGE at the build-env image under test:
#   IMAGE=dosemu2-builder:04-aur test/entrypoint-perms.sh
# Defaults to the local `make` tag. Needs Docker; no host root needed
# (root-owned fixtures are created via throwaway containers).

set -u

IMAGE="${IMAGE:-dosemu2-builder:04-aur}"
fails=0
work="$(mktemp -d)"

cleanup() {
  # Fixtures created via bind mounts are root-owned, so remove them
  # from inside a container rather than as the host user.
  docker run --rm -v "$work":/w alpine sh -c 'rm -rf /w/* /w/.[!.]*' >/dev/null 2>&1 || true
  rmdir "$work" 2>/dev/null || true
}
trap cleanup EXIT

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

echo "Testing entrypoint of: $IMAGE"
echo

# 1. User-owned source → remap; a file built inside lands owned by the
#    host user, not root or the image's default builder UID.
src1="$work/usersrc"
mkdir -p "$src1"
touch "$src1/existing"
docker run --rm -v "$src1":/workspace "$IMAGE" \
  bash -c 'touch /workspace/built' >/dev/null 2>&1
owner=$(stat -c '%u:%g' "$src1/built" 2>/dev/null || echo missing)
want="$(id -u):$(id -g)"
if [ "$owner" = "$want" ]; then
  pass "user-owned source: build artifact owned by host user ($owner)"
else
  fail "user-owned source: expected $want, got $owner"
fi

# 2. Root-owned, non-empty workspace → can't remap onto it; entrypoint
#    must warn (on stderr) instead of failing silently.
src2="$work/rootsrc"
docker run --rm -v "$src2":/workspace alpine touch /workspace/rootfile >/dev/null 2>&1
err=$(docker run --rm -v "$src2":/workspace "$IMAGE" true 2>&1 >/dev/null)
if printf '%s' "$err" | grep -q 'root-owned'; then
  pass "root-owned source: warning emitted"
else
  fail "root-owned source: expected a warning, got: ${err:-<none>}"
fi

# 3. Empty workspace (the no-real-mount ad-hoc shell) → stay quiet.
src3="$work/empty"
docker run --rm -v "$src3":/workspace alpine true >/dev/null 2>&1
err=$(docker run --rm -v "$src3":/workspace "$IMAGE" true 2>&1 >/dev/null)
if printf '%s' "$err" | grep -q 'root-owned'; then
  fail "empty workspace: spurious warning: $err"
else
  pass "empty workspace: no warning"
fi

# 4. HOSTUID/HOSTGID override → wins over stat detection. Assert on the
#    remapped identity (not file ownership: an arbitrary override UID
#    that doesn't own the workspace legitimately can't write to it).
src4="$work/override"
mkdir -p "$src4"
touch "$src4/x"
ids=$(docker run --rm -e HOSTUID=4242 -e HOSTGID=4343 -v "$src4":/workspace "$IMAGE" \
  id -u -r 2>/dev/null):$(docker run --rm -e HOSTUID=4242 -e HOSTGID=4343 -v "$src4":/workspace "$IMAGE" \
  id -g -r 2>/dev/null)
if [ "$ids" = "4242:4343" ]; then
  pass "HOSTUID/HOSTGID override honoured (build user remapped to $ids)"
else
  fail "HOSTUID/HOSTGID override: expected 4242:4343, got $ids"
fi

echo
if [ "$fails" -eq 0 ]; then
  echo "All tests passed."
else
  echo "$fails test(s) failed."
fi
exit $((fails > 0 ? 1 : 0))
