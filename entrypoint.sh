#!/bin/sh
# Run FS-UAE either on a host X11 display passed into the container, or on a
# private Xvfb display exported over VNC (and noVNC). See docs/usage.md.
set -eu

: "${FS_UAE_DATA_DIR:=/data}"
: "${FS_UAE_HEADLESS:=auto}"
: "${FS_UAE_DISPLAY_WIDTH:=1280}"
: "${FS_UAE_DISPLAY_HEIGHT:=800}"
: "${FS_UAE_DISPLAY_DEPTH:=24}"
: "${DISPLAY:=:0}"
: "${VNC_PORT:=5900}"
: "${NOVNC_PORT:=6080}"
: "${VNC_PASSWORD_FILE:=/run/secrets/vnc_password}"
: "${XDG_RUNTIME_DIR:=/tmp/runtime-fsuae}"
export DISPLAY XDG_RUNTIME_DIR

log() { echo "entrypoint: $*" >&2; }
die() { log "$*"; exit 1; }

mkdir -p "${XDG_RUNTIME_DIR}"
chmod 700 "${XDG_RUNTIME_DIR}"
mkdir -p "${FS_UAE_DATA_DIR}" 2>/dev/null || true

# With --user of an unknown uid, HOME is / and Mesa's shader cache complains.
if [ ! -w "${HOME:-/nonexistent}" ]; then
  HOME=${XDG_RUNTIME_DIR}
  export HOME
fi

[ $# -gt 0 ] || set -- fs-uae

# Keep FS-UAE state on the data volume unless the caller chose a base dir. The
# emulator and the launcher both take --base-dir.
needs_display=true
case "$1" in
  fs-uae|fs-uae-launcher)
    program=$1
    add_base_dir=true
    for arg in "$@"; do
      case "${arg}" in
        --version|--help) add_base_dir=false; needs_display=false;;
        --base-dir=*|--base_dir=*) add_base_dir=false;;
      esac
    done
    if [ "${add_base_dir}" = true ]; then
      shift
      set -- "${program}" "--base-dir=${FS_UAE_DATA_DIR}" "$@"
    fi
    ;;
esac

# Audio. A PulseAudio (or PipeWire) socket mounted in is preferred: on a desktop
# host the sound server owns the ALSA devices, so passing /dev/snd alone leaves
# OpenAL with nothing to open. libpulse looks for the socket under
# XDG_RUNTIME_DIR, which is not the host's, so point PULSE_SERVER at it.
find_pulse_socket() {
  for candidate in "${PULSE_SOCKET:-}" "${XDG_RUNTIME_DIR}/pulse/native" \
      "/run/user/$(id -u)/pulse/native" /tmp/pulse-native; do
    if [ -n "${candidate}" ] && [ -S "${candidate}" ]; then
      echo "${candidate}"
      return 0
    fi
  done
  return 1
}

if [ -z "${PULSE_SERVER:-}" ] && pulse_socket=$(find_pulse_socket); then
  PULSE_SERVER="unix:${pulse_socket}"
  export PULSE_SERVER
fi
if [ -z "${PULSE_COOKIE:-}" ] && [ -r /run/secrets/pulse_cookie ]; then
  PULSE_COOKIE=/run/secrets/pulse_cookie
  export PULSE_COOKIE
fi

if [ -n "${ALSOFT_DRIVERS:-}" ]; then
  log "audio: ALSOFT_DRIVERS=${ALSOFT_DRIVERS}"
elif [ -n "${PULSE_SERVER:-}" ]; then
  # Naming the backend skips OpenAL's failing pipewire probe first.
  export ALSOFT_DRIVERS=pulse
  log "audio: PulseAudio at ${PULSE_SERVER}"
elif [ -d /dev/snd ]; then
  log "audio: ALSA via /dev/snd"
else
  # OpenAL is noisy with no device at all, and FS-UAE logs errors per stream.
  export ALSOFT_DRIVERS=null
  log "audio: no sound server socket or /dev/snd, audio disabled"
fi

# A local display (:N[.S]) is a host display only if its socket is mounted in.
local_display=false
display_number=
case "${DISPLAY}" in
  :*) local_display=true
      display_number=${DISPLAY#:}
      display_number=${display_number%%.*};;
esac
# A remote DISPLAY (host:0) is always someone else's server; a local one is
# only usable if its socket was mounted in.
host_display=true
if [ "${local_display}" = true ] && [ ! -e "/tmp/.X11-unix/X${display_number}" ]; then
  host_display=false
fi

case "${FS_UAE_HEADLESS}" in
  1|true|yes) headless=true;;
  0|false|no) headless=false;;
  auto) if [ "${host_display}" = true ]; then headless=false; else headless=true; fi;;
  *) die "FS_UAE_HEADLESS must be auto, 1 or 0 (got ${FS_UAE_HEADLESS})";;
esac

pids=
cleanup() {
  [ -n "${pids}" ] || return 0
  # shellcheck disable=SC2086 # pids is a deliberately word split list.
  kill ${pids} 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

start_display() {
  [ "${local_display}" = true ] \
    || die "headless mode needs a local DISPLAY like :0 (got ${DISPLAY})"
  geometry="${FS_UAE_DISPLAY_WIDTH}x${FS_UAE_DISPLAY_HEIGHT}x${FS_UAE_DISPLAY_DEPTH}"
  log "starting Xvfb on ${DISPLAY} (${geometry})"
  Xvfb "${DISPLAY}" -screen 0 "${geometry}" -nolisten tcp &
  pids="${pids} $!"

  waited=0
  while [ "${waited}" -lt 100 ]; do
    xdpyinfo -display "${DISPLAY}" >/dev/null 2>&1 && return 0
    waited=$((waited + 1))
    sleep 0.1
  done
  die "Xvfb did not come up on ${DISPLAY}"
}

start_vnc() {
  set -- x11vnc -display "${DISPLAY}" -rfbport "${VNC_PORT}" \
    -forever -shared -noxdamage -quiet
  if [ -r "${VNC_PASSWORD_FILE}" ]; then
    # x11vnc reads the file itself, so the password never appears in argv.
    log "using VNC password from ${VNC_PASSWORD_FILE}"
    set -- "$@" -passwdfile "${VNC_PASSWORD_FILE}"
  else
    log "no password file at ${VNC_PASSWORD_FILE}; VNC is unauthenticated"
    set -- "$@" -nopw
  fi
  log "starting x11vnc on port ${VNC_PORT}"
  "$@" &
  pids="${pids} $!"
}

start_novnc() {
  log "starting noVNC on port ${NOVNC_PORT} (http://localhost:${NOVNC_PORT}/vnc.html)"
  websockify --web /usr/share/novnc "${NOVNC_PORT}" "localhost:${VNC_PORT}" &
  pids="${pids} $!"
}

if [ "${headless}" = true ] && [ "${needs_display}" = true ]; then
  start_display
  if [ "${VNC_PORT}" != 0 ]; then
    start_vnc
    [ "${NOVNC_PORT}" = 0 ] || start_novnc
  fi
fi

log "running: $*"
"$@" &
fs_uae_pid=$!
pids="${pids} ${fs_uae_pid}"
wait "${fs_uae_pid}"
