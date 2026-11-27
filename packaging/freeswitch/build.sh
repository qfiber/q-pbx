#!/usr/bin/env bash
# Builds the Q-PBX FreeSWITCH package for Debian 12 from public sources, with only the
# modules in modules.conf. Runs inside a debian:12 container (see build-in-container.sh).
# Output: /out/qpbx-freeswitch_<version>_amd64.deb
set -euo pipefail
FS_VERSION=${FS_VERSION:-v1.10.12}
SOFIA_VERSION=${SOFIA_VERSION:-v1.13.17}
BCG729_MOD_REF=${BCG729_MOD_REF:-4203247dee4719545005ec7ab9ea536fc83df1d8}  # xadhoom/mod_bcg729
SPANDSP_REF=${SPANDSP_REF:-0d2e6ac65e0e8f53d652665a743015a88bf048d4}  # newer spandsp breaks mod_spandsp in 1.10.12
PREFIX=/opt/qpbx-freeswitch
JOBS=$(nproc)
export DEBIAN_FRONTEND=noninteractive
# Run a step quietly; on failure show its last lines.
step() { echo "== $*"; "$@" > /tmp/step.log 2>&1 || { grep -n -E "error:|Error [0-9]|\*\*\*" /tmp/step.log | head -30; tail -15 /tmp/step.log; exit 1; }; }

step apt-get -qq update
step apt-get -qq install -y --no-install-recommends build-essential autoconf automake libtool libtool-bin pkg-config \
  git ca-certificates cmake yasm uuid-dev zlib1g-dev libjpeg-dev libsqlite3-dev libcurl4-openssl-dev \
  libpcre3-dev libspeex-dev libspeexdsp-dev libldns-dev libedit-dev libtiff-dev libopus-dev libsndfile1-dev \
  libssl-dev liblua5.2-dev libavformat-dev libswscale-dev \
  libopusenc-dev libopusfile-dev libshout3-dev libmp3lame-dev libmpg123-dev libbcg729-dev

src=/build && mkdir -p $src && cd $src
git clone -q --depth 1 --branch "$SOFIA_VERSION" https://github.com/freeswitch/sofia-sip.git
git clone -q https://github.com/freeswitch/spandsp.git && git -C spandsp checkout -q "$SPANDSP_REF"
git clone -q --depth 1 --branch "$FS_VERSION" https://github.com/signalwire/freeswitch.git

# sofia-sip and spandsp go into the same prefix and ship inside the package.
for lib in sofia-sip spandsp; do
  cd $src/$lib
  step ./bootstrap.sh
  step ./configure --prefix=$PREFIX
  step make -j$JOBS
  step make install
done
cd $src
export PKG_CONFIG_PATH=$PREFIX/lib/pkgconfig LD_LIBRARY_PATH=$PREFIX/lib

cd freeswitch
cp /src/modules.conf modules.conf
step ./bootstrap.sh -j
step ./configure --prefix=$PREFIX --disable-libvpx --disable-libyuv --without-pgsql --enable-core-pgsql-support=no \
  --with-rundir=/run/freeswitch --with-logfiledir=/var/log/freeswitch --with-dbdir=/var/lib/freeswitch/db \
  --with-storagedir=/var/lib/freeswitch/storage --with-recordingsdir=/var/lib/qpbx/recordings \
  LDFLAGS="-Wl,-rpath,$PREFIX/lib"
step make -j$JOBS
stage=/stage && rm -rf $stage
step make install DESTDIR=$stage
cp -a $PREFIX/lib/libsofia-sip-ua* $PREFIX/lib/libspandsp* $stage$PREFIX/lib/

# G.729 (optional codec in the spec; patents expired): mod_bcg729 against Debian's libbcg729.
git clone -q https://github.com/xadhoom/mod_bcg729.git $src/mod_bcg729 && git -C $src/mod_bcg729 checkout -q "$BCG729_MOD_REF"
step gcc -fPIC -O2 -shared -I$stage$PREFIX/include/freeswitch -o $stage$PREFIX/lib/freeswitch/mod/mod_bcg729.so \
  $src/mod_bcg729/mod_bcg729.c -lbcg729
# Config comes from Q-PBX (Ansible and mod_xml_curl), not from the vanilla samples.
rm -rf $stage$PREFIX/etc/freeswitch/* $stage$PREFIX/include $stage$PREFIX/lib/pkgconfig
find $stage$PREFIX/lib -name '*.la' -delete
strip --strip-unneeded $stage$PREFIX/bin/* $stage$PREFIX/lib/*.so* $stage$PREFIX/lib/freeswitch/mod/*.so 2>/dev/null || true

# Runtime dependencies: the Debian packages that own the shared libraries we link against.
# Debian 12 merges /usr: ldd may print /lib/... while dpkg records /usr/lib/... (or the reverse).
owner() {
  local f=$1 alt
  case $f in /usr/*) alt=${f#/usr} ;; *) alt=/usr$f ;; esac
  dpkg -S "$f" 2>/dev/null || dpkg -S "$alt" 2>/dev/null || dpkg -S "$(readlink -f "$f")" 2>/dev/null \
    || { echo "no package owns $f" >&2; return 1; }
}
libs=$(find $stage -type f \( -name '*.so*' -o -path '*/bin/*' \) -exec ldd {} \; 2>/dev/null \
  | awk '/=> \// {print $3}' | grep -v "^$PREFIX" | sort -u)
pkgs=$(for l in $libs; do owner "$l"; done | cut -d: -f1 | sort -u | grep -v '^libc6$')
deps=$(echo "$pkgs" | paste -sd, | sed 's/,/, /g')
# Build stamp, so every build is a new package version (apt upgrades even with the same FreeSWITCH).
ver="${FS_VERSION#v}+qpbx$(date -u +%Y%m%d%H%M%S)"
mkdir -p $stage/DEBIAN
cat > $stage/DEBIAN/control <<CTL
Package: qpbx-freeswitch
Version: $ver
Architecture: amd64
Maintainer: qFiber <ops@qfiber.co.il>
Depends: libc6, $deps
Description: FreeSWITCH for Q-PBX
 FreeSWITCH $ver with sofia-sip $SOFIA_VERSION and spandsp, built with only the modules Q-PBX uses.
CTL
dpkg-deb --build --root-owner-group $stage /out/qpbx-freeswitch_${ver}_amd64.deb >/dev/null
echo "built /out/qpbx-freeswitch_${ver}_amd64.deb"
dpkg-deb -I /out/qpbx-freeswitch_${ver}_amd64.deb | grep Depends
