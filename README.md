# docker-fs-uae

[FS-UAE](https://fs-uae.net/), the cross platform Amiga emulator, and FS-UAE Launcher, in
one container image: run them headlessly over VNC/noVNC, or on a host X11 display. Both
are in the same image, because the launcher runs the emulator by finding it side by side
on `PATH`.

Image versions match the upstream FS-UAE release exactly: image `v3.2.35` runs FS-UAE
`3.2.35`, built from the pinned, checksummed upstream source releases of the emulator and
the launcher. A daily workflow opens a pull request when upstream publishes a new stable
release of either.

## Images

    ghcr.io/anarkiwi/docker-fs-uae:v3.2.35
    docker.io/anarkiwi/fs-uae:v3.2.35

Tags: `vX.Y.Z`, `X.Y.Z`, `latest`. linux/amd64.

## Use

FS-UAE state (configurations, floppies, hard drives, Kickstarts, save states) lives in the
base directory, `/data` by default. Mount a directory there and run as yourself so the
files stay yours:

    docker run --rm -p 5900:5900 -p 6080:6080 \
      -u $(id -u):$(id -g) -v ~/FS-UAE:/data \
      ghcr.io/anarkiwi/docker-fs-uae:latest \
      fs-uae /data/Configurations/MyGame.fs-uae

With no host X11 display available the container starts its own Xvfb, exports it on
VNC port 5900, and serves noVNC on <http://localhost:6080/vnc.html>.

To use the host's display (and GPU, and sound) instead, pass them in — `bin/fs-uae-docker`
wraps this:

    ./bin/fs-uae-docker Configurations/MyGame.fs-uae

No Kickstart ROMs are included; they are not redistributable. Put your own in
`Kickstarts` under the base directory, or use FS-UAE's built in AROS Kickstart replacement
(the default when no ROM is found).

## Launcher

Run `fs-uae-launcher` instead of the emulator. Mount an existing FS-UAE directory **at the
same path it has on the host** and set `FS_UAE_DATA_DIR` to it: the launcher's settings and
database store absolute paths, so an existing setup keeps resolving its configurations,
Kickstarts and hard drive images. On vek-x, where FS-UAE lives in `/home/josh/FS-UAE`:

    docker run --rm \
      -u $(id -u):$(id -g) \
      -e FS_UAE_DATA_DIR=/home/josh/FS-UAE \
      -v /home/josh/FS-UAE:/home/josh/FS-UAE \
      -e DISPLAY -v /tmp/.X11-unix:/tmp/.X11-unix --device /dev/dri \
      -v $XDG_RUNTIME_DIR/pulse/native:/tmp/pulse-native \
      ghcr.io/anarkiwi/docker-fs-uae:latest fs-uae-launcher

That runs on the host's X display and GPU, with sound through the desktop sound server —
PulseAudio or PipeWire, whichever provides `$XDG_RUNTIME_DIR/pulse/native`. `--device
/dev/snd` on its own is not enough on a desktop, because the sound server holds the ALSA
devices and OpenAL then has nothing to open.

Drop the `DISPLAY`, `/tmp/.X11-unix` and `--device` arguments and add
`-p 5900:5900 -p 6080:6080` to get the same launcher over VNC and noVNC instead:

    docker run --rm \
      -u $(id -u):$(id -g) \
      -e FS_UAE_DATA_DIR=/home/josh/FS-UAE \
      -v /home/josh/FS-UAE:/home/josh/FS-UAE \
      -p 127.0.0.1:5900:5900 -p 127.0.0.1:6080:6080 \
      ghcr.io/anarkiwi/docker-fs-uae:latest fs-uae-launcher

Games the launcher runs are started by the emulator in the same container, so no extra
setup is needed. Media referenced by absolute paths outside the base directory (hard drive
images under `/usr/local`, a shared folder in `/home/josh/tmp`) needs its own `-v` mount at
the same path.

See [docs/usage.md](docs/usage.md) for configuration, VNC passwords, GPU and audio
passthrough, and [docs/releasing.md](docs/releasing.md) for the release and upstream
tracking workflows.

## Test

    docker build -t fs-uae:test .
    tests/smoke.sh fs-uae:test

The smoke test boots the emulator headlessly with the AROS Kickstart replacement, checks
an OpenGL context is created and the Amiga reaches library init, checks VNC and noVNC are
serving, starts the launcher and checks it maps its window and finds the emulator side by
side, and checks a shared host X11 display is used when one is present.

## Scope

The image holds the emulator, `fs-uae-device-helper` and FS-UAE Launcher, plus the
launcher's optional `lhafile` dependency for `.lha` (WHDLoad) archives. Arcade mode comes
with the launcher: run `fs-uae-launcher --arcade`.

FS-UAE and FS-UAE Launcher are GPL-2.0-or-later, © Frode Solheim and contributors; this
packaging is licensed separately, see [LICENSE](LICENSE).
