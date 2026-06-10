package main

import (
	"bytes"
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

// Data models

type User struct {
	ID           int    `json:"id"`
	Username     string `json:"username"`
	PasswordHash []byte `json:"-"`
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
	mu sync.RWMutex

	usersByID       map[int]*User
	usersByUsername map[string]*User
	nextUserID      int

	todosByID  map[int]*Todo
	nextTodoID int

	sessions map[string]int
}

func NewServer() *Server {
	return &Server{
		usersByID:       make(map[int]*User),
		usersByUsername: make(map[string]*User),
		nextUserID:      1,
		todosByID:       make(map[int]*Todo),
		nextTodoID:      1,
		sessions:        make(map[string]int),
	}
}

func (s *Server) now() string {
	return time.Now().UTC().Format("2006-01-02T15:04:05Z")
}

func (s *Server) writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if v == nil {
		return
	}
	enc := json.NewEncoder(w)
	enc.SetEscapeHTML(true)
	_ = enc.Encode(v)
}

func (s *Server) writeError(w http.ResponseWriter, status int, msg string) {
	s.writeJSON(w, status, map[string]string{"error": msg})
}

const SessionCookieName = "session_id"

func (s *Server) createSession(userID int) (string, error) {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	token := hex.EncodeToString(b)
	s.mu.Lock()
	s.sessions[token] = userID
	s.mu.Unlock()
	return token, nil
}

func (s *Server) getUserFromRequest(r *http.Request) (*User, error) {
	c, err := r.Cookie(SessionCookieName)
	if err != nil || c == nil || c.Value == "" {
		return nil, errors.New("auth required")
	}
	s.mu.RLock()
	uid, ok := s.sessions[c.Value]
	if !ok {
		s.mu.RUnlock()
		return nil, errors.New("auth required")
	}
	user := s.usersByID[uid]
	s.mu.RUnlock()
	if user == nil {
		return nil, errors.New("auth required")
	}
	return user, nil
}

func (s *Server) invalidateSession(r *http.Request) {
	c, err := r.Cookie(SessionCookieName)
	if err != nil || c == nil || c.Value == "" {
		return
	}
	s.mu.Lock()
	delete(s.sessions, c.Value)
	s.mu.Unlock()
}

// lenientToJSON attempts to transform relaxed JSON like {username:user_1} into strict JSON
func lenientToJSON(raw string) string {
	s := strings.TrimSpace(raw)
	// Normalize single quotes -> double quotes
	s = strings.ReplaceAll(s, "'", "\"")
	// Add quotes around keys
	reKey := regexp.MustCompile(`([\{\s,])([a-zA-Z_][a-zA-Z0-9_]*)\s*:`)
	s = reKey.ReplaceAllString(s, `$1"$2":`)
	// Quote bareword string values (excluding numbers, booleans, null)
	reVal := regexp.MustCompile(`:\s*([^\s\"\{\}\[\],][^,\}\s]*)`)
	s = reVal.ReplaceAllStringFunc(s, func(m string) string {
		idx := strings.Index(m, ":")
		val := strings.TrimSpace(m[idx+1:])
		lower := strings.ToLower(val)
		if lower == "true" || lower == "false" || lower == "null" {
			return ":" + val
		}
		if _, err := strconv.ParseFloat(val, 64); err == nil {
			return ":" + val
		}
		if !(strings.HasPrefix(val, "\"") && strings.HasSuffix(val, "\"")) {
			val = "\"" + val + "\""
		}
		return ":" + val
	})
	return s
}

// Safe JSON decoding helper with size cap and improved diagnostics
func decodeJSON[T any](r io.Reader, v *T) error {
	lr := io.LimitReader(r, 1<<20)
	data, err := io.ReadAll(lr)
	if err != nil {
		return err
	}
	raw := string(data)
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	if err := dec.Decode(v); err == nil {
		var extra any
		if err2 := dec.Decode(&extra); err2 == io.EOF {
			return nil
		}
	}
	fixed := lenientToJSON(raw)
	dec2 := json.NewDecoder(strings.NewReader(fixed))
	dec2.DisallowUnknownFields()
	if err2 := dec2.Decode(v); err2 == nil {
		return nil
	}
	log.Printf("decodeJSON failed. raw=%q fixed=%q", raw, fixed)
	return errors.New("invalid json")
}

// Handlers

var usernameRe = regexp.MustCompile(`^[a-zA-Z0-9_]{3,50}$`)

func (s *Server) handleRegister(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		s.writeError(w, http.StatusMethodNotAllowed, "Method not allowed")
		return
	}
	defer r.Body.Close()
	var body struct {
		Username string `json:"username"`
		Password string `json:"password"`
	}
	if err := decodeJSON(r.Body, &body); err != nil {
		s.writeError(w, http.StatusBadRequest, "Invalid JSON")
		return
	}
	if !usernameRe.MatchString(body.Username) {
		s.writeError(w, http.StatusBadRequest, "Invalid username")
		return
	}
	if len(body.Password) < 8 {
		s.writeError(w, http.StatusBadRequest, "Password too short")
		return
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	if _, exists := s.usersByUsername[strings.ToLower(body.Username)]; exists {
		s.writeError(w, http.StatusConflict, "Username already exists")
		return
	}
	hash, err := bcrypt.GenerateFromPassword([]byte(body.Password), bcrypt.DefaultCost)
	if err != nil {
		s.writeError(w, http.StatusInternalServerError, "Server error")
		return
	}
	user := &User{ID: s.nextUserID, Username: body.Username, PasswordHash: hash}
	s.usersByID[user.ID] = user
	s.usersByUsername[strings.ToLower(user.Username)] = user
	s.nextUserID++

	s.writeJSON(w, http.StatusCreated, map[string]any{"id": user.ID, "username": user.Username})
}

func (s *Server) handleLogin(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		s.writeError(w, http.StatusMethodNotAllowed, "Method not allowed")
		return
	}
	defer r.Body.Close()
	var body struct {
		Username string `json:"username"`
		Password string `json:"password"`
	}
	if err := decodeJSON(r.Body, &body); err != nil {
		s.writeError(w, http.StatusBadRequest, "Invalid JSON")
		return
	}
	s.mu.RLock()
	user := s.usersByUsername[strings.ToLower(body.Username)]
	s.mu.RUnlock()
	if user == nil || bcrypt.CompareHashAndPassword(user.PasswordHash, []byte(body.Password)) != nil {
		s.writeError(w, http.StatusUnauthorized, "Invalid credentials")
		return
	}
	token, err := s.createSession(user.ID)
	if err != nil {
		s.writeError(w, http.StatusInternalServerError, "Server error")
		return
	}
	cookie := &http.Cookie{Name: SessionCookieName, Value: token, Path: "/", HttpOnly: true}
	http.SetCookie(w, cookie)
	s.writeJSON(w, http.StatusOK, map[string]any{"id": user.ID, "username": user.Username})
}

func (s *Server) requireAuth(next func(http.ResponseWriter, *http.Request, *User)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		user, err := s.getUserFromRequest(r)
		if err != nil {
			s.writeError(w, http.StatusUnauthorized, "Authentication required")
			return
		}
		next(w, r, user)
	}
}

func (s *Server) handleLogout(w http.ResponseWriter, r *http.Request, user *User) {
	if r.Method != http.MethodPost {
		s.writeError(w, http.StatusMethodNotAllowed, "Method not allowed")
		return
	}
	s.invalidateSession(r)
	s.writeJSON(w, http.StatusOK, map[string]any{})
}

func (s *Server) handleMe(w http.ResponseWriter, r *http.Request, user *User) {
	if r.Method != http.MethodGet {
		s.writeError(w, http.StatusMethodNotAllowed, "Method not allowed")
		return
	}
	s.writeJSON(w, http.StatusOK, map[string]any{"id": user.ID, "username": user.Username})
}

func (s *Server) handlePassword(w http.ResponseWriter, r *http.Request, user *User) {
	if r.Method != http.MethodPut {
		s.writeError(w, http.StatusMethodNotAllowed, "Method not allowed")
		return
	}
	defer r.Body.Close()
	var body struct {
		OldPassword string `json:"old_password"`
		NewPassword string `json:"new_password"`
	}
	if err := decodeJSON(r.Body, &body); err != nil {
		s.writeError(w, http.StatusBadRequest, "Invalid JSON")
		return
	}
	if bcrypt.CompareHashAndPassword(user.PasswordHash, []byte(body.OldPassword)) != nil {
		s.writeError(w, http.StatusUnauthorized, "Invalid credentials")
		return
	}
	if len(body.NewPassword) < 8 {
		s.writeError(w, http.StatusBadRequest, "Password too short")
		return
	}
	hash, err := bcrypt.GenerateFromPassword([]byte(body.NewPassword), bcrypt.DefaultCost)
	if err != nil {
		s.writeError(w, http.StatusInternalServerError, "Server error")
		return
	}
	s.mu.Lock()
	user.PasswordHash = hash
	s.mu.Unlock()
	s.writeJSON(w, http.StatusOK, map[string]any{})
}

func (s *Server) listTodos(userID int) []*Todo {
	s.mu.RLock()
	defer s.mu.RUnlock()
	var todos []*Todo
	for _, t := range s.todosByID {
		if t.UserID == userID {
			copy := *t
			todos = append(todos, &copy)
		}
	}
	sort.Slice(todos, func(i, j int) bool { return todos[i].ID < todos[j].ID })
	return todos
}

func (s *Server) handleTodos(w http.ResponseWriter, r *http.Request, user *User) {
	switch r.Method {
	case http.MethodGet:
		s.writeJSON(w, http.StatusOK, s.listTodos(user.ID))
		return
	case http.MethodPost:
		defer r.Body.Close()
		var body struct {
			Title       string `json:"title"`
			Description string `json:"description"`
		}
		if err := decodeJSON(r.Body, &body); err != nil {
			s.writeError(w, http.StatusBadRequest, "Invalid JSON")
			return
		}
		if strings.TrimSpace(body.Title) == "" {
			s.writeError(w, http.StatusBadRequest, "Title is required")
			return
		}
		if body.Description == "" {
			body.Description = ""
		}
		now := s.now()
		s.mu.Lock()
		id := s.nextTodoID
		s.nextTodoID++
		todo := &Todo{ID: id, Title: body.Title, Description: body.Description, Completed: false, CreatedAt: now, UpdatedAt: now, UserID: user.ID}
		s.todosByID[id] = todo
		s.mu.Unlock()
		s.writeJSON(w, http.StatusCreated, todo)
		return
	default:
		s.writeError(w, http.StatusMethodNotAllowed, "Method not allowed")
		return
	}
}

func (s *Server) findTodoForUser(id int, userID int) (*Todo, bool) {
	s.mu.RLock()
	t, ok := s.todosByID[id]
	if ok && t.UserID == userID {
		copy := *t
		s.mu.RUnlock()
		return &copy, true
	}
	s.mu.RUnlock()
	return nil, false
}

func (s *Server) handleTodoByID(w http.ResponseWriter, r *http.Request, user *User) {
	// path: /todos/:id
	parts := strings.Split(strings.Trim(r.URL.Path, "/"), "/")
	if len(parts) != 2 {
		s.writeError(w, http.StatusNotFound, "Not found")
		return
	}
	id, err := strconv.Atoi(parts[1])
	if err != nil || id <= 0 {
		s.writeError(w, http.StatusNotFound, "Todo not found")
		return
	}

	switch r.Method {
	case http.MethodGet:
		if t, ok := s.findTodoForUser(id, user.ID); ok {
			s.writeJSON(w, http.StatusOK, t)
			return
		}
		s.writeError(w, http.StatusNotFound, "Todo not found")
		return
	case http.MethodPut:
		defer r.Body.Close()
		var body struct {
			Title       *string `json:"title"`
			Description *string `json:"description"`
			Completed   *bool   `json:"completed"`
		}
		if err := decodeJSON(r.Body, &body); err != nil {
			s.writeError(w, http.StatusBadRequest, "Invalid JSON")
			return
		}
		s.mu.Lock()
		t, ok := s.todosByID[id]
		if !ok || t.UserID != user.ID {
			s.mu.Unlock()
			s.writeError(w, http.StatusNotFound, "Todo not found")
			return
		}
		if body.Title != nil {
			if strings.TrimSpace(*body.Title) == "" {
				s.mu.Unlock()
				s.writeError(w, http.StatusBadRequest, "Title is required")
				return
			}
			t.Title = *body.Title
		}
		if body.Description != nil {
			t.Description = *body.Description
		}
		if body.Completed != nil {
			t.Completed = *body.Completed
		}
		t.UpdatedAt = s.now()
		updated := *t
		s.mu.Unlock()
		s.writeJSON(w, http.StatusOK, &updated)
		return
	case http.MethodDelete:
		s.mu.Lock()
		t, ok := s.todosByID[id]
		if !ok || t.UserID != user.ID {
			s.mu.Unlock()
			s.writeError(w, http.StatusNotFound, "Todo not found")
			return
		}
		delete(s.todosByID, id)
		s.mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusNoContent)
		return
	default:
		s.writeError(w, http.StatusMethodNotAllowed, "Method not allowed")
		return
	}
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

	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.URL.Path, "/register") || strings.HasPrefix(r.URL.Path, "/login") || strings.HasPrefix(r.URL.Path, "/logout") || strings.HasPrefix(r.URL.Path, "/me") || strings.HasPrefix(r.URL.Path, "/password") || strings.HasPrefix(r.URL.Path, "/todos") {
			mux.ServeHTTP(w, r)
			return
		}
		s.writeError(w, http.StatusNotFound, "Not found")
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
