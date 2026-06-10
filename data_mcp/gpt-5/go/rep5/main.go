package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
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

// Data models

type User struct {
	ID       int    `json:"id"`
	Username string `json:"username"`
}

type userRecord struct {
	User
	Password string
}

type Todo struct {
	ID          int    `json:"id"`
	Title       string `json:"title"`
	Description string `json:"description"`
	Completed   bool   `json:"completed"`
	CreatedAt   string `json:"created_at"`
	UpdatedAt   string `json:"updated_at"`
	UserID      int    `json:"-"`
}

type Server struct {
	mu            sync.RWMutex
	users         map[int]*userRecord
	usersByName   map[string]*userRecord
	nextUserID    int
	sessions      map[string]int // session_id -> userID
	nextTodoID    int
	todos         map[int]*Todo
}

func NewServer() *Server {
	return &Server{
		users:       make(map[int]*userRecord),
		usersByName: make(map[string]*userRecord),
		sessions:    make(map[string]int),
		todos:       make(map[int]*Todo),
		nextUserID:  1,
		nextTodoID:  1,
	}
}

func jsonTimeNow() string {
	// ISO 8601 UTC timestamp with second precision
	return time.Now().UTC().Format("2006-01-02T15:04:05Z")
}

func writeJSON(w http.ResponseWriter, status int, v interface{}) {
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

func readJSON(w http.ResponseWriter, r *http.Request, dst interface{}) bool {
	defer r.Body.Close()
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(dst); err != nil {
		writeError(w, http.StatusBadRequest, "Invalid JSON")
		return false
	}
	// Ensure single JSON object only
	if dec.More() {
		writeError(w, http.StatusBadRequest, "Invalid JSON")
		return false
	}
	return true
}

func generateToken(n int) (string, error) {
	b := make([]byte, n)
	_, err := rand.Read(b)
	if err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

// Authentication helpers
func (s *Server) getSessionUserID(r *http.Request) (int, bool) {
	cookie, err := r.Cookie("session_id")
	if err != nil || cookie.Value == "" {
		return 0, false
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	uid, ok := s.sessions[cookie.Value]
	return uid, ok
}

func (s *Server) requireAuth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if uid, ok := s.getSessionUserID(r); ok {
			// attach uid to context via header-like mechanism to avoid context types
			r.Header.Set("X-User-ID", strconv.Itoa(uid))
			next(w, r)
			return
		}
		writeError(w, http.StatusUnauthorized, "Authentication required")
	}
}

func (s *Server) currentUser(r *http.Request) (*userRecord, bool) {
	uidStr := r.Header.Get("X-User-ID")
	if uidStr == "" {
		return nil, false
	}
	uid, err := strconv.Atoi(uidStr)
	if err != nil {
		return nil, false
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	u, ok := s.users[uid]
	return u, ok
}

// Handlers

func (s *Server) handleRegister(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "Method not allowed")
		return
	}
	var req struct {
		Username string `json:"username"`
		Password string `json:"password"`
	}
	if !readJSON(w, r, &req) {
		return
	}
	username := strings.TrimSpace(req.Username)
	password := req.Password
	if !validateUsername(username) {
		writeError(w, http.StatusBadRequest, "Invalid username")
		return
	}
	if len(password) < 8 {
		writeError(w, http.StatusBadRequest, "Password too short")
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, exists := s.usersByName[username]; exists {
		writeError(w, http.StatusConflict, "Username already exists")
		return
	}
	id := s.nextUserID
	s.nextUserID++
	rec := &userRecord{User: User{ID: id, Username: username}, Password: password}
	s.users[id] = rec
	s.usersByName[username] = rec
	writeJSON(w, http.StatusCreated, rec.User)
}

func (s *Server) handleLogin(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "Method not allowed")
		return
	}
	var req struct {
		Username string `json:"username"`
		Password string `json:"password"`
	}
	if !readJSON(w, r, &req) {
		return
	}
	s.mu.RLock()
	rec, ok := s.usersByName[req.Username]
	s.mu.RUnlock()
	if !ok || rec.Password != req.Password {
		writeError(w, http.StatusUnauthorized, "Invalid credentials")
		return
	}
	token, err := generateToken(16)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "Server error")
		return
	}
	s.mu.Lock()
	s.sessions[token] = rec.ID
	s.mu.Unlock()
	http.SetCookie(w, &http.Cookie{
		Name:     "session_id",
		Value:    token,
		Path:     "/",
		HttpOnly: true,
		SameSite: http.SameSiteLaxMode,
	})
	writeJSON(w, http.StatusOK, rec.User)
}

func (s *Server) handleLogout(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "Method not allowed")
		return
	}
	cookie, err := r.Cookie("session_id")
	if err != nil || cookie.Value == "" {
		// treat as not authenticated
		writeError(w, http.StatusUnauthorized, "Authentication required")
		return
	}
	s.mu.Lock()
	delete(s.sessions, cookie.Value)
	s.mu.Unlock()
	// Clear cookie client-side as well
	http.SetCookie(w, &http.Cookie{
		Name:     "session_id",
		Value:    "",
		Path:     "/",
		HttpOnly: true,
		MaxAge:   -1,
	})
	writeJSON(w, http.StatusOK, map[string]interface{}{})
}

func (s *Server) handleMe(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "Method not allowed")
		return
	}
	u, ok := s.currentUser(r)
	if !ok {
		writeError(w, http.StatusUnauthorized, "Authentication required")
		return
	}
	writeJSON(w, http.StatusOK, u.User)
}

func (s *Server) handlePassword(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPut {
		writeError(w, http.StatusMethodNotAllowed, "Method not allowed")
		return
	}
	u, ok := s.currentUser(r)
	if !ok {
		writeError(w, http.StatusUnauthorized, "Authentication required")
		return
	}
	var req struct {
		Old string `json:"old_password"`
		New string `json:"new_password"`
	}
	if !readJSON(w, r, &req) {
		return
	}
	if req.Old != u.Password {
		writeError(w, http.StatusUnauthorized, "Invalid credentials")
		return
	}
	if len(req.New) < 8 {
		writeError(w, http.StatusBadRequest, "Password too short")
		return
	}
	s.mu.Lock()
	u.Password = req.New
	s.mu.Unlock()
	writeJSON(w, http.StatusOK, map[string]interface{}{})
}

func (s *Server) handleTodos(w http.ResponseWriter, r *http.Request) {
	u, ok := s.currentUser(r)
	if !ok {
		writeError(w, http.StatusUnauthorized, "Authentication required")
		return
	}
	switch r.Method {
	case http.MethodGet:
		// list todos for user ordered by ID asc
		s.mu.RLock()
		var list []*Todo
		for _, t := range s.todos {
			if t.UserID == u.ID {
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
		if !readJSON(w, r, &req) {
			return
		}
		if strings.TrimSpace(req.Title) == "" {
			writeError(w, http.StatusBadRequest, "Title is required")
			return
		}
		if req.Description == "" {
			req.Description = ""
		}
		now := jsonTimeNow()
		s.mu.Lock()
		id := s.nextTodoID
		s.nextTodoID++
		t := &Todo{
			ID:          id,
			Title:       req.Title,
			Description: req.Description,
			Completed:   false,
			CreatedAt:   now,
			UpdatedAt:   now,
			UserID:      u.ID,
		}
		s.todos[id] = t
		s.mu.Unlock()
		writeJSON(w, http.StatusCreated, t)
	default:
		writeError(w, http.StatusMethodNotAllowed, "Method not allowed")
	}
}

func (s *Server) parseTodoID(path string) (int, bool) {
	// path expected: /todos/:id
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

func (s *Server) handleTodoByID(w http.ResponseWriter, r *http.Request) {
	u, ok := s.currentUser(r)
	if !ok {
		writeError(w, http.StatusUnauthorized, "Authentication required")
		return
	}
	id, ok := s.parseTodoID(r.URL.Path)
	if !ok {
		writeError(w, http.StatusNotFound, "Todo not found")
		return
	}
	s.mu.RLock()
	t, exists := s.todos[id]
	s.mu.RUnlock()
	if !exists || t.UserID != u.ID {
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
		if !readJSON(w, r, &req) {
			return
		}
		if req.Title != nil && strings.TrimSpace(*req.Title) == "" {
			writeError(w, http.StatusBadRequest, "Title is required")
			return
		}
		s.mu.Lock()
		if req.Title != nil {
			t.Title = *req.Title
		}
		if req.Description != nil {
			t.Description = *req.Description
		}
		if req.Completed != nil {
			t.Completed = *req.Completed
		}
		t.UpdatedAt = jsonTimeNow()
		s.mu.Unlock()
		writeJSON(w, http.StatusOK, t)
	case http.MethodDelete:
		s.mu.Lock()
		delete(s.todos, id)
		s.mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusNoContent)
	default:
		writeError(w, http.StatusMethodNotAllowed, "Method not allowed")
	}
}

var usernameRe = regexp.MustCompile(`^[a-zA-Z0-9_]{3,50}$`)

func validateUsername(u string) bool {
	return usernameRe.MatchString(u)
}

func (s *Server) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/register", s.handleRegister)
	mux.HandleFunc("/login", s.handleLogin)
	mux.HandleFunc("/logout", s.requireAuth(s.handleLogout))
	mux.HandleFunc("/me", s.requireAuth(s.handleMe))
	mux.HandleFunc("/password", s.requireAuth(s.handlePassword))
	mux.HandleFunc("/todos", s.requireAuth(s.handleTodos))
	mux.HandleFunc("/todos/", s.requireAuth(s.handleTodoByID))
	// default: 404 JSON
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if h, pattern := mux.Handler(r); pattern != "" {
			h.ServeHTTP(w, r)
			return
		}
		writeError(w, http.StatusNotFound, "Not found")
	})
}

func main() {
	port := flag.Int("port", 8080, "port to listen on")
	flag.Parse()
	addr := fmt.Sprintf("0.0.0.0:%d", *port)
	server := NewServer()
	log.Printf("Listening on %s\n", addr)
	if err := http.ListenAndServe(addr, server.routes()); err != nil {
		log.Fatal(err)
	}
}
