package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log"
	"net/http"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Data types

type User struct {
	ID       int    `json:"id"`
	Username string `json:"username"`
	// store plaintext for simplicity per spec; in real world, hash passwords
	Password string `json:"-"`
}

type Todo struct {
	ID          int    `json:"id"`
	Title       string `json:"title"`
	Description string `json:"description"`
	Completed   bool   `json:"completed"`
	CreatedAt   string `json:"created_at"`
	UpdatedAt   string `json:"updated_at"`
	OwnerUserID int    `json:"-"`
}

type Server struct {
	usersByID       map[int]*User
	usersByUsername map[string]*User
	userMu          sync.RWMutex
	nextUserID      int

	sessions map[string]int // token -> userID
	sessMu   sync.RWMutex

	todosByID  map[int]*Todo
	todoMu     sync.RWMutex
	nextTodoID int
}

func NewServer() *Server {
	return &Server{
		usersByID:       make(map[int]*User),
		usersByUsername: make(map[string]*User),
		nextUserID:      1,
		sessions:        make(map[string]int),
		todosByID:       make(map[int]*Todo),
		nextTodoID:      1,
	}
}

// Helpers

func nowISO8601UTC() string {
	return time.Now().UTC().Format(time.RFC3339)
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if v == nil {
		return
	}
	enc := json.NewEncoder(w)
	enc.SetEscapeHTML(true)
	_ = enc.Encode(v)
}

func writeError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}

func (s *Server) getAuthUser(r *http.Request) (*User, error) {
	cookie, err := r.Cookie("session_id")
	if err != nil || cookie.Value == "" {
		return nil, errors.New("auth")
	}
	s.sessMu.RLock()
	uid, ok := s.sessions[cookie.Value]
	s.sessMu.RUnlock()
	if !ok {
		return nil, errors.New("auth")
	}
	s.userMu.RLock()
	u := s.usersByID[uid]
	s.userMu.RUnlock()
	if u == nil {
		return nil, errors.New("auth")
	}
	return u, nil
}

func (s *Server) requireAuth(next func(http.ResponseWriter, *http.Request, *User)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		u, err := s.getAuthUser(r)
		if err != nil {
			writeError(w, http.StatusUnauthorized, "Authentication required")
			return
		}
		next(w, r, u)
	}
}

func generateToken(n int) (string, error) {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

// Handlers

type credentials struct {
	Username string `json:"username"`
	Password string `json:"password"`
}

type changePasswordReq struct {
	OldPassword string `json:"old_password"`
	NewPassword string `json:"new_password"`
}

func (s *Server) handleRegister(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "Method not allowed")
		return
	}
	var c credentials
	if err := json.NewDecoder(r.Body).Decode(&c); err != nil {
		writeError(w, http.StatusBadRequest, "Invalid JSON")
		return
	}
	username := strings.TrimSpace(c.Username)
	password := c.Password
	// Validate username
	if len(username) < 3 || len(username) > 50 {
		writeError(w, http.StatusBadRequest, "Invalid username")
		return
	}
	validRe := regexp.MustCompile(`^[a-zA-Z0-9_]+$`)
	if !validRe.MatchString(username) {
		writeError(w, http.StatusBadRequest, "Invalid username")
		return
	}
	if len(password) < 8 {
		writeError(w, http.StatusBadRequest, "Password too short")
		return
	}
	// Uniqueness
	s.userMu.Lock()
	defer s.userMu.Unlock()
	if _, exists := s.usersByUsername[username]; exists {
		writeError(w, http.StatusConflict, "Username already exists")
		return
	}
	id := s.nextUserID
	s.nextUserID++
	u := &User{ID: id, Username: username, Password: password}
	s.usersByID[id] = u
	s.usersByUsername[username] = u
	writeJSON(w, http.StatusCreated, map[string]any{
		"id":       u.ID,
		"username": u.Username,
	})
}

func (s *Server) handleLogin(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "Method not allowed")
		return
	}
	var c credentials
	if err := json.NewDecoder(r.Body).Decode(&c); err != nil {
		writeError(w, http.StatusBadRequest, "Invalid JSON")
		return
	}
	s.userMu.RLock()
	u, ok := s.usersByUsername[c.Username]
	s.userMu.RUnlock()
	if !ok || u.Password != c.Password {
		writeError(w, http.StatusUnauthorized, "Invalid credentials")
		return
	}
	token, err := generateToken(16)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "Internal server error")
		return
	}
	s.sessMu.Lock()
	s.sessions[token] = u.ID
	s.sessMu.Unlock()
	http.SetCookie(w, &http.Cookie{
		Name:     "session_id",
		Value:    token,
		Path:     "/",
		HttpOnly: true,
	})
	writeJSON(w, http.StatusOK, map[string]any{
		"id":       u.ID,
		"username": u.Username,
	})
}

func (s *Server) handleLogout(w http.ResponseWriter, r *http.Request, u *User) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "Method not allowed")
		return
	}
	cookie, err := r.Cookie("session_id")
	if err == nil {
		s.sessMu.Lock()
		delete(s.sessions, cookie.Value)
		s.sessMu.Unlock()
	}
	writeJSON(w, http.StatusOK, map[string]any{})
}

func (s *Server) handleMe(w http.ResponseWriter, r *http.Request, u *User) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "Method not allowed")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"id":       u.ID,
		"username": u.Username,
	})
}

func (s *Server) handlePassword(w http.ResponseWriter, r *http.Request, u *User) {
	if r.Method != http.MethodPut {
		writeError(w, http.StatusMethodNotAllowed, "Method not allowed")
		return
	}
	var req changePasswordReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "Invalid JSON")
		return
	}
	if req.OldPassword != u.Password {
		writeError(w, http.StatusUnauthorized, "Invalid credentials")
		return
	}
	if len(req.NewPassword) < 8 {
		writeError(w, http.StatusBadRequest, "Password too short")
		return
	}
	// update password safely
	s.userMu.Lock()
	if uu := s.usersByID[u.ID]; uu != nil {
		uu.Password = req.NewPassword
	}
	s.userMu.Unlock()
	writeJSON(w, http.StatusOK, map[string]any{})
}

type createTodoReq struct {
	Title       string `json:"title"`
	Description string `json:"description"`
}

type updateTodoReq struct {
	Title       *string `json:"title"`
	Description *string `json:"description"`
	Completed   *bool   `json:"completed"`
}

func (s *Server) handleTodos(w http.ResponseWriter, r *http.Request, u *User) {
	switch r.Method {
	case http.MethodGet:
		// list
		s.todoMu.RLock()
		todos := make([]*Todo, 0)
		for _, t := range s.todosByID {
			if t.OwnerUserID == u.ID {
				cp := *t
				todos = append(todos, &cp)
			}
		}
		s.todoMu.RUnlock()
		sort.Slice(todos, func(i, j int) bool { return todos[i].ID < todos[j].ID })
		writeJSON(w, http.StatusOK, todos)
	case http.MethodPost:
		var req createTodoReq
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
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
			// default to empty string explicitly
			desc = ""
		}
		now := nowISO8601UTC()
		s.todoMu.Lock()
		id := s.nextTodoID
		s.nextTodoID++
		t := &Todo{ID: id, Title: title, Description: desc, Completed: false, CreatedAt: now, UpdatedAt: now, OwnerUserID: u.ID}
		s.todosByID[id] = t
		s.todoMu.Unlock()
		writeJSON(w, http.StatusCreated, t)
	default:
		writeError(w, http.StatusMethodNotAllowed, "Method not allowed")
	}
}

func (s *Server) parseTodoID(path string) (int, bool) {
	// path expected: /todos/{id}
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

func (s *Server) handleTodoByID(w http.ResponseWriter, r *http.Request, u *User) {
	id, ok := s.parseTodoID(r.URL.Path)
	if !ok {
		writeError(w, http.StatusNotFound, "Todo not found")
		return
	}
	// Fetch and authZ check
	s.todoMu.RLock()
	t, exists := s.todosByID[id]
	s.todoMu.RUnlock()
	if !exists || t.OwnerUserID != u.ID {
		writeError(w, http.StatusNotFound, "Todo not found")
		return
	}
	switch r.Method {
	case http.MethodGet:
		writeJSON(w, http.StatusOK, t)
	case http.MethodPut:
		var req updateTodoReq
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "Invalid JSON")
			return
		}
		updated := false
		s.todoMu.Lock()
		// recheck existence within lock
		cur, ok := s.todosByID[id]
		if !ok || cur.OwnerUserID != u.ID {
			s.todoMu.Unlock()
			writeError(w, http.StatusNotFound, "Todo not found")
			return
		}
		if req.Title != nil {
			title := strings.TrimSpace(*req.Title)
			if title == "" {
				s.todoMu.Unlock()
				writeError(w, http.StatusBadRequest, "Title is required")
				return
			}
			cur.Title = title
			updated = true
		}
		if req.Description != nil {
			cur.Description = *req.Description
			updated = true
		}
		if req.Completed != nil {
			cur.Completed = *req.Completed
			updated = true
		}
		// updated_at on any modification; set on any PUT as conservative approach
		if updated || true {
			cur.UpdatedAt = nowISO8601UTC()
		}
		s.todoMu.Unlock()
		writeJSON(w, http.StatusOK, cur)
	case http.MethodDelete:
		// No body on 204
		s.todoMu.Lock()
		// recheck
		cur, ok := s.todosByID[id]
		if !ok || cur.OwnerUserID != u.ID {
			s.todoMu.Unlock()
			writeError(w, http.StatusNotFound, "Todo not found")
			return
		}
		delete(s.todosByID, id)
		s.todoMu.Unlock()
		w.WriteHeader(http.StatusNoContent)
	default:
		writeError(w, http.StatusMethodNotAllowed, "Method not allowed")
	}
}

func main() {
	port := flag.String("port", "8080", "Port to listen on")
	flag.Parse()
	addr := fmt.Sprintf("0.0.0.0:%s", *port)

	s := NewServer()

	mux := http.NewServeMux()

	// Unprotected
	mux.HandleFunc("/register", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/register" {
			writeError(w, http.StatusNotFound, "Not found")
			return
		}
		s.handleRegister(w, r)
	})
	mux.HandleFunc("/login", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/login" {
			writeError(w, http.StatusNotFound, "Not found")
			return
		}
		s.handleLogin(w, r)
	})

	// Protected
	mux.HandleFunc("/logout", s.requireAuth(s.handleLogout))
	mux.HandleFunc("/me", s.requireAuth(s.handleMe))
	mux.HandleFunc("/password", s.requireAuth(s.handlePassword))
	// /todos and /todos/{id}
	mux.HandleFunc("/todos", s.requireAuth(s.handleTodos))
	mux.HandleFunc("/todos/", s.requireAuth(s.handleTodoByID))

	server := &http.Server{
		Addr:              addr,
		Handler:           withJSONContentType(mux),
		ReadHeaderTimeout: 5 * time.Second,
	}

	log.Printf("Listening on %s", addr)
	if err := server.ListenAndServe(); err != nil {
		log.Fatal(err)
	}
}

// Middleware to ensure Content-Type for JSON responses on non-DELETE methods.
func withJSONContentType(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Wrap ResponseWriter to set header before writing for non-DELETE
		tw := &typeWriter{ResponseWriter: w, method: r.Method}
		next.ServeHTTP(tw, r)
	})
}

type typeWriter struct {
	http.ResponseWriter
	wroteHeader bool
	method      string
}

func (tw *typeWriter) WriteHeader(statusCode int) {
	if !tw.wroteHeader {
		if tw.method != http.MethodDelete {
			// Ensure Content-Type unless already set
			if ct := tw.Header().Get("Content-Type"); ct == "" {
				tw.Header().Set("Content-Type", "application/json")
			}
		}
		tw.wroteHeader = true
	}
	tw.ResponseWriter.WriteHeader(statusCode)
}

func (tw *typeWriter) Write(b []byte) (int, error) {
	if !tw.wroteHeader {
		if tw.method != http.MethodDelete {
			if ct := tw.Header().Get("Content-Type"); ct == "" {
				tw.Header().Set("Content-Type", "application/json")
			}
		}
	}
	return tw.ResponseWriter.Write(b)
}
