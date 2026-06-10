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

// Data models

type User struct {
	ID       int    `json:"id"`
	Username string `json:"username"`
	Password string `json:"-"`
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

type Store struct {
	mu          sync.RWMutex
	usersByID   map[int]*User
	usersByName map[string]*User
	sessions    map[string]int // token -> userID
	todosByID   map[int]*Todo
	nextUserID  int
	nextTodoID  int
}

func NewStore() *Store {
	return &Store{
		usersByID:   make(map[int]*User),
		usersByName: make(map[string]*User),
		sessions:    make(map[string]int),
		todosByID:   make(map[int]*Todo),
		nextUserID:  1,
		nextTodoID:  1,
	}
}

// Helpers

func writeJSON(w http.ResponseWriter, status int, v interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	enc := json.NewEncoder(w)
	enc.SetEscapeHTML(true)
	_ = enc.Encode(v)
}

func writeError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}

func readJSON(r *http.Request, dst interface{}) error {
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	return dec.Decode(dst)
}

func generateToken() (string, error) {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

func nowISO8601() string {
	return time.Now().UTC().Format(time.RFC3339)
}

// Authentication

func (s *Store) getUserFromRequest(r *http.Request) (*User, string, error) {
	c, err := r.Cookie("session_id")
	if err != nil || c.Value == "" {
		return nil, "", errors.New("auth required")
	}
	s.mu.RLock()
	uid, ok := s.sessions[c.Value]
	if !ok {
		s.mu.RUnlock()
		return nil, c.Value, errors.New("auth required")
	}
	user := s.usersByID[uid]
	s.mu.RUnlock()
	if user == nil {
		return nil, c.Value, errors.New("auth required")
	}
	return user, c.Value, nil
}

// Handlers

type Server struct {
	store *Store
}

func NewServer() *Server {
	return &Server{store: NewStore()}
}

var usernameRe = regexp.MustCompile(`^[a-zA-Z0-9_]{3,50}$`)

func (s *Server) handleRegister(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusNotFound, "Not found")
		return
	}
	type reqT struct {
		Username string `json:"username"`
		Password string `json:"password"`
	}
	var req reqT
	if err := readJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "Invalid JSON")
		return
	}
	if !usernameRe.MatchString(req.Username) {
		writeError(w, http.StatusBadRequest, "Invalid username")
		return
	}
	if len(req.Password) < 8 {
		writeError(w, http.StatusBadRequest, "Password too short")
		return
	}
	s.store.mu.Lock()
	defer s.store.mu.Unlock()
	if _, exists := s.store.usersByName[req.Username]; exists {
		writeError(w, http.StatusConflict, "Username already exists")
		return
	}
	id := s.store.nextUserID
	s.store.nextUserID++
	user := &User{ID: id, Username: req.Username, Password: req.Password}
	s.store.usersByID[id] = user
	s.store.usersByName[req.Username] = user
	writeJSON(w, http.StatusCreated, map[string]interface{}{"id": user.ID, "username": user.Username})
}

func (s *Server) handleLogin(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusNotFound, "Not found")
		return
	}
	type reqT struct {
		Username string `json:"username"`
		Password string `json:"password"`
	}
	var req reqT
	if err := readJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "Invalid JSON")
		return
	}
	s.store.mu.RLock()
	user := s.store.usersByName[req.Username]
	s.store.mu.RUnlock()
	if user == nil || user.Password != req.Password {
		writeError(w, http.StatusUnauthorized, "Invalid credentials")
		return
	}
	tok, err := generateToken()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "Server error")
		return
	}
	s.store.mu.Lock()
	s.store.sessions[tok] = user.ID
	s.store.mu.Unlock()
	http.SetCookie(w, &http.Cookie{Name: "session_id", Value: tok, Path: "/", HttpOnly: true})
	writeJSON(w, http.StatusOK, map[string]interface{}{"id": user.ID, "username": user.Username})
}

func (s *Server) handleLogout(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusNotFound, "Not found")
		return
	}
	user, token, err := s.store.getUserFromRequest(r)
	_ = user
	if err != nil {
		writeError(w, http.StatusUnauthorized, "Authentication required")
		return
	}
	s.store.mu.Lock()
	delete(s.store.sessions, token)
	s.store.mu.Unlock()
	// Expire the cookie client-side as well
	http.SetCookie(w, &http.Cookie{Name: "session_id", Value: "", Path: "/", HttpOnly: true, MaxAge: -1, Expires: time.Unix(0, 0)})
	writeJSON(w, http.StatusOK, map[string]interface{}{})
}

func (s *Server) handleMe(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusNotFound, "Not found")
		return
	}
	user, _, err := s.store.getUserFromRequest(r)
	if err != nil {
		writeError(w, http.StatusUnauthorized, "Authentication required")
		return
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{"id": user.ID, "username": user.Username})
}

func (s *Server) handlePassword(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPut {
		writeError(w, http.StatusNotFound, "Not found")
		return
	}
	user, _, err := s.store.getUserFromRequest(r)
	if err != nil {
		writeError(w, http.StatusUnauthorized, "Authentication required")
		return
	}
	type reqT struct {
		OldPassword string `json:"old_password"`
		NewPassword string `json:"new_password"`
	}
	var req reqT
	if err := readJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "Invalid JSON")
		return
	}
	if req.OldPassword != user.Password {
		writeError(w, http.StatusUnauthorized, "Invalid credentials")
		return
	}
	if len(req.NewPassword) < 8 {
		writeError(w, http.StatusBadRequest, "Password too short")
		return
	}
	s.store.mu.Lock()
	user.Password = req.NewPassword
	s.store.mu.Unlock()
	writeJSON(w, http.StatusOK, map[string]interface{}{})
}

func (s *Server) handleTodos(w http.ResponseWriter, r *http.Request) {
	user, _, err := s.store.getUserFromRequest(r)
	if err != nil {
		writeError(w, http.StatusUnauthorized, "Authentication required")
		return
	}
	switch r.Method {
	case http.MethodGet:
		// List todos for user ordered by id asc
		s.store.mu.RLock()
		var list []*Todo
		for _, t := range s.store.todosByID {
			if t.UserID == user.ID {
				// make a copy to avoid accidental mutation
				copyT := *t
				list = append(list, &copyT)
			}
		}
		s.store.mu.RUnlock()
		sort.Slice(list, func(i, j int) bool { return list[i].ID < list[j].ID })
		writeJSON(w, http.StatusOK, list)
	case http.MethodPost:
		type reqT struct {
			Title       string `json:"title"`
			Description string `json:"description"`
		}
		var req reqT
		if err := readJSON(r, &req); err != nil {
			writeError(w, http.StatusBadRequest, "Invalid JSON")
			return
		}
		if strings.TrimSpace(req.Title) == "" {
			writeError(w, http.StatusBadRequest, "Title is required")
			return
		}
		if req.Description == "" {
			// default already empty
		}
		created := nowISO8601()
		s.store.mu.Lock()
		id := s.store.nextTodoID
		s.store.nextTodoID++
		todo := &Todo{
			ID:          id,
			Title:       req.Title,
			Description: req.Description,
			Completed:   false,
			CreatedAt:   created,
			UpdatedAt:   created,
			UserID:      user.ID,
		}
		s.store.todosByID[id] = todo
		s.store.mu.Unlock()
		writeJSON(w, http.StatusCreated, todo)
	default:
		writeError(w, http.StatusNotFound, "Not found")
	}
}

func (s *Server) handleTodoItem(w http.ResponseWriter, r *http.Request) {
	user, _, err := s.store.getUserFromRequest(r)
	if err != nil {
		// For any method, require auth
		writeError(w, http.StatusUnauthorized, "Authentication required")
		return
	}
	// Path expected: /todos/{id}
	parts := strings.Split(strings.TrimPrefix(r.URL.Path, "/todos/"), "/")
	if len(parts) == 0 || parts[0] == "" || (len(parts) > 1 && parts[1] != "") {
		// malformed or extra segments
		writeError(w, http.StatusNotFound, "Todo not found")
		return
	}
	idStr := parts[0]
	id, err := strconv.Atoi(idStr)
	if err != nil || id <= 0 {
		writeError(w, http.StatusNotFound, "Todo not found")
		return
	}

	s.store.mu.RLock()
	t, ok := s.store.todosByID[id]
	if ok {
		// ensure ownership
		if t.UserID != user.ID {
			// do not reveal existence
			s.store.mu.RUnlock()
			if r.Method == http.MethodDelete {
				// 404 with JSON per spec, but DELETE success returns no body; here not success
				writeError(w, http.StatusNotFound, "Todo not found")
				return
			}
			writeError(w, http.StatusNotFound, "Todo not found")
			return
		}
	}
	s.store.mu.RUnlock()
	if !ok {
		writeError(w, http.StatusNotFound, "Todo not found")
		return
	}

	switch r.Method {
	case http.MethodGet:
		// return copy without UserID
		copyT := *t
		writeJSON(w, http.StatusOK, &copyT)
	case http.MethodPut:
		type reqT struct {
			Title       *string `json:"title"`
			Description *string `json:"description"`
			Completed   *bool   `json:"completed"`
		}
		var req reqT
		if err := readJSON(r, &req); err != nil {
			writeError(w, http.StatusBadRequest, "Invalid JSON")
			return
		}
		// Validate title if present
		if req.Title != nil && strings.TrimSpace(*req.Title) == "" {
			writeError(w, http.StatusBadRequest, "Title is required")
			return
		}
		s.store.mu.Lock()
		// Re-check to avoid race
		cur, ok2 := s.store.todosByID[id]
		if !ok2 || cur.UserID != user.ID {
			s.store.mu.Unlock()
			writeError(w, http.StatusNotFound, "Todo not found")
			return
		}
		if req.Title != nil {
			cur.Title = *req.Title
		}
		if req.Description != nil {
			cur.Description = *req.Description
		}
		if req.Completed != nil {
			cur.Completed = *req.Completed
		}
		cur.UpdatedAt = nowISO8601()
		updated := *cur
		s.store.mu.Unlock()
		writeJSON(w, http.StatusOK, &updated)
	case http.MethodDelete:
		// Delete and return 204 with no body
		s.store.mu.Lock()
		// Re-check ownership
		cur, ok2 := s.store.todosByID[id]
		if !ok2 || cur.UserID != user.ID {
			s.store.mu.Unlock()
			writeError(w, http.StatusNotFound, "Todo not found")
			return
		}
		delete(s.store.todosByID, id)
		s.store.mu.Unlock()
		w.WriteHeader(http.StatusNoContent)
		return
	default:
		writeError(w, http.StatusNotFound, "Todo not found")
	}
}

func (s *Server) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/register", s.handleRegister)
	mux.HandleFunc("/login", s.handleLogin)
	mux.HandleFunc("/logout", s.handleLogout)
	mux.HandleFunc("/me", s.handleMe)
	mux.HandleFunc("/password", s.handlePassword)
	mux.HandleFunc("/todos", s.handleTodos)   // GET, POST
	mux.HandleFunc("/todos/", s.handleTodoItem) // GET, PUT, DELETE
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Ensure JSON Content-Type for all responses except DELETE success where handler returns without writing
		// We cannot set header here globally because handlers may return 204 without body.
		// We only ensure unknown routes return JSON error.
		// Delegate to mux and intercept 404s by checking if a handler exists.
		rec := &responseRecorder{ResponseWriter: w}
		mux.ServeHTTP(rec, r)
		if rec.notFound {
			writeError(w, http.StatusNotFound, "Not found")
		}
	})
}

type responseRecorder struct {
	http.ResponseWriter
	notFound bool
}

func (rr *responseRecorder) WriteHeader(statusCode int) {
	if statusCode == http.StatusNotFound {
		rr.notFound = true
		// do not write yet; caller will handle
		return
	}
	rr.ResponseWriter.WriteHeader(statusCode)
}

func (rr *responseRecorder) Write(b []byte) (int, error) {
	if rr.notFound {
		// swallow
		return len(b), nil
	}
	return rr.ResponseWriter.Write(b)
}

func main() {
	var port string
	flag.StringVar(&port, "port", "8080", "port to listen on")
	// allow --port also by default flag pkg supports it
	flag.Parse()
	addr := fmt.Sprintf("0.0.0.0:%s", port)

	server := NewServer()
	mux := server.routes()

	httpServer := &http.Server{
		Addr:              addr,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}
	log.Printf("Listening on %s", addr)
	if err := httpServer.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatalf("server error: %v", err)
	}
}
