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
}

type internalUser struct {
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
	usersByID     map[int]*internalUser
	usersByName   map[string]*internalUser
	nextUserID    int
	sessions      map[string]int // session token -> userID
	todosByID     map[int]*Todo
	nextTodoID    int
}

func NewServer() *Server {
	return &Server{
		usersByID:   make(map[int]*internalUser),
		usersByName: make(map[string]*internalUser),
		sessions:    make(map[string]int),
		todosByID:   make(map[int]*Todo),
		nextUserID:  1,
		nextTodoID:  1,
	}
}

// Utilities

func nowISO8601() string {
	// second precision UTC
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

func (s *Server) generateToken() (string, error) {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

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

func (s *Server) requireAuth(next func(http.ResponseWriter, *http.Request, *internalUser)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		uid, ok := s.getSessionUserID(r)
		if !ok {
			writeError(w, http.StatusUnauthorized, "Authentication required")
			return
		}
		s.mu.RLock()
		user := s.usersByID[uid]
		s.mu.RUnlock()
		if user == nil {
			writeError(w, http.StatusUnauthorized, "Authentication required")
			return
		}
		next(w, r, user)
	}
}

// Handlers

func (s *Server) handleRegister(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusNotFound, "Not found")
		return
	}
	defer r.Body.Close()
	var input struct {
		Username string `json:"username"`
		Password string `json:"password"`
	}
	if err := json.NewDecoder(r.Body).Decode(&input); err != nil {
		writeError(w, http.StatusBadRequest, "Invalid JSON")
		return
	}
	username := strings.TrimSpace(input.Username)
	password := input.Password

	if !validUsername(username) {
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
	user := &internalUser{User: User{ID: id, Username: username}, Password: password}
	s.usersByID[id] = user
	s.usersByName[username] = user

	writeJSON(w, http.StatusCreated, user.User)
}

func (s *Server) handleLogin(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusNotFound, "Not found")
		return
	}
	defer r.Body.Close()
	var input struct {
		Username string `json:"username"`
		Password string `json:"password"`
	}
	if err := json.NewDecoder(r.Body).Decode(&input); err != nil {
		writeError(w, http.StatusBadRequest, "Invalid JSON")
		return
	}

	s.mu.RLock()
	user := s.usersByName[input.Username]
	s.mu.RUnlock()
	if user == nil || user.Password != input.Password {
		writeError(w, http.StatusUnauthorized, "Invalid credentials")
		return
	}
	tok, err := s.generateToken()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "Internal error")
		return
	}
	s.mu.Lock()
	s.sessions[tok] = user.ID
	s.mu.Unlock()

	cookie := &http.Cookie{Name: "session_id", Value: tok, Path: "/", HttpOnly: true}
	http.SetCookie(w, cookie)
	writeJSON(w, http.StatusOK, user.User)
}

func (s *Server) handleLogout(w http.ResponseWriter, r *http.Request, user *internalUser) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusNotFound, "Not found")
		return
	}
	cookie, err := r.Cookie("session_id")
	if err == nil && cookie.Value != "" {
		s.mu.Lock()
		delete(s.sessions, cookie.Value)
		s.mu.Unlock()
	}
	writeJSON(w, http.StatusOK, map[string]any{})
}

func (s *Server) handleMe(w http.ResponseWriter, r *http.Request, user *internalUser) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusNotFound, "Not found")
		return
	}
	writeJSON(w, http.StatusOK, user.User)
}

func (s *Server) handlePassword(w http.ResponseWriter, r *http.Request, user *internalUser) {
	if r.Method != http.MethodPut {
		writeError(w, http.StatusNotFound, "Not found")
		return
	}
	defer r.Body.Close()
	var input struct {
		Old string `json:"old_password"`
		New string `json:"new_password"`
	}
	if err := json.NewDecoder(r.Body).Decode(&input); err != nil {
		writeError(w, http.StatusBadRequest, "Invalid JSON")
		return
	}
	if input.Old != user.Password {
		writeError(w, http.StatusUnauthorized, "Invalid credentials")
		return
	}
	if len(input.New) < 8 {
		writeError(w, http.StatusBadRequest, "Password too short")
		return
	}
	s.mu.Lock()
	user.Password = input.New
	s.mu.Unlock()
	writeJSON(w, http.StatusOK, map[string]any{})
}

func (s *Server) handleTodos(w http.ResponseWriter, r *http.Request, user *internalUser) {
	switch r.Method {
	case http.MethodGet:
		// List
		s.mu.RLock()
		var list []*Todo
		for _, t := range s.todosByID {
			if t.UserID == user.ID {
				copy := *t
				list = append(list, &copy)
			}
		}
		s.mu.RUnlock()
		sort.Slice(list, func(i, j int) bool { return list[i].ID < list[j].ID })
		writeJSON(w, http.StatusOK, list)
	case http.MethodPost:
		defer r.Body.Close()
		var input struct {
			Title       *string `json:"title"`
			Description *string `json:"description"`
		}
		if err := json.NewDecoder(r.Body).Decode(&input); err != nil {
			writeError(w, http.StatusBadRequest, "Invalid JSON")
			return
		}
		if input.Title == nil || strings.TrimSpace(*input.Title) == "" {
			writeError(w, http.StatusBadRequest, "Title is required")
			return
		}
		desc := ""
		if input.Description != nil {
			desc = *input.Description
		}
		now := nowISO8601()
		s.mu.Lock()
		id := s.nextTodoID
		s.nextTodoID++
		t := &Todo{ID: id, Title: strings.TrimSpace(*input.Title), Description: desc, Completed: false, CreatedAt: now, UpdatedAt: now, UserID: user.ID}
		s.todosByID[id] = t
		s.mu.Unlock()
		writeJSON(w, http.StatusCreated, t)
	default:
		writeError(w, http.StatusNotFound, "Not found")
	}
}

func (s *Server) parseTodoIDFromPath(path string) (int, error) {
	parts := strings.Split(strings.TrimPrefix(path, "/"), "/")
	if len(parts) < 2 || parts[0] != "todos" {
		return 0, errors.New("bad path")
	}
	id, err := strconv.Atoi(parts[1])
	if err != nil || id <= 0 {
		return 0, errors.New("bad id")
	}
	return id, nil
}

func (s *Server) handleTodoByID(w http.ResponseWriter, r *http.Request, user *internalUser) {
	id, err := s.parseTodoIDFromPath(r.URL.Path)
	if err != nil {
		writeError(w, http.StatusNotFound, "Todo not found")
		return
	}
	s.mu.RLock()
	t := s.todosByID[id]
	s.mu.RUnlock()
	if t == nil || t.UserID != user.ID {
		writeError(w, http.StatusNotFound, "Todo not found")
		return
	}
	switch r.Method {
	case http.MethodGet:
		writeJSON(w, http.StatusOK, t)
	case http.MethodPut:
		defer r.Body.Close()
		var input struct {
			Title       *string `json:"title"`
			Description *string `json:"description"`
			Completed   *bool   `json:"completed"`
		}
		if err := json.NewDecoder(r.Body).Decode(&input); err != nil {
			writeError(w, http.StatusBadRequest, "Invalid JSON")
			return
		}
		if input.Title != nil && strings.TrimSpace(*input.Title) == "" {
			writeError(w, http.StatusBadRequest, "Title is required")
			return
		}
		s.mu.Lock()
		if input.Title != nil {
			t.Title = strings.TrimSpace(*input.Title)
		}
		if input.Description != nil {
			t.Description = *input.Description
		}
		if input.Completed != nil {
			t.Completed = *input.Completed
		}
		t.UpdatedAt = nowISO8601()
		s.mu.Unlock()
		writeJSON(w, http.StatusOK, t)
	case http.MethodDelete:
		s.mu.Lock()
		delete(s.todosByID, id)
		s.mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusNoContent)
	default:
		writeError(w, http.StatusNotFound, "Not found")
	}
}

var usernameRe = regexp.MustCompile(`^[a-zA-Z0-9_]{3,50}$`)

func validUsername(u string) bool { return usernameRe.MatchString(u) }

func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	// Ensure JSON content type on all responses except 204 handled in delete
	// We'll set default here; specific helpers also set it.
	w.Header().Set("Content-Type", "application/json")

	path := r.URL.Path
	switch {
	case r.Method == http.MethodPost && path == "/register":
		s.handleRegister(w, r)
	case r.Method == http.MethodPost && path == "/login":
		s.handleLogin(w, r)
	case path == "/logout":
		s.requireAuth(s.handleLogout)(w, r)
	case path == "/me":
		s.requireAuth(s.handleMe)(w, r)
	case path == "/password":
		s.requireAuth(s.handlePassword)(w, r)
	case path == "/todos" || path == "/todos/":
		s.requireAuth(s.handleTodos)(w, r)
	case strings.HasPrefix(path, "/todos/"):
		s.requireAuth(s.handleTodoByID)(w, r)
	default:
		writeError(w, http.StatusNotFound, "Not found")
	}
}

func main() {
	var port int
	flag.IntVar(&port, "port", 8080, "port to listen on")
	flag.Parse()

	addr := fmt.Sprintf("0.0.0.0:%d", port)
	srv := &http.Server{Addr: addr, Handler: NewServer()}
	log.Printf("listening on %s", addr)
	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatalf("server error: %v", err)
	}
}
