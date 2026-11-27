package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"net/netip"
	"regexp"
	"sort"
)

// MaxElements bounds a replace request so a client cannot exhaust memory or nft.
const MaxElements = 65536

// MaxTimeout bounds an element timeout (30 days, in seconds).
const MaxTimeout = 30 * 24 * 3600

// Family of a managed set.
type Family string

const (
	IPv4 Family = "ipv4"
	IPv6 Family = "ipv6"
)

// Request is one command from the app. Exactly three operations exist.
type Request struct {
	Op        string    `json:"op"`
	Set       string    `json:"set"`
	Address   string    `json:"address,omitempty"`
	Addresses *[]string `json:"addresses,omitempty"`
	// Timeouts (replace only): seconds until the kernel removes an element, by address.
	Timeouts map[string]int `json:"timeouts,omitempty"`
}

// Response is the single reply line.
type Response struct {
	OK    bool   `json:"ok"`
	Error string `json:"error,omitempty"`
}

// Command is a validated request: the set exists and every element is canonical.
type Command struct {
	Op       string
	Set      string
	Elements []string
	Timeouts map[string]int // canonical element -> seconds; nil when none
}

var identRe = regexp.MustCompile(`^[a-z][a-z0-9_]{0,31}$`)

// ParseRequest decodes and validates one request line against the managed sets.
func ParseRequest(line []byte, sets map[string]Family) (Command, error) {
	var req Request
	dec := json.NewDecoder(bytes.NewReader(line))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&req); err != nil {
		return Command{}, fmt.Errorf("bad request: %v", err)
	}
	if dec.More() {
		return Command{}, errors.New("bad request: trailing data")
	}
	fam, ok := sets[req.Set]
	if !ok {
		return Command{}, fmt.Errorf("unknown set %q", req.Set)
	}

	switch req.Op {
	case "add", "remove":
		if req.Addresses != nil || req.Timeouts != nil {
			return Command{}, errors.New(req.Op + " takes one address")
		}
		el, err := Element(req.Address, fam)
		if err != nil {
			return Command{}, err
		}
		return Command{Op: req.Op, Set: req.Set, Elements: []string{el}}, nil
	case "replace":
		if req.Address != "" || req.Addresses == nil {
			return Command{}, errors.New("replace takes addresses")
		}
		if len(*req.Addresses) > MaxElements {
			return Command{}, fmt.Errorf("too many addresses (max %d)", MaxElements)
		}
		els, err := Elements(*req.Addresses, fam)
		if err != nil {
			return Command{}, err
		}
		ts, err := Timeouts(req.Timeouts, els, fam)
		if err != nil {
			return Command{}, err
		}
		return Command{Op: "replace", Set: req.Set, Elements: els, Timeouts: ts}, nil
	default:
		return Command{}, fmt.Errorf("unknown op %q", req.Op)
	}
}

// Element validates one address or CIDR prefix of the given family and returns its
// canonical text: a plain address for single hosts, a masked prefix otherwise.
func Element(s string, fam Family) (string, error) {
	p, err := parse(s)
	if err != nil {
		return "", err
	}
	if (fam == IPv4) != p.Addr().Is4() {
		return "", fmt.Errorf("%q is not %s", s, fam)
	}
	if p.IsSingleIP() {
		return p.Addr().String(), nil
	}
	return p.String(), nil
}

func parse(s string) (netip.Prefix, error) {
	if s == "" || len(s) > 64 {
		return netip.Prefix{}, fmt.Errorf("invalid address %q", s)
	}
	var p netip.Prefix
	if bytes.ContainsRune([]byte(s), '/') {
		pp, err := netip.ParsePrefix(s)
		if err != nil {
			return netip.Prefix{}, fmt.Errorf("invalid prefix %q", s)
		}
		p = pp.Masked()
	} else {
		a, err := netip.ParseAddr(s)
		// Zones (fe80::1%eth0) are refused, not stripped.
		if err != nil || a.Zone() != "" {
			return netip.Prefix{}, fmt.Errorf("invalid address %q", s)
		}
		p = netip.PrefixFrom(a, a.BitLen())
	}
	// IPv4-mapped IPv6 is refused, not rewritten.
	if p.Addr().Is4In6() {
		return netip.Prefix{}, fmt.Errorf("invalid address %q", s)
	}
	return p, nil
}

// Elements validates a list and removes duplicates and entries covered by a wider prefix,
// because an nftables interval set refuses overlapping elements.
func Elements(in []string, fam Family) ([]string, error) {
	ps := make([]netip.Prefix, 0, len(in))
	for _, s := range in {
		el, err := Element(s, fam)
		if err != nil {
			return nil, err
		}
		p, _ := parse(el)
		ps = append(ps, p)
	}
	// Widest first, so a prefix is checked against every wider one already kept.
	sort.Slice(ps, func(i, j int) bool {
		if ps[i].Bits() != ps[j].Bits() {
			return ps[i].Bits() < ps[j].Bits()
		}
		return ps[i].Addr().Less(ps[j].Addr())
	})
	var kept []netip.Prefix
	for _, p := range ps {
		covered := false
		for _, k := range kept {
			if k.Contains(p.Addr()) && k.Bits() <= p.Bits() {
				covered = true
				break
			}
		}
		if !covered {
			kept = append(kept, p)
		}
	}
	out := make([]string, len(kept))
	for i, p := range kept {
		if p.IsSingleIP() {
			out[i] = p.Addr().String()
		} else {
			out[i] = p.String()
		}
	}
	return out, nil
}

// Timeouts validates element timeouts against the canonical elements of a replace. A timeout
// for an element dropped as covered by a wider prefix is dropped too; one for an address not
// in the request is refused.
func Timeouts(in map[string]int, els []string, fam Family) (map[string]int, error) {
	if len(in) == 0 {
		return nil, nil
	}
	if len(in) > MaxElements {
		return nil, fmt.Errorf("too many timeouts (max %d)", MaxElements)
	}
	kept := map[string]bool{}
	for _, e := range els {
		kept[e] = true
	}
	out := map[string]int{}
	for addr, secs := range in {
		el, err := Element(addr, fam)
		if err != nil {
			return nil, err
		}
		if secs < 1 || secs > MaxTimeout {
			return nil, fmt.Errorf("timeout for %s out of range (1..%d s)", el, MaxTimeout)
		}
		if kept[el] {
			out[el] = secs
		} else if !covered(el, els) {
			return nil, fmt.Errorf("timeout for %s, which is not in addresses", el)
		}
	}
	if len(out) == 0 {
		return nil, nil
	}
	return out, nil
}

func covered(el string, els []string) bool {
	p, _ := parse(el)
	for _, e := range els {
		w, _ := parse(e)
		if w.Bits() <= p.Bits() && w.Contains(p.Addr()) {
			return true
		}
	}
	return false
}

// ParseSets reads the -sets flag: "name:ipv4,name2:ipv6".
func ParseSets(spec string) (map[string]Family, error) {
	sets := map[string]Family{}
	for _, item := range bytes.Split([]byte(spec), []byte(",")) {
		parts := bytes.SplitN(bytes.TrimSpace(item), []byte(":"), 2)
		if len(parts) != 2 || !identRe.Match(parts[0]) {
			return nil, fmt.Errorf("bad set spec %q", item)
		}
		fam := Family(parts[1])
		if fam != IPv4 && fam != IPv6 {
			return nil, fmt.Errorf("bad family in %q", item)
		}
		sets[string(parts[0])] = fam
	}
	if len(sets) == 0 {
		return nil, errors.New("no sets configured")
	}
	return sets, nil
}
