package main

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

var testSets = map[string]Family{"mgmt_v4": IPv4, "mgmt_v6": IPv6}

func TestParseRequestValid(t *testing.T) {
	cases := []struct {
		line string
		want Command
	}{
		{`{"op":"add","set":"mgmt_v4","address":"203.0.113.7"}`, Command{"add", "mgmt_v4", []string{"203.0.113.7"}}},
		{`{"op":"add","set":"mgmt_v4","address":"10.1.2.3/8"}`, Command{"add", "mgmt_v4", []string{"10.0.0.0/8"}}},
		{`{"op":"add","set":"mgmt_v4","address":"10.1.2.3/32"}`, Command{"add", "mgmt_v4", []string{"10.1.2.3"}}},
		{`{"op":"remove","set":"mgmt_v6","address":"2001:DB8::1"}`, Command{"remove", "mgmt_v6", []string{"2001:db8::1"}}},
		{`{"op":"replace","set":"mgmt_v4","addresses":[]}`, Command{"replace", "mgmt_v4", []string{}}},
		{`{"op":"replace","set":"mgmt_v4","addresses":["10.0.0.5","10.0.0.0/8","10.0.0.0/8","192.0.2.1"]}`,
			Command{"replace", "mgmt_v4", []string{"10.0.0.0/8", "192.0.2.1"}}},
	}
	for _, c := range cases {
		got, err := ParseRequest([]byte(c.line), testSets)
		if err != nil {
			t.Errorf("%s: %v", c.line, err)
			continue
		}
		if !reflect.DeepEqual(got, c.want) {
			t.Errorf("%s: got %+v want %+v", c.line, got, c.want)
		}
	}
}

func TestParseRequestRejects(t *testing.T) {
	bad := []string{
		``, `not json`, `{"op":"add"}`,
		`{"op":"flush","set":"mgmt_v4"}`,                                   // unknown op
		`{"op":"add","set":"input","address":"1.2.3.4"}`,                   // unmanaged set (a chain name)
		`{"op":"add","set":"mgmt_v4","address":"2001:db8::1"}`,             // wrong family
		`{"op":"add","set":"mgmt_v6","address":"1.2.3.4"}`,                 // wrong family
		`{"op":"add","set":"mgmt_v4","address":"1.2.3.4; flush ruleset"}`,  // injection attempt
		`{"op":"add","set":"mgmt_v4","address":"1.2.3.4 }"}`,               // injection attempt
		`{"op":"add","set":"mgmt_v4","address":"999.1.1.1"}`,               // not an address
		`{"op":"add","set":"mgmt_v6","address":"fe80::1%eth0"}`,            // zone
		`{"op":"add","set":"mgmt_v6","address":"::ffff:1.2.3.4"}`,          // IPv4-mapped
		`{"op":"add","set":"mgmt_v4","address":"1.2.3.4/33"}`,              // bad prefix
		`{"op":"add","set":"mgmt_v4","address":"1.2.3.4","addresses":[]}`,  // mixed fields
		`{"op":"add","set":"mgmt_v4","addresses":["1.2.3.4"]}`,             // add takes one
		`{"op":"replace","set":"mgmt_v4","address":"1.2.3.4"}`,             // replace takes a list
		`{"op":"replace","set":"mgmt_v4","addresses":["1.2.3.4","bogus"]}`, // one bad element fails all
		`{"op":"add","set":"mgmt_v4","address":"1.2.3.4","rule":"accept"}`, // unknown field
		`{"op":"add","set":"mgmt_v4","address":"1.2.3.4"} {"op":"add"}`,    // trailing data
	}
	for _, line := range bad {
		if c, err := ParseRequest([]byte(line), testSets); err == nil {
			t.Errorf("accepted %s as %+v", line, c)
		}
	}
	many := make([]string, MaxElements+1)
	for i := range many {
		many[i] = "10.0.0.1"
	}
	b, _ := json.Marshal(Request{Op: "replace", Set: "mgmt_v4", Addresses: &many})
	if _, err := ParseRequest(b, testSets); err == nil {
		t.Error("accepted too many addresses")
	}
}

func TestScript(t *testing.T) {
	tb := "inet qpbx"
	if got := Script(tb, Command{"add", "mgmt_v4", []string{"1.2.3.4"}}); got != "add element inet qpbx mgmt_v4 { 1.2.3.4 }\n" {
		t.Errorf("add: %q", got)
	}
	if got := Script(tb, Command{"remove", "mgmt_v4", []string{"1.2.3.4"}}); got != "delete element inet qpbx mgmt_v4 { 1.2.3.4 }\n" {
		t.Errorf("remove: %q", got)
	}
	want := "flush set inet qpbx mgmt_v4\nadd element inet qpbx mgmt_v4 { 10.0.0.0/8, 1.2.3.4 }\n"
	if got := Script(tb, Command{"replace", "mgmt_v4", []string{"10.0.0.0/8", "1.2.3.4"}}); got != want {
		t.Errorf("replace: %q", got)
	}
	if got := Script(tb, Command{"replace", "mgmt_v4", nil}); got != "flush set inet qpbx mgmt_v4\n" {
		t.Errorf("empty replace: %q", got)
	}
}

func TestParseSets(t *testing.T) {
	sets, err := ParseSets("mgmt_v4:ipv4, mgmt_v6:ipv6")
	if err != nil || len(sets) != 2 || sets["mgmt_v6"] != IPv6 {
		t.Fatalf("got %v %v", sets, err)
	}
	for _, bad := range []string{"", "x", "Mgmt:ipv4", "a:ipv5", "a b:ipv4"} {
		if _, err := ParseSets(bad); err == nil {
			t.Errorf("accepted %q", bad)
		}
	}
}

// fakeRunner keeps sets in memory and records scripts.
type fakeRunner struct {
	scripts []string
	sets    map[string][]string
	fail    error
}

func (f *fakeRunner) Apply(script string) error {
	if f.fail != nil {
		return f.fail
	}
	f.scripts = append(f.scripts, script)
	for _, line := range strings.Split(strings.TrimSpace(script), "\n") {
		fields := strings.Fields(line)
		switch {
		case strings.HasPrefix(line, "flush set"):
			f.sets[fields[4]] = nil
		case strings.HasPrefix(line, "add element"):
			body := line[strings.Index(line, "{")+1 : strings.LastIndex(line, "}")]
			for _, e := range strings.Split(body, ",") {
				f.sets[fields[4]] = append(f.sets[fields[4]], strings.TrimSpace(e))
			}
		}
	}
	return nil
}

func (f *fakeRunner) ListSet(_, set string) ([]byte, error) {
	var elems []any
	for _, e := range f.sets[set] {
		if i := strings.Index(e, "/"); i > 0 {
			var l int
			_ = json.Unmarshal([]byte(e[i+1:]), &l)
			elems = append(elems, map[string]any{"prefix": map[string]any{"addr": e[:i], "len": l}})
		} else {
			elems = append(elems, e)
		}
	}
	return json.Marshal(map[string]any{"nftables": []any{
		map[string]any{"metainfo": map[string]any{}},
		map[string]any{"set": map[string]any{"name": set, "elem": elems}},
	}})
}

func TestServerSavesAndRestores(t *testing.T) {
	dir := t.TempDir()
	state := filepath.Join(dir, "sets.json")
	f := &fakeRunner{sets: map[string][]string{}}
	srv := &Server{Runner: f, Table: "inet qpbx", Sets: testSets, StatePath: state}

	if r := srv.Handle([]byte(`{"op":"replace","set":"mgmt_v4","addresses":["198.51.100.0/24","203.0.113.7"]}`)); !r.OK {
		t.Fatalf("replace: %+v", r)
	}
	if r := srv.Handle([]byte(`{"op":"add","set":"mgmt_v6","address":"2001:db8::/32"}`)); !r.OK {
		t.Fatalf("add: %+v", r)
	}
	if r := srv.Handle([]byte(`{"op":"add","set":"nope","address":"1.2.3.4"}`)); r.OK || len(f.scripts) != 2 {
		t.Fatalf("bad request reached nft: %+v %v", r, f.scripts)
	}

	var st State
	data, _ := os.ReadFile(state)
	if err := json.Unmarshal(data, &st); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(st["mgmt_v4"], []string{"198.51.100.0/24", "203.0.113.7"}) || !reflect.DeepEqual(st["mgmt_v6"], []string{"2001:db8::/32"}) {
		t.Fatalf("state: %+v", st)
	}

	// After a reboot the sets are empty; Restore puts them back in one transaction.
	f2 := &fakeRunner{sets: map[string][]string{}}
	if err := Restore(f2, "inet qpbx", testSets, state); err != nil {
		t.Fatal(err)
	}
	if len(f2.scripts) != 1 || !reflect.DeepEqual(f2.sets["mgmt_v4"], []string{"198.51.100.0/24", "203.0.113.7"}) {
		t.Fatalf("restore: %v %v", f2.scripts, f2.sets)
	}
}

func TestRestoreRejectsTamperedState(t *testing.T) {
	state := filepath.Join(t.TempDir(), "sets.json")
	os.WriteFile(state, []byte(`{"mgmt_v4":["1.2.3.4; flush ruleset"]}`), 0o600)
	f := &fakeRunner{sets: map[string][]string{}}
	if err := Restore(f, "inet qpbx", testSets, state); err == nil || len(f.scripts) != 0 {
		t.Fatalf("tampered state applied: %v %v", err, f.scripts)
	}
	if err := Restore(f, "inet qpbx", testSets, filepath.Join(t.TempDir(), "missing.json")); err != nil {
		t.Fatalf("missing state should be fine: %v", err)
	}
}

func TestNftErrorIsReported(t *testing.T) {
	f := &fakeRunner{sets: map[string][]string{}, fail: errors.New("nft: boom")}
	srv := &Server{Runner: f, Table: "inet qpbx", Sets: testSets, StatePath: filepath.Join(t.TempDir(), "s.json")}
	if r := srv.Handle([]byte(`{"op":"add","set":"mgmt_v4","address":"1.2.3.4"}`)); r.OK || !strings.Contains(r.Error, "boom") {
		t.Fatalf("got %+v", r)
	}
}

func TestParseSetJSON(t *testing.T) {
	real := `{"nftables": [{"metainfo": {"version": "1.0.6"}}, {"set": {"family": "inet", "name": "mgmt_v4", "table": "qpbx", "type": "ipv4_addr", "flags": ["interval"], "elem": ["203.0.113.7", {"prefix": {"addr": "198.51.100.0", "len": 24}}]}}]}`
	got, err := ParseSetJSON([]byte(real))
	if err != nil || !reflect.DeepEqual(got, []string{"203.0.113.7", "198.51.100.0/24"}) {
		t.Fatalf("got %v %v", got, err)
	}
	empty := `{"nftables": [{"metainfo": {}}, {"set": {"name": "mgmt_v4"}}]}`
	if got, err := ParseSetJSON([]byte(empty)); err != nil || len(got) != 0 {
		t.Fatalf("empty: %v %v", got, err)
	}
	if _, err := ParseSetJSON([]byte(`{"nftables":[{"set":{"elem":[{"range":["1.1.1.1","1.1.1.9"]}]}}]}`)); err == nil {
		t.Fatal("range should be unsupported")
	}
}
