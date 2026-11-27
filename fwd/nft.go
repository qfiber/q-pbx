package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
)

// Runner runs nft with a script on stdin, or lists a set as JSON. Swapped out in tests.
type Runner interface {
	Apply(script string) error
	ListSet(table, set string) ([]byte, error)
}

// NftRunner calls the real nft binary.
type NftRunner struct{ Path string }

func (r NftRunner) Apply(script string) error {
	cmd := exec.Command(r.Path, "-f", "-")
	cmd.Stdin = strings.NewReader(script)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("nft: %v: %s", err, bytes.TrimSpace(out))
	}
	return nil
}

func (r NftRunner) ListSet(table, set string) ([]byte, error) {
	out, err := exec.Command(r.Path, "-j", "list", "set", strings.Fields(table)[0], strings.Fields(table)[1], set).Output()
	if err != nil {
		return nil, fmt.Errorf("nft list set %s: %v", set, err)
	}
	return out, nil
}

// Script turns a validated command into an nft script. One -f run is one atomic transaction.
func Script(table string, c Command) string {
	ref := table + " " + c.Set
	switch c.Op {
	case "add":
		return fmt.Sprintf("add element %s { %s }\n", ref, c.Elements[0])
	case "remove":
		return fmt.Sprintf("delete element %s { %s }\n", ref, c.Elements[0])
	default: // replace
		s := fmt.Sprintf("flush set %s\n", ref)
		if len(c.Elements) > 0 {
			els := make([]string, len(c.Elements))
			for i, e := range c.Elements {
				els[i] = e
				if t, ok := c.Timeouts[e]; ok {
					els[i] = fmt.Sprintf("%s timeout %ds", e, t)
				}
			}
			s += fmt.Sprintf("add element %s { %s }\n", ref, strings.Join(els, ", "))
		}
		return s
	}
}

// ParseSetJSON extracts the elements of `nft -j list set` output, and for elements with a
// timeout the seconds left before they expire.
func ParseSetJSON(data []byte) ([]string, map[string]int, error) {
	var doc struct {
		Nftables []map[string]json.RawMessage `json:"nftables"`
	}
	if err := json.Unmarshal(data, &doc); err != nil {
		return nil, nil, err
	}
	for _, item := range doc.Nftables {
		raw, ok := item["set"]
		if !ok {
			continue
		}
		var set struct {
			Elem []json.RawMessage `json:"elem"`
		}
		if err := json.Unmarshal(raw, &set); err != nil {
			return nil, nil, err
		}
		out := make([]string, 0, len(set.Elem))
		left := map[string]int{}
		for _, e := range set.Elem {
			// An element with a timeout: {"elem": {"val": V, "timeout": T, "expires": E}}.
			var timed struct {
				Elem *struct {
					Val     json.RawMessage `json:"val"`
					Expires int             `json:"expires"`
				} `json:"elem"`
			}
			if json.Unmarshal(e, &timed) == nil && timed.Elem != nil {
				v, err := elemValue(timed.Elem.Val)
				if err != nil {
					return nil, nil, err
				}
				out = append(out, v)
				if timed.Elem.Expires > 0 {
					left[v] = timed.Elem.Expires
				}
				continue
			}
			v, err := elemValue(e)
			if err != nil {
				return nil, nil, err
			}
			out = append(out, v)
		}
		if len(left) == 0 {
			left = nil
		}
		return out, left, nil
	}
	return nil, nil, errors.New("no set in nft output")
}

// elemValue reads an address ("1.2.3.4") or a prefix ({"prefix": {...}}).
func elemValue(e json.RawMessage) (string, error) {
	var s string
	if json.Unmarshal(e, &s) == nil {
		return s, nil
	}
	var p struct {
		Prefix *struct {
			Addr string `json:"addr"`
			Len  int    `json:"len"`
		} `json:"prefix"`
	}
	if json.Unmarshal(e, &p) == nil && p.Prefix != nil {
		return fmt.Sprintf("%s/%d", p.Prefix.Addr, p.Prefix.Len), nil
	}
	return "", fmt.Errorf("unsupported element %s", e)
}

// State is what survives a reboot: the elements of every managed set, and the seconds that
// were left on elements with a timeout (they restart from there).
type State struct {
	Sets     map[string][]string       `json:"sets"`
	Timeouts map[string]map[string]int `json:"timeouts,omitempty"`
}

// readState reads the state file; the first format (a bare map of sets) is still accepted.
func readState(data []byte) (State, error) {
	var st State
	if err := json.Unmarshal(data, &st); err == nil && st.Sets != nil {
		return st, nil
	}
	var old map[string][]string
	if err := json.Unmarshal(data, &old); err != nil {
		return State{}, fmt.Errorf("state file: %v", err)
	}
	return State{Sets: old}, nil
}

// Save reads every managed set back from nft and writes it atomically to path.
func Save(r Runner, table string, sets map[string]Family, path string) error {
	st := State{Sets: map[string][]string{}, Timeouts: map[string]map[string]int{}}
	for name := range sets {
		data, err := r.ListSet(table, name)
		if err != nil {
			return err
		}
		els, left, err := ParseSetJSON(data)
		if err != nil {
			return fmt.Errorf("set %s: %v", name, err)
		}
		sort.Strings(els)
		st.Sets[name] = els
		if left != nil {
			st.Timeouts[name] = left
		}
	}
	data, err := json.MarshalIndent(st, "", "  ")
	if err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".state-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), path)
}

// Restore re-applies a saved state, validating it like any request. A missing file is fine.
func Restore(r Runner, table string, sets map[string]Family, path string) error {
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	st, err := readState(data)
	if err != nil {
		return err
	}
	names := make([]string, 0, len(st.Sets))
	for n := range st.Sets {
		names = append(names, n)
	}
	sort.Strings(names)
	var script strings.Builder
	for _, name := range names {
		fam, ok := sets[name]
		if !ok {
			continue // set no longer managed
		}
		els, err := Elements(st.Sets[name], fam)
		if err != nil {
			return fmt.Errorf("state file, set %s: %v", name, err)
		}
		ts, err := Timeouts(st.Timeouts[name], els, fam)
		if err != nil {
			return fmt.Errorf("state file, set %s: %v", name, err)
		}
		script.WriteString(Script(table, Command{Op: "replace", Set: name, Elements: els, Timeouts: ts}))
	}
	if script.Len() == 0 {
		return nil
	}
	return r.Apply(script.String())
}
