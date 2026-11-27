// qpbx-fwd is the only Q-PBX component allowed to change nftables. It holds CAP_NET_ADMIN
// and accepts three commands over a local Unix socket: add an address to a named set,
// remove one, and replace a set. It cannot touch rules, chains or unmanaged sets.
//
// Protocol: one JSON request line per connection, one JSON response line back.
//
//	{"op":"add","set":"sip_allow_v4","address":"203.0.113.7"}
//	{"op":"remove","set":"sip_allow_v4","address":"203.0.113.7"}
//	{"op":"replace","set":"mgmt_v4","addresses":["198.51.100.0/24"]}
package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log"
	"net"
	"os"
	"os/signal"
	"regexp"
	"sync"
	"syscall"
	"time"
)

const maxLine = 4 << 20 // a full replace of MaxElements IPv6 prefixes fits

// Server applies validated commands one at a time and saves state after each change.
type Server struct {
	Runner    Runner
	Table     string
	Sets      map[string]Family
	StatePath string
	mu        sync.Mutex
}

// Handle processes one request line and returns the response.
func (s *Server) Handle(line []byte) Response {
	cmd, err := ParseRequest(line, s.Sets)
	if err != nil {
		return Response{Error: err.Error()}
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.Runner.Apply(Script(s.Table, cmd)); err != nil {
		return Response{Error: err.Error()}
	}
	if err := Save(s.Runner, s.Table, s.Sets, s.StatePath); err != nil {
		// The change is live; only persistence failed. Report it so the app alerts.
		log.Printf("save state: %v", err)
		return Response{Error: "applied, but saving state failed: " + err.Error()}
	}
	log.Printf("%s %s (%d elements)", cmd.Op, cmd.Set, len(cmd.Elements))
	return Response{OK: true}
}

func (s *Server) serve(conn net.Conn) {
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(30 * time.Second))
	r := bufio.NewReaderSize(conn, 64<<10)
	line, err := readLine(r)
	var resp Response
	if err != nil {
		resp = Response{Error: err.Error()}
	} else {
		resp = s.Handle(line)
	}
	out, _ := json.Marshal(resp)
	_, _ = conn.Write(append(out, '\n'))
}

func readLine(r *bufio.Reader) ([]byte, error) {
	var buf []byte
	for {
		chunk, isPrefix, err := r.ReadLine()
		if err != nil {
			return nil, fmt.Errorf("read: %v", err)
		}
		buf = append(buf, chunk...)
		if len(buf) > maxLine {
			return nil, errors.New("request too large")
		}
		if !isPrefix {
			return buf, nil
		}
	}
}

var tableRe = regexp.MustCompile(`^(inet|ip|ip6) [a-z][a-z0-9_]{0,31}$`)

func main() {
	socket := flag.String("socket", "/run/qpbx-fwd/fwd.sock", "Unix socket path")
	table := flag.String("table", "inet qpbx", "nftables family and table")
	setsSpec := flag.String("sets", "", "managed sets, e.g. mgmt_v4:ipv4,mgmt_v6:ipv6")
	state := flag.String("state", "/var/lib/qpbx-fwd/sets.json", "state file")
	nft := flag.String("nft", "/usr/sbin/nft", "nft binary")
	mode := flag.Uint("mode", 0o660, "socket file mode")
	flag.Parse()

	if !tableRe.MatchString(*table) {
		log.Fatalf("bad -table %q", *table)
	}
	sets, err := ParseSets(*setsSpec)
	if err != nil {
		log.Fatalf("-sets: %v", err)
	}
	srv := &Server{Runner: NftRunner{Path: *nft}, Table: *table, Sets: sets, StatePath: *state}

	if err := Restore(srv.Runner, srv.Table, srv.Sets, srv.StatePath); err != nil {
		log.Fatalf("restore: %v", err)
	}

	_ = os.Remove(*socket)
	ln, err := net.Listen("unix", *socket)
	if err != nil {
		log.Fatalf("listen: %v", err)
	}
	if err := os.Chmod(*socket, os.FileMode(*mode)); err != nil {
		log.Fatalf("chmod socket: %v", err)
	}
	go func() {
		sig := make(chan os.Signal, 1)
		signal.Notify(sig, syscall.SIGTERM, syscall.SIGINT)
		<-sig
		ln.Close()
	}()
	log.Printf("listening on %s, table %q, %d sets", *socket, *table, len(sets))
	for {
		conn, err := ln.Accept()
		if err != nil {
			if errors.Is(err, net.ErrClosed) {
				return
			}
			log.Printf("accept: %v", err)
			continue
		}
		go srv.serve(conn)
	}
}
