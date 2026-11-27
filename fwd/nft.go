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
			s += fmt.Sprintf("add element %s { %s }\n", ref, strings.Join(c.Elements, ", "))
		}
		return s
	}
}

// ParseSetJSON extracts the elements of `nft -j list set` output.
func ParseSetJSON(data []byte) ([]string, error) {
	var doc struct {
		Nftables []map[string]json.RawMessage `json:"nftables"`
	}
	if err := json.Unmarshal(data, &doc); err != nil {
		return nil, err
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
			return nil, err
		}
		out := make([]string, 0, len(set.Elem))
		for _, e := range set.Elem {
			var s string
			if json.Unmarshal(e, &s) == nil {
				out = append(out, s)
				continue
			}
			var p struct {
				Prefix *struct {
					Addr string `json:"addr"`
					Len  int    `json:"len"`
				} `json:"prefix"`
			}
			if json.Unmarshal(e, &p) == nil && p.Prefix != nil {
				out = append(out, fmt.Sprintf("%s/%d", p.Prefix.Addr, p.Prefix.Len))
				continue
			}
			return nil, fmt.Errorf("unsupported element %s", e)
		}
		return out, nil
	}
	return nil, errors.New("no set in nft output")
}

// State is what survives a reboot: the elements of every managed set.
type State map[string][]string

// Save reads every managed set back from nft and writes it atomically to path.
func Save(r Runner, table string, sets map[string]Family, path string) error {
	st := State{}
	for name := range sets {
		data, err := r.ListSet(table, name)
		if err != nil {
			return err
		}
		els, err := ParseSetJSON(data)
		if err != nil {
			return fmt.Errorf("set %s: %v", name, err)
		}
		sort.Strings(els)
		st[name] = els
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
	var st State
	if err := json.Unmarshal(data, &st); err != nil {
		return fmt.Errorf("state file: %v", err)
	}
	names := make([]string, 0, len(st))
	for n := range st {
		names = append(names, n)
	}
	sort.Strings(names)
	var script strings.Builder
	for _, name := range names {
		fam, ok := sets[name]
		if !ok {
			continue // set no longer managed
		}
		els, err := Elements(st[name], fam)
		if err != nil {
			return fmt.Errorf("state file, set %s: %v", name, err)
		}
		script.WriteString(Script(table, Command{Op: "replace", Set: name, Elements: els}))
	}
	if script.Len() == 0 {
		return nil
	}
	return r.Apply(script.String())
}
