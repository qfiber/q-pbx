#!/usr/bin/env bash
# Builds qpbx-sounds: the English voice prompts (FreeSWITCH "Callie", 8 kHz) that voicemail and
# later IVRs play. Prompts only; no code. Runs inside the app build container (needs curl and
# dpkg-deb). Output: /out/qpbx-sounds_<version>_all.deb
set -euo pipefail
VERSION=1.0.53
SHA256=24a2baad88696169950c84cafc236124b2bfa63114c7c8ac7d330fd980c8db05
url=https://files.freeswitch.org/releases/sounds/freeswitch-sounds-en-us-callie-8000-$VERSION.tar.gz
work=$(mktemp -d) && trap 'rm -rf "$work"' EXIT
curl -fsSL -o "$work/sounds.tar.gz" "$url"
echo "$SHA256  $work/sounds.tar.gz" | sha256sum -c --quiet
stage=$work/stage && mkdir -p $stage/usr/share/qpbx/sounds $stage/DEBIAN
tar -xzf "$work/sounds.tar.gz" -C $stage/usr/share/qpbx/sounds
# Only what Q-PBX plays: voicemail, digits, IVR words, tones and misc words.
find $stage/usr/share/qpbx/sounds/en/us/callie -mindepth 1 -maxdepth 1 -type d \
  ! -name voicemail ! -name digits ! -name ivr ! -name misc ! -name time -exec rm -rf {} +
cat > $stage/DEBIAN/control <<CTL
Package: qpbx-sounds
Version: $VERSION
Architecture: all
Maintainer: qFiber <ops@qfiber.co.il>
Description: English voice prompts for Q-PBX
 The FreeSWITCH "Callie" English prompts (8 kHz) used by voicemail and IVRs.
CTL
dpkg-deb --build --root-owner-group $stage /out/qpbx-sounds_${VERSION}_all.deb >/dev/null
