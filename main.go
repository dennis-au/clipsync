// clipsync — portapapeles compartido vía web (sin instalar nada en el cliente).
// Modelo de "log de items": cada Ctrl+V / Enviar es un item atómico (texto o imagen)
// recuperable desde el historial. Sync en vivo por SSE + fallback de polling.
// Acceso por contraseña compartida (cookie). Items con pin (no caducan). TTL configurable.
package main

import (
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

const (
	maxSize       = 12 << 20 // 12 MiB por item
	maxItems      = 60       // items NO fijados retenidos por sala
	maxTextInList = 4000     // recorte de texto en listados/SSE
	cookieName    = "clip_auth"
)

var (
	seq        uint64
	totalBytes int64
)

func nextID() string {
	n := atomic.AddUint64(&seq, 1)
	return strconv.FormatInt(time.Now().UnixNano(), 36) + "-" + strconv.FormatUint(n, 36)
}

type item struct {
	ID     string `json:"id"`
	Kind   string `json:"kind"` // "text" | "image"
	Text   string `json:"text,omitempty"`
	Mime   string `json:"mime,omitempty"`
	Size   int    `json:"size"`
	From   string `json:"from"`
	At     int64  `json:"at"`
	Pinned bool   `json:"pinned"`
	trunc  bool
}

func (it item) view() item {
	v := it
	if v.Kind == "text" && len(v.Text) > maxTextInList {
		v.Text = v.Text[:maxTextInList]
		v.trunc = true
	}
	return v
}

type sseEvent struct {
	Kind string `json:"kind"` // "push" | "update"
	Item item   `json:"item"`
}

type room struct {
	mu    sync.Mutex
	items []item
	subs  map[chan sseEvent]struct{}
}

func newRoom() *room { return &room{subs: make(map[chan sseEvent]struct{})} }

func (r *room) list() []item {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := make([]item, len(r.items))
	for i, it := range r.items {
		out[i] = it.view()
	}
	return out
}

func (r *room) find(id string) (item, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	for _, it := range r.items {
		if it.ID == id {
			return it, true
		}
	}
	return item{}, false
}

func (r *room) broadcast(ev sseEvent) {
	r.mu.Lock()
	subs := make([]chan sseEvent, 0, len(r.subs))
	for c := range r.subs {
		subs = append(subs, c)
	}
	r.mu.Unlock()
	for _, c := range subs {
		select {
		case c <- ev:
		default:
		}
	}
}

// add inserta el item y devuelve los items evacuados (cap de NO fijados superado).
func (r *room) add(it item) (item, []item) {
	r.mu.Lock()
	r.items = append(r.items, it)
	var evicted []item
	for {
		// contar no fijados
		n := 0
		for _, x := range r.items {
			if !x.Pinned {
				n++
			}
		}
		if n <= maxItems {
			break
		}
		// quitar el no-fijado más antiguo
		idx := -1
		for i, x := range r.items {
			if !x.Pinned {
				idx = i
				break
			}
		}
		if idx < 0 {
			break
		}
		evicted = append(evicted, r.items[idx])
		r.items = append(r.items[:idx], r.items[idx+1:]...)
	}
	r.mu.Unlock()
	r.broadcast(sseEvent{Kind: "push", Item: it.view()})
	return it, evicted
}

func (r *room) setPin(id string, pin bool) (item, bool) {
	r.mu.Lock()
	for i := range r.items {
		if r.items[i].ID == id {
			r.items[i].Pinned = pin
			it := r.items[i]
			r.mu.Unlock()
			r.broadcast(sseEvent{Kind: "update", Item: it.view()})
			return it, true
		}
	}
	r.mu.Unlock()
	return item{}, false
}

// prune elimina items caducados NO fijados; devuelve los eliminados.
func (r *room) prune(cutoff int64) []item {
	r.mu.Lock()
	defer r.mu.Unlock()
	kept := r.items[:0]
	var removed []item
	for _, it := range r.items {
		if !it.Pinned && it.At < cutoff {
			removed = append(removed, it)
		} else {
			kept = append(kept, it)
		}
	}
	r.items = kept
	return removed
}

func (r *room) empty() bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	return len(r.items) == 0
}

func (r *room) sub() chan sseEvent {
	c := make(chan sseEvent, 8)
	r.mu.Lock()
	r.subs[c] = struct{}{}
	r.mu.Unlock()
	return c
}
func (r *room) unsub(c chan sseEvent) {
	r.mu.Lock()
	delete(r.subs, c)
	r.mu.Unlock()
	close(c)
}

// ---------------- rate limiter por IP ----------------

type bucket struct {
	tokens float64
	last   time.Time
}
type limiter struct {
	mu     sync.Mutex
	b      map[string]*bucket
	rate   float64 // tokens/seg
	burst  float64
}

func newLimiter(rate, burst float64) *limiter {
	return &limiter{b: map[string]*bucket{}, rate: rate, burst: burst}
}
func (l *limiter) allow(ip string) bool {
	now := time.Now()
	l.mu.Lock()
	defer l.mu.Unlock()
	bk := l.b[ip]
	if bk == nil {
		bk = &bucket{tokens: l.burst, last: now}
		l.b[ip] = bk
	}
	bk.tokens += now.Sub(bk.last).Seconds() * l.rate
	if bk.tokens > l.burst {
		bk.tokens = l.burst
	}
	bk.last = now
	if bk.tokens < 1 {
		return false
	}
	bk.tokens--
	return true
}

// ---------------- server ----------------

type server struct {
	mu          sync.Mutex
	rooms       map[string]*room
	stateDir    string
	authToken   string // hex(sha256(password)); vacío = sin auth
	ttl         time.Duration
	maxDisk     int64
	lim         *limiter
}

func (s *server) room(name string) *room {
	s.mu.Lock()
	defer s.mu.Unlock()
	r, ok := s.rooms[name]
	if !ok {
		r = newRoom()
		s.rooms[name] = r
	}
	return r
}

func (s *server) blobDir(roomName string) string {
	return filepath.Join(s.stateDir, "blobs", sanitize(roomName))
}
func (s *server) blobPath(roomName, id string) string {
	return filepath.Join(s.blobDir(roomName), sanitize(id))
}

func sanitize(x string) string {
	b := make([]byte, 0, len(x))
	for i := 0; i < len(x); i++ {
		c := x[i]
		if c == '-' || c == '_' || c == '.' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') {
			b = append(b, c)
		} else {
			b = append(b, '_')
		}
	}
	return string(b)
}

func (s *server) persistPath() string { return filepath.Join(s.stateDir, "items.json") }

func (s *server) save() {
	s.mu.Lock()
	dump := map[string][]item{}
	for name, r := range s.rooms {
		r.mu.Lock()
		if len(r.items) > 0 {
			dump[name] = append([]item{}, r.items...)
		}
		r.mu.Unlock()
	}
	s.mu.Unlock()
	b, _ := json.Marshal(dump)
	tmp := s.persistPath() + ".tmp"
	if os.WriteFile(tmp, b, 0600) == nil {
		os.Rename(tmp, s.persistPath())
	}
}

func (s *server) load() {
	b, err := os.ReadFile(s.persistPath())
	if err != nil {
		return
	}
	dump := map[string][]item{}
	if json.Unmarshal(b, &dump) != nil {
		return
	}
	var total int64
	s.mu.Lock()
	for name, its := range dump {
		r := newRoom()
		r.items = its
		s.rooms[name] = r
		for _, it := range its {
			total += int64(it.Size)
		}
	}
	s.mu.Unlock()
	atomic.StoreInt64(&totalBytes, total)
}

// barrido periódico: caducidad (respeta pins) + limpieza de salas vacías
func (s *server) sweep() {
	cutoff := time.Now().Add(-s.ttl).Unix()
	s.mu.Lock()
	rooms := map[string]*room{}
	for n, r := range s.rooms {
		rooms[n] = r
	}
	s.mu.Unlock()
	changed := false
	for name, r := range rooms {
		removed := r.prune(cutoff)
		for _, it := range removed {
			if it.Kind == "image" {
				os.Remove(s.blobPath(name, it.ID))
			}
			atomic.AddInt64(&totalBytes, -int64(it.Size))
			changed = true
		}
		if r.empty() {
			s.mu.Lock()
			delete(s.rooms, name)
			s.mu.Unlock()
		}
	}
	if changed {
		s.save()
	}
}

// ---------------- auth ----------------

func (s *server) authed(req *http.Request) bool {
	if s.authToken == "" {
		return true
	}
	c, err := req.Cookie(cookieName)
	if err != nil {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(c.Value), []byte(s.authToken)) == 1
}

func (s *server) setCookie(w http.ResponseWriter) {
	http.SetCookie(w, &http.Cookie{
		Name: cookieName, Value: s.authToken, Path: "/",
		HttpOnly: true, Secure: true, SameSite: http.SameSiteLaxMode,
		MaxAge: 60 * 60 * 24 * 365,
	})
}

func (s *server) handleLogin(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodPost {
		http.Error(w, "method", 405)
		return
	}
	req.ParseForm()
	pw := req.FormValue("password")
	if pw == "" {
		http.Error(w, "falta password", 400)
		return
	}
	sum := sha256.Sum256([]byte(pw))
	if subtle.ConstantTimeCompare([]byte(hex.EncodeToString(sum[:])), []byte(s.authToken)) != 1 {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.WriteHeader(401)
		w.Write([]byte(strings.Replace(loginHTML, "<!--ERR-->", "Contraseña incorrecta", 1)))
		return
	}
	s.setCookie(w)
	http.Redirect(w, req, "/", http.StatusSeeOther)
}

func (s *server) handleLogout(w http.ResponseWriter, req *http.Request) {
	http.SetCookie(w, &http.Cookie{Name: cookieName, Value: "", Path: "/", MaxAge: -1})
	http.Redirect(w, req, "/", http.StatusSeeOther)
}

// requireAuth protege endpoints de API (401 si no autenticado)
func (s *server) requireAuth(h http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, req *http.Request) {
		if !s.authed(req) {
			http.Error(w, "no autorizado", 401)
			return
		}
		h(w, req)
	}
}

func clientIP(req *http.Request) string {
	if xff := req.Header.Get("X-Forwarded-For"); xff != "" {
		return strings.TrimSpace(strings.Split(xff, ",")[0])
	}
	host, _, _ := net.SplitHostPort(req.RemoteAddr)
	return host
}

func roomOf(req *http.Request) string {
	rm := req.URL.Query().Get("room")
	if rm == "" {
		rm = req.Header.Get("X-Room")
	}
	return rm
}

// ---------------- handlers de datos ----------------

func (s *server) handleList(w http.ResponseWriter, req *http.Request) {
	rm := roomOf(req)
	if rm == "" {
		http.Error(w, "falta room", 400)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]any{"items": s.room(rm).list()})
}

func (s *server) handlePush(w http.ResponseWriter, req *http.Request) {
	rm := roomOf(req)
	if rm == "" {
		http.Error(w, "falta room", 400)
		return
	}
	if len(rm) < 8 {
		http.Error(w, "el código de sala debe tener al menos 8 caracteres", 400)
		return
	}
	if !s.lim.allow(clientIP(req)) {
		http.Error(w, "demasiadas peticiones, espera un momento", 429)
		return
	}
	body, err := io.ReadAll(io.LimitReader(req.Body, maxSize+1))
	if err != nil {
		http.Error(w, "error", 400)
		return
	}
	if len(body) > maxSize {
		http.Error(w, "demasiado grande", 413)
		return
	}
	if atomic.LoadInt64(&totalBytes)+int64(len(body)) > s.maxDisk {
		http.Error(w, "almacenamiento lleno", 507)
		return
	}
	kind := req.Header.Get("X-Kind")
	if kind != "image" {
		kind = "text"
	}
	from := req.Header.Get("X-From")
	if from == "" {
		from = "?"
	}
	it := item{ID: nextID(), Kind: kind, Size: len(body), From: from, At: time.Now().Unix()}
	if kind == "image" {
		mime := req.Header.Get("X-Mime")
		if mime == "" {
			mime = "image/png"
		}
		it.Mime = mime
		os.MkdirAll(s.blobDir(rm), 0700)
		if os.WriteFile(s.blobPath(rm, it.ID), body, 0600) != nil {
			http.Error(w, "no se pudo guardar imagen", 500)
			return
		}
	} else {
		it.Text = string(body)
	}
	atomic.AddInt64(&totalBytes, int64(len(body)))
	_, evicted := s.room(rm).add(it)
	for _, ev := range evicted {
		if ev.Kind == "image" {
			os.Remove(s.blobPath(rm, ev.ID))
		}
		atomic.AddInt64(&totalBytes, -int64(ev.Size))
	}
	go s.save()
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(it.view())
}

func (s *server) handlePin(w http.ResponseWriter, req *http.Request) {
	rm := roomOf(req)
	id := req.URL.Query().Get("id")
	if rm == "" || id == "" {
		http.Error(w, "faltan params", 400)
		return
	}
	pin := req.URL.Query().Get("pin") != "0"
	it, ok := s.room(rm).setPin(id, pin)
	if !ok {
		http.NotFound(w, req)
		return
	}
	go s.save()
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(it.view())
}

func (s *server) handleItem(w http.ResponseWriter, req *http.Request) {
	rm := roomOf(req)
	id := req.URL.Query().Get("id")
	if rm == "" || id == "" {
		http.Error(w, "faltan params", 400)
		return
	}
	it, ok := s.room(rm).find(id)
	if !ok {
		http.NotFound(w, req)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(it)
}

func (s *server) handleBlob(w http.ResponseWriter, req *http.Request) {
	rm := roomOf(req)
	id := req.URL.Query().Get("id")
	if rm == "" || id == "" {
		http.Error(w, "faltan params", 400)
		return
	}
	it, ok := s.room(rm).find(id)
	if !ok || it.Kind != "image" {
		http.NotFound(w, req)
		return
	}
	b, err := os.ReadFile(s.blobPath(rm, id))
	if err != nil {
		http.NotFound(w, req)
		return
	}
	w.Header().Set("Content-Type", it.Mime)
	w.Header().Set("Cache-Control", "private, max-age=31536000, immutable")
	w.Write(b)
}

func (s *server) handleEvents(w http.ResponseWriter, req *http.Request) {
	rm := roomOf(req)
	if rm == "" {
		http.Error(w, "falta room", 400)
		return
	}
	fl, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "no streaming", 500)
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("X-Accel-Buffering", "no")

	r := s.room(rm)
	ch := r.sub()
	defer r.unsub(ch)

	writeSSE(w, fl, map[string]any{"kind": "snapshot", "items": r.list()})

	ping := time.NewTicker(20 * time.Second)
	defer ping.Stop()
	ctx := req.Context()
	for {
		select {
		case <-ctx.Done():
			return
		case ev := <-ch:
			writeSSE(w, fl, ev)
		case <-ping.C:
			fmt.Fprintf(w, ": ping\n\n")
			fl.Flush()
		}
	}
}

func writeSSE(w io.Writer, fl http.Flusher, v any) {
	b, _ := json.Marshal(v)
	fmt.Fprintf(w, "data: %s\n\n", b)
	fl.Flush()
}

func envInt(k string, def int64) int64 {
	if v := os.Getenv(k); v != "" {
		if n, err := strconv.ParseInt(v, 10, 64); err == nil {
			return n
		}
	}
	return def
}

func main() {
	addr := os.Getenv("CLIPSYNC_ADDR")
	if addr == "" {
		addr = ":8787"
	}
	dir := os.Getenv("CLIPSYNC_STATE")
	if dir == "" {
		dir = "/var/lib/clipsync"
	}
	os.MkdirAll(dir, 0700)

	s := &server{
		rooms:    map[string]*room{},
		stateDir: dir,
		ttl:      time.Duration(envInt("CLIPSYNC_TTL_DAYS", 180)) * 24 * time.Hour,
		maxDisk:  envInt("CLIPSYNC_MAX_DISK_MB", 1024) << 20,
		lim:      newLimiter(1.0, 60), // 1 push/seg sostenido, ráfaga 60
	}
	if pw := os.Getenv("CLIPSYNC_PASSWORD"); pw != "" {
		sum := sha256.Sum256([]byte(pw))
		s.authToken = hex.EncodeToString(sum[:])
	}
	s.load()

	// barrido cada hora
	go func() {
		t := time.NewTicker(time.Hour)
		defer t.Stop()
		for range t.C {
			s.sweep()
		}
	}()

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) { w.Write([]byte("ok")) })
	mux.HandleFunc("/login", s.handleLogin)
	mux.HandleFunc("/logout", s.handleLogout)
	mux.HandleFunc("/list", s.requireAuth(s.handleList))
	mux.HandleFunc("/push", s.requireAuth(s.handlePush))
	mux.HandleFunc("/pin", s.requireAuth(s.handlePin))
	mux.HandleFunc("/item", s.requireAuth(s.handleItem))
	mux.HandleFunc("/blob", s.requireAuth(s.handleBlob))
	mux.HandleFunc("/events", s.requireAuth(s.handleEvents))
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		if !s.authed(r) {
			w.Write([]byte(strings.Replace(loginHTML, "<!--ERR-->", "", 1)))
			return
		}
		w.Write([]byte(indexHTML))
	})

	log.Printf("clipsync escuchando en %s (estado:%s, auth:%v, ttl:%v, maxDisk:%dMB)",
		addr, dir, s.authToken != "", s.ttl, s.maxDisk>>20)
	log.Fatal((&http.Server{Addr: addr, Handler: mux}).ListenAndServe())
}
