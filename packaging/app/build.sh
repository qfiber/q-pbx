#!/usr/bin/env bash
# Builds the Q-PBX app (mix release) and qpbx-fwd as Debian 12 packages. Runs inside the
# hexpm/elixir Debian bookworm image so the bundled Erlang runtime matches Debian 12's libraries.
# Output: /out/qpbx_<version>_amd64.deb and /out/qpbx-fwd_<version>_amd64.deb
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive MIX_ENV=prod
apt-get -qq update && apt-get -qq install -y --no-install-recommends git build-essential curl ca-certificates >/dev/null

cp -a /src/. /build/
cd /build
mix local.hex --force >/dev/null && mix local.rebar --force >/dev/null
mix deps.get --only prod
mix compile
mix assets.setup && mix assets.deploy
mix release --overwrite
version=$(sed -nE 's/^\s*version: "([^"]+)",/\1/p' mix.exs | head -1)
# Build stamp, so every build is a new package version (apt upgrades even without a version bump).
version="$version+$(date -u +%Y%m%d%H%M%S)"

stage=/stage/qpbx && mkdir -p $stage/opt $stage/DEBIAN
cp -a _build/prod/rel/qpbx $stage/opt/qpbx
cat > $stage/DEBIAN/control <<CTL
Package: qpbx
Version: $version
Architecture: amd64
Maintainer: qFiber <ops@qfiber.co.il>
Depends: libc6, libssl3, libncurses6, libstdc++6, zlib1g, coreutils
Description: Q-PBX control plane
 Elixir/Phoenix release of the Q-PBX control plane (portal, API, health endpoint).
CTL
dpkg-deb --build --root-owner-group $stage /out/qpbx_${version}_amd64.deb >/dev/null

# qpbx-fwd: static Go binary.
curl -fsSL https://go.dev/dl/go1.24.13.linux-amd64.tar.gz | tar -C /usr/local -xz
(cd /build/fwd && CGO_ENABLED=0 /usr/local/go/bin/go build -trimpath -ldflags "-s -w" -o /tmp/qpbx-fwd .)
fstage=/stage/fwd && mkdir -p $fstage/usr/sbin $fstage/DEBIAN
install -m 0755 /tmp/qpbx-fwd $fstage/usr/sbin/qpbx-fwd
cat > $fstage/DEBIAN/control <<CTL
Package: qpbx-fwd
Version: $version
Architecture: amd64
Maintainer: qFiber <ops@qfiber.co.il>
Depends: nftables
Description: Q-PBX firewall helper
 Applies Q-PBX allow and block lists to named nftables sets; the only Q-PBX part with CAP_NET_ADMIN.
CTL
dpkg-deb --build --root-owner-group $fstage /out/qpbx-fwd_${version}_amd64.deb >/dev/null

# Voice prompts (a separate package: they change rarely).
bash /src/packaging/sounds/build.sh
ls -1 /out/*.deb
