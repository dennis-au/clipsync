// clipsync — portapapeles compartido vía web (sin instalar nada en el cliente).
// Modelo de "log de items": cada Ctrl+V / Enviar es un item atómico (texto o imagen)
// recuperable desde el historial. Sync en vivo por SSE + fallback de polling.
// Acceso por contraseña compartida (cookie). Items con pin (no caducan). TTL configurable.
package main

import (
	"bytes"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"mime"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

const (
	defaultMaxUnpinnedItemsPerRoom = 60
	defaultMaxItemsPerRoom         = 80
	defaultMaxPinnedItemsPerRoom   = 20
	defaultMaxRooms                = 128
	defaultMaxRoomNameBytes        = 64
	maxTextInList                  = 4000     // recorte de texto en listados/SSE
	defaultTextInlineSize          = 64 << 10 // 64 KiB; larger text lives in a blob
	uploadBufferSize               = 1 << 20  // 1 MiB
	blobBufferSize                 = 32 << 10 // 32 KiB
	cookieName                     = "clip_auth"
	maxHeaderBytes                 = 32 << 10 // 32 KiB
	readHeaderTimeout              = 10 * time.Second
	idleTimeout                    = 90 * time.Second
	limiterBucketTTL               = 15 * time.Minute
	limiterMaxBuckets              = 2048
	defaultUploadTTL               = 15 * time.Minute
	uploadSweepInterval            = time.Minute
	defaultMaxUploads              = 16
	defaultMaxUploadsPerClient     = 2
	defaultMaxUploadsPerRoom       = 4
	defaultUploadChunkIdleTimeout  = 2 * time.Minute
	uploadIDBytes                  = 32
)

var (
	seq             uint64
	totalBytes      int64
	errItemTooLarge = errors.New("item too large")
	errStorageFull  = errors.New("storage full")
	errInvalidImage = errors.New("invalid image data")
	errInvalidRoom  = errors.New("invalid room code")
	errRoomLimit    = errors.New("room limit reached")
	errItemLimit    = errors.New("room item limit reached")
	errPinLimit     = errors.New("pinned item limit reached")
)

func nextID() string {
	n := atomic.AddUint64(&seq, 1)
	return strconv.FormatInt(time.Now().UnixNano(), 36) + "-" + strconv.FormatUint(n, 36)
}

func newUploadID() (string, error) {
	b := make([]byte, uploadIDBytes)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

type item struct {
	ID       string `json:"id"`
	Kind     string `json:"kind"` // "text" | "image" | "file"
	Text     string `json:"text,omitempty"`
	TextBlob bool   `json:"textBlob,omitempty"`
	Mime     string `json:"mime,omitempty"`
	Name     string `json:"name,omitempty"`
	Size     int64  `json:"size"`
	From     string `json:"from"`
	At       int64  `json:"at"`
	Pinned   bool   `json:"pinned"`
	Trunc    bool   `json:"trunc,omitempty"`
}

func (it item) view() item {
	v := it
	if v.Kind == "text" && len(v.Text) > maxTextInList {
		v.Text = v.Text[:maxTextInList]
		v.Trunc = true
	}
	return v
}

func (it item) hasBlob() bool {
	return it.Kind == "image" || it.Kind == "file" || (it.Kind == "text" && it.TextBlob)
}

type sseEvent struct {
	Kind string `json:"kind"` // "push" | "update" | "clear"
	Item item   `json:"item,omitempty"`
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
	return append([]item{}, r.items...)
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

// addLocked inserts an item, evicting the oldest unpinned items only when necessary.
// The caller must hold r.mu.
func (r *room) addLocked(it item, maxUnpinned, maxItems int) (item, []item, bool) {
	if len(r.items) >= maxItems {
		hasUnpinned := false
		for _, x := range r.items {
			if !x.Pinned {
				hasUnpinned = true
				break
			}
		}
		if !hasUnpinned {
			return item{}, nil, false
		}
	}
	r.items = append(r.items, it)
	var evicted []item
	for {
		// Count unpinned items while keeping a hard ceiling on all room items.
		n := 0
		for _, x := range r.items {
			if !x.Pinned {
				n++
			}
		}
		if n <= maxUnpinned && len(r.items) <= maxItems {
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
			return item{}, nil, false
		}
		evicted = append(evicted, r.items[idx])
		r.items = append(r.items[:idx], r.items[idx+1:]...)
	}
	return it, evicted, true
}

func (r *room) add(it item, maxUnpinned, maxItems int) (item, []item, bool) {
	r.mu.Lock()
	added, evicted, ok := r.addLocked(it, maxUnpinned, maxItems)
	r.mu.Unlock()
	if ok {
		r.broadcast(sseEvent{Kind: "push", Item: added})
	}
	return added, evicted, ok
}

func (r *room) setPin(id string, pin bool, maxPinned, maxUnpinned int) (item, bool, error) {
	r.mu.Lock()
	for i := range r.items {
		if r.items[i].ID == id {
			if pin && !r.items[i].Pinned {
				pinned := 0
				for _, candidate := range r.items {
					if candidate.Pinned {
						pinned++
					}
				}
				if pinned >= maxPinned {
					r.mu.Unlock()
					return item{}, true, errPinLimit
				}
			}
			if !pin && r.items[i].Pinned {
				unpinned := 0
				for _, candidate := range r.items {
					if !candidate.Pinned {
						unpinned++
					}
				}
				if unpinned >= maxUnpinned {
					r.mu.Unlock()
					return item{}, true, errItemLimit
				}
			}
			r.items[i].Pinned = pin
			it := r.items[i]
			r.mu.Unlock()
			r.broadcast(sseEvent{Kind: "update", Item: it})
			return it, true, nil
		}
	}
	r.mu.Unlock()
	return item{}, false, nil
}

func (r *room) clear() []item {
	r.mu.Lock()
	removed := append([]item(nil), r.items...)
	r.items = nil
	r.mu.Unlock()
	r.broadcast(sseEvent{Kind: "clear"})
	return removed
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
}

// ---------------- rate limiter por cliente ----------------

type bucket struct {
	tokens float64
	last   time.Time
}
type limiter struct {
	mu         sync.Mutex
	b          map[string]*bucket
	rate       float64 // tokens/seg
	burst      float64
	ttl        time.Duration
	maxBuckets int
}

func newLimiter(rate, burst float64, ttl time.Duration, maxBuckets int) *limiter {
	if ttl <= 0 {
		ttl = limiterBucketTTL
	}
	if maxBuckets <= 0 {
		maxBuckets = limiterMaxBuckets
	}
	return &limiter{
		b:          map[string]*bucket{},
		rate:       rate,
		burst:      burst,
		ttl:        ttl,
		maxBuckets: maxBuckets,
	}
}

func (l *limiter) allow(client string) bool {
	return l.allowAt(client, time.Now())
}

func (l *limiter) allowAt(client string, now time.Time) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.expireLocked(now)
	bk := l.b[client]
	if bk == nil {
		if len(l.b) >= l.maxBuckets {
			l.evictOldestLocked()
		}
		bk = &bucket{tokens: l.burst, last: now}
		l.b[client] = bk
	}
	if elapsed := now.Sub(bk.last); elapsed > 0 {
		bk.tokens += elapsed.Seconds() * l.rate
	}
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

func (l *limiter) expireLocked(now time.Time) {
	for client, bk := range l.b {
		if !bk.last.Add(l.ttl).After(now) {
			delete(l.b, client)
		}
	}
}

func (l *limiter) evictOldestLocked() {
	var oldestClient string
	var oldest time.Time
	for client, bk := range l.b {
		if oldestClient == "" || bk.last.Before(oldest) {
			oldestClient = client
			oldest = bk.last
		}
	}
	if oldestClient != "" {
		delete(l.b, oldestClient)
	}
}

// ---------------- server ----------------

type server struct {
	mu                      sync.Mutex
	mutationMu              sync.Mutex
	persistMu               sync.Mutex
	rooms                   map[string]*room
	pendingRemovals         []pendingRemoval
	uploads                 map[string]*upload
	stateDir                string
	persistOps              persistenceOps
	authToken               string // hex(sha256(password)); vacío = sin auth
	ttl                     time.Duration
	maxDisk                 int64
	maxTextSize             int64
	textInlineSize          int64
	maxImageSize            int64
	maxFileSize             int64
	uploadChunkSize         int64
	uploadTTL               time.Duration
	uploadChunkIdleTimeout  time.Duration
	maxUploads              int
	maxUploadsPerClient     int
	maxUploadsPerRoom       int
	uploadsByClient         map[string]int
	uploadsByRoom           map[string]int
	maxRooms                int
	maxRoomNameBytes        int
	maxItemsPerRoom         int
	maxUnpinnedItemsPerRoom int
	maxPinnedItemsPerRoom   int
	trustedProxies          []*net.IPNet
	loginLimiter            *limiter
	mutationLimiter         *limiter
	sseMu                   sync.Mutex
	sseTotal                int
	sseByClient             map[string]int
	maxSSE                  int
	maxSSEPerClient         int
}

type pendingRemoval struct {
	room string
	item item
}

// persistenceOps keeps filesystem failures testable without changing the
// production persistence protocol. Any unset operation uses the os package.
type persistenceOps struct {
	readFile   func(string) ([]byte, error)
	createTemp func(string, string) (*os.File, error)
	write      func(*os.File, []byte) (int, error)
	chmod      func(*os.File, os.FileMode) error
	sync       func(*os.File) error
	close      func(*os.File) error
	rename     func(string, string) error
	remove     func(string) error
	open       func(string) (*os.File, error)
}

func defaultPersistenceOps() persistenceOps {
	return persistenceOps{
		readFile:   os.ReadFile,
		createTemp: os.CreateTemp,
		write:      func(f *os.File, p []byte) (int, error) { return f.Write(p) },
		chmod:      func(f *os.File, mode os.FileMode) error { return f.Chmod(mode) },
		sync:       func(f *os.File) error { return f.Sync() },
		close:      func(f *os.File) error { return f.Close() },
		rename:     os.Rename,
		remove:     os.Remove,
		open:       os.Open,
	}
}

func (s *server) persistence() persistenceOps {
	defaults := defaultPersistenceOps()
	ops := s.persistOps
	if ops.readFile == nil {
		ops.readFile = defaults.readFile
	}
	if ops.createTemp == nil {
		ops.createTemp = defaults.createTemp
	}
	if ops.write == nil {
		ops.write = defaults.write
	}
	if ops.chmod == nil {
		ops.chmod = defaults.chmod
	}
	if ops.sync == nil {
		ops.sync = defaults.sync
	}
	if ops.close == nil {
		ops.close = defaults.close
	}
	if ops.rename == nil {
		ops.rename = defaults.rename
	}
	if ops.remove == nil {
		ops.remove = defaults.remove
	}
	if ops.open == nil {
		ops.open = defaults.open
	}
	return ops
}

type upload struct {
	room     string
	owner    string
	item     item
	path     string
	received int64
	reserved int64
	expires  time.Time
	busy     bool
}

type idleDeadlineReader struct {
	reader      io.Reader
	setDeadline func(time.Time) error
	idle        time.Duration
}

func (r *idleDeadlineReader) Read(p []byte) (int, error) {
	if r.idle > 0 {
		if err := r.setDeadline(time.Now().Add(r.idle)); err != nil && !errors.Is(err, http.ErrNotSupported) {
			return 0, err
		}
	}
	return r.reader.Read(p)
}

func uploadDeadlineSetter(w http.ResponseWriter) func(time.Time) error {
	return http.NewResponseController(w).SetReadDeadline
}

func validRoomName(name string, maxBytes int) bool {
	if name == "" || len(name) > maxBytes {
		return false
	}
	for i := 0; i < len(name); i++ {
		c := name[i]
		if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.') {
			return false
		}
	}
	return true
}

func (s *server) existingRoom(name string) *room {
	s.mu.Lock()
	r := s.rooms[name]
	s.mu.Unlock()
	return r
}

func (s *server) canCreateRoom(name string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, exists := s.rooms[name]
	return exists || len(s.rooms) < s.maxRooms
}

func (s *server) removeEmptyRoom(name string, expected *room) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.rooms[name] != expected {
		return
	}
	expected.mu.Lock()
	empty := len(expected.items) == 0 && len(expected.subs) == 0
	expected.mu.Unlock()
	if empty {
		delete(s.rooms, name)
	}
}

// subscribeRoom creates a transient, empty room for an SSE listener when needed.
// The caller removes it once the last listener disconnects, so opening a new room
// does not leave durable state behind.
func (s *server) subscribeRoom(name string) (*room, chan sseEvent, error) {
	s.mu.Lock()
	r := s.rooms[name]
	if r == nil {
		if len(s.rooms) >= s.maxRooms {
			s.mu.Unlock()
			return nil, nil, errRoomLimit
		}
		r = newRoom()
		s.rooms[name] = r
	}
	r.mu.Lock()
	ch := make(chan sseEvent, 8)
	r.subs[ch] = struct{}{}
	r.mu.Unlock()
	s.mu.Unlock()
	return r, ch, nil
}

func (s *server) addToRoom(name string, it item) ([]item, error) {
	if !validRoomName(name, s.maxRoomNameBytes) {
		return nil, errInvalidRoom
	}
	s.mu.Lock()
	r := s.rooms[name]
	if r == nil {
		if len(s.rooms) >= s.maxRooms {
			s.mu.Unlock()
			return nil, errRoomLimit
		}
		r = newRoom()
		s.rooms[name] = r
	}
	r.mu.Lock()
	added, evicted, ok := r.addLocked(it, s.maxUnpinnedItemsPerRoom, s.maxItemsPerRoom)
	r.mu.Unlock()
	s.mu.Unlock()
	if !ok {
		s.removeEmptyRoom(name, r)
		return nil, errItemLimit
	}
	r.broadcast(sseEvent{Kind: "push", Item: added})
	return evicted, nil
}

func (s *server) uploadDir() string {
	return filepath.Join(s.stateDir, "uploads")
}

type uploadAccess int

const (
	uploadMissing uploadAccess = iota
	uploadUnauthorized
	uploadBusy
	uploadGranted
)

// beginUpload claims an upload session for one request. Keeping the session busy
// prevents expiry, abort, and completion from racing with a chunk write.
func (s *server) beginUpload(id, client, requestedRoom string) (*upload, uploadAccess) {
	now := time.Now()
	var expired *upload
	s.mu.Lock()
	u := s.uploads[id]
	if u == nil {
		s.mu.Unlock()
		return nil, uploadMissing
	}
	if u.owner != client || (requestedRoom != "" && requestedRoom != u.room) {
		s.mu.Unlock()
		return nil, uploadUnauthorized
	}
	if !u.busy && !u.expires.After(now) {
		s.detachUploadLocked(id, u)
		expired = u
		s.mu.Unlock()
		s.discardUpload(expired)
		return nil, uploadMissing
	}
	if u.busy {
		s.mu.Unlock()
		return nil, uploadBusy
	}
	u.busy = true
	s.mu.Unlock()
	return u, uploadGranted
}

func (s *server) finishUpload(id string, expected *upload) {
	s.mu.Lock()
	if s.uploads[id] == expected {
		expected.busy = false
	}
	s.mu.Unlock()
}

func (s *server) registerUpload(u *upload) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if len(s.uploads) >= s.maxUploads || s.uploadsByClient[u.owner] >= s.maxUploadsPerClient || s.uploadsByRoom[u.room] >= s.maxUploadsPerRoom {
		return false
	}
	if _, exists := s.uploads[u.item.ID]; exists {
		return false
	}
	s.uploads[u.item.ID] = u
	s.uploadsByClient[u.owner]++
	s.uploadsByRoom[u.room]++
	return true
}

// detachUpload removes the active-session bookkeeping exactly once. The caller
// must discard the returned upload when true to release its written-byte quota.
func (s *server) detachUpload(id string, expected *upload) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.uploads[id] != expected {
		return false
	}
	s.detachUploadLocked(id, expected)
	return true
}

func (s *server) detachUploadLocked(id string, expected *upload) {
	delete(s.uploads, id)
	if s.uploadsByClient[expected.owner] <= 1 {
		delete(s.uploadsByClient, expected.owner)
	} else {
		s.uploadsByClient[expected.owner]--
	}
	if s.uploadsByRoom[expected.room] <= 1 {
		delete(s.uploadsByRoom, expected.room)
	} else {
		s.uploadsByRoom[expected.room]--
	}
}

func (s *server) discardUpload(u *upload) {
	_ = os.Remove(u.path)
	release(u.reserved)
}

func (s *server) blobDir(roomName string) string {
	return filepath.Join(s.stateDir, "blobs", sanitize(roomName))
}
func (s *server) blobPath(roomName, id string) string {
	return filepath.Join(s.blobDir(roomName), sanitize(id))
}

// Text blobs have a distinct suffix so startup recovery can remove a
// never-persisted text upload without touching arbitrary-file blobs.
func (s *server) textBlobPath(roomName, id string) string {
	return filepath.Join(s.blobDir(roomName), sanitize(id)+".text")
}

func (s *server) itemBlobPath(roomName string, it item) string {
	if it.Kind == "text" && it.TextBlob {
		return s.textBlobPath(roomName, it.ID)
	}
	return s.blobPath(roomName, it.ID)
}

func (s *server) removeBlob(roomName string, it item) {
	if it.hasBlob() {
		_ = os.Remove(s.itemBlobPath(roomName, it))
	}
}

// queueRemovals and flushPersistedRemovals must run while mutationMu is held.
// Keeping storage until the replacement metadata snapshot is durable prevents an
// interrupted clear or eviction from leaving the prior snapshot with dead blobs.
func (s *server) queueRemovals(roomName string, items []item) {
	for _, it := range items {
		s.pendingRemovals = append(s.pendingRemovals, pendingRemoval{room: roomName, item: it})
	}
}

func (s *server) flushPersistedRemovals() {
	remaining := s.pendingRemovals[:0]
	for _, removal := range s.pendingRemovals {
		if removal.item.hasBlob() {
			err := os.Remove(s.itemBlobPath(removal.room, removal.item))
			if err != nil && !errors.Is(err, os.ErrNotExist) {
				log.Printf("could not remove persisted blob %s/%s: %v", removal.room, removal.item.ID, err)
				remaining = append(remaining, removal)
				continue
			}
		}
		release(removal.item.Size)
	}
	s.pendingRemovals = remaining
}

func (s *server) reserve(n int64) bool {
	for {
		current := atomic.LoadInt64(&totalBytes)
		if current+n > s.maxDisk {
			return false
		}
		if atomic.CompareAndSwapInt64(&totalBytes, current, current+n) {
			return true
		}
	}
}

func release(n int64) {
	if n > 0 {
		atomic.AddInt64(&totalBytes, -n)
	}
}

// writeBlob streams a binary upload to disk while reserving the shared disk cap
// one buffer at a time. This avoids holding large files in the Go heap.
func (s *server) writeBlob(roomName, id string, body io.Reader, maxSize int64) (int64, error) {
	return s.writeBlobPath(roomName, s.blobPath(roomName, id), body, maxSize, true, "")
}

func (s *server) writeTextBlob(roomName, id string, body io.Reader, maxSize int64) (int64, error) {
	return s.writeBlobPath(roomName, s.textBlobPath(roomName, id), body, maxSize, true, "")
}

// writeImageBlob validates its small format signature while the upload is still
// a temporary file. That prevents a MIME mismatch from becoming a stored blob.
func (s *server) writeImageBlob(roomName, id, imageType string, body io.Reader, maxSize int64) (int64, error) {
	return s.writeBlobPath(roomName, s.blobPath(roomName, id), body, maxSize, true, imageType)
}

func (s *server) writeBlobPath(roomName, destination string, body io.Reader, maxSize int64, accountQuota bool, imageType string) (int64, error) {
	if err := os.MkdirAll(s.blobDir(roomName), 0700); err != nil {
		return 0, err
	}
	tmp, err := os.CreateTemp(s.blobDir(roomName), ".upload-*")
	if err != nil {
		return 0, err
	}
	tmpPath := tmp.Name()
	keep := false
	defer func() {
		tmp.Close()
		if !keep {
			os.Remove(tmpPath)
		}
	}()

	limited := io.LimitReader(body, maxSize+1)
	buf := make([]byte, uploadBufferSize)
	var written int64
	for {
		n, readErr := limited.Read(buf)
		if n > 0 {
			chunkSize := int64(n)
			if written > maxSize-chunkSize {
				if accountQuota {
					release(written)
				}
				return 0, errItemTooLarge
			}
			if accountQuota && !s.reserve(chunkSize) {
				release(written)
				return 0, errStorageFull
			}
			w, writeErr := tmp.Write(buf[:n])
			if writeErr != nil || w != n {
				if accountQuota {
					release(written + chunkSize)
				}
				if writeErr != nil {
					return 0, writeErr
				}
				return 0, io.ErrShortWrite
			}
			written += chunkSize
		}
		if readErr == io.EOF {
			break
		}
		if readErr != nil {
			if accountQuota {
				release(written)
			}
			return 0, readErr
		}
	}
	if imageType != "" {
		if _, err := tmp.Seek(0, io.SeekStart); err != nil {
			if accountQuota {
				release(written)
			}
			return 0, err
		}
		if err := validateImageSignature(tmp, imageType); err != nil {
			if accountQuota {
				release(written)
			}
			return 0, err
		}
	}
	if err := tmp.Close(); err != nil {
		if accountQuota {
			release(written)
		}
		return 0, err
	}
	if err := os.Rename(tmpPath, destination); err != nil {
		if accountQuota {
			release(written)
		}
		return 0, err
	}
	keep = true
	return written, nil
}

// writeLoadedTextBlob migrates oversized legacy text out of items.json during
// startup. The caller rebuilds quota accounting from the resulting blob scan.
func (s *server) writeLoadedTextBlob(roomName, id string, text []byte) error {
	_, err := s.writeBlobPath(roomName, s.textBlobPath(roomName, id), bytes.NewReader(text), int64(len(text)), false, "")
	return err
}

func (s *server) readTextBlob(roomName string, it item) (string, error) {
	if !it.TextBlob || it.Kind != "text" {
		return it.Text, nil
	}
	if it.Size < 1 || it.Size > s.maxTextSize {
		return "", errors.New("invalid text blob size")
	}
	data, err := os.ReadFile(s.textBlobPath(roomName, it.ID))
	if err != nil {
		return "", err
	}
	if int64(len(data)) != it.Size {
		return "", errors.New("text blob size mismatch")
	}
	return string(data), nil
}

func (s *server) textView(roomName string, it item) item {
	v := it.view()
	if v.Kind != "text" || !v.TextBlob {
		return v
	}
	f, err := os.Open(s.textBlobPath(roomName, v.ID))
	if err != nil {
		v.Trunc = true
		return v
	}
	defer f.Close()
	preview, err := io.ReadAll(io.LimitReader(f, maxTextInList+1))
	if err != nil {
		v.Trunc = true
		return v
	}
	if len(preview) > maxTextInList {
		preview = preview[:maxTextInList]
		v.Trunc = true
	}
	v.Text = string(preview)
	return v
}

func (s *server) textViews(roomName string, items []item) []item {
	for i := range items {
		items[i] = s.textView(roomName, items[i])
	}
	return items
}

func (s *server) resetUploadStaging() {
	os.RemoveAll(s.uploadDir())
	os.MkdirAll(s.uploadDir(), 0700)
}

func (s *server) expireUploads() {
	now := time.Now()
	var expired []*upload
	s.mu.Lock()
	for id, u := range s.uploads {
		if !u.busy && !u.expires.After(now) {
			s.detachUploadLocked(id, u)
			expired = append(expired, u)
		}
	}
	s.mu.Unlock()
	for _, u := range expired {
		s.discardUpload(u)
	}
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

func cleanFileName(name string) string {
	name = filepath.Base(strings.TrimSpace(name))
	name = strings.Map(func(r rune) rune {
		if r < 32 || r == 127 {
			return -1
		}
		return r
	}, name)
	if name == "" || name == "." {
		return "download"
	}
	runes := []rune(name)
	if len(runes) > 180 {
		name = string(runes[:180])
	}
	return name
}

func cleanFrom(name string) string {
	name = strings.Map(func(r rune) rune {
		if r < 32 || r == 127 {
			return -1
		}
		return r
	}, strings.TrimSpace(name))
	if name == "" {
		return "?"
	}
	runes := []rune(name)
	if len(runes) > 64 {
		name = string(runes[:64])
	}
	return name
}

func imageMIME(value string) (string, bool) {
	value = strings.ToLower(strings.TrimSpace(strings.Split(value, ";")[0]))
	switch value {
	case "image/png", "image/jpeg", "image/gif", "image/webp":
		return value, true
	default:
		return "", false
	}
}

// validateImageSignature reads only the bytes needed to recognize the declared
// image type. It deliberately does not decode the full image or inspect generic
// files, which stay download-only attachments.
func validateImageSignature(r io.Reader, imageType string) error {
	var header [12]byte
	needed := 0
	switch imageType {
	case "image/png":
		needed = 8
	case "image/jpeg":
		needed = 3
	case "image/gif":
		needed = 6
	case "image/webp":
		needed = 12
	default:
		return errInvalidImage
	}
	if _, err := io.ReadFull(r, header[:needed]); err != nil {
		return errInvalidImage
	}

	switch imageType {
	case "image/png":
		if bytes.Equal(header[:8], []byte{'\x89', 'P', 'N', 'G', '\r', '\n', '\x1a', '\n'}) {
			return nil
		}
	case "image/jpeg":
		if bytes.Equal(header[:3], []byte{'\xff', '\xd8', '\xff'}) {
			return nil
		}
	case "image/gif":
		if bytes.Equal(header[:6], []byte("GIF87a")) || bytes.Equal(header[:6], []byte("GIF89a")) {
			return nil
		}
	case "image/webp":
		if bytes.Equal(header[:4], []byte("RIFF")) && bytes.Equal(header[8:12], []byte("WEBP")) {
			return nil
		}
	}
	return errInvalidImage
}

func validateImagePath(path, imageType string) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	return validateImageSignature(f, imageType)
}

func contentMIME(value string) string {
	value = strings.TrimSpace(strings.Split(value, ";")[0])
	if value == "" {
		return "application/octet-stream"
	}
	return value
}

func (s *server) persistPath() string { return filepath.Join(s.stateDir, "items.json") }

func (s *server) persistBackupPath() string { return filepath.Join(s.stateDir, "items.json.bak") }

var errNoPersistedSnapshot = errors.New("no persisted snapshot")

func (s *server) snapshot() map[string][]item {
	s.mu.Lock()
	defer s.mu.Unlock()
	dump := make(map[string][]item, len(s.rooms))
	for name, r := range s.rooms {
		r.mu.Lock()
		if len(r.items) > 0 {
			dump[name] = append([]item(nil), r.items...)
		}
		r.mu.Unlock()
	}
	return dump
}

func decodeSnapshot(b []byte) (map[string][]item, error) {
	dump := map[string][]item{}
	if err := json.Unmarshal(b, &dump); err != nil {
		return nil, err
	}
	if dump == nil {
		dump = map[string][]item{}
	}
	return dump, nil
}

func (s *server) readSnapshot(path string) (map[string][]item, []byte, error) {
	b, err := s.persistence().readFile(path)
	if err != nil {
		return nil, nil, err
	}
	dump, err := decodeSnapshot(b)
	if err != nil {
		return nil, nil, fmt.Errorf("decode %s: %w", path, err)
	}
	return dump, b, nil
}

func (s *server) loadSnapshot() (map[string][]item, bool, error) {
	dump, _, primaryErr := s.readSnapshot(s.persistPath())
	if primaryErr == nil {
		return dump, false, nil
	}
	backup, _, backupErr := s.readSnapshot(s.persistBackupPath())
	if backupErr == nil {
		log.Printf("metadata primary unavailable (%v); recovering from %s", primaryErr, s.persistBackupPath())
		return backup, true, nil
	}
	if errors.Is(primaryErr, os.ErrNotExist) && errors.Is(backupErr, os.ErrNotExist) {
		return nil, false, errNoPersistedSnapshot
	}
	return nil, false, fmt.Errorf("primary metadata: %v; backup metadata: %w", primaryErr, backupErr)
}

func writeAll(write func(*os.File, []byte) (int, error), f *os.File, data []byte) error {
	for len(data) > 0 {
		n, err := write(f, data)
		if n > 0 {
			data = data[n:]
		}
		if err != nil {
			return err
		}
		if n == 0 {
			return io.ErrShortWrite
		}
	}
	return nil
}

// writeSnapshotTemp produces a fully synced private candidate in the same
// directory as the final file, so the later rename remains atomic.
func (s *server) writeSnapshotTemp(data []byte) (string, error) {
	dir := filepath.Dir(s.persistPath())
	if err := os.MkdirAll(dir, 0700); err != nil {
		return "", err
	}
	ops := s.persistence()
	tmp, err := ops.createTemp(dir, ".items.json-*")
	if err != nil {
		return "", err
	}
	tmpPath := tmp.Name()
	closed := false
	keep := false
	defer func() {
		if !closed {
			_ = ops.close(tmp)
		}
		if !keep {
			_ = ops.remove(tmpPath)
		}
	}()
	if err := ops.chmod(tmp, 0600); err != nil {
		return "", err
	}
	if err := writeAll(ops.write, tmp, data); err != nil {
		return "", err
	}
	if err := ops.sync(tmp); err != nil {
		return "", err
	}
	if err := ops.close(tmp); err != nil {
		return "", err
	}
	closed = true
	keep = true
	return tmpPath, nil
}

func unsupportedDirectorySync(err error) bool {
	return errors.Is(err, syscall.EINVAL) || errors.Is(err, syscall.ENOTSUP) || errors.Is(err, syscall.EOPNOTSUPP)
}

func (s *server) syncPersistDirectory() error {
	ops := s.persistence()
	dir, err := ops.open(filepath.Dir(s.persistPath()))
	if err != nil {
		return err
	}
	if err := ops.sync(dir); err != nil && !unsupportedDirectorySync(err) {
		_ = ops.close(dir)
		return err
	}
	return ops.close(dir)
}

// installSnapshot atomically replaces destination with a synced temp file.
// The bool says whether the rename happened, including a later directory-sync
// failure, so callers never try to remove a path that was already installed.
func (s *server) installSnapshot(tmpPath, destination string) (bool, error) {
	if err := s.persistence().rename(tmpPath, destination); err != nil {
		return false, err
	}
	if err := s.syncPersistDirectory(); err != nil {
		return true, err
	}
	return true, nil
}

func (s *server) replaceSnapshot(destination string, data []byte) error {
	tmpPath, err := s.writeSnapshotTemp(data)
	if err != nil {
		return err
	}
	installed := false
	defer func() {
		if !installed {
			_ = s.persistence().remove(tmpPath)
		}
	}()
	installed, err = s.installSnapshot(tmpPath, destination)
	return err
}

// save serializes both snapshot capture and installation. A later mutation can
// never install an older snapshot after a newer one.
func (s *server) save() error {
	s.persistMu.Lock()
	defer s.persistMu.Unlock()

	dump := s.snapshot()
	data, err := json.Marshal(dump)
	if err != nil {
		return fmt.Errorf("encode metadata snapshot: %w", err)
	}
	primaryPath := s.persistPath()
	backupPath := s.persistBackupPath()
	primaryBytes, readErr := s.persistence().readFile(primaryPath)
	var previous []byte
	hadValidPrimary := false
	switch {
	case readErr == nil:
		if _, err := decodeSnapshot(primaryBytes); err != nil {
			// A corrupt primary must never replace the independently retained
			// backup. The candidate below can safely repair it from memory.
			log.Printf("metadata primary is not a usable snapshot; preserving existing backup: %v", err)
		} else {
			previous = primaryBytes
			hadValidPrimary = true
		}
	case errors.Is(readErr, os.ErrNotExist):
		// First save: install the primary, then create an identical backup.
	default:
		return fmt.Errorf("read current metadata snapshot: %w", readErr)
	}

	primaryTmp, err := s.writeSnapshotTemp(data)
	if err != nil {
		return fmt.Errorf("write new metadata snapshot: %w", err)
	}
	primaryInstalled := false
	defer func() {
		if !primaryInstalled {
			_ = s.persistence().remove(primaryTmp)
		}
	}()

	// Preserve the previous valid primary while the replacement is being installed.
	if hadValidPrimary {
		if err := s.replaceSnapshot(backupPath, previous); err != nil {
			return fmt.Errorf("rotate metadata backup: %w", err)
		}
	}
	installed, err := s.installSnapshot(primaryTmp, primaryPath)
	primaryInstalled = installed
	if err != nil {
		return fmt.Errorf("install metadata snapshot: %w", err)
	}
	// A successful backup must describe the same metadata as the primary. Blob
	// cleanup happens only after save returns, so either snapshot remains fully
	// usable if the other one is lost or corrupted.
	if err := s.replaceSnapshot(backupPath, data); err != nil {
		return fmt.Errorf("metadata saved but backup refresh failed: %w", err)
	}
	return nil
}

// persistMutation makes a failed durable write explicit. The already-applied
// in-memory change remains coherent and is included in the next successful
// snapshot, so clients should refresh instead of blindly retrying the action.
func (s *server) persistMutation(w http.ResponseWriter, action string) bool {
	if err := s.save(); err != nil {
		log.Printf("metadata persistence failed after %s: %v", action, err)
		w.Header().Set("X-Clipsync-Persistence", "failed")
		http.Error(w, "state updated but could not be durably saved; refresh before retrying", http.StatusServiceUnavailable)
		return false
	}
	s.flushPersistedRemovals()
	return true
}

func (s *server) load() {
	dump, recoveredFromBackup, err := s.loadSnapshot()
	if errors.Is(err, errNoPersistedSnapshot) {
		if err := s.removeOrphanTextBlobs(map[string]struct{}{}); err != nil {
			log.Printf("could not reconcile orphaned text blobs without metadata: %v", err)
		}
		blobBytes, err := s.blobBytesOnDisk()
		if err != nil || blobBytes > s.maxDisk {
			if err != nil {
				log.Printf("could not scan blob storage without metadata: %v", err)
			}
			atomic.StoreInt64(&totalBytes, s.maxDisk)
			return
		}
		atomic.StoreInt64(&totalBytes, blobBytes)
		return
	}
	if err != nil {
		log.Printf("could not load metadata: %v", err)
		return
	}
	roomNames := make([]string, 0, len(dump))
	for name := range dump {
		roomNames = append(roomNames, name)
	}
	sort.Strings(roomNames)

	type droppedBlob struct {
		room string
		item item
	}
	var dropped []droppedBlob
	retainedBlobPaths := map[string]struct{}{}
	var textBytes int64
	changed := false
	s.mu.Lock()
	s.rooms = map[string]*room{}
	for _, name := range roomNames {
		its := dump[name]
		if !validRoomName(name, s.maxRoomNameBytes) || len(s.rooms) >= s.maxRooms {
			changed = true
			if validRoomName(name, s.maxRoomNameBytes) {
				for _, it := range its {
					if it.hasBlob() {
						dropped = append(dropped, droppedBlob{room: name, item: it})
					}
				}
			}
			continue
		}
		r := newRoom()
		for _, it := range its {
			normalized, discard, itemChanged := s.normalizeLoadedItem(name, it)
			changed = changed || itemChanged
			if !discard && it.Pinned && countPinned(r.items) >= s.maxPinnedItemsPerRoom {
				discard = true
			}
			if !discard && !it.Pinned && countUnpinned(r.items) >= s.maxUnpinnedItemsPerRoom {
				discard = true
			}
			if !discard && len(r.items) >= s.maxItemsPerRoom {
				discard = true
			}
			if discard {
				changed = true
				candidate := normalized
				if !candidate.hasBlob() {
					candidate = it
				}
				if candidate.hasBlob() {
					dropped = append(dropped, droppedBlob{room: name, item: candidate})
				}
				continue
			}
			r.items = append(r.items, normalized)
			if normalized.hasBlob() {
				retainedBlobPaths[s.itemBlobPath(name, normalized)] = struct{}{}
			} else {
				textBytes += normalized.Size
			}
		}
		if len(r.items) == 0 {
			changed = changed || len(its) > 0
			continue
		}
		s.rooms[name] = r
	}
	s.mu.Unlock()
	blobBytes, err := s.blobBytesOnDisk()
	if err != nil || blobBytes > int64(^uint64(0)>>1)-textBytes {
		if err == nil {
			err = errors.New("total storage size overflow")
		}
		log.Printf("could not scan blob storage: %v", err)
		atomic.StoreInt64(&totalBytes, s.maxDisk)
	} else {
		atomic.StoreInt64(&totalBytes, textBytes+blobBytes)
	}
	if changed || recoveredFromBackup {
		if err := s.save(); err != nil {
			log.Printf("could not persist recovered/normalized metadata: %v", err)
			return
		}
		for _, candidate := range dropped {
			if _, retained := retainedBlobPaths[s.itemBlobPath(candidate.room, candidate.item)]; !retained {
				s.removeBlob(candidate.room, candidate.item)
			}
		}
	}
	if err := s.removeOrphanTextBlobs(retainedBlobPaths); err != nil {
		log.Printf("could not reconcile orphaned text blobs: %v", err)
	}
	blobBytes, err = s.blobBytesOnDisk()
	if err != nil || blobBytes > int64(^uint64(0)>>1)-textBytes {
		if err == nil {
			err = errors.New("total storage size overflow")
		}
		log.Printf("could not rescan blob storage after metadata recovery: %v", err)
		atomic.StoreInt64(&totalBytes, s.maxDisk)
		return
	}
	atomic.StoreInt64(&totalBytes, textBytes+blobBytes)
}

func (s *server) normalizeLoadedItem(roomName string, it item) (item, bool, bool) {
	if it.Size < 0 {
		return item{}, true, true
	}
	switch it.Kind {
	case "text":
		if it.TextBlob {
			cleanedText := it.Text != ""
			if cleanedText {
				it.Text = ""
			}
			info, err := os.Stat(s.textBlobPath(roomName, it.ID))
			if err != nil || !info.Mode().IsRegular() || info.Size() < 1 || info.Size() > s.maxTextSize {
				return item{}, true, true
			}
			if it.Size != info.Size() {
				it.Size = info.Size()
				return it, false, true
			}
			return it, false, cleanedText
		}
		size := int64(len(it.Text))
		if size > s.maxTextSize || strings.TrimSpace(it.Text) == "" {
			return item{}, true, true
		}
		if size > s.textInlineSize {
			if err := s.writeLoadedTextBlob(roomName, it.ID, []byte(it.Text)); err != nil {
				log.Printf("could not migrate large text %s/%s into blob storage: %v", roomName, it.ID, err)
				return item{}, true, true
			}
			it.Text = ""
			it.TextBlob = true
			it.Size = size
			return it, false, true
		}
		if it.Size != size {
			it.Size = size
			return it, false, true
		}
		return it, false, false
	case "image", "file":
		info, err := os.Stat(s.blobPath(roomName, it.ID))
		if err != nil || !info.Mode().IsRegular() {
			return item{}, true, true
		}
		if it.Size != info.Size() {
			it.Size = info.Size()
			return it, false, true
		}
		return it, false, false
	default:
		return item{}, true, true
	}
}

func (s *server) blobBytesOnDisk() (int64, error) {
	root := filepath.Join(s.stateDir, "blobs")
	var total int64
	err := filepath.WalkDir(root, func(_ string, entry os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if !entry.Type().IsRegular() {
			return nil
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		if info.Size() > 0 && total > int64(^uint64(0)>>1)-info.Size() {
			return errors.New("blob storage size overflow")
		}
		total += info.Size()
		return nil
	})
	if errors.Is(err, os.ErrNotExist) {
		return 0, nil
	}
	return total, err
}

// removeOrphanTextBlobs reclaims only the distinct text-blob filenames. Binary
// blobs remain conservatively charged if their metadata was lost, while a text
// blob created before a failed metadata write cannot permanently consume quota.
func (s *server) removeOrphanTextBlobs(retained map[string]struct{}) error {
	root := filepath.Join(s.stateDir, "blobs")
	err := filepath.WalkDir(root, func(path string, entry os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if !entry.Type().IsRegular() || !strings.HasSuffix(entry.Name(), ".text") {
			return nil
		}
		if _, ok := retained[path]; ok {
			return nil
		}
		return os.Remove(path)
	})
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	return err
}

func countPinned(items []item) int {
	count := 0
	for _, it := range items {
		if it.Pinned {
			count++
		}
	}
	return count
}

func countUnpinned(items []item) int {
	count := 0
	for _, it := range items {
		if !it.Pinned {
			count++
		}
	}
	return count
}

// barrido periódico: caducidad (respeta pins) + limpieza de salas vacías
func (s *server) sweep() {
	s.expireUploads()
	s.mutationMu.Lock()
	defer s.mutationMu.Unlock()
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
		if len(removed) > 0 {
			s.queueRemovals(name, removed)
			changed = true
		}
		s.removeEmptyRoom(name, r)
	}
	if changed {
		if err := s.save(); err != nil {
			log.Printf("metadata persistence failed after expiry sweep: %v", err)
			return
		}
		s.flushPersistedRemovals()
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
		http.Error(w, "password required", 400)
		return
	}
	sum := sha256.Sum256([]byte(pw))
	if subtle.ConstantTimeCompare([]byte(hex.EncodeToString(sum[:])), []byte(s.authToken)) != 1 {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.WriteHeader(401)
		w.Write([]byte(strings.Replace(loginHTML, "<!--ERR-->", "Incorrect password", 1)))
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
			http.Error(w, "unauthorized", 401)
			return
		}
		h(w, req)
	}
}

func (s *server) requireRateLimit(l *limiter, h http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, req *http.Request) {
		if l != nil && !l.allow(s.clientIdentity(req)) {
			w.Header().Set("Retry-After", "1")
			http.Error(w, "too many requests; wait a moment", http.StatusTooManyRequests)
			return
		}
		h(w, req)
	}
}

func (s *server) clientIdentity(req *http.Request) string {
	peer := remoteIP(req.RemoteAddr)
	if peer == nil {
		return "unknown"
	}
	if s.isTrustedProxy(peer) {
		if forwarded := net.ParseIP(strings.TrimSpace(req.Header.Get("CF-Connecting-IP"))); forwarded != nil {
			return forwarded.String()
		}
	}
	return peer.String()
}

func remoteIP(remoteAddr string) net.IP {
	host, _, err := net.SplitHostPort(remoteAddr)
	if err == nil {
		return net.ParseIP(host)
	}
	return net.ParseIP(remoteAddr)
}

func (s *server) isTrustedProxy(peer net.IP) bool {
	for _, trusted := range s.trustedProxies {
		if trusted.Contains(peer) {
			return true
		}
	}
	return false
}

func parseTrustedProxies(raw string) ([]*net.IPNet, error) {
	var trusted []*net.IPNet
	for _, value := range strings.Split(raw, ",") {
		value = strings.TrimSpace(value)
		if value == "" {
			continue
		}
		if ip := net.ParseIP(value); ip != nil {
			bits := 128
			if ip.To4() != nil {
				ip = ip.To4()
				bits = 32
			}
			trusted = append(trusted, &net.IPNet{IP: ip, Mask: net.CIDRMask(bits, bits)})
			continue
		}
		_, cidr, err := net.ParseCIDR(value)
		if err != nil {
			return nil, fmt.Errorf("invalid trusted proxy %q: %w", value, err)
		}
		trusted = append(trusted, cidr)
	}
	return trusted, nil
}

func roomOf(req *http.Request) string {
	rm := req.URL.Query().Get("room")
	if rm == "" {
		rm = req.Header.Get("X-Room")
	}
	return rm
}

func (s *server) requestRoom(w http.ResponseWriter, req *http.Request) (string, bool) {
	rm := roomOf(req)
	if rm == "" {
		http.Error(w, "room required", http.StatusBadRequest)
		return "", false
	}
	if !validRoomName(rm, s.maxRoomNameBytes) {
		http.Error(w, "invalid room code", http.StatusBadRequest)
		return "", false
	}
	return rm, true
}

// ---------------- handlers de datos ----------------

func (s *server) handleList(w http.ResponseWriter, req *http.Request) {
	rm, ok := s.requestRoom(w, req)
	if !ok {
		return
	}
	items := []item{}
	if r := s.existingRoom(rm); r != nil {
		items = s.textViews(rm, r.list())
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]any{"items": items})
}

func (s *server) handlePush(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodPost {
		http.Error(w, "method", http.StatusMethodNotAllowed)
		return
	}
	rm, ok := s.requestRoom(w, req)
	if !ok {
		return
	}
	if !s.canCreateRoom(rm) {
		s.handleRoomError(w, errRoomLimit)
		return
	}
	kind := req.Header.Get("X-Kind")
	from := cleanFrom(req.Header.Get("X-From"))
	it := item{ID: nextID(), From: from, At: time.Now().Unix()}
	switch kind {
	case "image":
		imageType, ok := imageMIME(req.Header.Get("X-Mime"))
		if !ok {
			http.Error(w, "unsupported image type", http.StatusUnsupportedMediaType)
			return
		}
		it.Kind = "image"
		it.Mime = imageType
		if req.ContentLength > s.maxImageSize {
			http.Error(w, "item too large", http.StatusRequestEntityTooLarge)
			return
		}
		size, err := s.writeImageBlob(rm, it.ID, imageType, req.Body, s.maxImageSize)
		if err != nil {
			s.handleUploadError(w, err)
			return
		}
		it.Size = size
	case "file":
		it.Kind = "file"
		it.Mime = contentMIME(req.Header.Get("X-Mime"))
		it.Name = cleanFileName(req.Header.Get("X-Name"))
		if req.ContentLength > s.maxFileSize {
			http.Error(w, "item too large", http.StatusRequestEntityTooLarge)
			return
		}
		var size int64
		var err error
		if imageType, imageLabelled := imageMIME(it.Mime); imageLabelled {
			size, err = s.writeImageBlob(rm, it.ID, imageType, req.Body, s.maxFileSize)
		} else {
			size, err = s.writeBlob(rm, it.ID, req.Body, s.maxFileSize)
		}
		if err != nil {
			s.handleUploadError(w, err)
			return
		}
		it.Size = size
	default:
		body, err := io.ReadAll(io.LimitReader(req.Body, s.maxTextSize+1))
		if err != nil {
			http.Error(w, "error", http.StatusBadRequest)
			return
		}
		if int64(len(body)) > s.maxTextSize {
			http.Error(w, "item too large", http.StatusRequestEntityTooLarge)
			return
		}
		if len(bytes.TrimSpace(body)) == 0 {
			http.Error(w, "text required", http.StatusBadRequest)
			return
		}
		it.Kind = "text"
		if int64(len(body)) > s.textInlineSize {
			size, err := s.writeTextBlob(rm, it.ID, bytes.NewReader(body), s.maxTextSize)
			if err != nil {
				s.handleUploadError(w, err)
				return
			}
			it.TextBlob = true
			it.Size = size
		} else {
			if !s.reserve(int64(len(body))) {
				http.Error(w, "storage full", http.StatusInsufficientStorage)
				return
			}
			it.Text = string(body)
			it.Size = int64(len(body))
		}
	}
	s.mutationMu.Lock()
	defer s.mutationMu.Unlock()
	evicted, err := s.addToRoom(rm, it)
	if err != nil {
		s.removeBlob(rm, it)
		release(it.Size)
		s.handleRoomError(w, err)
		return
	}
	s.queueRemovals(rm, evicted)
	if !s.persistMutation(w, "push") {
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(s.textView(rm, it))
}

func (s *server) handleUploadError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, errItemTooLarge):
		http.Error(w, "item too large", http.StatusRequestEntityTooLarge)
	case errors.Is(err, errStorageFull):
		http.Error(w, "storage full", http.StatusInsufficientStorage)
	case errors.Is(err, errInvalidImage):
		http.Error(w, "image data does not match its type", http.StatusUnsupportedMediaType)
	default:
		http.Error(w, "could not save file", http.StatusInternalServerError)
	}
}

func (s *server) handleRoomError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, errInvalidRoom):
		http.Error(w, "invalid room code", http.StatusBadRequest)
	case errors.Is(err, errRoomLimit):
		http.Error(w, "room limit reached", http.StatusTooManyRequests)
	case errors.Is(err, errItemLimit):
		http.Error(w, "room item limit reached", http.StatusConflict)
	case errors.Is(err, errPinLimit):
		http.Error(w, "pinned item limit reached", http.StatusConflict)
	default:
		http.Error(w, "room unavailable", http.StatusInternalServerError)
	}
}

func (s *server) handleUploadStart(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodPost {
		http.Error(w, "method", http.StatusMethodNotAllowed)
		return
	}
	rm, ok := s.requestRoom(w, req)
	if !ok {
		return
	}
	if !s.canCreateRoom(rm) {
		s.handleRoomError(w, errRoomLimit)
		return
	}
	size, err := strconv.ParseInt(req.Header.Get("X-Size"), 10, 64)
	if err != nil || size <= 0 {
		http.Error(w, "invalid file size", http.StatusBadRequest)
		return
	}
	if size > s.maxFileSize {
		http.Error(w, "item too large", http.StatusRequestEntityTooLarge)
		return
	}
	id, err := newUploadID()
	if err != nil {
		http.Error(w, "could not start upload", http.StatusInternalServerError)
		return
	}
	if err := os.MkdirAll(s.uploadDir(), 0700); err != nil {
		http.Error(w, "could not start upload", http.StatusInternalServerError)
		return
	}
	tmp, err := os.CreateTemp(s.uploadDir(), ".upload-*")
	if err != nil {
		http.Error(w, "could not start upload", http.StatusInternalServerError)
		return
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmp.Name())
		http.Error(w, "could not start upload", http.StatusInternalServerError)
		return
	}
	u := &upload{
		room:  rm,
		owner: s.clientIdentity(req),
		item: item{
			ID:   id,
			Kind: "file",
			Mime: contentMIME(req.Header.Get("X-Mime")),
			Name: cleanFileName(req.Header.Get("X-Name")),
			Size: size,
			From: cleanFrom(req.Header.Get("X-From")),
			At:   time.Now().Unix(),
		},
		path:    tmp.Name(),
		expires: time.Now().Add(s.uploadTTL),
	}
	if !s.registerUpload(u) {
		os.Remove(u.path)
		w.Header().Set("Retry-After", "60")
		http.Error(w, "too many active uploads", http.StatusTooManyRequests)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]any{"upload": id, "chunkSize": s.uploadChunkSize})
}

func (s *server) handleUploadChunk(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodPost {
		http.Error(w, "method", http.StatusMethodNotAllowed)
		return
	}
	id := req.URL.Query().Get("upload")
	offset, err := strconv.ParseInt(req.URL.Query().Get("offset"), 10, 64)
	if id == "" || err != nil || offset < 0 {
		http.Error(w, "invalid upload parameters", http.StatusBadRequest)
		return
	}
	u, access := s.beginUpload(id, s.clientIdentity(req), req.URL.Query().Get("room"))
	switch access {
	case uploadMissing, uploadUnauthorized:
		http.NotFound(w, req)
		return
	case uploadBusy:
		http.Error(w, "upload busy", http.StatusConflict)
		return
	}
	defer s.finishUpload(id, u)
	if offset != u.received {
		http.Error(w, "unexpected upload offset", http.StatusConflict)
		return
	}
	remaining := u.item.Size - u.received
	if remaining <= 0 {
		http.Error(w, "upload already complete", http.StatusConflict)
		return
	}
	limit := s.uploadChunkSize
	if remaining < limit {
		limit = remaining
	}
	if req.ContentLength > limit {
		http.Error(w, "chunk too large", http.StatusRequestEntityTooLarge)
		return
	}
	f, err := os.OpenFile(u.path, os.O_WRONLY, 0600)
	if err != nil {
		http.Error(w, "upload unavailable", http.StatusInternalServerError)
		return
	}
	defer f.Close()
	if _, err := f.Seek(u.received, io.SeekStart); err != nil {
		http.Error(w, "upload unavailable", http.StatusInternalServerError)
		return
	}

	start := u.received
	var reserved int64
	valid := false
	discard := false
	defer func() {
		if !valid {
			_ = f.Truncate(start)
			release(reserved)
			if discard && s.detachUpload(id, u) {
				s.discardUpload(u)
			}
		}
	}()
	setDeadline := uploadDeadlineSetter(w)
	defer func() {
		if valid {
			_ = setDeadline(time.Time{})
			return
		}
		// Preserve the expired deadline and mark the request body closed so
		// net/http does not block draining a peer that stopped mid-chunk.
		_ = req.Body.Close()
	}()
	limited := io.LimitReader(&idleDeadlineReader{
		reader:      req.Body,
		setDeadline: setDeadline,
		idle:        s.uploadChunkIdleTimeout,
	}, limit+1)
	buf := make([]byte, uploadBufferSize)
	var written int64
	for {
		n, readErr := limited.Read(buf)
		if n > 0 {
			chunkSize := int64(n)
			if written > limit-chunkSize {
				http.Error(w, "chunk too large", http.StatusRequestEntityTooLarge)
				return
			}
			if !s.reserve(chunkSize) {
				http.Error(w, "storage full", http.StatusInsufficientStorage)
				return
			}
			reserved += chunkSize
			writtenNow, writeErr := f.Write(buf[:n])
			if writeErr != nil || writtenNow != n {
				http.Error(w, "could not save upload chunk", http.StatusInternalServerError)
				return
			}
			written += chunkSize
		}
		if readErr == io.EOF {
			break
		}
		if readErr != nil {
			discard = true
			if networkErr, ok := readErr.(net.Error); ok && networkErr.Timeout() {
				http.Error(w, "upload chunk timed out", http.StatusRequestTimeout)
			} else {
				http.Error(w, "could not read upload chunk", http.StatusBadRequest)
			}
			return
		}
	}
	if written == 0 {
		http.Error(w, "empty upload chunk", http.StatusBadRequest)
		return
	}
	u.received += written
	u.reserved += reserved
	u.expires = time.Now().Add(s.uploadTTL)
	valid = true
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]int64{"received": u.received})
}

func (s *server) handleUploadComplete(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodPost {
		http.Error(w, "method", http.StatusMethodNotAllowed)
		return
	}
	id := req.URL.Query().Get("upload")
	if id == "" {
		http.NotFound(w, req)
		return
	}
	u, access := s.beginUpload(id, s.clientIdentity(req), req.URL.Query().Get("room"))
	switch access {
	case uploadMissing, uploadUnauthorized:
		http.NotFound(w, req)
		return
	case uploadBusy:
		http.Error(w, "upload busy", http.StatusConflict)
		return
	}
	defer s.finishUpload(id, u)
	if u.received != u.item.Size {
		http.Error(w, "upload incomplete", http.StatusConflict)
		return
	}
	if imageType, imageLabelled := imageMIME(u.item.Mime); imageLabelled {
		if err := validateImagePath(u.path, imageType); err != nil {
			if s.detachUpload(id, u) {
				s.discardUpload(u)
			}
			s.handleUploadError(w, err)
			return
		}
	}
	if err := os.MkdirAll(s.blobDir(u.room), 0700); err != nil {
		http.Error(w, "could not finalize upload", http.StatusInternalServerError)
		return
	}
	if err := os.Rename(u.path, s.blobPath(u.room, u.item.ID)); err != nil {
		http.Error(w, "could not finalize upload", http.StatusInternalServerError)
		return
	}
	s.mutationMu.Lock()
	defer s.mutationMu.Unlock()
	evicted, err := s.addToRoom(u.room, u.item)
	if err != nil {
		_ = os.Remove(s.blobPath(u.room, u.item.ID))
		if s.detachUpload(id, u) {
			s.discardUpload(u)
		}
		s.handleRoomError(w, err)
		return
	}
	if !s.detachUpload(id, u) {
		_ = os.Remove(s.blobPath(u.room, u.item.ID))
		http.NotFound(w, req)
		return
	}
	s.queueRemovals(u.room, evicted)
	if !s.persistMutation(w, "upload completion") {
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(s.textView(u.room, u.item))
}

func (s *server) handleUploadAbort(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodPost {
		http.Error(w, "method", http.StatusMethodNotAllowed)
		return
	}
	id := req.URL.Query().Get("upload")
	if id == "" {
		w.WriteHeader(http.StatusNoContent)
		return
	}
	u, access := s.beginUpload(id, s.clientIdentity(req), req.URL.Query().Get("room"))
	switch access {
	case uploadMissing:
		w.WriteHeader(http.StatusNoContent)
		return
	case uploadUnauthorized:
		http.NotFound(w, req)
		return
	case uploadBusy:
		http.Error(w, "upload busy", http.StatusConflict)
		return
	}
	if s.detachUpload(id, u) {
		s.discardUpload(u)
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *server) handlePin(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodPost {
		http.Error(w, "method", http.StatusMethodNotAllowed)
		return
	}
	rm, roomOK := s.requestRoom(w, req)
	id := req.URL.Query().Get("id")
	if !roomOK {
		return
	}
	if id == "" {
		http.Error(w, "missing parameters", 400)
		return
	}
	pin := req.URL.Query().Get("pin") != "0"
	s.mutationMu.Lock()
	defer s.mutationMu.Unlock()
	r := s.existingRoom(rm)
	if r == nil {
		http.NotFound(w, req)
		return
	}
	it, found, err := r.setPin(id, pin, s.maxPinnedItemsPerRoom, s.maxUnpinnedItemsPerRoom)
	if err != nil {
		s.handleRoomError(w, err)
		return
	}
	if !found {
		http.NotFound(w, req)
		return
	}
	if !s.persistMutation(w, "pin update") {
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(s.textView(rm, it))
}

func (s *server) handleClear(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodPost {
		http.Error(w, "method", http.StatusMethodNotAllowed)
		return
	}
	rm, ok := s.requestRoom(w, req)
	if !ok {
		return
	}

	s.mutationMu.Lock()
	defer s.mutationMu.Unlock()
	r := s.existingRoom(rm)
	cleared := 0
	if r != nil {
		removed := r.clear()
		cleared = len(removed)
		s.queueRemovals(rm, removed)
		s.removeEmptyRoom(rm, r)
		if !s.persistMutation(w, "room clear") {
			return
		}
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]int{"cleared": cleared})
}

func (s *server) handleItem(w http.ResponseWriter, req *http.Request) {
	rm, roomOK := s.requestRoom(w, req)
	id := req.URL.Query().Get("id")
	if !roomOK {
		return
	}
	if id == "" {
		http.Error(w, "missing parameters", 400)
		return
	}
	r := s.existingRoom(rm)
	if r == nil {
		http.NotFound(w, req)
		return
	}
	it, ok := r.find(id)
	if !ok {
		http.NotFound(w, req)
		return
	}
	if it.Kind == "text" && it.TextBlob {
		text, err := s.readTextBlob(rm, it)
		if err != nil {
			http.NotFound(w, req)
			return
		}
		it.Text = text
		it.TextBlob = false
		it.Trunc = false
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(it)
}

func (s *server) handleBlob(w http.ResponseWriter, req *http.Request) {
	rm, roomOK := s.requestRoom(w, req)
	id := req.URL.Query().Get("id")
	if !roomOK {
		return
	}
	if id == "" {
		http.Error(w, "missing parameters", 400)
		return
	}
	r := s.existingRoom(rm)
	if r == nil {
		http.NotFound(w, req)
		return
	}
	it, ok := r.find(id)
	if !ok || (it.Kind != "image" && it.Kind != "file") {
		http.NotFound(w, req)
		return
	}
	blob, err := os.Open(s.blobPath(rm, id))
	if err != nil {
		http.NotFound(w, req)
		return
	}
	defer blob.Close()
	info, err := blob.Stat()
	if err != nil {
		http.NotFound(w, req)
		return
	}
	w.Header().Set("Content-Type", it.Mime)
	w.Header().Set("X-Content-Type-Options", "nosniff")
	if it.Kind == "file" {
		w.Header().Set("Content-Disposition", mime.FormatMediaType("attachment", map[string]string{"filename": it.Name}))
	}
	w.Header().Set("Cache-Control", "private, max-age=31536000, immutable")
	w.Header().Set("Content-Length", strconv.FormatInt(info.Size(), 10))
	_, _ = io.CopyBuffer(w, io.LimitReader(blob, info.Size()), make([]byte, blobBufferSize))
}

func (s *server) handleEvents(w http.ResponseWriter, req *http.Request) {
	rm, ok := s.requestRoom(w, req)
	if !ok {
		return
	}
	fl, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "streaming unavailable", 500)
		return
	}
	r, ch, err := s.subscribeRoom(rm)
	if err != nil {
		s.handleRoomError(w, err)
		return
	}
	defer func() {
		r.unsub(ch)
		s.removeEmptyRoom(rm, r)
	}()

	client := s.clientIdentity(req)
	if !s.reserveSSE(client) {
		w.Header().Set("Retry-After", "5")
		http.Error(w, "too many live connections", http.StatusTooManyRequests)
		return
	}
	defer s.releaseSSE(client)
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("X-Accel-Buffering", "no")

	writeSSE(w, fl, map[string]any{"kind": "snapshot", "items": s.textViews(rm, r.list())})

	ping := time.NewTicker(20 * time.Second)
	defer ping.Stop()
	ctx := req.Context()
	for {
		select {
		case <-ctx.Done():
			return
		case ev := <-ch:
			ev.Item = s.textView(rm, ev.Item)
			writeSSE(w, fl, ev)
		case <-ping.C:
			fmt.Fprintf(w, ": ping\n\n")
			fl.Flush()
		}
	}
}

func (s *server) reserveSSE(client string) bool {
	s.sseMu.Lock()
	defer s.sseMu.Unlock()
	if s.maxSSE <= 0 || s.maxSSEPerClient <= 0 || s.sseTotal >= s.maxSSE || s.sseByClient[client] >= s.maxSSEPerClient {
		return false
	}
	if s.sseByClient == nil {
		s.sseByClient = map[string]int{}
	}
	s.sseTotal++
	s.sseByClient[client]++
	return true
}

func (s *server) releaseSSE(client string) {
	s.sseMu.Lock()
	defer s.sseMu.Unlock()
	if s.sseByClient[client] <= 1 {
		delete(s.sseByClient, client)
	} else {
		s.sseByClient[client]--
	}
	if s.sseTotal > 0 {
		s.sseTotal--
	}
}

func (s *server) sseCounts() (int, map[string]int) {
	s.sseMu.Lock()
	defer s.sseMu.Unlock()
	byClient := make(map[string]int, len(s.sseByClient))
	for client, count := range s.sseByClient {
		byClient[client] = count
	}
	return s.sseTotal, byClient
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

func positiveEnvInt(k string, def int) int {
	v := envInt(k, int64(def))
	if v <= 0 || v > int64(^uint(0)>>1) {
		return def
	}
	return int(v)
}

func configuredTextInlineSize(maxTextSize int64) int64 {
	inlineKB := int64(positiveEnvInt("CLIPSYNC_TEXT_INLINE_KB", defaultTextInlineSize>>10))
	if inlineKB > int64(^uint64(0)>>1)>>10 {
		return maxTextSize
	}
	inlineSize := inlineKB << 10
	if inlineSize > maxTextSize {
		return maxTextSize
	}
	return inlineSize
}

// configuredAuthToken keeps unauthenticated operation an explicit local-development
// choice. Deployments must provide a password instead of accidentally starting open.
func configuredAuthToken(password, allowNoAuth string) (string, error) {
	if strings.TrimSpace(password) != "" {
		sum := sha256.Sum256([]byte(password))
		return hex.EncodeToString(sum[:]), nil
	}
	switch allowNoAuth {
	case "1":
		return "", nil
	case "":
		return "", errors.New("CLIPSYNC_PASSWORD is required (set CLIPSYNC_ALLOW_NO_AUTH=1 only for local development)")
	default:
		return "", errors.New("CLIPSYNC_ALLOW_NO_AUTH must be exactly 1 when CLIPSYNC_PASSWORD is unset")
	}
}

func (s *server) httpServer(addr string) *http.Server {
	return &http.Server{
		Addr:              addr,
		Handler:           s.handler(),
		ReadHeaderTimeout: readHeaderTimeout,
		IdleTimeout:       idleTimeout,
		MaxHeaderBytes:    maxHeaderBytes,
		// WriteTimeout and ReadTimeout intentionally remain unset: SSE connections
		// and 2 GiB streaming uploads can legitimately outlive a fixed deadline.
	}
}

func (s *server) handler() http.Handler {
	mux := http.NewServeMux()
	mutating := func(h http.HandlerFunc) http.HandlerFunc {
		return s.requireAuth(s.requireRateLimit(s.mutationLimiter, h))
	}
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) { w.Write([]byte("ok")) })
	mux.HandleFunc("/login", s.requireRateLimit(s.loginLimiter, s.handleLogin))
	mux.HandleFunc("/logout", s.handleLogout)
	mux.HandleFunc("/list", s.requireAuth(s.handleList))
	mux.HandleFunc("/push", mutating(s.handlePush))
	mux.HandleFunc("/upload/start", mutating(s.handleUploadStart))
	mux.HandleFunc("/upload/chunk", mutating(s.handleUploadChunk))
	mux.HandleFunc("/upload/complete", mutating(s.handleUploadComplete))
	mux.HandleFunc("/upload/abort", mutating(s.handleUploadAbort))
	mux.HandleFunc("/pin", mutating(s.handlePin))
	mux.HandleFunc("/clear", mutating(s.handleClear))
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
		config := fmt.Sprintf("<script>window.CLIPSYNC_ROOM_LIMIT=%d;window.CLIPSYNC_MAX_TEXT_BYTES=%d;window.CLIPSYNC_MAX_FILE_BYTES=%d;</script>", s.maxRoomNameBytes, s.maxTextSize, s.maxFileSize)
		w.Write([]byte(strings.Replace(indexHTML, "<!--ROOM-CONFIG-->", config, 1)))
	})
	return mux
}

func main() {
	authToken, err := configuredAuthToken(os.Getenv("CLIPSYNC_PASSWORD"), os.Getenv("CLIPSYNC_ALLOW_NO_AUTH"))
	if err != nil {
		log.Fatal(err)
	}
	addr := os.Getenv("CLIPSYNC_ADDR")
	if addr == "" {
		addr = ":8787"
	}
	dir := os.Getenv("CLIPSYNC_STATE")
	if dir == "" {
		dir = "/var/lib/clipsync"
	}
	os.MkdirAll(dir, 0700)
	trustedProxies, err := parseTrustedProxies(os.Getenv("CLIPSYNC_TRUSTED_PROXY_CIDRS"))
	if err != nil {
		log.Fatal(err)
	}
	maxSSE := positiveEnvInt("CLIPSYNC_MAX_SSE", 128)
	maxSSEPerClient := positiveEnvInt("CLIPSYNC_MAX_SSE_PER_CLIENT", 4)
	if maxSSEPerClient > maxSSE {
		maxSSEPerClient = maxSSE
	}
	maxItemsPerRoom := positiveEnvInt("CLIPSYNC_MAX_ITEMS_PER_ROOM", defaultMaxItemsPerRoom)
	maxUnpinnedItemsPerRoom := positiveEnvInt("CLIPSYNC_MAX_UNPINNED_ITEMS_PER_ROOM", defaultMaxUnpinnedItemsPerRoom)
	maxPinnedItemsPerRoom := positiveEnvInt("CLIPSYNC_MAX_PINNED_ITEMS_PER_ROOM", defaultMaxPinnedItemsPerRoom)
	if maxUnpinnedItemsPerRoom > maxItemsPerRoom {
		maxUnpinnedItemsPerRoom = maxItemsPerRoom
	}
	if maxPinnedItemsPerRoom > maxItemsPerRoom {
		maxPinnedItemsPerRoom = maxItemsPerRoom
	}
	maxUploads := positiveEnvInt("CLIPSYNC_MAX_UPLOADS", defaultMaxUploads)
	maxUploadsPerClient := positiveEnvInt("CLIPSYNC_MAX_UPLOADS_PER_CLIENT", defaultMaxUploadsPerClient)
	maxUploadsPerRoom := positiveEnvInt("CLIPSYNC_MAX_UPLOADS_PER_ROOM", defaultMaxUploadsPerRoom)
	if maxUploadsPerClient > maxUploads {
		maxUploadsPerClient = maxUploads
	}
	if maxUploadsPerRoom > maxUploads {
		maxUploadsPerRoom = maxUploads
	}
	uploadTTL := time.Duration(positiveEnvInt("CLIPSYNC_UPLOAD_TTL_MINUTES", int(defaultUploadTTL/time.Minute))) * time.Minute
	uploadChunkIdleTimeout := time.Duration(positiveEnvInt("CLIPSYNC_UPLOAD_CHUNK_IDLE_SECONDS", int(defaultUploadChunkIdleTimeout/time.Second))) * time.Second

	maxTextSize := envInt("CLIPSYNC_MAX_TEXT_MB", 64) << 20
	s := &server{
		rooms:                   map[string]*room{},
		uploads:                 map[string]*upload{},
		stateDir:                dir,
		ttl:                     time.Duration(envInt("CLIPSYNC_TTL_DAYS", 180)) * 24 * time.Hour,
		maxDisk:                 envInt("CLIPSYNC_MAX_DISK_MB", 1024) << 20,
		maxTextSize:             maxTextSize,
		textInlineSize:          configuredTextInlineSize(maxTextSize),
		maxImageSize:            envInt("CLIPSYNC_MAX_IMAGE_MB", 64) << 20,
		maxFileSize:             envInt("CLIPSYNC_MAX_FILE_MB", 64) << 20,
		uploadChunkSize:         envInt("CLIPSYNC_UPLOAD_CHUNK_MB", 32) << 20,
		uploadTTL:               uploadTTL,
		uploadChunkIdleTimeout:  uploadChunkIdleTimeout,
		maxUploads:              maxUploads,
		maxUploadsPerClient:     maxUploadsPerClient,
		maxUploadsPerRoom:       maxUploadsPerRoom,
		uploadsByClient:         map[string]int{},
		uploadsByRoom:           map[string]int{},
		maxRooms:                positiveEnvInt("CLIPSYNC_MAX_ROOMS", defaultMaxRooms),
		maxRoomNameBytes:        positiveEnvInt("CLIPSYNC_MAX_ROOM_NAME_BYTES", defaultMaxRoomNameBytes),
		maxItemsPerRoom:         maxItemsPerRoom,
		maxUnpinnedItemsPerRoom: maxUnpinnedItemsPerRoom,
		maxPinnedItemsPerRoom:   maxPinnedItemsPerRoom,
		trustedProxies:          trustedProxies,
		loginLimiter:            newLimiter(0.1, 5, limiterBucketTTL, limiterMaxBuckets),
		mutationLimiter:         newLimiter(2, 120, limiterBucketTTL, limiterMaxBuckets),
		sseByClient:             map[string]int{},
		maxSSE:                  maxSSE,
		maxSSEPerClient:         maxSSEPerClient,
	}
	s.authToken = authToken
	s.load()
	s.resetUploadStaging()

	// Expired upload staging is short-lived; room-item retention can remain daily.
	go func() {
		t := time.NewTicker(uploadSweepInterval)
		defer t.Stop()
		for range t.C {
			s.sweep()
		}
	}()

	log.Printf("clipsync escuchando en %s (estado:%s, auth:%v, ttl:%v, maxDisk:%dMB, trustedProxies:%d, maxSSE:%d)",
		addr, dir, s.authToken != "", s.ttl, s.maxDisk>>20, len(s.trustedProxies), s.maxSSE)
	log.Fatal(s.httpServer(addr).ListenAndServe())
}
