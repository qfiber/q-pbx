# qpbx-fwd (Go)

**Purpose:** the only component that changes nftables. Runs as its own systemd service with
`CAP_NET_ADMIN`; the Elixir app (no root) talks to it over a Unix socket.

**Protocol:** one JSON line per connection, one JSON line back (`{"ok":true}` or
`{"ok":false,"error":"..."}`). Exactly three operations:
- `{"op":"add","set":S,"address":A}`
- `{"op":"remove","set":S,"address":A}`
- `{"op":"replace","set":S,"addresses":[...]}` (flush and refill in one atomic nft transaction)

**Validation:** only sets named in `-sets` (`name:ipv4|ipv6`); addresses parsed with
`net/netip`, family must match, zones and IPv4-mapped IPv6 refused, prefixes masked,
duplicates and covered prefixes dropped (interval sets refuse overlaps), max 65536 elements,
unknown JSON fields refused. The nft script is built only from canonical addresses.

**State:** after every change it reads the managed sets back (`nft -j list set`) and writes
`-state` (JSON) atomically; on start it re-validates and restores that file. Element timeouts
are not supported yet (bans with TTL arrive in phase 2).

**Flags:** `-socket`, `-table` (default `inet qpbx`), `-sets`, `-state`, `-nft`, `-mode`.

**Tests:** `go test ./...` (unit, fake nft); `./integration_test.sh` (real nftables in a
Debian 12 container with `CAP_NET_ADMIN`; needs podman or docker).

**Gotchas:** the base ruleset (tables, chains, set definitions) is owned by the Ansible
`nftables` role; this helper never creates or deletes sets. Sets must be `flags interval`.
