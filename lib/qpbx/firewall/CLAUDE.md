# Firewall (`QPBX.Firewall`)

**Purpose:** platform and tenant allow/block lists, applied to named nftables sets through the
`qpbx-fwd` helper. Kamailio sync arrives in phase 2.

**Public API:** none yet.

**Events emitted:** none yet. **Events consumed:** none yet.

**Gotchas:** the app never runs `nft` itself; only `qpbx-fwd` holds `CAP_NET_ADMIN`.
