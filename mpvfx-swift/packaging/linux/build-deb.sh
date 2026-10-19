#!/bin/sh
#===----------------------------------------------------------------------===#
#
# This source file is part of MpVFX.
#
# Copyright (c) 2026 Arshiya Rahgozar.
#
# Licensed under either of the Apache License, Version 2.0 (LICENSE-APACHE or
# http://www.apache.org/licenses/LICENSE-2.0) or the MIT license (LICENSE-MIT
# or http://opensource.org/licenses/MIT), at your option.
#
# SPDX-License-Identifier: MIT OR Apache-2.0
#
#===----------------------------------------------------------------------===#
# Build the Debian/Ubuntu package from a release build.
# Run from mpvfx-swift/ after the release build (CI: `swift build -c release --static-swift-stdlib`):
#   sh packaging/linux/build-deb.sh <dist-dir> <bin-dir>
# Writes <dist-dir>/mpvfx_<version>_amd64.deb (prints its path last). Install: sudo apt install ./mpvfx_*.deb
# Layout: the app in /opt/mpvfx, `mpvfx` on PATH, a menu entry and icons under /usr/share.
# Depends: the packages owning each library the binary links directly (objdump NEEDED -> ldconfig -> dpkg -S),
# so the list follows the build instead of being kept by hand.
set -eu

dist=${1:?usage: build-deb.sh <dist-dir> <bin-dir>}
bin=${2:?usage: build-deb.sh <dist-dir> <bin-dir>}
mkdir -p "$dist"; dist=$(cd "$dist" && pwd)
version=${MPVFX_VERSION:-$(cat packaging/VERSION)}
build=${MPVFX_BUILD:-$(git rev-parse --short HEAD 2>/dev/null || echo 0)}
arch=$(dpkg --print-architecture)
# Commit time first so that apt sees each newer build as an upgrade (a short sha alone does not sort).
stamp=$(git log -1 --format=%cd --date=format:%Y%m%d%H%M 2>/dev/null || date -u +%Y%m%d%H%M)
debver="$version+git$stamp.$build"
id=app.onetake.mpvfx
root=$(mktemp -d)/mpvfx

mkdir -p "$root/DEBIAN" "$root/opt/mpvfx" "$root/usr/bin" "$root/usr/share/applications"
cp "$bin/MpVFX" "$root/opt/mpvfx/MpVFX"
for b in "$bin"/*.resources; do if [ -e "$b" ]; then cp -R "$b" "$root/opt/mpvfx/"; fi; done
strip --strip-unneeded "$root/opt/mpvfx/MpVFX"
# The engine libraries (binaries.lock) go to /usr/lib/mpvfx; the program looks for them there.
mkdir -p "$root/usr/lib/mpvfx"
cp -L .binaries/*/lib/*.so* "$root/usr/lib/mpvfx/"
patchelf --set-rpath /usr/lib/mpvfx "$root/opt/mpvfx/MpVFX"
for c in .binaries/*/; do   # each engine's licence and third-party notices
  c=$(basename "$c"); mkdir -p "$root/usr/share/doc/mpvfx/engines/$c"
  cp .binaries/"$c"/LICENSE .binaries/"$c"/NOTICE "$root/usr/share/doc/mpvfx/engines/$c/" 2>/dev/null || true
done

cat > "$root/usr/bin/mpvfx" <<'SH'
#!/bin/sh
exec /opt/mpvfx/MpVFX "$@"
SH
chmod 755 "$root/usr/bin/mpvfx"

cat > "$root/usr/share/applications/$id.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=MpVFX
GenericName=Video Editor
Comment=Cut, grade and export video
Exec=mpvfx
Icon=$id
Terminal=false
Categories=AudioVideo;Video;AudioVideoEditing;
StartupWMClass=MpVFX
DESKTOP

for s in 16 24 32 48 64 128 256 512; do
  d="$root/usr/share/icons/hicolor/${s}x${s}/apps"; mkdir -p "$d"
  cp "packaging/icon/mpvfx-$s.png" "$d/$id.png"
done

# Package of each directly linked library.
deps=""
for lib in $(objdump -p "$root/opt/mpvfx/MpVFX" "$root"/usr/lib/mpvfx/*.so* | awk '/NEEDED/ {print $2}' | sort -u); do
  [ -e "$root/usr/lib/mpvfx/$lib" ] && continue   # shipped in the package
  path=$(ldconfig -p | awk -v l="$lib" '$1 == l && /x86-64|x86_64|aarch64|AArch64/ {print $NF; exit}')
  [ -n "$path" ] || { echo "cannot resolve $lib" >&2; exit 1; }
  pkg=$(dpkg -S "$(readlink -f "$path")" 2>/dev/null || dpkg -S "$path" 2>/dev/null || dpkg -S "/usr$path" 2>/dev/null) \
    || { echo "no package owns $path" >&2; exit 1; }
  pkg=$(echo "$pkg" | head -1 | cut -d: -f1)
  case " $deps " in *" $pkg "*) ;; *) deps="$deps $pkg" ;; esac
done
depends=$(echo $deps | tr ' ' '\n' | sort | paste -sd, - | sed 's/,/, /g')
echo "Depends: $depends" >&2

size=$(du -sk "$root" | cut -f1)
cat > "$root/DEBIAN/control" <<CONTROL
Package: mpvfx
Version: $debver
Architecture: $arch
Maintainer: Arshiya Rahgozar <57055687+marshiyar@users.noreply.github.com>
Installed-Size: $size
Depends: $depends
Section: video
Priority: optional
Homepage: https://github.com/OneTake-app
Description: native video editor
 MpVFX cuts, grades and exports video. Media is decoded, previewed and
 exported by its media engine, installed with it as a library.
CONTROL

deb="$dist/mpvfx_${debver}_$arch.deb"
dpkg-deb --root-owner-group --build "$root" "$deb" >&2
dpkg-deb --info "$deb" >&2
rm -rf "$(dirname "$root")"
echo "$deb"
