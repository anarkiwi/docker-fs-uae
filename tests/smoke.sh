#!/bin/sh
# Smoke test an FS-UAE image: tests/smoke.sh <image> [expected-version]
# Boots the emulator headlessly (no ROM needed, FS-UAE has a built in AROS
# Kickstart replacement) and checks the display, VNC and noVNC paths.
set -eu

image=${1:?usage: smoke.sh <image> [expected-version]}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
expected=${2:-$(sed -n 's/^ARG FS_UAE_VERSION=//p' "${here}/../Dockerfile")}
bare=${expected#v}
launcher_expected=$(sed -n 's/^ARG FS_UAE_LAUNCHER_VERSION=//p' "${here}/../Dockerfile")
launcher_bare=${launcher_expected#v}
boot_timeout=${FS_UAE_SMOKE_TIMEOUT:-90}

work=$(mktemp -d)
containers=
volumes=
cleanup() {
  # shellcheck disable=SC2086 # deliberately word split lists.
  [ -z "${containers}" ] || docker rm -f ${containers} >/dev/null 2>&1 || true
  # shellcheck disable=SC2086
  [ -z "${volumes}" ] || docker volume rm -f ${volumes} >/dev/null 2>&1 || true
  rm -rf "${work}"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }

# Wait for a log file to contain a pattern, or fail after boot_timeout seconds.
wait_for() {
  file=$1
  pattern=$2
  what=$3
  waited=0
  while [ "${waited}" -lt "${boot_timeout}" ]; do
    grep -q "${pattern}" "${file}" 2>/dev/null && return 0
    waited=$((waited + 1))
    sleep 1
  done
  tail -20 "${file}" >&2 2>/dev/null || true
  fail "timed out after ${boot_timeout}s waiting for ${what}"
}

# 1. Version, and no display started for a command that does not need one.
got=$(docker run --rm "${image}" fs-uae --version 2>"${work}/version.err")
[ "${got}" = "${bare}" ] || fail "fs-uae --version ${got} != ${bare}"
grep -q "starting Xvfb" "${work}/version.err" \
  && fail "--version started a display server"
env_version=$(docker run --rm --entrypoint sh "${image}" -c 'printf %s "$FS_UAE_VERSION"')
[ "${env_version}" = "${expected}" ] \
  || fail "image FS_UAE_VERSION ${env_version} != ${expected}"
ok "version ${got}"

# The launcher runs the emulator by looking for it side by side, so both must
# be in this image, along with the Python modules the launcher imports.
docker run --rm --entrypoint sh "${image}" -c \
  'test -x /usr/bin/fs-uae && test -x /usr/bin/fs-uae-device-helper \
   && test -x "$(readlink -f /usr/bin/fs-uae-launcher)"' \
  || fail "emulator and launcher are not both installed side by side"
docker run --rm --entrypoint python3 "${image}" -c \
  'import PyQt5.QtWidgets, OpenGL.GL, requests, lhafile, distutils.spawn' \
  || fail "launcher Python dependencies missing"
env_launcher=$(docker run --rm --entrypoint sh "${image}" -c \
  'printf %s "$FS_UAE_LAUNCHER_VERSION"')
[ "${env_launcher}" = "${launcher_expected}" ] \
  || fail "image FS_UAE_LAUNCHER_VERSION ${env_launcher} != ${launcher_expected}"
ok "emulator, device helper and launcher ${launcher_bare} installed together"

# 2. Headless boot, as the calling user against a bind mounted data dir.
mkdir -p "${work}/data"
name=fs-uae-smoke-$$
containers="${containers} ${name}"
docker run -d --name "${name}" \
  -u "$(id -u):$(id -g)" \
  -p 127.0.0.1::5900 -p 127.0.0.1::6080 \
  -v "${work}/data:/data" \
  "${image}" >/dev/null
log="${work}/data/Cache/Logs/fs-uae.log.txt"

wait_for "${log}" "FS-UAE ${bare}" "FS-UAE to start"
ok "emulator started, base dir on the data volume"

wait_for "${log}" "opengl renderer" "an OpenGL context"
renderer=$(sed -n 's/^opengl renderer: //p' "${log}" | head -1)
ok "opengl renderer: ${renderer}"

# The built in AROS ROM boots far enough to initialise Amiga libraries.
wait_for "${log}" 'InitResident.*exec.library' "the Amiga to boot"
ok "amiga booted (AROS Kickstart replacement)"

grep -q "\[ERROR\]" "${log}" && fail "errors logged: $(grep '\[ERROR\]' "${log}" | head -3)"
[ -d "${work}/data/Configurations" ] || fail "data dir not populated"
[ "$(find "${work}/data/Configurations" -maxdepth 0 -user "$(id -un)" | wc -l)" = 1 ] \
  || fail "data dir not owned by the calling user"
ok "data dir populated and owned by the calling user"

# 3. VNC and noVNC are serving, checked from inside the container's netns
# (python3 comes with websockify).
probe() {
  docker run --rm --network "container:${name}" --entrypoint python3 "${image}" \
    -c "$1" 2>/dev/null || true
}
handshake=$(probe 'import socket
s = socket.create_connection(("127.0.0.1", 5900), 10)
print(s.recv(11).decode(errors="replace").strip())')
case "${handshake}" in
  RFB*) ok "vnc serving (${handshake})";;
  *) fail "no RFB handshake on the VNC port (got '${handshake}')";;
esac
status=$(probe 'import socket
s = socket.create_connection(("127.0.0.1", 6080), 10)
s.sendall(b"GET /vnc.html HTTP/1.0\r\n\r\n")
print(s.recv(64).decode(errors="replace").splitlines()[0])')
case "${status}" in
  *200*) ok "novnc serving (${status})";;
  *) fail "noVNC did not return 200 (got '${status}')";;
esac

# The published ports are reachable from the host too.
vnc_port=$(docker port "${name}" 5900/tcp | head -1 | sed 's/.*://')
[ -n "${vnc_port}" ] || fail "VNC port not published"
ok "vnc published on 127.0.0.1:${vnc_port}"

docker rm -f "${name}" >/dev/null
containers=

# 4. The launcher: starts, maps its own window, and finds the emulator.
mkdir -p "${work}/launcher"
lname=fs-uae-smoke-launcher-$$
containers="${containers} ${lname}"
docker run -d --name "${lname}" -u "$(id -u):$(id -g)" \
  -v "${work}/launcher:/data" "${image}" fs-uae-launcher >/dev/null
llog="${work}/launcher/Cache/Logs/fs-uae-launcher.log.txt"

wait_for "${llog}" "Find executable: fs-uae-device-helper" "the launcher to start"
grep -q "Check executable /usr/bin/fs-uae-device-helper: YES" "${llog}" \
  || fail "launcher did not find the emulator side by side"
ok "launcher started and found the emulator"

waited=0
while [ "${waited}" -lt "${boot_timeout}" ]; do
  title=$(docker exec "${lname}" xwininfo -root -children 2>/dev/null \
    | sed -n 's/.*"\(FS-UAE Launcher [^"]*\)".*/\1/p' | head -1)
  [ -n "${title}" ] && break
  waited=$((waited + 1))
  sleep 1
done
[ -n "${title}" ] || fail "launcher never mapped a window"
case "${title}" in
  "FS-UAE Launcher ${launcher_bare}"*) ok "launcher window: ${title}";;
  *) fail "launcher window title ${title} is not version ${launcher_bare}";;
esac

# OpenGL_accelerate is the one optional module upstream expects to be absent.
for module in OpenGL lhafile distutils PyQt5 requests; do
  grep -q "No module named '${module}'" "${llog}" \
    && fail "launcher could not import ${module}"
done
ok "launcher imported its modules, including .lha support"

docker rm -f "${lname}" >/dev/null
containers=

# 5. Host display passthrough: an X server in another container, shared over a
# volume, is detected and used instead of starting Xvfb and VNC.
volume=fs-uae-smoke-x11-$$
volumes="${volumes} ${volume}"
xserver=fs-uae-smoke-x-$$
containers="${containers} ${xserver}"
docker volume create "${volume}" >/dev/null
docker run -d --name "${xserver}" -u "$(id -u):$(id -g)" \
  -v "${volume}:/tmp/.X11-unix" --entrypoint Xvfb \
  "${image}" :0 -screen 0 640x480x24 -nolisten tcp >/dev/null

mkdir -p "${work}/hostdata"
client=fs-uae-smoke-client-$$
containers="${containers} ${client}"
docker run -d --name "${client}" -u "$(id -u):$(id -g)" \
  -v "${volume}:/tmp/.X11-unix" -v "${work}/hostdata:/data" \
  "${image}" >/dev/null
hostlog="${work}/hostdata/Cache/Logs/fs-uae.log.txt"
wait_for "${hostlog}" "opengl renderer" "FS-UAE on the shared X display"
docker logs "${client}" 2>&1 | grep -q "starting Xvfb" \
  && fail "started Xvfb despite a host display being available"
ok "host X11 display used without starting Xvfb or VNC"

echo "PASS ${image} (${expected})"
