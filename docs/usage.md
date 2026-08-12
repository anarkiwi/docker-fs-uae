# Usage

## Data directory

FS-UAE's base directory is `/data` in the container: `Configurations`, `Floppies`,
`Hard Drives`, `CD-ROMs`, `Kickstarts`, `Save States`, `Themes` and `Cache/Logs` are
created there on first run. Mount a host directory there, and run as yourself so files
stay owned by you:

    docker run --rm -u $(id -u):$(id -g) -v ~/FS-UAE:/data \
      ghcr.io/anarkiwi/docker-fs-uae:latest

The entrypoint passes `--base-dir=/data` to `fs-uae` and `fs-uae-launcher` unless you give
your own `--base-dir=`. Paths in options and configuration files must be container paths
under `/data`, so mount media where FS-UAE expects it:

    docker run --rm -u $(id -u):$(id -g) -v ~/FS-UAE:/data \
      ghcr.io/anarkiwi/docker-fs-uae:latest \
      fs-uae --amiga-model=A1200 --floppy-drive-0=/data/Floppies/game.adf

Set `FS_UAE_DATA_DIR` if you mount the data directory somewhere other than `/data`.

## Launcher

FS-UAE Launcher is in the same image as the emulator, which is what makes it able to start
games: it finds `fs-uae` and `fs-uae-device-helper` side by side in `/usr/bin`, exactly as
it would in a native install.

    docker run --rm -p 5900:5900 -p 6080:6080 \
      -u $(id -u):$(id -g) -v ~/FS-UAE:/data \
      ghcr.io/anarkiwi/docker-fs-uae:latest fs-uae-launcher

`fs-uae-launcher --arcade` starts Arcade mode instead.

### Mount an existing setup at its own path

The launcher records absolute paths — the last configuration in `Data/Settings.ini`, scan
results and game file locations in `Data/Databases/*.sqlite`. Mounting an existing FS-UAE
directory at `/data` leaves those paths dangling, and the launcher falls back to
re-scanning. Mount it at the path it already has instead, and point `FS_UAE_DATA_DIR`
there:

    docker run --rm \
      -u $(id -u):$(id -g) \
      -e FS_UAE_DATA_DIR=/home/josh/FS-UAE \
      -v /home/josh/FS-UAE:/home/josh/FS-UAE \
      -e DISPLAY -v /tmp/.X11-unix:/tmp/.X11-unix \
      --device /dev/dri --device /dev/snd \
      ghcr.io/anarkiwi/docker-fs-uae:latest fs-uae-launcher

Media referenced from configurations but stored outside the base directory needs mounting
the same way, at its host path, or FS-UAE logs `WARNING: HD not found` and carries on
without it.

`.lha` (WHDLoad) archives work: the optional `lhafile` module is installed. The launcher's
online features (logging in, downloading from the game database) need outbound HTTPS, which
the default bridge network provides.

## Kickstart ROMs

None are included; Amiga ROMs are not redistributable. Copy your own into
`/data/Kickstarts` (FS-UAE scans that directory), or let FS-UAE fall back to its built in
AROS Kickstart replacement, which boots but is not compatible with every title.

## Headless (VNC and noVNC)

With no host X11 display the container starts `Xvfb`, `x11vnc` and noVNC:

    docker run --rm -p 5900:5900 -p 6080:6080 -v ~/FS-UAE:/data \
      ghcr.io/anarkiwi/docker-fs-uae:latest

* VNC client: `localhost:5900`
* Browser: <http://localhost:6080/vnc.html>

Rendering uses Mesa's llvmpipe software rasteriser unless a GPU is passed in, so keep the
display size modest and expect fewer frames per second than native.

| Variable | Default | Purpose |
| --- | --- | --- |
| `FS_UAE_HEADLESS` | `auto` | `1` always start Xvfb, `0` never, `auto` only when no host display |
| `FS_UAE_DISPLAY_WIDTH` | `1280` | Xvfb screen width; the launcher window wants ~1240 |
| `FS_UAE_DISPLAY_HEIGHT` | `800` | Xvfb screen height |
| `FS_UAE_DISPLAY_DEPTH` | `24` | Xvfb colour depth |
| `VNC_PORT` | `5900` | x11vnc port; `0` disables VNC and noVNC |
| `NOVNC_PORT` | `6080` | noVNC port; `0` disables noVNC only |
| `VNC_PASSWORD_FILE` | `/run/secrets/vnc_password` | password file, if present |
| `FS_UAE_DATA_DIR` | `/data` | FS-UAE base directory |

### VNC password

Without a password file the VNC server is unauthenticated — publish it only on a trusted
network or bind it to localhost (`-p 127.0.0.1:5900:5900`). To require a password, provide
it as a Docker secret; `x11vnc` reads the file itself, so it never appears in the process
list or in `docker inspect`:

    echo 's3cret' | docker secret create vnc_password -    # swarm
    docker run --rm -v ~/vnc_password:/run/secrets/vnc_password:ro ...   # plain docker

Note noVNC's HTTP endpoint is plain HTTP; put it behind a TLS reverse proxy if it leaves
the host.

## Host X11 display

Mounting the X11 socket makes the entrypoint skip Xvfb and VNC and use your display
directly, which is faster and gets you real GPU rendering:

    docker run --rm -u $(id -u):$(id -g) \
      -e DISPLAY -v /tmp/.X11-unix:/tmp/.X11-unix \
      --device /dev/dri --device /dev/snd \
      -v ~/FS-UAE:/data ghcr.io/anarkiwi/docker-fs-uae:latest

`bin/fs-uae-docker` does that for you, mounting the current directory (or
`FS_UAE_DATA_DIR`) as the base directory and adding `/dev/dri` and `/dev/snd` when the host
has them:

    ./bin/fs-uae-docker Configurations/MyGame.fs-uae
    FS_UAE_IMAGE=ghcr.io/anarkiwi/docker-fs-uae:v3.2.35 ./bin/fs-uae-docker --help

| Variable | Default | Purpose |
| --- | --- | --- |
| `FS_UAE_IMAGE` | `ghcr.io/anarkiwi/docker-fs-uae:latest` | image to run |
| `FS_UAE_DOCKER` | `docker` | container runtime |
| `FS_UAE_DATA_DIR` | `$PWD` | host directory mounted at `/data` |
| `FS_UAE_DOCKER_OPTS` | | extra `docker run` options, word split |

If your X server needs authorisation, the wrapper mounts `$XAUTHORITY`. `xhost` rules
otherwise apply as usual.

## Audio

Sound is silenced (`ALSOFT_DRIVERS=null`) when the container has neither `/dev/snd` nor
`PULSE_SERVER`, which keeps OpenAL quiet in headless runs. Pass `--device /dev/snd` for
ALSA, or point OpenAL at PulseAudio/PipeWire:

    -e PULSE_SERVER=unix:/run/user/1000/pulse/native \
    -v /run/user/$(id -u)/pulse/native:/run/user/1000/pulse/native

## Input

Joysticks and gamepads need their device nodes passed in (`--device /dev/input/js0`, or
`-v /dev/input:/dev/input` plus `--group-add` for the `input` group). Keyboard and mouse
come from whichever display the emulator is using — the VNC session, or your X server.

## Other commands

Anything else in the image can be run instead of the emulator, and still gets a display:

    docker run --rm ghcr.io/anarkiwi/docker-fs-uae:latest xdpyinfo

`fs-uae --version` and `fs-uae --help` are special cased: they do not start a display.
Use `--entrypoint` to bypass the entrypoint entirely:

    docker run --rm --entrypoint sh ghcr.io/anarkiwi/docker-fs-uae:latest -c 'ls /data'
