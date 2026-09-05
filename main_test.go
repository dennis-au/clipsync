package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func newTestServer(t *testing.T) *server {
	t.Helper()
	atomicStoreTotalBytes(0)
	return &server{
		rooms:                   map[string]*room{},
		uploads:                 map[string]*upload{},
		stateDir:                t.TempDir(),
		maxDisk:                 1 << 20,
		maxTextSize:             1 << 20,
		textInlineSize:          defaultTextInlineSize,
		maxImageSize:            1 << 20,
		maxFileSize:             1 << 20,
		uploadChunkSize:         4,
		uploadTTL:               time.Minute,
		uploadChunkIdleTimeout:  defaultUploadChunkIdleTimeout,
		maxUploads:              8,
		maxUploadsPerClient:     4,
		maxUploadsPerRoom:       4,
		uploadsByClient:         map[string]int{},
		uploadsByRoom:           map[string]int{},
		maxRooms:                defaultMaxRooms,
		maxRoomNameBytes:        defaultMaxRoomNameBytes,
		maxItemsPerRoom:         defaultMaxItemsPerRoom,
		maxUnpinnedItemsPerRoom: defaultMaxUnpinnedItemsPerRoom,
		maxPinnedItemsPerRoom:   defaultMaxPinnedItemsPerRoom,
		loginLimiter:            newLimiter(1000, 1000, time.Minute, 128),
		mutationLimiter:         newLimiter(1000, 1000, time.Minute, 128),
		sseByClient:             map[string]int{},
		maxSSE:                  8,
		maxSSEPerClient:         4,
	}
}

func testItem(id, text string) item {
	return item{ID: id, Kind: "text", Text: text, Size: int64(len(text)), From: "test", At: time.Now().Unix()}
}

func mustAddToRoom(t *testing.T, s *server, roomName string, it item) {
	t.Helper()
	if !s.reserve(it.Size) {
		t.Fatalf("reserve %d bytes", it.Size)
	}
	if _, err := s.addToRoom(roomName, it); err != nil {
		t.Fatal(err)
	}
}

func atomicStoreTotalBytes(value int64) {
	atomic.StoreInt64(&totalBytes, value)
}

func TestConfiguredAuthToken(t *testing.T) {
	wantPassword := sha256.Sum256([]byte("correct horse battery staple"))
	tests := []struct {
		name        string
		password    string
		allowNoAuth string
		want        string
		wantErr     bool
	}{
		{
			name:     "password is hashed",
			password: "correct horse battery staple",
			want:     hex.EncodeToString(wantPassword[:]),
		},
		{
			name:        "explicit local development opt in",
			allowNoAuth: "1",
		},
		{
			name:    "password is required by default",
			wantErr: true,
		},
		{
			name:     "whitespace password is rejected",
			password: " \t ",
			wantErr:  true,
		},
		{
			name:        "invalid opt in is rejected",
			allowNoAuth: "true",
			wantErr:     true,
		},
		{
			name:        "password takes precedence over development opt in",
			password:    "correct horse battery staple",
			allowNoAuth: "1",
			want:        hex.EncodeToString(wantPassword[:]),
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := configuredAuthToken(tt.password, tt.allowNoAuth)
			if (err != nil) != tt.wantErr {
				t.Fatalf("configuredAuthToken() error = %v, wantErr %v", err, tt.wantErr)
			}
			if got != tt.want {
				t.Fatalf("configuredAuthToken() = %q, want %q", got, tt.want)
			}
		})
	}
}

func authenticatedRequest(s *server, method, target string, body io.Reader) *http.Request {
	req := httptest.NewRequest(method, target, body)
	req.RemoteAddr = "203.0.113.10:12345"
	req.AddCookie(&http.Cookie{Name: cookieName, Value: s.authToken})
	return req
}

func TestLogoutRequiresAuthenticationAndPost(t *testing.T) {
	s := newTestServer(t)
	s.authToken = "test-token"
	h := s.handler()

	unauthenticated := httptest.NewRecorder()
	h.ServeHTTP(unauthenticated, httptest.NewRequest(http.MethodPost, "/logout", nil))
	if unauthenticated.Code != http.StatusUnauthorized {
		t.Fatalf("unauthenticated logout status = %d, want %d", unauthenticated.Code, http.StatusUnauthorized)
	}

	get := httptest.NewRecorder()
	h.ServeHTTP(get, authenticatedRequest(s, http.MethodGet, "/logout", nil))
	if get.Code != http.StatusMethodNotAllowed {
		t.Fatalf("GET logout status = %d, want %d", get.Code, http.StatusMethodNotAllowed)
	}

	post := httptest.NewRecorder()
	h.ServeHTTP(post, authenticatedRequest(s, http.MethodPost, "/logout", nil))
	if post.Code != http.StatusSeeOther {
		t.Fatalf("POST logout status = %d, want %d", post.Code, http.StatusSeeOther)
	}
	if got := post.Header().Get("Location"); got != "/" {
		t.Fatalf("POST logout location = %q, want /", got)
	}

	cookies := post.Result().Cookies()
	if len(cookies) != 1 || cookies[0].Name != cookieName || cookies[0].MaxAge >= 0 {
		t.Fatalf("logout cookie = %#v, want deleted %q cookie", cookies, cookieName)
	}
}

type boundedResponseWriter struct {
	header   http.Header
	status   int
	writes   int
	maxWrite int
	written  int64
}

type sseResponseWriter struct {
	header http.Header
	mu     sync.Mutex
	status int
	body   bytes.Buffer
	wrote  chan struct{}
	once   sync.Once
}

func newSSEResponseWriter() *sseResponseWriter {
	return &sseResponseWriter{header: make(http.Header), wrote: make(chan struct{})}
}

func (w *sseResponseWriter) Header() http.Header { return w.header }

func (w *sseResponseWriter) WriteHeader(status int) {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.status == 0 {
		w.status = status
	}
}

func (w *sseResponseWriter) Write(p []byte) (int, error) {
	w.mu.Lock()
	if w.status == 0 {
		w.status = http.StatusOK
	}
	n, err := w.body.Write(p)
	w.mu.Unlock()
	w.once.Do(func() { close(w.wrote) })
	return n, err
}

func (w *sseResponseWriter) Flush() {}

func (w *sseResponseWriter) BodyString() string {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.body.String()
}

func newBoundedResponseWriter() *boundedResponseWriter {
	return &boundedResponseWriter{header: make(http.Header)}
}

func (w *boundedResponseWriter) Header() http.Header {
	return w.header
}

func (w *boundedResponseWriter) WriteHeader(status int) {
	w.status = status
}

func (w *boundedResponseWriter) Write(p []byte) (int, error) {
	if w.status == 0 {
		w.status = http.StatusOK
	}
	w.writes++
	w.written += int64(len(p))
	if len(p) > w.maxWrite {
		w.maxWrite = len(p)
	}
	return len(p), nil
}

func TestFilePushAndDownload(t *testing.T) {
	s := newTestServer(t)
	body := []byte("a small shared file\n")
	push := httptest.NewRequest(http.MethodPost, "/push?room=shared-room", bytes.NewReader(body))
	push.Header.Set("X-Kind", "file")
	push.Header.Set("X-Mime", "text/plain")
	push.Header.Set("X-Name", "../../notes.txt")
	push.Header.Set("X-From", "laptop")
	pushResult := httptest.NewRecorder()
	s.handler().ServeHTTP(pushResult, push)

	if pushResult.Code != http.StatusOK {
		t.Fatalf("push status = %d, body = %s", pushResult.Code, pushResult.Body.String())
	}
	var stored item
	if err := json.NewDecoder(pushResult.Body).Decode(&stored); err != nil {
		t.Fatal(err)
	}
	if stored.Kind != "file" || stored.Name != "notes.txt" {
		t.Fatalf("stored item = %#v", stored)
	}

	download := httptest.NewRequest(http.MethodGet, "/blob?room=shared-room&id="+stored.ID, nil)
	downloadResult := httptest.NewRecorder()
	s.handler().ServeHTTP(downloadResult, download)

	if downloadResult.Code != http.StatusOK {
		t.Fatalf("download status = %d", downloadResult.Code)
	}
	if got := downloadResult.Header().Get("Content-Disposition"); !strings.Contains(got, "attachment") || !strings.Contains(got, "notes.txt") {
		t.Fatalf("content disposition = %q", got)
	}
	gotBody, err := io.ReadAll(downloadResult.Result().Body)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(gotBody, body) {
		t.Fatalf("download body = %q, want %q", gotBody, body)
	}
}

func TestBlobDownloadStreamsWithBoundedWrites(t *testing.T) {
	s := newTestServer(t)
	body := bytes.Repeat([]byte("0123456789abcdef"), 1<<16) // 1 MiB
	id := nextID()
	size, err := s.writeBlob("shared-room", id, bytes.NewReader(body), int64(len(body)))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.addToRoom("shared-room", item{
		ID:   id,
		Kind: "file",
		Mime: "application/octet-stream",
		Name: "large.bin",
		Size: size,
	}); err != nil {
		t.Fatal(err)
	}

	download := httptest.NewRequest(http.MethodGet, "/blob?room=shared-room&id="+id, nil)
	downloadResult := newBoundedResponseWriter()
	s.handler().ServeHTTP(downloadResult, download)

	if downloadResult.status != http.StatusOK {
		t.Fatalf("download status = %d", downloadResult.status)
	}
	if downloadResult.written != int64(len(body)) {
		t.Fatalf("streamed bytes = %d, want %d", downloadResult.written, len(body))
	}
	if downloadResult.writes < 2 || downloadResult.maxWrite > blobBufferSize {
		t.Fatalf("writes/max write = %d/%d, want multiple writes bounded by %d", downloadResult.writes, downloadResult.maxWrite, blobBufferSize)
	}
	if got := downloadResult.Header().Get("Content-Type"); got != "application/octet-stream" {
		t.Fatalf("content type = %q", got)
	}
	if got := downloadResult.Header().Get("Content-Length"); got != strconv.Itoa(len(body)) {
		t.Fatalf("content length = %q", got)
	}
	if got := downloadResult.Header().Get("X-Content-Type-Options"); got != "nosniff" {
		t.Fatalf("nosniff header = %q", got)
	}
	if got := downloadResult.Header().Get("Cache-Control"); got != "private, max-age=31536000, immutable" {
		t.Fatalf("cache-control = %q", got)
	}
	if got := downloadResult.Header().Get("Content-Disposition"); !strings.Contains(got, "attachment") || !strings.Contains(got, "large.bin") {
		t.Fatalf("content disposition = %q", got)
	}
}

func TestTextAndImagePush(t *testing.T) {
	s := newTestServer(t)
	textPush := httptest.NewRequest(http.MethodPost, "/push?room=2", strings.NewReader("Shared text"))
	textPush.Header.Set("X-Kind", "text")
	textResult := httptest.NewRecorder()
	s.handler().ServeHTTP(textResult, textPush)
	if textResult.Code != http.StatusOK {
		t.Fatalf("text push status = %d", textResult.Code)
	}
	var storedText item
	if err := json.NewDecoder(textResult.Body).Decode(&storedText); err != nil {
		t.Fatal(err)
	}
	if storedText.Text != "Shared text" || storedText.TextBlob {
		t.Fatalf("small text should stay inline: %#v", storedText)
	}

	imageBody := []byte{0x89, 0x50, 0x4e, 0x47, '\r', '\n', 0x1a, '\n'}
	imagePush := httptest.NewRequest(http.MethodPost, "/push?room=2", bytes.NewReader(imageBody))
	imagePush.Header.Set("X-Kind", "image")
	imagePush.Header.Set("X-Mime", "image/png")
	imageResult := httptest.NewRecorder()
	s.handler().ServeHTTP(imageResult, imagePush)
	if imageResult.Code != http.StatusOK {
		t.Fatalf("image push status = %d", imageResult.Code)
	}
	var stored item
	if err := json.NewDecoder(imageResult.Body).Decode(&stored); err != nil {
		t.Fatal(err)
	}
	if stored.Kind != "image" || stored.Mime != "image/png" {
		t.Fatalf("stored image = %#v", stored)
	}

	imageGet := httptest.NewRequest(http.MethodGet, "/blob?room=2&id="+stored.ID, nil)
	imageGetResult := httptest.NewRecorder()
	s.handler().ServeHTTP(imageGetResult, imageGet)
	if imageGetResult.Code != http.StatusOK || !bytes.Equal(imageGetResult.Body.Bytes(), imageBody) {
		t.Fatalf("image fetch status/body = %d/%x", imageGetResult.Code, imageGetResult.Body.Bytes())
	}
}

func TestImageSignatureValidationAcceptsSupportedFormats(t *testing.T) {
	tests := []struct {
		mime string
		body []byte
	}{
		{"image/png", []byte{0x89, 0x50, 0x4e, 0x47, '\r', '\n', 0x1a, '\n'}},
		{"image/jpeg", []byte{0xff, 0xd8, 0xff, 0xe0}},
		{"image/gif", []byte("GIF89a")},
		{"image/webp", []byte{'R', 'I', 'F', 'F', 0, 0, 0, 0, 'W', 'E', 'B', 'P'}},
	}
	for _, tt := range tests {
		t.Run(tt.mime, func(t *testing.T) {
			s := newTestServer(t)
			push := httptest.NewRequest(http.MethodPost, "/push?room=images", bytes.NewReader(tt.body))
			push.Header.Set("X-Kind", "image")
			push.Header.Set("X-Mime", tt.mime)
			result := httptest.NewRecorder()
			s.handler().ServeHTTP(result, push)
			if result.Code != http.StatusOK {
				t.Fatalf("push status = %d, body = %s", result.Code, result.Body.String())
			}
			if got := atomic.LoadInt64(&totalBytes); got != int64(len(tt.body)) {
				t.Fatalf("reserved bytes = %d, want %d", got, len(tt.body))
			}
		})
	}
}

func TestImageSignatureValidationRejectsMismatchAndTruncationWithoutLeaks(t *testing.T) {
	tests := []struct {
		name string
		mime string
		body []byte
	}{
		{"spoofed png", "image/png", []byte("GIF89a")},
		{"truncated png", "image/png", []byte{0x89, 0x50, 0x4e, 0x47, '\r', '\n', 0x1a}},
		{"truncated jpeg", "image/jpeg", []byte{0xff, 0xd8}},
		{"truncated gif", "image/gif", []byte("GIF89")},
		{"truncated webp", "image/webp", []byte("RIFF0000WEB")},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			s := newTestServer(t)
			push := httptest.NewRequest(http.MethodPost, "/push?room=images", bytes.NewReader(tt.body))
			push.Header.Set("X-Kind", "image")
			push.Header.Set("X-Mime", tt.mime)
			result := httptest.NewRecorder()
			s.handler().ServeHTTP(result, push)
			if result.Code != http.StatusUnsupportedMediaType {
				t.Fatalf("push status = %d, want %d, body = %s", result.Code, http.StatusUnsupportedMediaType, result.Body.String())
			}
			if got := atomic.LoadInt64(&totalBytes); got != 0 {
				t.Fatalf("rejected image reserved %d bytes", got)
			}
			if s.existingRoom("images") != nil {
				t.Fatal("rejected image created a room item")
			}
			entries, err := os.ReadDir(s.blobDir("images"))
			if err != nil {
				t.Fatal(err)
			}
			if len(entries) != 0 {
				t.Fatalf("rejected image left blobs: %#v", entries)
			}
		})
	}
}

func TestDirectImageLabelledFileRejectsSpoofWithoutLeaks(t *testing.T) {
	s := newTestServer(t)
	push := httptest.NewRequest(http.MethodPost, "/push?room=images", strings.NewReader("not an image"))
	push.Header.Set("X-Kind", "file")
	push.Header.Set("X-Mime", "image/png")
	push.Header.Set("X-Name", "masquerade.bin")
	result := httptest.NewRecorder()
	s.handler().ServeHTTP(result, push)
	if result.Code != http.StatusUnsupportedMediaType {
		t.Fatalf("push status = %d, want %d, body = %s", result.Code, http.StatusUnsupportedMediaType, result.Body.String())
	}
	if got := atomic.LoadInt64(&totalBytes); got != 0 {
		t.Fatalf("rejected file reserved %d bytes", got)
	}
	if s.existingRoom("images") != nil {
		t.Fatal("rejected image-labelled file created a room item")
	}
	entries, err := os.ReadDir(s.blobDir("images"))
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 0 {
		t.Fatalf("rejected image-labelled file left blobs: %#v", entries)
	}
}

func TestResumableImageLabelledFileRejectsSpoofAndCleansUp(t *testing.T) {
	s := newTestServer(t)
	spoofed := []byte("bad!")
	start := httptest.NewRequest(http.MethodPost, "/upload/start?room=images", nil)
	start.Header.Set("X-Size", strconv.Itoa(len(spoofed)))
	start.Header.Set("X-Mime", "image/png")
	start.Header.Set("X-Name", "masquerade.bin")
	startResult := httptest.NewRecorder()
	s.handler().ServeHTTP(startResult, start)
	if startResult.Code != http.StatusOK {
		t.Fatalf("start status = %d, body = %s", startResult.Code, startResult.Body.String())
	}
	var session struct {
		Upload string `json:"upload"`
	}
	if err := json.NewDecoder(startResult.Body).Decode(&session); err != nil {
		t.Fatal(err)
	}
	chunk := httptest.NewRequest(http.MethodPost, "/upload/chunk?upload="+session.Upload+"&offset=0", bytes.NewReader(spoofed))
	chunkResult := httptest.NewRecorder()
	s.handler().ServeHTTP(chunkResult, chunk)
	if chunkResult.Code != http.StatusOK {
		t.Fatalf("chunk status = %d, body = %s", chunkResult.Code, chunkResult.Body.String())
	}
	complete := httptest.NewRequest(http.MethodPost, "/upload/complete?upload="+session.Upload, nil)
	completeResult := httptest.NewRecorder()
	s.handler().ServeHTTP(completeResult, complete)
	if completeResult.Code != http.StatusUnsupportedMediaType {
		t.Fatalf("complete status = %d, want %d, body = %s", completeResult.Code, http.StatusUnsupportedMediaType, completeResult.Body.String())
	}
	if got := atomic.LoadInt64(&totalBytes); got != 0 {
		t.Fatalf("rejected upload reserved %d bytes", got)
	}
	s.mu.Lock()
	_, active := s.uploads[session.Upload]
	s.mu.Unlock()
	if active {
		t.Fatal("rejected upload session remained active")
	}
	entries, err := os.ReadDir(s.uploadDir())
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 0 {
		t.Fatalf("rejected upload left staging files: %#v", entries)
	}
	if _, err := os.Stat(s.blobPath("images", session.Upload)); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("rejected upload left committed blob: %v", err)
	}
}

func TestResumableImageLabelledFileWithValidMagicRemainsAttachment(t *testing.T) {
	s := newTestServer(t)
	image := []byte{0x89, 0x50, 0x4e, 0x47, '\r', '\n', 0x1a, '\n'}
	start := httptest.NewRequest(http.MethodPost, "/upload/start?room=images", nil)
	start.Header.Set("X-Size", strconv.Itoa(len(image)))
	start.Header.Set("X-Mime", "image/png")
	start.Header.Set("X-Name", "pasted-image.png")
	startResult := httptest.NewRecorder()
	s.handler().ServeHTTP(startResult, start)
	if startResult.Code != http.StatusOK {
		t.Fatalf("start status = %d, body = %s", startResult.Code, startResult.Body.String())
	}
	var session struct {
		Upload string `json:"upload"`
	}
	if err := json.NewDecoder(startResult.Body).Decode(&session); err != nil {
		t.Fatal(err)
	}
	for offset := 0; offset < len(image); offset += 4 {
		chunk := httptest.NewRequest(http.MethodPost, "/upload/chunk?upload="+session.Upload+"&offset="+strconv.Itoa(offset), bytes.NewReader(image[offset:offset+4]))
		chunkResult := httptest.NewRecorder()
		s.handler().ServeHTTP(chunkResult, chunk)
		if chunkResult.Code != http.StatusOK {
			t.Fatalf("chunk at %d status = %d, body = %s", offset, chunkResult.Code, chunkResult.Body.String())
		}
	}
	complete := httptest.NewRequest(http.MethodPost, "/upload/complete?upload="+session.Upload, nil)
	completeResult := httptest.NewRecorder()
	s.handler().ServeHTTP(completeResult, complete)
	if completeResult.Code != http.StatusOK {
		t.Fatalf("complete status = %d, body = %s", completeResult.Code, completeResult.Body.String())
	}
	var stored item
	if err := json.NewDecoder(completeResult.Body).Decode(&stored); err != nil {
		t.Fatal(err)
	}
	if stored.Kind != "file" || stored.Mime != "image/png" {
		t.Fatalf("stored image-labelled file = %#v", stored)
	}
	download := httptest.NewRequest(http.MethodGet, "/blob?room=images&id="+stored.ID, nil)
	downloadResult := httptest.NewRecorder()
	s.handler().ServeHTTP(downloadResult, download)
	if downloadResult.Code != http.StatusOK || !bytes.Equal(downloadResult.Body.Bytes(), image) {
		t.Fatalf("download status/body = %d/%x", downloadResult.Code, downloadResult.Body.Bytes())
	}
	if disposition := downloadResult.Header().Get("Content-Disposition"); !strings.Contains(disposition, "attachment") {
		t.Fatalf("image-labelled file was not an attachment: %q", disposition)
	}
	if nosniff := downloadResult.Header().Get("X-Content-Type-Options"); nosniff != "nosniff" {
		t.Fatalf("nosniff header = %q", nosniff)
	}
}

func TestUnsupportedImageTypeIsRejected(t *testing.T) {
	s := newTestServer(t)
	push := httptest.NewRequest(http.MethodPost, "/push?room=shared-room", strings.NewReader("<svg></svg>"))
	push.Header.Set("X-Kind", "image")
	push.Header.Set("X-Mime", "image/svg+xml")
	pushResult := httptest.NewRecorder()
	s.handler().ServeHTTP(pushResult, push)

	if pushResult.Code != http.StatusUnsupportedMediaType {
		t.Fatalf("push status = %d, want %d", pushResult.Code, http.StatusUnsupportedMediaType)
	}
}

func TestOversizedChunkedFileIsRejectedWithoutConsumingCapacity(t *testing.T) {
	s := newTestServer(t)
	s.maxFileSize = 8
	push := httptest.NewRequest(http.MethodPost, "/push?room=shared-room", bytes.NewReader([]byte("123456789")))
	push.ContentLength = -1
	push.Header.Set("X-Kind", "file")
	push.Header.Set("X-Mime", "application/octet-stream")
	push.Header.Set("X-Name", "too-large.bin")
	pushResult := httptest.NewRecorder()
	s.handler().ServeHTTP(pushResult, push)

	if pushResult.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("push status = %d, want %d", pushResult.Code, http.StatusRequestEntityTooLarge)
	}
	if atomic.LoadInt64(&totalBytes) != 0 {
		t.Fatalf("reserved capacity after rejection = %d", atomic.LoadInt64(&totalBytes))
	}
}

func TestResumableFileUploadAndDownload(t *testing.T) {
	s := newTestServer(t)
	body := []byte("a resumable shared file")

	start := httptest.NewRequest(http.MethodPost, "/upload/start?room=shared-room", nil)
	start.Header.Set("X-From", "laptop")
	start.Header.Set("X-Mime", "text/plain")
	start.Header.Set("X-Name", "notes.txt")
	start.Header.Set("X-Size", "23")
	startResult := httptest.NewRecorder()
	s.handler().ServeHTTP(startResult, start)
	if startResult.Code != http.StatusOK {
		t.Fatalf("start status = %d, body = %s", startResult.Code, startResult.Body.String())
	}
	var session struct {
		Upload    string `json:"upload"`
		ChunkSize int64  `json:"chunkSize"`
	}
	if err := json.NewDecoder(startResult.Body).Decode(&session); err != nil {
		t.Fatal(err)
	}
	if session.Upload == "" || session.ChunkSize != 4 {
		t.Fatalf("upload session = %#v", session)
	}
	if got := atomic.LoadInt64(&totalBytes); got != 0 {
		t.Fatalf("reserved capacity after start = %d, want 0", got)
	}

	for offset := 0; offset < len(body); offset += int(session.ChunkSize) {
		end := offset + int(session.ChunkSize)
		if end > len(body) {
			end = len(body)
		}
		chunk := httptest.NewRequest(http.MethodPost, "/upload/chunk?upload="+session.Upload+"&offset="+strconv.Itoa(offset), bytes.NewReader(body[offset:end]))
		chunkResult := httptest.NewRecorder()
		s.handler().ServeHTTP(chunkResult, chunk)
		if chunkResult.Code != http.StatusOK {
			t.Fatalf("chunk at %d status = %d, body = %s", offset, chunkResult.Code, chunkResult.Body.String())
		}
		if got := atomic.LoadInt64(&totalBytes); got != int64(end) {
			t.Fatalf("reserved capacity after chunk at %d = %d, want %d", offset, got, end)
		}
	}

	complete := httptest.NewRequest(http.MethodPost, "/upload/complete?upload="+session.Upload, nil)
	completeResult := httptest.NewRecorder()
	s.handler().ServeHTTP(completeResult, complete)
	if completeResult.Code != http.StatusOK {
		t.Fatalf("complete status = %d, body = %s", completeResult.Code, completeResult.Body.String())
	}
	var stored item
	if err := json.NewDecoder(completeResult.Body).Decode(&stored); err != nil {
		t.Fatal(err)
	}

	download := httptest.NewRequest(http.MethodGet, "/blob?room=shared-room&id="+stored.ID, nil)
	downloadResult := httptest.NewRecorder()
	s.handler().ServeHTTP(downloadResult, download)
	if downloadResult.Code != http.StatusOK || !bytes.Equal(downloadResult.Body.Bytes(), body) {
		t.Fatalf("download status/body = %d/%q", downloadResult.Code, downloadResult.Body.Bytes())
	}
	if got := atomic.LoadInt64(&totalBytes); got != int64(len(body)) {
		t.Fatalf("reserved capacity after completion = %d, want %d", got, len(body))
	}
}

func TestUploadIDsAreOpaqueRandomHex(t *testing.T) {
	seen := map[string]struct{}{}
	for i := 0; i < 128; i++ {
		id, err := newUploadID()
		if err != nil {
			t.Fatal(err)
		}
		if len(id) != uploadIDBytes*2 {
			t.Fatalf("upload ID length = %d, want %d", len(id), uploadIDBytes*2)
		}
		if _, err := hex.DecodeString(id); err != nil {
			t.Fatalf("upload ID is not hex: %q", id)
		}
		if _, exists := seen[id]; exists {
			t.Fatalf("duplicate upload ID: %q", id)
		}
		seen[id] = struct{}{}
	}
}

func startResumableUpload(t *testing.T, s *server, room, remote string, size int) string {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, "/upload/start?room="+room, nil)
	req.RemoteAddr = remote
	req.Header.Set("X-Size", strconv.Itoa(size))
	req.Header.Set("X-Name", "archive.bin")
	result := httptest.NewRecorder()
	s.handler().ServeHTTP(result, req)
	if result.Code != http.StatusOK {
		t.Fatalf("start status = %d, body = %s", result.Code, result.Body.String())
	}
	var session struct {
		Upload string `json:"upload"`
	}
	if err := json.NewDecoder(result.Body).Decode(&session); err != nil {
		t.Fatal(err)
	}
	if session.Upload == "" {
		t.Fatal("missing upload ID")
	}
	return session.Upload
}

func TestResumableUploadRejectsCrossClientAndRoom(t *testing.T) {
	s := newTestServer(t)
	owner := "198.51.100.10:1234"
	id := startResumableUpload(t, s, "owner-room", owner, 4)

	for _, target := range []string{
		"/upload/chunk?upload=" + id + "&offset=0",
		"/upload/complete?upload=" + id,
		"/upload/abort?upload=" + id,
	} {
		req := httptest.NewRequest(http.MethodPost, target, bytes.NewReader([]byte("abcd")))
		req.RemoteAddr = "198.51.100.11:1234"
		result := httptest.NewRecorder()
		s.handler().ServeHTTP(result, req)
		if result.Code != http.StatusNotFound {
			t.Fatalf("cross-client %s status = %d, want %d", target, result.Code, http.StatusNotFound)
		}
	}
	if got := atomic.LoadInt64(&totalBytes); got != 0 {
		t.Fatalf("cross-client access reserved %d bytes", got)
	}

	wrongRoom := httptest.NewRequest(http.MethodPost, "/upload/chunk?upload="+id+"&offset=0&room=other-room", bytes.NewReader([]byte("abcd")))
	wrongRoom.RemoteAddr = owner
	wrongRoomResult := httptest.NewRecorder()
	s.handler().ServeHTTP(wrongRoomResult, wrongRoom)
	if wrongRoomResult.Code != http.StatusNotFound {
		t.Fatalf("wrong-room chunk status = %d, want %d", wrongRoomResult.Code, http.StatusNotFound)
	}

	chunk := httptest.NewRequest(http.MethodPost, "/upload/chunk?upload="+id+"&offset=0", bytes.NewReader([]byte("abcd")))
	chunk.RemoteAddr = owner
	chunkResult := httptest.NewRecorder()
	s.handler().ServeHTTP(chunkResult, chunk)
	if chunkResult.Code != http.StatusOK {
		t.Fatalf("owner chunk status = %d, body = %s", chunkResult.Code, chunkResult.Body.String())
	}
}

func TestResumableUploadAccountsOnlyWrittenChunks(t *testing.T) {
	s := newTestServer(t)
	s.maxDisk = 5
	id := startResumableUpload(t, s, "quota-room", "198.51.100.20:1234", 6)
	if got := atomic.LoadInt64(&totalBytes); got != 0 {
		t.Fatalf("start reserved %d bytes, want 0", got)
	}

	first := httptest.NewRequest(http.MethodPost, "/upload/chunk?upload="+id+"&offset=0", bytes.NewReader([]byte("abcd")))
	first.RemoteAddr = "198.51.100.20:1234"
	firstResult := httptest.NewRecorder()
	s.handler().ServeHTTP(firstResult, first)
	if firstResult.Code != http.StatusOK {
		t.Fatalf("first chunk status = %d, body = %s", firstResult.Code, firstResult.Body.String())
	}
	if got := atomic.LoadInt64(&totalBytes); got != 4 {
		t.Fatalf("first chunk reserved %d bytes, want 4", got)
	}

	second := httptest.NewRequest(http.MethodPost, "/upload/chunk?upload="+id+"&offset=4", bytes.NewReader([]byte("ef")))
	second.RemoteAddr = "198.51.100.20:1234"
	secondResult := httptest.NewRecorder()
	s.handler().ServeHTTP(secondResult, second)
	if secondResult.Code != http.StatusInsufficientStorage {
		t.Fatalf("second chunk status = %d, want %d", secondResult.Code, http.StatusInsufficientStorage)
	}
	if got := atomic.LoadInt64(&totalBytes); got != 4 {
		t.Fatalf("failed chunk changed reservation to %d, want 4", got)
	}

	abort := httptest.NewRequest(http.MethodPost, "/upload/abort?upload="+id, nil)
	abort.RemoteAddr = "198.51.100.20:1234"
	abortResult := httptest.NewRecorder()
	s.handler().ServeHTTP(abortResult, abort)
	if abortResult.Code != http.StatusNoContent || atomic.LoadInt64(&totalBytes) != 0 {
		t.Fatalf("abort status/reservation = %d/%d", abortResult.Code, atomic.LoadInt64(&totalBytes))
	}
}

func TestResumableUploadSessionCapsAndExpiryAccounting(t *testing.T) {
	s := newTestServer(t)
	s.maxUploads = 2
	s.maxUploadsPerClient = 1
	s.maxUploadsPerRoom = 1
	first := startResumableUpload(t, s, "one", "198.51.100.30:1234", 4)

	for _, attempt := range []struct {
		room   string
		remote string
	}{
		{"two", "198.51.100.30:1234"},
		{"one", "198.51.100.31:1234"},
	} {
		req := httptest.NewRequest(http.MethodPost, "/upload/start?room="+attempt.room, nil)
		req.RemoteAddr = attempt.remote
		req.Header.Set("X-Size", "4")
		result := httptest.NewRecorder()
		s.handler().ServeHTTP(result, req)
		if result.Code != http.StatusTooManyRequests {
			t.Fatalf("cap start for %s/%s status = %d, want %d", attempt.room, attempt.remote, result.Code, http.StatusTooManyRequests)
		}
	}
	second := startResumableUpload(t, s, "two", "198.51.100.31:1234", 4)
	req := httptest.NewRequest(http.MethodPost, "/upload/start?room=three", nil)
	req.RemoteAddr = "198.51.100.32:1234"
	req.Header.Set("X-Size", "4")
	result := httptest.NewRecorder()
	s.handler().ServeHTTP(result, req)
	if result.Code != http.StatusTooManyRequests {
		t.Fatalf("global cap status = %d, want %d", result.Code, http.StatusTooManyRequests)
	}

	chunk := httptest.NewRequest(http.MethodPost, "/upload/chunk?upload="+first+"&offset=0", bytes.NewReader([]byte("abcd")))
	chunk.RemoteAddr = "198.51.100.30:1234"
	chunkResult := httptest.NewRecorder()
	s.handler().ServeHTTP(chunkResult, chunk)
	if chunkResult.Code != http.StatusOK || atomic.LoadInt64(&totalBytes) != 4 {
		t.Fatalf("first chunk status/reservation = %d/%d", chunkResult.Code, atomic.LoadInt64(&totalBytes))
	}
	s.mu.Lock()
	s.uploads[first].expires = time.Now().Add(-time.Second)
	s.mu.Unlock()

	complete := httptest.NewRequest(http.MethodPost, "/upload/complete?upload="+first, nil)
	complete.RemoteAddr = "198.51.100.30:1234"
	completeResult := httptest.NewRecorder()
	s.handler().ServeHTTP(completeResult, complete)
	if completeResult.Code != http.StatusNotFound {
		t.Fatalf("expired complete status = %d, want %d", completeResult.Code, http.StatusNotFound)
	}
	if got := atomic.LoadInt64(&totalBytes); got != 0 {
		t.Fatalf("expired upload leaked reservation = %d", got)
	}
	s.mu.Lock()
	_, firstPresent := s.uploads[first]
	secondPresent := s.uploads[second] != nil
	clientCount := s.uploadsByClient["198.51.100.30"]
	roomCount := s.uploadsByRoom["one"]
	s.mu.Unlock()
	if firstPresent || !secondPresent || clientCount != 0 || roomCount != 0 {
		t.Fatalf("expired upload bookkeeping first=%v second=%v client=%d room=%d", firstPresent, secondPresent, clientCount, roomCount)
	}

	abort := httptest.NewRequest(http.MethodPost, "/upload/abort?upload="+second, nil)
	abort.RemoteAddr = "198.51.100.31:1234"
	abortResult := httptest.NewRecorder()
	s.handler().ServeHTTP(abortResult, abort)
	if abortResult.Code != http.StatusNoContent || atomic.LoadInt64(&totalBytes) != 0 {
		t.Fatalf("abort status/reservation = %d/%d", abortResult.Code, atomic.LoadInt64(&totalBytes))
	}
}

func TestStalledResumableChunkReleasesItsSession(t *testing.T) {
	s := newTestServer(t)
	s.maxUploads = 1
	s.maxUploadsPerClient = 1
	s.maxUploadsPerRoom = 1
	s.uploadChunkIdleTimeout = 100 * time.Millisecond
	httpServer := httptest.NewServer(s.handler())
	defer httpServer.Close()

	start := func(room string) (string, *http.Response) {
		t.Helper()
		req, err := http.NewRequest(http.MethodPost, httpServer.URL+"/upload/start?room="+room, nil)
		if err != nil {
			t.Fatal(err)
		}
		req.Header.Set("X-Size", "4")
		res, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		if res.StatusCode != http.StatusOK {
			t.Fatalf("start status = %d", res.StatusCode)
		}
		defer res.Body.Close()
		var session struct {
			Upload string `json:"upload"`
		}
		if err := json.NewDecoder(res.Body).Decode(&session); err != nil {
			t.Fatal(err)
		}
		return session.Upload, res
	}

	id, _ := start("stalled")
	reader, writer := io.Pipe()
	chunk, err := http.NewRequest(http.MethodPost, httpServer.URL+"/upload/chunk?upload="+id+"&offset=0", reader)
	if err != nil {
		t.Fatal(err)
	}
	chunk.ContentLength = 4
	chunkResult := make(chan *http.Response, 1)
	chunkError := make(chan error, 1)
	go func() {
		res, err := http.DefaultClient.Do(chunk)
		if err != nil {
			chunkError <- err
			return
		}
		chunkResult <- res
	}()
	go func() {
		_, _ = writer.Write([]byte("a"))
	}()

	select {
	case err := <-chunkError:
		t.Fatalf("stalled chunk request failed before response: %v", err)
	case res := <-chunkResult:
		defer res.Body.Close()
		if res.StatusCode != http.StatusRequestTimeout {
			t.Fatalf("stalled chunk status = %d, want %d", res.StatusCode, http.StatusRequestTimeout)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("stalled chunk did not time out")
	}
	_ = writer.Close()

	if got := atomic.LoadInt64(&totalBytes); got != 0 {
		t.Fatalf("stalled chunk leaked reservation = %d", got)
	}
	s.mu.Lock()
	_, present := s.uploads[id]
	s.mu.Unlock()
	if present {
		t.Fatal("stalled upload session remained active")
	}
	if _, res := start("replacement"); res.StatusCode != http.StatusOK {
		t.Fatalf("replacement start status = %d", res.StatusCode)
	}
}

func TestClearRoomDeletesHistoryAndBlobs(t *testing.T) {
	s := newTestServer(t)
	body := []byte("remove me")
	push := httptest.NewRequest(http.MethodPost, "/push?room=clear-room", bytes.NewReader(body))
	push.Header.Set("X-Kind", "file")
	push.Header.Set("X-Mime", "text/plain")
	push.Header.Set("X-Name", "remove.txt")
	pushResult := httptest.NewRecorder()
	s.handler().ServeHTTP(pushResult, push)
	if pushResult.Code != http.StatusOK {
		t.Fatalf("push status = %d", pushResult.Code)
	}
	var stored item
	if err := json.NewDecoder(pushResult.Body).Decode(&stored); err != nil {
		t.Fatal(err)
	}

	clear := httptest.NewRequest(http.MethodPost, "/clear?room=clear-room", nil)
	clearResult := httptest.NewRecorder()
	s.handler().ServeHTTP(clearResult, clear)
	if clearResult.Code != http.StatusOK {
		t.Fatalf("clear status = %d", clearResult.Code)
	}
	var response struct {
		Cleared int `json:"cleared"`
	}
	if err := json.NewDecoder(clearResult.Body).Decode(&response); err != nil {
		t.Fatal(err)
	}
	if response.Cleared != 1 || atomic.LoadInt64(&totalBytes) != 0 {
		t.Fatalf("clear response/size = %#v/%d", response, atomic.LoadInt64(&totalBytes))
	}

	download := httptest.NewRequest(http.MethodGet, "/blob?room=clear-room&id="+stored.ID, nil)
	downloadResult := httptest.NewRecorder()
	s.handler().ServeHTTP(downloadResult, download)
	if downloadResult.Code != http.StatusNotFound {
		t.Fatalf("download after clear status = %d", downloadResult.Code)
	}
}

func TestClientIdentityTrustsOnlyConfiguredCloudflaredPeer(t *testing.T) {
	s := newTestServer(t)
	trusted, err := parseTrustedProxies("172.30.0.3/32")
	if err != nil {
		t.Fatal(err)
	}
	s.trustedProxies = trusted

	tests := []struct {
		name         string
		remoteAddr   string
		cfConnecting string
		xff          string
		want         string
	}{
		{
			name:         "trusted cloudflared peer accepts canonical Cloudflare header",
			remoteAddr:   "172.30.0.3:45678",
			cfConnecting: "198.51.100.7",
			xff:          "192.0.2.1",
			want:         "198.51.100.7",
		},
		{
			name:         "direct host ignores spoofed forwarding headers",
			remoteAddr:   "127.0.0.1:45678",
			cfConnecting: "198.51.100.7",
			xff:          "192.0.2.1",
			want:         "127.0.0.1",
		},
		{
			name:       "untrusted container ignores spoofed forwarding headers",
			remoteAddr: "172.30.0.4:45678",
			xff:        "192.0.2.1",
			want:       "172.30.0.4",
		},
		{
			name:       "trusted peer does not fall back to XFF",
			remoteAddr: "172.30.0.3:45678",
			xff:        "192.0.2.1",
			want:       "172.30.0.3",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodPost, "/push", nil)
			req.RemoteAddr = tt.remoteAddr
			req.Header.Set("CF-Connecting-IP", tt.cfConnecting)
			req.Header.Set("X-Forwarded-For", tt.xff)
			if got := s.clientIdentity(req); got != tt.want {
				t.Fatalf("client identity = %q, want %q", got, tt.want)
			}
		})
	}
}

func TestLimiterExpiresAndBoundsBuckets(t *testing.T) {
	l := newLimiter(0, 1, time.Minute, 2)
	now := time.Unix(1_000, 0)
	if !l.allowAt("oldest", now) || !l.allowAt("newer", now.Add(time.Second)) || !l.allowAt("replacement", now.Add(2*time.Second)) {
		t.Fatal("new client bucket should receive its burst token")
	}
	l.mu.Lock()
	_, oldestPresent := l.b["oldest"]
	countAfterBound := len(l.b)
	l.mu.Unlock()
	if oldestPresent || countAfterBound != 2 {
		t.Fatalf("bounded buckets = %d, oldest present = %v", countAfterBound, oldestPresent)
	}
	if !l.allowAt("fresh", now.Add(3*time.Minute)) {
		t.Fatal("expired buckets should make room for a fresh client")
	}
	l.mu.Lock()
	countAfterExpiry := len(l.b)
	_, freshPresent := l.b["fresh"]
	l.mu.Unlock()
	if countAfterExpiry != 1 || !freshPresent {
		t.Fatalf("bucket expiry left %d buckets, fresh present = %v", countAfterExpiry, freshPresent)
	}
}

func TestLoginAndMutationRoutesAreRateLimited(t *testing.T) {
	loginServer := newTestServer(t)
	loginServer.authToken = "test-token"
	loginServer.loginLimiter = newLimiter(0, 1, time.Minute, 8)
	for attempt := 0; attempt < 2; attempt++ {
		req := httptest.NewRequest(http.MethodPost, "/login", strings.NewReader("password=wrong"))
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		req.RemoteAddr = "203.0.113.10:12345"
		result := httptest.NewRecorder()
		loginServer.handler().ServeHTTP(result, req)
		if attempt == 0 && result.Code == http.StatusTooManyRequests {
			t.Fatal("first login request was unexpectedly throttled")
		}
		if attempt == 1 && result.Code != http.StatusTooManyRequests {
			t.Fatalf("second login status = %d, want %d", result.Code, http.StatusTooManyRequests)
		}
	}

	routes := []struct {
		name    string
		method  string
		target  string
		prepare func(*http.Request)
	}{
		{"push", http.MethodPost, "/push?room=shared-room", nil},
		{"upload start", http.MethodPost, "/upload/start?room=shared-room", func(req *http.Request) { req.Header.Set("X-Size", "0") }},
		{"upload chunk", http.MethodPost, "/upload/chunk?upload=missing&offset=0", nil},
		{"upload complete", http.MethodPost, "/upload/complete?upload=missing", nil},
		{"upload abort", http.MethodPost, "/upload/abort?upload=missing", nil},
		{"pin", http.MethodPost, "/pin?room=shared-room&id=missing", nil},
		{"clear", http.MethodPost, "/clear?room=shared-room", nil},
	}
	for _, route := range routes {
		t.Run(route.name, func(t *testing.T) {
			s := newTestServer(t)
			s.authToken = "test-token"
			s.mutationLimiter = newLimiter(0, 1, time.Minute, 8)
			for attempt := 0; attempt < 2; attempt++ {
				req := authenticatedRequest(s, route.method, route.target, nil)
				if route.prepare != nil {
					route.prepare(req)
				}
				result := httptest.NewRecorder()
				s.handler().ServeHTTP(result, req)
				if attempt == 0 && result.Code == http.StatusTooManyRequests {
					t.Fatal("first mutation request was unexpectedly throttled")
				}
				if attempt == 1 && result.Code != http.StatusTooManyRequests {
					t.Fatalf("second mutation status = %d, want %d", result.Code, http.StatusTooManyRequests)
				}
			}
		})
	}
}

func TestSSESubscriptionLimits(t *testing.T) {
	s := newTestServer(t)
	s.maxSSE = 2
	s.maxSSEPerClient = 1
	if _, err := s.addToRoom("shared-room", item{ID: nextID(), Kind: "text", Text: "ready", Size: 5, At: time.Now().Unix()}); err != nil {
		t.Fatal(err)
	}

	start := func(client string) (*httptest.ResponseRecorder, context.CancelFunc, <-chan struct{}) {
		ctx, cancel := context.WithCancel(context.Background())
		req := httptest.NewRequest(http.MethodGet, "/events?room=shared-room", nil).WithContext(ctx)
		req.RemoteAddr = client + ":12345"
		result := httptest.NewRecorder()
		done := make(chan struct{})
		go func() {
			s.handler().ServeHTTP(result, req)
			close(done)
		}()
		return result, cancel, done
	}
	waitForTotal := func(want int) {
		deadline := time.Now().Add(time.Second)
		for time.Now().Before(deadline) {
			if total, _ := s.sseCounts(); total == want {
				return
			}
			time.Sleep(time.Millisecond)
		}
		total, clients := s.sseCounts()
		t.Fatalf("SSE total = %d, clients = %#v, want total %d", total, clients, want)
	}

	first, cancelFirst, firstDone := start("203.0.113.10")
	waitForTotal(1)
	sameClient := httptest.NewRequest(http.MethodGet, "/events?room=shared-room", nil)
	sameClient.RemoteAddr = "203.0.113.10:54321"
	sameClientResult := httptest.NewRecorder()
	s.handler().ServeHTTP(sameClientResult, sameClient)
	if sameClientResult.Code != http.StatusTooManyRequests {
		t.Fatalf("same-client SSE status = %d, want %d", sameClientResult.Code, http.StatusTooManyRequests)
	}

	_, cancelSecond, secondDone := start("203.0.113.11")
	waitForTotal(2)
	thirdClient := httptest.NewRequest(http.MethodGet, "/events?room=shared-room", nil)
	thirdClient.RemoteAddr = "203.0.113.12:54321"
	thirdClientResult := httptest.NewRecorder()
	s.handler().ServeHTTP(thirdClientResult, thirdClient)
	if thirdClientResult.Code != http.StatusTooManyRequests {
		t.Fatalf("global SSE status = %d, want %d", thirdClientResult.Code, http.StatusTooManyRequests)
	}

	cancelFirst()
	cancelSecond()
	<-firstDone
	<-secondDone
	waitForTotal(0)
	if first.Code != http.StatusOK || !strings.Contains(first.Body.String(), `"kind":"snapshot"`) {
		t.Fatalf("first SSE response = status %d, body %q", first.Code, first.Body.String())
	}
}

func TestHTTPServerUsesStreamingSafeLimits(t *testing.T) {
	s := newTestServer(t)
	httpServer := s.httpServer("127.0.0.1:0")
	if httpServer.ReadHeaderTimeout != readHeaderTimeout {
		t.Fatalf("read header timeout = %v, want %v", httpServer.ReadHeaderTimeout, readHeaderTimeout)
	}
	if httpServer.IdleTimeout != idleTimeout {
		t.Fatalf("idle timeout = %v, want %v", httpServer.IdleTimeout, idleTimeout)
	}
	if httpServer.MaxHeaderBytes != maxHeaderBytes {
		t.Fatalf("max header bytes = %d, want %d", httpServer.MaxHeaderBytes, maxHeaderBytes)
	}
	if httpServer.ReadTimeout != 0 || httpServer.WriteTimeout != 0 {
		t.Fatalf("streaming server deadlines = read %v, write %v", httpServer.ReadTimeout, httpServer.WriteTimeout)
	}
}

func TestRoomNameValidationAndBrowserCompatibleCodes(t *testing.T) {
	s := newTestServer(t)
	invalidRoutes := []struct {
		method string
		target string
		setup  func(*http.Request)
	}{
		{http.MethodGet, "/list?room=bad%2Froom", nil},
		{http.MethodPost, "/push?room=bad%2Froom", func(req *http.Request) { req.Header.Set("X-Kind", "text") }},
		{http.MethodPost, "/upload/start?room=bad%2Froom", func(req *http.Request) { req.Header.Set("X-Size", "0") }},
		{http.MethodPost, "/pin?room=bad%2Froom&id=missing", nil},
		{http.MethodPost, "/clear?room=bad%2Froom", nil},
		{http.MethodGet, "/item?room=bad%2Froom&id=missing", nil},
		{http.MethodGet, "/blob?room=bad%2Froom&id=missing", nil},
		{http.MethodGet, "/events?room=bad%2Froom", nil},
	}
	for _, route := range invalidRoutes {
		req := httptest.NewRequest(route.method, route.target, strings.NewReader("text"))
		if route.setup != nil {
			route.setup(req)
		}
		result := httptest.NewRecorder()
		s.handler().ServeHTTP(result, req)
		if result.Code != http.StatusBadRequest {
			t.Fatalf("%s %s status = %d, want %d", route.method, route.target, result.Code, http.StatusBadRequest)
		}
	}
	if len(s.rooms) != 0 {
		t.Fatalf("invalid room routes created %d rooms", len(s.rooms))
	}

	valid := httptest.NewRequest(http.MethodPost, "/push?room=2", strings.NewReader("works"))
	valid.Header.Set("X-Kind", "text")
	validResult := httptest.NewRecorder()
	s.handler().ServeHTTP(validResult, valid)
	if validResult.Code != http.StatusOK || s.existingRoom("2") == nil || !validRoomName("a-B_c.9", s.maxRoomNameBytes) {
		t.Fatalf("browser-compatible room code was rejected: status %d", validResult.Code)
	}

	headerRoom := httptest.NewRequest(http.MethodGet, "/list", nil)
	headerRoom.Header.Set("X-Room", "not allowed/")
	headerResult := httptest.NewRecorder()
	s.handler().ServeHTTP(headerResult, headerRoom)
	if headerResult.Code != http.StatusBadRequest {
		t.Fatalf("invalid X-Room status = %d, want %d", headerResult.Code, http.StatusBadRequest)
	}
}

func TestPassiveRoomRoutesDoNotCreateRooms(t *testing.T) {
	s := newTestServer(t)
	routes := []struct {
		method string
		target string
		want   int
	}{
		{http.MethodGet, "/list?room=missing", http.StatusOK},
		{http.MethodGet, "/item?room=missing&id=nope", http.StatusNotFound},
		{http.MethodGet, "/blob?room=missing&id=nope", http.StatusNotFound},
		{http.MethodPost, "/pin?room=missing&id=nope", http.StatusNotFound},
		{http.MethodPost, "/clear?room=missing", http.StatusOK},
	}
	for _, route := range routes {
		req := httptest.NewRequest(route.method, route.target, nil)
		result := httptest.NewRecorder()
		s.handler().ServeHTTP(result, req)
		if result.Code != route.want {
			t.Fatalf("%s %s status = %d, want %d", route.method, route.target, result.Code, route.want)
		}
		if len(s.rooms) != 0 {
			t.Fatalf("%s %s created a room", route.method, route.target)
		}
	}
}

func TestEmptyRoomEventsAreLiveAndTransient(t *testing.T) {
	s := newTestServer(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	req := httptest.NewRequest(http.MethodGet, "/events?room=fresh-room", nil).WithContext(ctx)
	result := newSSEResponseWriter()
	done := make(chan struct{})
	go func() {
		s.handler().ServeHTTP(result, req)
		close(done)
	}()
	select {
	case <-result.wrote:
	case <-time.After(time.Second):
		t.Fatal("empty-room SSE snapshot was not written")
	}
	if result.status != http.StatusOK || !strings.Contains(result.BodyString(), `"kind":"snapshot"`) || !strings.Contains(result.BodyString(), `"items":[]`) {
		t.Fatalf("empty-room SSE response = status %d, body %q", result.status, result.BodyString())
	}
	if s.existingRoom("fresh-room") == nil {
		t.Fatal("empty-room SSE did not create a transient room")
	}
	cancel()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("empty-room SSE did not stop after cancellation")
	}
	if s.existingRoom("fresh-room") != nil {
		t.Fatal("empty-room SSE left a room after the listener closed")
	}
}

func TestRoomAndItemCaps(t *testing.T) {
	t.Run("room cap rejects a new creator before storing text", func(t *testing.T) {
		s := newTestServer(t)
		s.maxRooms = 1
		for _, roomName := range []string{"first", "second"} {
			req := httptest.NewRequest(http.MethodPost, "/push?room="+roomName, strings.NewReader(roomName))
			req.Header.Set("X-Kind", "text")
			result := httptest.NewRecorder()
			s.handler().ServeHTTP(result, req)
			if roomName == "first" && result.Code != http.StatusOK {
				t.Fatalf("first room status = %d", result.Code)
			}
			if roomName == "second" && result.Code != http.StatusTooManyRequests {
				t.Fatalf("second room status = %d, want %d", result.Code, http.StatusTooManyRequests)
			}
		}
		if len(s.rooms) != 1 || s.existingRoom("second") != nil {
			t.Fatal("room cap allowed a second room")
		}
	})

	t.Run("total and pinned caps preserve recent unpinned history", func(t *testing.T) {
		s := newTestServer(t)
		s.maxItemsPerRoom = 3
		s.maxUnpinnedItemsPerRoom = 2
		s.maxPinnedItemsPerRoom = 1
		push := func(text string) item {
			req := httptest.NewRequest(http.MethodPost, "/push?room=shared", strings.NewReader(text))
			req.Header.Set("X-Kind", "text")
			result := httptest.NewRecorder()
			s.handler().ServeHTTP(result, req)
			if result.Code != http.StatusOK {
				t.Fatalf("push %q status = %d, body = %s", text, result.Code, result.Body.String())
			}
			var stored item
			if err := json.NewDecoder(result.Body).Decode(&stored); err != nil {
				t.Fatal(err)
			}
			return stored
		}
		one := push("one")
		two := push("two")
		pin := httptest.NewRequest(http.MethodPost, "/pin?room=shared&id="+one.ID+"&pin=1", nil)
		pinResult := httptest.NewRecorder()
		s.handler().ServeHTTP(pinResult, pin)
		if pinResult.Code != http.StatusOK {
			t.Fatalf("pin status = %d", pinResult.Code)
		}
		three := push("three")
		_ = three
		push("four")

		items := s.existingRoom("shared").list()
		if len(items) != 3 {
			t.Fatalf("room item count = %d, want 3", len(items))
		}
		for _, stored := range items {
			if stored.ID == two.ID {
				t.Fatal("oldest unpinned item was not evicted")
			}
		}
		secondPin := httptest.NewRequest(http.MethodPost, "/pin?room=shared&id="+three.ID+"&pin=1", nil)
		secondPinResult := httptest.NewRecorder()
		s.handler().ServeHTTP(secondPinResult, secondPin)
		if secondPinResult.Code != http.StatusConflict {
			t.Fatalf("second pin status = %d, want %d", secondPinResult.Code, http.StatusConflict)
		}
		unpin := httptest.NewRequest(http.MethodPost, "/pin?room=shared&id="+one.ID+"&pin=0", nil)
		unpinResult := httptest.NewRecorder()
		s.handler().ServeHTTP(unpinResult, unpin)
		if unpinResult.Code != http.StatusConflict {
			t.Fatalf("unpin over unpinned cap status = %d, want %d", unpinResult.Code, http.StatusConflict)
		}
	})

	t.Run("a room full of pinned items rejects another item", func(t *testing.T) {
		s := newTestServer(t)
		s.maxItemsPerRoom = 1
		s.maxUnpinnedItemsPerRoom = 1
		s.maxPinnedItemsPerRoom = 1
		first := httptest.NewRequest(http.MethodPost, "/push?room=shared", strings.NewReader("one"))
		first.Header.Set("X-Kind", "text")
		firstResult := httptest.NewRecorder()
		s.handler().ServeHTTP(firstResult, first)
		var stored item
		if err := json.NewDecoder(firstResult.Body).Decode(&stored); err != nil {
			t.Fatal(err)
		}
		pin := httptest.NewRequest(http.MethodPost, "/pin?room=shared&id="+stored.ID+"&pin=1", nil)
		pinResult := httptest.NewRecorder()
		s.handler().ServeHTTP(pinResult, pin)
		if pinResult.Code != http.StatusOK {
			t.Fatalf("pin status = %d", pinResult.Code)
		}
		second := httptest.NewRequest(http.MethodPost, "/push?room=shared", strings.NewReader("two"))
		second.Header.Set("X-Kind", "text")
		secondResult := httptest.NewRecorder()
		s.handler().ServeHTTP(secondResult, second)
		if secondResult.Code != http.StatusConflict {
			t.Fatalf("push into pinned room status = %d, want %d", secondResult.Code, http.StatusConflict)
		}
	})
}

func TestWhitespaceTextAndClearRemoveEmptyRooms(t *testing.T) {
	s := newTestServer(t)
	for _, body := range []string{"", " \t\n"} {
		req := httptest.NewRequest(http.MethodPost, "/push?room=shared", strings.NewReader(body))
		req.Header.Set("X-Kind", "text")
		result := httptest.NewRecorder()
		s.handler().ServeHTTP(result, req)
		if result.Code != http.StatusBadRequest {
			t.Fatalf("whitespace text %q status = %d, want %d", body, result.Code, http.StatusBadRequest)
		}
	}
	if len(s.rooms) != 0 || atomic.LoadInt64(&totalBytes) != 0 {
		t.Fatalf("whitespace text changed room state: rooms=%d bytes=%d", len(s.rooms), atomic.LoadInt64(&totalBytes))
	}

	push := httptest.NewRequest(http.MethodPost, "/push?room=shared", strings.NewReader("keep briefly"))
	push.Header.Set("X-Kind", "text")
	pushResult := httptest.NewRecorder()
	s.handler().ServeHTTP(pushResult, push)
	if pushResult.Code != http.StatusOK {
		t.Fatalf("push status = %d", pushResult.Code)
	}
	clear := httptest.NewRequest(http.MethodPost, "/clear?room=shared", nil)
	clearResult := httptest.NewRecorder()
	s.handler().ServeHTTP(clearResult, clear)
	if clearResult.Code != http.StatusOK || s.existingRoom("shared") != nil {
		t.Fatalf("clear did not remove an inactive empty room: status=%d", clearResult.Code)
	}
}

func TestLoadEnforcesRoomStateBounds(t *testing.T) {
	s := newTestServer(t)
	s.maxRooms = 1
	s.maxItemsPerRoom = 1
	s.maxUnpinnedItemsPerRoom = 1
	s.maxPinnedItemsPerRoom = 1
	seed := map[string][]item{
		"bad/room": {{ID: "bad", Kind: "text", Text: "stale", Size: 5, From: "test", At: 1, Pinned: true}},
		"good": {
			{ID: "first", Kind: "text", Text: "keep", Size: 4, From: "test", At: 2, Pinned: true},
			{ID: "second", Kind: "text", Text: "drop", Size: 4, From: "test", At: 3, Pinned: true},
		},
		"other": {{ID: "other", Kind: "text", Text: "drop", Size: 4, From: "test", At: 4}},
	}
	b, err := json.Marshal(seed)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(s.persistPath(), b, 0600); err != nil {
		t.Fatal(err)
	}
	s.load()

	if len(s.rooms) != 1 || s.existingRoom("good") == nil || s.existingRoom("other") != nil {
		t.Fatalf("loaded rooms = %#v", s.rooms)
	}
	items := s.existingRoom("good").list()
	if len(items) != 1 || items[0].ID != "first" || atomic.LoadInt64(&totalBytes) != 4 {
		t.Fatalf("loaded items/bytes = %#v/%d", items, atomic.LoadInt64(&totalBytes))
	}
	invalid := httptest.NewRequest(http.MethodGet, "/list?room=bad%2Froom", nil)
	invalidResult := httptest.NewRecorder()
	s.handler().ServeHTTP(invalidResult, invalid)
	if invalidResult.Code != http.StatusBadRequest {
		t.Fatalf("legacy invalid room status = %d, want %d", invalidResult.Code, http.StatusBadRequest)
	}
	push := httptest.NewRequest(http.MethodPost, "/push?room=other", strings.NewReader("new"))
	push.Header.Set("X-Kind", "text")
	pushResult := httptest.NewRecorder()
	s.handler().ServeHTTP(pushResult, push)
	if pushResult.Code != http.StatusTooManyRequests {
		t.Fatalf("push after capped load status = %d, want %d", pushResult.Code, http.StatusTooManyRequests)
	}

	var persisted map[string][]item
	persistedBytes, err := os.ReadFile(s.persistPath())
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(persistedBytes, &persisted); err != nil {
		t.Fatal(err)
	}
	if len(persisted) != 1 || len(persisted["good"]) != 1 {
		t.Fatalf("persisted normalized state = %#v", persisted)
	}
}

func TestIndexPublishesConfiguredRoomLength(t *testing.T) {
	s := newTestServer(t)
	s.maxRoomNameBytes = 7
	result := httptest.NewRecorder()
	s.handler().ServeHTTP(result, httptest.NewRequest(http.MethodGet, "/", nil))
	body := result.Body.String()
	if result.Code != http.StatusOK || !strings.Contains(body, "<body data-theme=\"dark\">") || !strings.Contains(body, ">Clipsync</div>") || !strings.Contains(body, "class=\"topbar-leading\"") || !strings.Contains(body, "id=\"theme\"") || !strings.Contains(body, "window.CLIPSYNC_ROOM_LIMIT=7") || !strings.Contains(body, "window.CLIPSYNC_MAX_TEXT_BYTES=1048576") || !strings.Contains(body, "window.CLIPSYNC_MAX_FILE_BYTES=1048576") {
		t.Fatalf("index config response = status %d, body %q", result.Code, body)
	}
	if strings.Index(body, "class=\"topbar-leading\"") > strings.Index(body, "class=\"connection\"") {
		t.Fatalf("theme control must remain outside the connection controls")
	}
}

func TestLoadCleansDiscardedBlobsAndAccountsLegacyOrphans(t *testing.T) {
	t.Run("discarded valid-room blob is removed", func(t *testing.T) {
		s := newTestServer(t)
		s.maxItemsPerRoom = 1
		s.maxUnpinnedItemsPerRoom = 1
		seed := map[string][]item{
			"room": {
				{ID: "keep", Kind: "file", Mime: "application/octet-stream", Name: "keep.bin", Size: 1, At: 1},
				{ID: "drop", Kind: "file", Mime: "application/octet-stream", Name: "drop.bin", Size: 8, At: 2},
			},
		}
		b, err := json.Marshal(seed)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(s.persistPath(), b, 0600); err != nil {
			t.Fatal(err)
		}
		if err := os.MkdirAll(s.blobDir("room"), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(s.blobPath("room", "keep"), []byte("k"), 0600); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(s.blobPath("room", "drop"), []byte("dropdata"), 0600); err != nil {
			t.Fatal(err)
		}

		s.load()
		if _, err := os.Stat(s.blobPath("room", "drop")); !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("discarded blob stat error = %v, want not exist", err)
		}
		if got := atomic.LoadInt64(&totalBytes); got != 1 {
			t.Fatalf("accounted bytes = %d, want 1", got)
		}
	})

	t.Run("legacy invalid-room blob remains charged after metadata is normalized", func(t *testing.T) {
		s := newTestServer(t)
		s.maxDisk = 5
		seed := map[string][]item{
			"bad/room": {{ID: "stale", Kind: "file", Mime: "application/octet-stream", Name: "stale.bin", Size: 5, At: 1}},
		}
		b, err := json.Marshal(seed)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(s.persistPath(), b, 0600); err != nil {
			t.Fatal(err)
		}
		if err := os.MkdirAll(s.blobDir("bad/room"), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(s.blobPath("bad/room", "stale"), []byte("stale"), 0600); err != nil {
			t.Fatal(err)
		}
		s.load()

		s2 := newTestServer(t)
		s2.stateDir = s.stateDir
		s2.maxDisk = 5
		s2.load()
		push := httptest.NewRequest(http.MethodPost, "/push?room=valid", strings.NewReader("x"))
		push.Header.Set("X-Kind", "text")
		pushResult := httptest.NewRecorder()
		s2.handler().ServeHTTP(pushResult, push)
		if pushResult.Code != http.StatusInsufficientStorage {
			t.Fatalf("push after orphan scan status = %d, want %d", pushResult.Code, http.StatusInsufficientStorage)
		}
	})
}

func TestLoadNormalizesPersistedTextSize(t *testing.T) {
	s := newTestServer(t)
	s.maxDisk = 1 << 20
	s.maxTextSize = 2 << 20
	text := strings.Repeat("x", 1<<20)
	seed := map[string][]item{
		"room": {{ID: "text", Kind: "text", Text: text, Size: 0, From: "test", At: 1}},
	}
	b, err := json.Marshal(seed)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(s.persistPath(), b, 0600); err != nil {
		t.Fatal(err)
	}
	s.load()
	if got := atomic.LoadInt64(&totalBytes); got != int64(len(text)) {
		t.Fatalf("normalized text bytes = %d, want %d", got, len(text))
	}
	push := httptest.NewRequest(http.MethodPost, "/push?room=room", strings.NewReader("x"))
	push.Header.Set("X-Kind", "text")
	pushResult := httptest.NewRecorder()
	s.handler().ServeHTTP(pushResult, push)
	if pushResult.Code != http.StatusInsufficientStorage {
		t.Fatalf("push after text normalization status = %d, want %d", pushResult.Code, http.StatusInsufficientStorage)
	}
	var persisted map[string][]item
	persistedBytes, err := os.ReadFile(s.persistPath())
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(persistedBytes, &persisted); err != nil {
		t.Fatal(err)
	}
	if got := persisted["room"][0].Size; got != int64(len(text)) {
		t.Fatalf("persisted normalized text size = %d, want %d", got, len(text))
	}
	if persisted["room"][0].Text != "" || !persisted["room"][0].TextBlob {
		t.Fatalf("legacy large text was not migrated to a blob: %#v", persisted["room"][0])
	}
	if _, err := os.Stat(s.textBlobPath("room", "text")); err != nil {
		t.Fatalf("migrated text blob missing: %v", err)
	}
}

func TestLargeTextUsesBlobWithBoundedListAndFullItem(t *testing.T) {
	s := newTestServer(t)
	s.textInlineSize = 16
	text := "private-large-text-" + strings.Repeat("x", maxTextInList+128)
	push := httptest.NewRequest(http.MethodPost, "/push?room=room", strings.NewReader(text))
	push.Header.Set("X-Kind", "text")
	pushResult := httptest.NewRecorder()
	s.handler().ServeHTTP(pushResult, push)
	if pushResult.Code != http.StatusOK {
		t.Fatalf("large text push status = %d, body=%s", pushResult.Code, pushResult.Body.String())
	}
	var created item
	if err := json.NewDecoder(pushResult.Body).Decode(&created); err != nil {
		t.Fatal(err)
	}
	if !created.TextBlob || !created.Trunc || len(created.Text) != maxTextInList {
		t.Fatalf("push view = %#v", created)
	}
	raw := s.existingRoom("room").list()
	if len(raw) != 1 || !raw[0].TextBlob || raw[0].Text != "" {
		t.Fatalf("room retained raw large text: %#v", raw)
	}
	if _, err := os.Stat(s.textBlobPath("room", created.ID)); err != nil {
		t.Fatalf("large text blob stat: %v", err)
	}
	if got := atomic.LoadInt64(&totalBytes); got != int64(len(text)) {
		t.Fatalf("large text quota = %d, want %d", got, len(text))
	}

	persisted, err := os.ReadFile(s.persistPath())
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(persisted, []byte(text)) {
		t.Fatal("items.json contains the large text payload")
	}

	list := httptest.NewRequest(http.MethodGet, "/list?room=room", nil)
	listResult := httptest.NewRecorder()
	s.handler().ServeHTTP(listResult, list)
	var listed struct {
		Items []item `json:"items"`
	}
	if err := json.NewDecoder(listResult.Body).Decode(&listed); err != nil {
		t.Fatal(err)
	}
	if len(listed.Items) != 1 || listed.Items[0].Text != text[:maxTextInList] || !listed.Items[0].Trunc {
		t.Fatalf("large text list preview = %#v", listed.Items)
	}

	get := httptest.NewRequest(http.MethodGet, "/item?room=room&id="+created.ID, nil)
	getResult := httptest.NewRecorder()
	s.handler().ServeHTTP(getResult, get)
	var full item
	if err := json.NewDecoder(getResult.Body).Decode(&full); err != nil {
		t.Fatal(err)
	}
	if full.Text != text || full.TextBlob || full.Trunc {
		t.Fatalf("full large text item = %#v", full)
	}
}

func TestLargeTextBlobSSEPreviewAndLifecycleCleanup(t *testing.T) {
	s := newTestServer(t)
	s.textInlineSize = 8
	s.maxItemsPerRoom = 1
	s.maxUnpinnedItemsPerRoom = 1
	text := strings.Repeat("s", maxTextInList+64)
	push := httptest.NewRequest(http.MethodPost, "/push?room=room", strings.NewReader(text))
	push.Header.Set("X-Kind", "text")
	pushResult := httptest.NewRecorder()
	s.handler().ServeHTTP(pushResult, push)
	if pushResult.Code != http.StatusOK {
		t.Fatalf("large text push status = %d", pushResult.Code)
	}
	var stored item
	if err := json.NewDecoder(pushResult.Body).Decode(&stored); err != nil {
		t.Fatal(err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	events := httptest.NewRequest(http.MethodGet, "/events?room=room", nil).WithContext(ctx)
	eventsResult := newSSEResponseWriter()
	done := make(chan struct{})
	go func() {
		s.handler().ServeHTTP(eventsResult, events)
		close(done)
	}()
	select {
	case <-eventsResult.wrote:
	case <-time.After(time.Second):
		t.Fatal("SSE snapshot was not written")
	}
	cancel()
	<-done
	if body := eventsResult.BodyString(); !strings.Contains(body, `"trunc":true`) || !strings.Contains(body, text[:maxTextInList]) {
		t.Fatalf("SSE did not publish bounded text preview: %q", body)
	}

	replacement := httptest.NewRequest(http.MethodPost, "/push?room=room", strings.NewReader("small"))
	replacement.Header.Set("X-Kind", "text")
	replacementResult := httptest.NewRecorder()
	s.handler().ServeHTTP(replacementResult, replacement)
	if replacementResult.Code != http.StatusOK {
		t.Fatalf("replacement status = %d", replacementResult.Code)
	}
	if _, err := os.Stat(s.textBlobPath("room", stored.ID)); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("evicted text blob remained: %v", err)
	}
	if got := atomic.LoadInt64(&totalBytes); got != int64(len("small")) {
		t.Fatalf("quota after large-text eviction = %d", got)
	}

	clear := httptest.NewRequest(http.MethodPost, "/clear?room=room", nil)
	clearResult := httptest.NewRecorder()
	s.handler().ServeHTTP(clearResult, clear)
	if clearResult.Code != http.StatusOK || atomic.LoadInt64(&totalBytes) != 0 {
		t.Fatalf("clear status/quota = %d/%d", clearResult.Code, atomic.LoadInt64(&totalBytes))
	}
}

func TestLargeTextBlobRestartsAndDropsMissingOrCorruptStorage(t *testing.T) {
	t.Run("restart preserves full text", func(t *testing.T) {
		s := newTestServer(t)
		s.textInlineSize = 8
		text := strings.Repeat("r", 512)
		push := httptest.NewRequest(http.MethodPost, "/push?room=room", strings.NewReader(text))
		push.Header.Set("X-Kind", "text")
		pushResult := httptest.NewRecorder()
		s.handler().ServeHTTP(pushResult, push)
		var stored item
		if err := json.NewDecoder(pushResult.Body).Decode(&stored); err != nil {
			t.Fatal(err)
		}

		restarted := newTestServer(t)
		restarted.stateDir = s.stateDir
		restarted.textInlineSize = s.textInlineSize
		restarted.load()
		raw := restarted.existingRoom("room").list()
		if len(raw) != 1 || !raw[0].TextBlob || raw[0].Text != "" {
			t.Fatalf("restarted raw text item = %#v", raw)
		}
		get := httptest.NewRequest(http.MethodGet, "/item?room=room&id="+stored.ID, nil)
		getResult := httptest.NewRecorder()
		restarted.handler().ServeHTTP(getResult, get)
		var full item
		if err := json.NewDecoder(getResult.Body).Decode(&full); err != nil {
			t.Fatal(err)
		}
		if full.Text != text {
			t.Fatalf("restarted full text = %q", full.Text)
		}
	})

	for _, tc := range []struct {
		name         string
		blob         []byte
		size         int64
		wantRetained bool
	}{
		{name: "missing blob", size: 5},
		{name: "size mismatch is repaired", blob: []byte("wrong"), size: 6, wantRetained: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s := newTestServer(t)
			seed := map[string][]item{"room": {{ID: "lost", Kind: "text", TextBlob: true, Size: tc.size, At: 1}}}
			data, err := json.Marshal(seed)
			if err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(s.persistPath(), data, 0600); err != nil {
				t.Fatal(err)
			}
			if tc.blob != nil {
				if err := os.MkdirAll(s.blobDir("room"), 0700); err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(s.textBlobPath("room", "lost"), tc.blob, 0600); err != nil {
					t.Fatal(err)
				}
			}
			s.load()
			if tc.wantRetained {
				raw := s.existingRoom("room").list()
				if len(raw) != 1 || raw[0].Size != int64(len(tc.blob)) || atomic.LoadInt64(&totalBytes) != int64(len(tc.blob)) {
					t.Fatalf("text blob metadata was not repaired: items=%#v bytes=%d", raw, atomic.LoadInt64(&totalBytes))
				}
				return
			}
			if s.existingRoom("room") != nil || atomic.LoadInt64(&totalBytes) != 0 {
				t.Fatalf("missing text blob was retained: rooms=%#v bytes=%d", s.rooms, atomic.LoadInt64(&totalBytes))
			}
		})
	}
}

func TestTextBlobRecoveryCleansMetadataAndOrphans(t *testing.T) {
	t.Run("legacy text blob metadata is rewritten without the payload", func(t *testing.T) {
		s := newTestServer(t)
		text := strings.Repeat("legacy-secret-", 64)
		seed := map[string][]item{
			"room": {{ID: "legacy", Kind: "text", TextBlob: true, Text: text, Size: int64(len(text)), At: 1}},
		}
		data, err := json.Marshal(seed)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(s.persistPath(), data, 0600); err != nil {
			t.Fatal(err)
		}
		if err := os.MkdirAll(s.blobDir("room"), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(s.textBlobPath("room", "legacy"), []byte(text), 0600); err != nil {
			t.Fatal(err)
		}

		s.load()
		persisted, err := os.ReadFile(s.persistPath())
		if err != nil {
			t.Fatal(err)
		}
		if bytes.Contains(persisted, []byte(text)) {
			t.Fatal("recovered metadata retained legacy text payload")
		}
	})

	t.Run("migrated legacy text discarded by room cap is removed", func(t *testing.T) {
		s := newTestServer(t)
		s.textInlineSize = 8
		s.maxItemsPerRoom = 1
		s.maxUnpinnedItemsPerRoom = 1
		large := strings.Repeat("m", 128)
		seed := map[string][]item{
			"room": {
				{ID: "keep", Kind: "text", Text: "small", Size: 5, At: 1},
				{ID: "drop", Kind: "text", Text: large, Size: int64(len(large)), At: 2},
			},
		}
		data, err := json.Marshal(seed)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(s.persistPath(), data, 0600); err != nil {
			t.Fatal(err)
		}

		s.load()
		if _, err := os.Stat(s.textBlobPath("room", "drop")); !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("discarded migrated text blob remained: %v", err)
		}
		if got := atomic.LoadInt64(&totalBytes); got != 5 {
			t.Fatalf("discarded migrated text remained charged: %d", got)
		}
	})

	t.Run("failed first persist leaves no text blob after restart", func(t *testing.T) {
		s := newTestServer(t)
		s.textInlineSize = 8
		s.persistOps.createTemp = func(string, string) (*os.File, error) {
			return nil, errors.New("injected create failure")
		}
		text := strings.Repeat("orphan", 32)
		push := httptest.NewRequest(http.MethodPost, "/push?room=room", strings.NewReader(text))
		push.Header.Set("X-Kind", "text")
		pushResult := httptest.NewRecorder()
		s.handler().ServeHTTP(pushResult, push)
		if pushResult.Code != http.StatusServiceUnavailable {
			t.Fatalf("failed persist status = %d", pushResult.Code)
		}
		entries, err := os.ReadDir(s.blobDir("room"))
		if err != nil || len(entries) != 1 {
			t.Fatalf("expected one pending text blob, entries=%#v err=%v", entries, err)
		}

		restarted := newTestServer(t)
		restarted.stateDir = s.stateDir
		restarted.textInlineSize = s.textInlineSize
		restarted.load()
		entries, err = os.ReadDir(restarted.blobDir("room"))
		if err != nil && !errors.Is(err, os.ErrNotExist) {
			t.Fatal(err)
		}
		if len(entries) != 0 || atomic.LoadInt64(&totalBytes) != 0 {
			t.Fatalf("orphan text blob survived restart: entries=%#v bytes=%d", entries, atomic.LoadInt64(&totalBytes))
		}
	})
}

func TestPersistenceRecoversCorruptPrimaryFromBackup(t *testing.T) {
	s := newTestServer(t)
	mustAddToRoom(t, s, "room", testItem("first", "first"))
	if err := s.save(); err != nil {
		t.Fatal(err)
	}
	mustAddToRoom(t, s, "room", testItem("second", "second"))
	if err := s.save(); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(s.persistPath(), []byte("not-json"), 0600); err != nil {
		t.Fatal(err)
	}

	restarted := newTestServer(t)
	restarted.stateDir = s.stateDir
	restarted.load()
	items := restarted.existingRoom("room").list()
	if len(items) != 2 || items[0].ID != "first" || items[1].ID != "second" {
		t.Fatalf("recovered items = %#v, want the newest complete backup snapshot", items)
	}
	primary, err := os.ReadFile(restarted.persistPath())
	if err != nil {
		t.Fatal(err)
	}
	persisted, err := decodeSnapshot(primary)
	if err != nil {
		t.Fatal(err)
	}
	if len(persisted["room"]) != 2 || persisted["room"][0].ID != "first" || persisted["room"][1].ID != "second" {
		t.Fatalf("recovered primary = %#v", persisted)
	}
}

func TestPersistenceSerializesConcurrentSnapshotsAndRestart(t *testing.T) {
	s := newTestServer(t)
	const writers = 24
	var wg sync.WaitGroup
	errs := make(chan error, writers)
	for i := 0; i < writers; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			it := testItem(strconv.Itoa(i), "x")
			if !s.reserve(it.Size) {
				errs <- errors.New("reserve failed")
				return
			}
			if _, err := s.addToRoom("room", it); err != nil {
				errs <- err
				return
			}
			if err := s.save(); err != nil {
				errs <- err
			}
		}(i)
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		t.Error(err)
	}
	if t.Failed() {
		return
	}

	if err := s.save(); err != nil {
		t.Fatal(err)
	}
	restarted := newTestServer(t)
	restarted.stateDir = s.stateDir
	restarted.load()
	items := restarted.existingRoom("room").list()
	if len(items) != writers {
		t.Fatalf("restarted items = %d, want %d", len(items), writers)
	}
}

func TestPersistenceRenameFailureLeavesPrimaryAndBackupUsable(t *testing.T) {
	s := newTestServer(t)
	mustAddToRoom(t, s, "room", testItem("first", "first"))
	if err := s.save(); err != nil {
		t.Fatal(err)
	}
	primaryBefore, err := os.ReadFile(s.persistPath())
	if err != nil {
		t.Fatal(err)
	}
	mustAddToRoom(t, s, "room", testItem("second", "second"))
	originalRename := os.Rename
	s.persistOps.rename = func(oldPath, newPath string) error {
		if newPath == s.persistPath() {
			return errors.New("injected rename failure")
		}
		return originalRename(oldPath, newPath)
	}
	if err := s.save(); err == nil {
		t.Fatal("save succeeded with injected primary rename failure")
	}
	primaryAfter, err := os.ReadFile(s.persistPath())
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(primaryBefore, primaryAfter) {
		t.Fatal("primary changed despite failed rename")
	}
	backup, err := os.ReadFile(s.persistBackupPath())
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(backup, primaryBefore) {
		t.Fatal("backup does not retain the prior valid snapshot")
	}
}

func TestPersistenceWriteFailureLeavesPrimaryAndBackupUsable(t *testing.T) {
	s := newTestServer(t)
	mustAddToRoom(t, s, "room", testItem("first", "first"))
	if err := s.save(); err != nil {
		t.Fatal(err)
	}
	primaryBefore, err := os.ReadFile(s.persistPath())
	if err != nil {
		t.Fatal(err)
	}
	mustAddToRoom(t, s, "room", testItem("second", "second"))
	s.persistOps.write = func(*os.File, []byte) (int, error) {
		return 0, errors.New("injected write failure")
	}
	if err := s.save(); err == nil {
		t.Fatal("save succeeded with injected write failure")
	}
	primaryAfter, err := os.ReadFile(s.persistPath())
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(primaryBefore, primaryAfter) {
		t.Fatal("primary changed despite failed write")
	}
	backup, err := os.ReadFile(s.persistBackupPath())
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(backup, primaryBefore) {
		t.Fatal("backup does not retain the prior valid snapshot")
	}
}

func TestPushReportsPersistenceFailureWithoutLosingCoherentMemoryState(t *testing.T) {
	s := newTestServer(t)
	s.persistOps.createTemp = func(string, string) (*os.File, error) {
		return nil, errors.New("injected create failure")
	}
	req := httptest.NewRequest(http.MethodPost, "/push?room=room", strings.NewReader("accepted in memory"))
	req.Header.Set("X-Kind", "text")
	result := httptest.NewRecorder()
	s.handler().ServeHTTP(result, req)
	if result.Code != http.StatusServiceUnavailable {
		t.Fatalf("push status = %d, want %d", result.Code, http.StatusServiceUnavailable)
	}
	if result.Header().Get("X-Clipsync-Persistence") != "failed" {
		t.Fatalf("persistence status header = %q", result.Header().Get("X-Clipsync-Persistence"))
	}
	items := s.existingRoom("room").list()
	if len(items) != 1 || items[0].Text != "accepted in memory" {
		t.Fatalf("in-memory mutation was not retained: %#v", items)
	}
}

func TestClearPersistenceFailureKeepsPriorBlobSnapshotRestartable(t *testing.T) {
	s := newTestServer(t)
	id := nextID()
	size, err := s.writeBlob("room", id, bytes.NewReader([]byte("keep on disk")), 64)
	if err != nil {
		t.Fatal(err)
	}
	mustAddToRoom(t, s, "room", item{ID: id, Kind: "file", Mime: "application/octet-stream", Name: "keep.bin", Size: size, At: 1})
	if err := s.save(); err != nil {
		t.Fatal(err)
	}
	s.persistOps.createTemp = func(string, string) (*os.File, error) {
		return nil, errors.New("injected create failure")
	}
	clear := httptest.NewRequest(http.MethodPost, "/clear?room=room", nil)
	result := httptest.NewRecorder()
	s.handler().ServeHTTP(result, clear)
	if result.Code != http.StatusServiceUnavailable {
		t.Fatalf("clear status = %d, want %d", result.Code, http.StatusServiceUnavailable)
	}
	if _, err := os.Stat(s.blobPath("room", id)); err != nil {
		t.Fatalf("clear deleted blob before metadata save: %v", err)
	}

	restarted := newTestServer(t)
	restarted.stateDir = s.stateDir
	restarted.load()
	items := restarted.existingRoom("room").list()
	if len(items) != 1 || items[0].ID != id {
		t.Fatalf("restart after failed clear items = %#v", items)
	}
}

func TestEvictionCleanupWaitsForDurableSnapshot(t *testing.T) {
	s := newTestServer(t)
	s.maxItemsPerRoom = 1
	s.maxUnpinnedItemsPerRoom = 1
	id := nextID()
	size, err := s.writeBlob("room", id, bytes.NewReader([]byte("old file")), 64)
	if err != nil {
		t.Fatal(err)
	}
	mustAddToRoom(t, s, "room", item{ID: id, Kind: "file", Mime: "application/octet-stream", Name: "old.bin", Size: size, At: 1})
	if err := s.save(); err != nil {
		t.Fatal(err)
	}
	s.persistOps.createTemp = func(string, string) (*os.File, error) {
		return nil, errors.New("injected create failure")
	}
	push := httptest.NewRequest(http.MethodPost, "/push?room=room", strings.NewReader("new text"))
	push.Header.Set("X-Kind", "text")
	failed := httptest.NewRecorder()
	s.handler().ServeHTTP(failed, push)
	if failed.Code != http.StatusServiceUnavailable {
		t.Fatalf("evicting push status = %d, want %d", failed.Code, http.StatusServiceUnavailable)
	}
	if _, err := os.Stat(s.blobPath("room", id)); err != nil {
		t.Fatalf("eviction deleted blob before metadata save: %v", err)
	}

	restarted := newTestServer(t)
	restarted.stateDir = s.stateDir
	restarted.load()
	items := restarted.existingRoom("room").list()
	if len(items) != 1 || items[0].ID != id {
		t.Fatalf("restart after failed eviction items = %#v", items)
	}

	s.persistOps = persistenceOps{}
	s.maxItemsPerRoom = 2
	s.maxUnpinnedItemsPerRoom = 2
	commit := httptest.NewRequest(http.MethodPost, "/push?room=room", strings.NewReader("commit cleanup"))
	commit.Header.Set("X-Kind", "text")
	committed := httptest.NewRecorder()
	s.handler().ServeHTTP(committed, commit)
	if committed.Code != http.StatusOK {
		t.Fatalf("follow-up push status = %d, body=%s", committed.Code, committed.Body.String())
	}
	if _, err := os.Stat(s.blobPath("room", id)); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("old blob remained after later durable snapshot: %v", err)
	}
}

func TestBackupRemainsCoherentAfterSuccessfulClearAndPrimaryCorruption(t *testing.T) {
	s := newTestServer(t)
	id := nextID()
	size, err := s.writeBlob("room", id, bytes.NewReader([]byte("clear safely")), 64)
	if err != nil {
		t.Fatal(err)
	}
	mustAddToRoom(t, s, "room", item{ID: id, Kind: "file", Mime: "application/octet-stream", Name: "clear.bin", Size: size, At: 1})
	if err := s.save(); err != nil {
		t.Fatal(err)
	}
	clear := httptest.NewRequest(http.MethodPost, "/clear?room=room", nil)
	result := httptest.NewRecorder()
	s.handler().ServeHTTP(result, clear)
	if result.Code != http.StatusOK {
		t.Fatalf("clear status = %d, body=%s", result.Code, result.Body.String())
	}
	if err := os.WriteFile(s.persistPath(), []byte("not-json"), 0600); err != nil {
		t.Fatal(err)
	}

	restarted := newTestServer(t)
	restarted.stateDir = s.stateDir
	restarted.load()
	if r := restarted.existingRoom("room"); r != nil && len(r.list()) != 0 {
		t.Fatalf("backup resurrected deleted metadata: %#v", r.list())
	}
	backup, err := os.ReadFile(restarted.persistBackupPath())
	if err != nil {
		t.Fatal(err)
	}
	persisted, err := decodeSnapshot(backup)
	if err != nil {
		t.Fatal(err)
	}
	if len(persisted) != 0 {
		t.Fatalf("backup after clear = %#v, want empty snapshot", persisted)
	}
}

func TestBackupRemainsCoherentAfterSuccessfulEvictionAndPrimaryCorruption(t *testing.T) {
	s := newTestServer(t)
	s.maxItemsPerRoom = 1
	s.maxUnpinnedItemsPerRoom = 1
	id := nextID()
	size, err := s.writeBlob("room", id, bytes.NewReader([]byte("evict safely")), 64)
	if err != nil {
		t.Fatal(err)
	}
	mustAddToRoom(t, s, "room", item{ID: id, Kind: "file", Mime: "application/octet-stream", Name: "evict.bin", Size: size, At: 1})
	if err := s.save(); err != nil {
		t.Fatal(err)
	}
	push := httptest.NewRequest(http.MethodPost, "/push?room=room", strings.NewReader("replacement"))
	push.Header.Set("X-Kind", "text")
	result := httptest.NewRecorder()
	s.handler().ServeHTTP(result, push)
	if result.Code != http.StatusOK {
		t.Fatalf("evicting push status = %d, body=%s", result.Code, result.Body.String())
	}
	if err := os.WriteFile(s.persistPath(), []byte("not-json"), 0600); err != nil {
		t.Fatal(err)
	}

	restarted := newTestServer(t)
	restarted.stateDir = s.stateDir
	restarted.load()
	items := restarted.existingRoom("room").list()
	if len(items) != 1 || items[0].Kind != "text" || items[0].Text != "replacement" {
		t.Fatalf("backup after eviction items = %#v", items)
	}
}
