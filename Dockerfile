# syntax=docker/dockerfile:1

# Pinned upstream releases, updated by .github/workflows/upstream-bump.yml.
# The image release version is derived from FS_UAE_VERSION; the launcher is
# released separately upstream and can lag the emulator.
ARG FS_UAE_VERSION=v3.2.35
ARG FS_UAE_SHA256=f3d3cb8d3df34b0b0125c45a5a3e187ff71050be5dc8455cc4505c0380269117
ARG FS_UAE_LAUNCHER_VERSION=v3.2.35
ARG FS_UAE_LAUNCHER_SHA256=cdfd74cd99281931a904340d414c7ebc44ddbdd0d0d599b3eb9818d58105dc25

FROM debian:trixie-slim AS build
ARG FS_UAE_VERSION
ARG FS_UAE_SHA256
SHELL ["/bin/sh", "-eux", "-c"]
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential ca-certificates curl gettext libglew-dev libglib2.0-dev \
        libgl-dev libmpeg2-4-dev libopenal-dev libpng-dev libsdl2-dev \
        libx11-dev pkg-config xz-utils zip zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
RUN version=${FS_UAE_VERSION#v} \
    && curl -fsSL -o src.tar.xz \
      "https://github.com/FrodeSolheim/fs-uae/releases/download/${FS_UAE_VERSION}/fs-uae-${version}.tar.xz" \
    && printf '%s  src.tar.xz\n' "${FS_UAE_SHA256}" > src.sha256 \
    && sha256sum -c src.sha256 \
    && tar -xJf src.tar.xz --strip-components=1 \
    && rm src.tar.xz src.sha256

RUN ./configure --prefix=/usr --disable-dependency-tracking \
    && make -j"$(nproc)" \
    && make install-strip DESTDIR=/out \
    && test -x /out/usr/bin/fs-uae

FROM debian:trixie-slim AS launcher-build
ARG FS_UAE_LAUNCHER_VERSION
ARG FS_UAE_LAUNCHER_SHA256
SHELL ["/bin/sh", "-eux", "-c"]
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates curl gettext make python3 python3-pip python3-setuptools \
        xz-utils \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /launcher
RUN version=${FS_UAE_LAUNCHER_VERSION#v} \
    && curl -fsSL -o src.tar.xz \
      "https://github.com/FrodeSolheim/fs-uae-launcher/releases/download/${FS_UAE_LAUNCHER_VERSION}/fs-uae-launcher-${version}.tar.xz" \
    && printf '%s  src.tar.xz\n' "${FS_UAE_LAUNCHER_SHA256}" > src.sha256 \
    && sha256sum -c src.sha256 \
    && tar -xJf src.tar.xz --strip-components=1 \
    && rm src.tar.xz src.sha256

# Pure Python; make install compiles the translations and lays out
# /usr/share/fs-uae-launcher with a symlink from /usr/bin.
RUN make install DESTDIR=/out prefix=/usr \
    && test -x /out/usr/share/fs-uae-launcher/fs-uae-launcher \
    && find /out -name '__pycache__' -prune -exec rm -rf {} +

# .lha support is optional for the launcher and not in Debian; the wheel lands
# in /out/usr/local/lib/python3/dist-packages, copied with the rest of /out/usr.
COPY requirements-launcher.txt .
RUN pip3 install --break-system-packages --no-cache-dir --only-binary=:all: \
      --require-hashes --root=/out -r requirements-launcher.txt \
    && rm requirements-launcher.txt

FROM debian:trixie-slim
ARG FS_UAE_VERSION
ARG FS_UAE_LAUNCHER_VERSION
SHELL ["/bin/sh", "-eux", "-c"]

# libgl1-mesa-dri gives software (llvmpipe) OpenGL, so the emulator renders
# without a GPU; xvfb/x11vnc/novnc provide the headless display served by
# entrypoint.sh. Mount /dev/dri to use the host GPU instead.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        libgl1 libgl1-mesa-dri libglew2.2 libglib2.0-0t64 libglx-mesa0 \
        libmpeg2-4 libopenal1 libpng16-16t64 libsdl2-2.0-0 zlib1g \
        novnc x11-utils x11vnc xauth xvfb \
        python3 python3-opengl python3-pyqt5 python3-pyqt5.qtopengl \
        python3-pyqt5.qtsvg python3-requests python3-setuptools \
    && rm -rf /var/lib/apt/lists/* \
    && useradd -m -u 1000 -s /bin/sh fsuae \
    && install -d -o fsuae -g fsuae /data \
    && install -d -m 1777 /tmp/.X11-unix

COPY --from=build /out/usr /usr
COPY --from=launcher-build /out/usr /usr
COPY entrypoint.sh /usr/local/bin/entrypoint.sh

ENV FS_UAE_VERSION=${FS_UAE_VERSION} \
    FS_UAE_LAUNCHER_VERSION=${FS_UAE_LAUNCHER_VERSION} \
    FS_UAE_DATA_DIR=/data \
    DISPLAY=:0 \
    FS_UAE_DISPLAY_WIDTH=1280 \
    FS_UAE_DISPLAY_HEIGHT=800 \
    VNC_PORT=5900 \
    NOVNC_PORT=6080 \
    XDG_RUNTIME_DIR=/tmp/runtime-fsuae

USER 1000:1000
WORKDIR /data
VOLUME ["/data"]
EXPOSE 5900 6080
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["fs-uae"]

LABEL org.opencontainers.image.title="FS-UAE" \
      org.opencontainers.image.description="FS-UAE Amiga emulator and Launcher, headless over VNC or on a host X11 display" \
      org.opencontainers.image.version="${FS_UAE_VERSION}" \
      org.opencontainers.image.source="https://github.com/anarkiwi/docker-fs-uae" \
      org.opencontainers.image.url="https://fs-uae.net/" \
      org.opencontainers.image.licenses="GPL-2.0-or-later"
