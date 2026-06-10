package main

import (
	"context"
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

	"golang.org/x/crypto/bcrypt"
)

// Data models

type User struct {
	ID       int    `json:"id"`
	Username string `json:"username"`
}

type Todo struct {
	ID          int    `json:"id"`
	Title       string `json:"title"`
	Description string `json:"description"`
	Completed   bool   `json:"completed"`
	CreatedAt   string `json:"created_at"`
	UpdatedAt   string `json:"updated_at"`
}

type userRecord struct {
	User
	PasswordHash []byte
}

type todoRecord struct {
	Todo
	OwnerUserID int
}

type Server struct {
	mux *http.ServeMux

	mu sync.RWMutex

	usersByID    map[int]*userRecord
	usersByName  map[string]*userRecord
	nextUserID   int

	sessions     map[string]int // token -> userID

	todosByID    map[int]*todoRecord
	nextTodoID   int
}

func NewServer() *Server {
	s := &Server{
		mux:         http.NewServeMux(),
		usersByID:   make(map[int]*userRecord),
		usersByName: make(map[string]*userRecord),
		sessions:    make(map[string]int),
		todosByID:   make(map[int]*todoRecord),
		nextUserID:  1,
		nextTodoID:  1,
	}
	// Routes
	s.mux.HandleFunc("/register", s.handleRegister)
	s.mux.HandleFunc("/login", s.handleLogin)
	s.mux.HandleFunc("/logout", s.requireAuth(s.handleLogout))
	s.mux.HandleFunc("/me", s.requireAuth(s.handleMe))
	s.mux.HandleFunc("/password", s.requireAuth(s.handlePassword))
	s.mux.HandleFunc("/todos", s.requireAuth(s.handleTodos))
	s.mux.HandleFunc("/todos/", s.requireAuth(s.handleTodoByID))
	// fallback
	s.mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		respondError(w, http.StatusNotFound, "Not found")
	})
	return s
}

func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	// Default: JSON content type for all responses
	w.Header().Set("Content-Type", "application/json")
	s.mux.ServeHTTP(w, r)
}

// Helpers

func respondJSON(w http.ResponseWriter, status int, v interface{}) {
	w.WriteHeader(status)
	if v == nil {
		return
	}
	enc := json.NewEncoder(w)
	enc.SetEscapeHTML(false)
	_ = enc.Encode(v)
}

func respondError(w http.ResponseWriter, status int, msg string) {
	respondJSON(w, status, map[string]string{"error": msg})
}

func nowISO8601() string {
	// Must be second precision per spec. time.RFC3339 uses seconds by default when no nanoseconds.
	return time.Now().UTC().Format("2006-01-02T15:04:05Z07:00")
}

func generateToken() (string, error) {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

// Auth middleware

type ctxKey string

const userIDKey ctxKey = "userID"

func (s *Server) requireAuth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		c, err := r.Cookie("session_id")
		if err != nil || c == nil || c.Value == "" {
			respondError(w, http.StatusUnauthorized, "Authentication required")
			return
		}
		s.mu.RLock()
		uid, ok := s.sessions[c.Value]
		s.mu.RUnlock()
		if !ok {
			respondError(w, http.StatusUnauthorized, "Authentication required")
			return
		}
		r = r.WithContext(context.WithValue(r.Context(), userIDKey, uid))
		next(w, r)
	}
}

func getUserID(r *http.Request) (int, bool) {
	v := r.Context().Value(userIDKey)
	if v == nil {
		return 0, false
	}
	uid, ok := v.(int)
	return uid, ok
}

// Handlers

func (s *Server) handleRegister(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		respondError(w, http.StatusNotFound, "Not found")
		return
	}
	var req struct {
		Username string `json:"username"`
		Password string `json:"password"`
	}
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(&req); err != nil {
		respondError(w, http.StatusBadRequest, "Invalid JSON")
		return
	}
	// Validation
	if !isValidUsername(req.Username) {
		respondError(w, http.StatusBadRequest, "Invalid username")
		return
	}
	if len(req.Password) < 8 {
		respondError(w, http.StatusBadRequest, "Password too short")
		return
	}
	// Create user
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, exists := s.usersByName[req.Username]; exists {
		respondError(w, http.StatusConflict, "Username already exists")
		return
	}
	hash, err := bcrypt.GenerateFromPassword([]byte(req.Password), bcrypt.DefaultCost)
	if err != nil {
		respondError(w, http.StatusInternalServerError, "Internal error")
		return
	}
	uid := s.nextUserID
	s.nextUserID++
	u := &userRecord{User: User{ID: uid, Username: req.Username}, PasswordHash: hash}
	s.usersByID[uid] = u
	s.usersByName[req.Username] = u
	respondJSON(w, http.StatusCreated, u.User)
}

func (s *Server) handleLogin(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		respondError(w, http.StatusNotFound, "Not found")
		return
	}
	var req struct {
		Username string `json:"username"`
		Password string `json:"password"`
	}
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(&req); err != nil {
		respondError(w, http.StatusBadRequest, "Invalid JSON")
		return
	}
	s.mu.RLock()
	u, ok := s.usersByName[req.Username]
	s.mu.RUnlock()
	if !ok || bcrypt.CompareHashAndPassword(u.PasswordHash, []byte(req.Password)) != nil {
		respondError(w, http.StatusUnauthorized, "Invalid credentials")
		return
	}
	tok, err := generateToken()
	if err != nil {
		respondError(w, http.StatusInternalServerError, "Internal error")
		return
	}
	s.mu.Lock()
	s.sessions[tok] = u.ID
	s.mu.Unlock()
	cookie := &http.Cookie{Name: "session_id", Value: tok, Path: "/", HttpOnly: true}
	http.SetCookie(w, cookie)
	respondJSON(w, http.StatusOK, u.User)
}

func (s *Server) handleLogout(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		respondError(w, http.StatusNotFound, "Not found")
		return
	}
	c, err := r.Cookie("session_id")
	if err == nil && c != nil {
		s.mu.Lock()
		delete(s.sessions, c.Value)
		s.mu.Unlock()
	}
	respondJSON(w, http.StatusOK, map[string]any{})
}

func (s *Server) handleMe(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		respondError(w, http.StatusNotFound, "Not found")
		return
	}
	uid, ok := getUserID(r)
	if !ok {
		respondError(w, http.StatusUnauthorized, "Authentication required")
		return
	}
	s.mu.RLock()
	u := s.usersByID[uid]
	s.mu.RUnlock()
	respondJSON(w, http.StatusOK, u.User)
}

func (s *Server) handlePassword(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPut {
		respondError(w, http.StatusNotFound, "Not found")
		return
	}
	uid, ok := getUserID(r)
	if !ok {
		respondError(w, http.StatusUnauthorized, "Authentication required")
		return
	}
	var req struct {
		Old string `json:"old_password"`
		New string `json:"new_password"`
	}
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(&req); err != nil {
		respondError(w, http.StatusBadRequest, "Invalid JSON")
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	u := s.usersByID[uid]
	if u == nil || bcrypt.CompareHashAndPassword(u.PasswordHash, []byte(req.Old)) != nil {
		respondError(w, http.StatusUnauthorized, "Invalid credentials")
		return
	}
	if len(req.New) < 8 {
		respondError(w, http.StatusBadRequest, "Password too short")
		return
	}
	hash, err := bcrypt.GenerateFromPassword([]byte(req.New), bcrypt.DefaultCost)
	if err != nil {
		respondError(w, http.StatusInternalServerError, "Internal error")
		return
	}
	u.PasswordHash = hash
	respondJSON(w, http.StatusOK, map[string]any{})
}

func (s *Server) handleTodos(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		s.listTodos(w, r)
	case http.MethodPost:
		s.createTodo(w, r)
	default:
		respondError(w, http.StatusNotFound, "Not found")
	}
}

func (s *Server) listTodos(w http.ResponseWriter, r *http.Request) {
	uid, ok := getUserID(r)
	if !ok {
		respondError(w, http.StatusUnauthorized, "Authentication required")
		return
	}
	s.mu.RLock()
	var todos []Todo
	for _, tr := range s.todosByID {
		if tr.OwnerUserID == uid {
			todos = append(todos, tr.Todo)
		}
	}
	s.mu.RUnlock()
	sort.Slice(todos, func(i, j int) bool { return todos[i].ID < todos[j].ID })
	respondJSON(w, http.StatusOK, todos)
}

func (s *Server) createTodo(w http.ResponseWriter, r *http.Request) {
	uid, ok := getUserID(r)
	if !ok {
		respondError(w, http.StatusUnauthorized, "Authentication required")
		return
	}
	var req struct {
		Title       string  `json:"title"`
		Description *string `json:"description"`
	}
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(&req); err != nil {
		respondError(w, http.StatusBadRequest, "Invalid JSON")
		return
	}
	if strings.TrimSpace(req.Title) == "" {
		respondError(w, http.StatusBadRequest, "Title is required")
		return
	}
	desc := ""
	if req.Description != nil {
		desc = *req.Description
	}
	now := time.Now().UTC().Format("2006-01-02T15:04:05Z07:00")
	s.mu.Lock()
	id := s.nextTodoID
	s.nextTodoID++
	tr := &todoRecord{
		Todo: Todo{ID: id, Title: req.Title, Description: desc, Completed: false, CreatedAt: now, UpdatedAt: now},
		OwnerUserID: uid,
	}
	s.todosByID[id] = tr
	s.mu.Unlock()
	respondJSON(w, http.StatusCreated, tr.Todo)
}

func (s *Server) handleTodoByID(w http.ResponseWriter, r *http.Request) {
	// Expect path /todos/:id
	parts := strings.Split(strings.Trim(r.URL.Path, "/"), "/")
	if len(parts) < 2 {
		respondError(w, http.StatusNotFound, "Not found")
		return
	}
	idStr := parts[1]
	id, err := strconv.Atoi(idStr)
	if err != nil || id <= 0 {
		respondError(w, http.StatusNotFound, "Not found")
		return
	}
	switch r.Method {
	case http.MethodGet:
		s.getTodo(w, r, id)
	case http.MethodPut:
		s.updateTodo(w, r, id)
	case http.MethodDelete:
		s.deleteTodo(w, r, id)
	default:
		respondError(w, http.StatusNotFound, "Not found")
	}
}

func (s *Server) getTodo(w http.ResponseWriter, r *http.Request, id int) {
	uid, ok := getUserID(r)
	if !ok {
		respondError(w, http.StatusUnauthorized, "Authentication required")
		return
	}
	s.mu.RLock()
	tr, ok := s.todosByID[id]
	s.mu.RUnlock()
	if !ok || tr.OwnerUserID != uid {
		respondError(w, http.StatusNotFound, "Todo not found")
		return
	}
	respondJSON(w, http.StatusOK, tr.Todo)
}

func (s *Server) updateTodo(w http.ResponseWriter, r *http.Request, id int) {
	uid, ok := getUserID(r)
	if !ok {
		respondError(w, http.StatusUnauthorized, "Authentication required")
		return
	}
	var req struct {
		Title       *string `json:"title"`
		Description *string `json:"description"`
		Completed   *bool   `json:"completed"`
	}
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(&req); err != nil {
		respondError(w, http.StatusBadRequest, "Invalid JSON")
		return
	}
	s.mu.Lock()
	tr, ok := s.todosByID[id]
	if !ok || tr.OwnerUserID != uid {
		s.mu.Unlock()
		respondError(w, http.StatusNotFound, "Todo not found")
		return
	}
	if req.Title != nil {
		if strings.TrimSpace(*req.Title) == "" {
			s.mu.Unlock()
			respondError(w, http.StatusBadRequest, "Title is required")
			return
		}
		tr.Title = *req.Title
	}
	if req.Description != nil {
		tr.Description = *req.Description
	}
	if req.Completed != nil {
		tr.Completed = *req.Completed
	}
	tr.UpdatedAt = time.Now().UTC().Format("2006-01-02T15:04:05Z07:00")
	updated := tr.Todo
	s.mu.Unlock()
	respondJSON(w, http.StatusOK, updated)
}

func (s *Server) deleteTodo(w http.ResponseWriter, r *http.Request, id int) {
	uid, ok := getUserID(r)
	if !ok {
		// Error path should return JSON
		respondError(w, http.StatusUnauthorized, "Authentication required")
		return
	}
	s.mu.Lock()
	tr, ok := s.todosByID[id]
	if !ok || tr.OwnerUserID != uid {
		s.mu.Unlock()
		respondError(w, http.StatusNotFound, "Todo not found")
		return
	}
	delete(s.todosByID, id)
	s.mu.Unlock()
	// No body on success and no JSON content-type header
	w.Header().Del("Content-Type")
	w.WriteHeader(http.StatusNoContent)
}

var usernameRe = regexp.MustCompile(`^[a-zA-Z0-9_]{3,50}$`)

func isValidUsername(s string) bool {
	return usernameRe.MatchString(s)
}

func main() {
	port := flag.Int("port", 8080, "port to listen on")
	flag.Parse()
	addr := fmt.Sprintf("0.0.0.0:%d", *port)
	server := NewServer()
	log.Printf("Listening on %s", addr)
	if err := http.ListenAndServe(addr, server); err != nil {
		log.Fatal(err)
	}
}
