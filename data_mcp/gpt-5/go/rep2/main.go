package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"golang.org/x/crypto/bcrypt"
)

type User struct {
	ID       int    `json:"id"`
	Username string `json:"username"`
}

type userRecord struct {
	User
	PasswordHash []byte
}

type Todo struct {
	ID          int    `json:"id"`
	Title       string `json:"title"`
	Description string `json:"description"`
	Completed   bool   `json:"completed"`
	CreatedAt   string `json:"created_at"`
	UpdatedAt   string `json:"updated_at"`
}

type server struct {
	mu sync.RWMutex

	// users by id
	users map[int]*userRecord
	// username -> id
	usernameIndex map[string]int
	// next user id
	nextUserID int

	// todos by id
	todos map[int]*Todo
	// todo ownership: todo id -> user id
	todoOwner map[int]int
	nextTodoID int

	// sessions token -> user id
	sessions map[string]int
}

func newServer() *server {
	return &server{
		users:         make(map[int]*userRecord),
		usernameIndex: make(map[string]int),
		nextUserID:    1,
		todos:         make(map[int]*Todo),
		todoOwner:     make(map[int]int),
		nextTodoID:    1,
		sessions:      make(map[string]int),
	}
}

func (s *server) nowTS() string {
	// UTC with second precision
	return time.Now().UTC().Format("2006-01-02T15:04:05Z")
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if v == nil {
		return
	}
	enc := json.NewEncoder(w)
	enc.SetEscapeHTML(false)
	_ = enc.Encode(v)
}

func writeError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}

func parseJSON(r *http.Request, dst any) error {
	defer r.Body.Close()
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(dst); err != nil {
		return err
	}
	// ensure no trailing data
	if _, err := dec.Token(); err != io.EOF {
		if err == nil {
			return errors.New("invalid JSON: extra data")
		}
		return err
	}
	return nil
}

func (s *server) generateToken() (string, error) {
	b := make([]byte, 16) // 128-bit
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

func (s *server) getAuthUserID(r *http.Request) (int, bool) {
	cookie, err := r.Cookie("session_id")
	if err != nil || cookie.Value == "" {
		return 0, false
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	uid, ok := s.sessions[cookie.Value]
	return uid, ok
}

func (s *server) requireAuth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if uid, ok := s.getAuthUserID(r); ok {
			// attach uid to context using request headers map to avoid context types
			r = r.Clone(r.Context())
			r.Header.Set("X-Auth-UserID", strconv.Itoa(uid))
			next(w, r)
			return
		}
		writeError(w, http.StatusUnauthorized, "Authentication required")
	}
}

func (s *server) handleRegister(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusNotFound, "Not found")
		return
	}
	var req struct {
		Username string `json:"username"`
		Password string `json:"password"`
	}
	if err := parseJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "Invalid JSON")
		return
	}
	uname := strings.TrimSpace(req.Username)
	if !regexp.MustCompile(`^[a-zA-Z0-9_]{3,50}$`).MatchString(uname) {
		writeError(w, http.StatusBadRequest, "Invalid username")
		return
	}
	if len(req.Password) < 8 {
		writeError(w, http.StatusBadRequest, "Password too short")
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, exists := s.usernameIndex[uname]; exists {
		writeError(w, http.StatusConflict, "Username already exists")
		return
	}
	hash, err := bcrypt.GenerateFromPassword([]byte(req.Password), bcrypt.DefaultCost)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "Internal error")
		return
	}
	id := s.nextUserID
	s.nextUserID++
	rec := &userRecord{User: User{ID: id, Username: uname}, PasswordHash: hash}
	s.users[id] = rec
	s.usernameIndex[uname] = id
	writeJSON(w, http.StatusCreated, rec.User)
}

func (s *server) handleLogin(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusNotFound, "Not found")
		return
	}
	var req struct {
		Username string `json:"username"`
		Password string `json:"password"`
	}
	if err := parseJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "Invalid JSON")
		return
	}
	s.mu.RLock()
	uid, ok := s.usernameIndex[req.Username]
	var rec *userRecord
	if ok {
		rec = s.users[uid]
	}
	s.mu.RUnlock()
	if !ok || bcrypt.CompareHashAndPassword(rec.PasswordHash, []byte(req.Password)) != nil {
		writeError(w, http.StatusUnauthorized, "Invalid credentials")
		return
	}
	token, err := s.generateToken()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "Internal error")
		return
	}
	s.mu.Lock()
	s.sessions[token] = uid
	s.mu.Unlock()
	http.SetCookie(w, &http.Cookie{Name: "session_id", Value: token, Path: "/", HttpOnly: true})
	writeJSON(w, http.StatusOK, rec.User)
}

func (s *server) handleLogout(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusNotFound, "Not found")
		return
	}
	cookie, err := r.Cookie("session_id")
	if err != nil {
		writeError(w, http.StatusUnauthorized, "Authentication required")
		return
	}
	s.mu.Lock()
	delete(s.sessions, cookie.Value)
	s.mu.Unlock()
	writeJSON(w, http.StatusOK, map[string]any{})
}

func (s *server) currentUser(r *http.Request) (User, bool) {
	uidStr := r.Header.Get("X-Auth-UserID")
	uid, _ := strconv.Atoi(uidStr)
	if uid == 0 {
		return User{}, false
	}
	s.mu.RLock()
	rec, ok := s.users[uid]
	s.mu.RUnlock()
	if !ok {
		return User{}, false
	}
	return rec.User, true
}

func (s *server) handleMe(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusNotFound, "Not found")
		return
	}
	user, ok := s.currentUser(r)
	if !ok {
		writeError(w, http.StatusUnauthorized, "Authentication required")
		return
	}
	writeJSON(w, http.StatusOK, user)
}

func (s *server) handlePassword(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPut {
		writeError(w, http.StatusNotFound, "Not found")
		return
	}
	user, ok := s.currentUser(r)
	if !ok {
		writeError(w, http.StatusUnauthorized, "Authentication required")
		return
	}
	var req struct {
		Old string `json:"old_password"`
		New string `json:"new_password"`
	}
	if err := parseJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "Invalid JSON")
		return
	}
	s.mu.RLock()
	rec := s.users[user.ID]
	s.mu.RUnlock()
	if bcrypt.CompareHashAndPassword(rec.PasswordHash, []byte(req.Old)) != nil {
		writeError(w, http.StatusUnauthorized, "Invalid credentials")
		return
	}
	if len(req.New) < 8 {
		writeError(w, http.StatusBadRequest, "Password too short")
		return
	}
	hash, err := bcrypt.GenerateFromPassword([]byte(req.New), bcrypt.DefaultCost)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "Internal error")
		return
	}
	s.mu.Lock()
	rec.PasswordHash = hash
	s.mu.Unlock()
	writeJSON(w, http.StatusOK, map[string]any{})
}

func (s *server) handleTodos(w http.ResponseWriter, r *http.Request) {
	user, ok := s.currentUser(r)
	if !ok {
		writeError(w, http.StatusUnauthorized, "Authentication required")
		return
	}
	switch r.Method {
	case http.MethodGet:
		// list
		s.mu.RLock()
		list := make([]*Todo, 0)
		for id, t := range s.todos {
			if s.todoOwner[id] == user.ID {
				copy := *t
				list = append(list, &copy)
			}
		}
		s.mu.RUnlock()
		sort.Slice(list, func(i, j int) bool { return list[i].ID < list[j].ID })
		writeJSON(w, http.StatusOK, list)
	case http.MethodPost:
		var req struct {
			Title       string `json:"title"`
			Description string `json:"description"`
		}
		if err := parseJSON(r, &req); err != nil {
			writeError(w, http.StatusBadRequest, "Invalid JSON")
			return
		}
		title := strings.TrimSpace(req.Title)
		if title == "" {
			writeError(w, http.StatusBadRequest, "Title is required")
			return
		}
		desc := req.Description
		if desc == "" {
			desc = ""
		}
		now := s.nowTS()
		s.mu.Lock()
		id := s.nextTodoID
		s.nextTodoID++
		t := &Todo{ID: id, Title: title, Description: desc, Completed: false, CreatedAt: now, UpdatedAt: now}
		s.todos[id] = t
		s.todoOwner[id] = user.ID
		s.mu.Unlock()
		writeJSON(w, http.StatusCreated, t)
	default:
		writeError(w, http.StatusNotFound, "Not found")
	}
}

func parseTodoID(path string) (int, bool) {
	// expect /todos/:id exactly
	parts := strings.Split(strings.Trim(path, "/"), "/")
	if len(parts) != 2 || parts[0] != "todos" {
		return 0, false
	}
	id, err := strconv.Atoi(parts[1])
	if err != nil || id <= 0 {
		return 0, false
	}
	return id, true
}

func (s *server) handleTodoByID(w http.ResponseWriter, r *http.Request) {
	user, ok := s.currentUser(r)
	if !ok {
		writeError(w, http.StatusUnauthorized, "Authentication required")
		return
	}
	id, ok := parseTodoID(r.URL.Path)
	if !ok {
		writeError(w, http.StatusNotFound, "Not found")
		return
	}
	s.mu.RLock()
	t, exists := s.todos[id]
	owner := s.todoOwner[id]
	s.mu.RUnlock()
	if !exists || owner != user.ID {
		writeError(w, http.StatusNotFound, "Todo not found")
		return
	}
	switch r.Method {
	case http.MethodGet:
		writeJSON(w, http.StatusOK, t)
	case http.MethodPut:
		var req struct {
			Title       *string `json:"title"`
			Description *string `json:"description"`
			Completed   *bool   `json:"completed"`
		}
		if err := parseJSON(r, &req); err != nil {
			writeError(w, http.StatusBadRequest, "Invalid JSON")
			return
		}
		s.mu.Lock()
		defer s.mu.Unlock()
		// re-fetch to ensure current and owner check again
		t2, exists2 := s.todos[id]
		if !exists2 || s.todoOwner[id] != user.ID {
			writeError(w, http.StatusNotFound, "Todo not found")
			return
		}
		if req.Title != nil {
			title := strings.TrimSpace(*req.Title)
			if title == "" {
				writeError(w, http.StatusBadRequest, "Title is required")
				return
			}
			t2.Title = title
		}
		if req.Description != nil {
			t2.Description = *req.Description
		}
		if req.Completed != nil {
			t2.Completed = *req.Completed
		}
		t2.UpdatedAt = s.nowTS()
		writeJSON(w, http.StatusOK, t2)
	case http.MethodDelete:
		s.mu.Lock()
		defer s.mu.Unlock()
		// verify still exists and owner
		if _, ok := s.todos[id]; !ok || s.todoOwner[id] != user.ID {
			writeError(w, http.StatusNotFound, "Todo not found")
			return
		}
		delete(s.todos, id)
		delete(s.todoOwner, id)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusNoContent)
	default:
		writeError(w, http.StatusNotFound, "Not found")
	}
}

func (s *server) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/register", s.handleRegister)
	mux.HandleFunc("/login", s.handleLogin)
	mux.HandleFunc("/logout", s.requireAuth(s.handleLogout))
	mux.HandleFunc("/me", s.requireAuth(s.handleMe))
	mux.HandleFunc("/password", s.requireAuth(s.handlePassword))
	mux.HandleFunc("/todos", s.requireAuth(s.handleTodos))
	mux.HandleFunc("/todos/", s.requireAuth(s.handleTodoByID))
	// any other path
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		writeError(w, http.StatusNotFound, "Not found")
	})
	return contentTypeJSONMiddleware(mux)
}

func contentTypeJSONMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Ensure all non-DELETE responses have application/json
		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(rec, r)
		if r.Method != http.MethodDelete {
			if ct := w.Header().Get("Content-Type"); ct == "" {
				w.Header().Set("Content-Type", "application/json")
			}
		}
	})
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (s *statusRecorder) WriteHeader(code int) {
	s.status = code
	s.ResponseWriter.WriteHeader(code)
}

func main() {
	port := flag.Int("port", 8080, "port to listen on")
	flag.Parse()

	s := newServer()

	addr := fmt.Sprintf("0.0.0.0:%d", *port)
	server := &http.Server{
		Addr:              addr,
		Handler:           s.routes(),
		ReadHeaderTimeout: 5 * time.Second,
	}
	log.Printf("Listening on %s", addr)
	if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatalf("server error: %v", err)
	}
}
