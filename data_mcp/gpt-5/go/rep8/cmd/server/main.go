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

type User struct {
	ID       int    `json:"id"`
	Username string `json:"username"`
	// password is stored as hash; for simplicity in-memory plain string is acceptable here
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

type Server struct {
	mu sync.Mutex

	usersByID    map[int]*User
	usersByName  map[string]*User
	sessions     map[string]int // session token -> userID
	userSeq      int

	todosByID map[int]*Todo
	todoSeq   int
}

func NewServer() *Server {
	return &Server{
		usersByID:   make(map[int]*User),
		usersByName: make(map[string]*User),
		sessions:    make(map[string]int),
		todosByID:   make(map[int]*Todo),
	}
}

func writeJSON(w http.ResponseWriter, status int, v interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if v != nil {
		enc := json.NewEncoder(w)
		enc.SetEscapeHTML(false)
		_ = enc.Encode(v)
	}
}

func writeError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}

var usernameRE = regexp.MustCompile(`^[a-zA-Z0-9_]{3,50}$`)

func parseJSONBody(r *http.Request, dst interface{}) error {
	if r.Body == nil {
		return errors.New("empty body")
	}
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(dst); err != nil {
		return err
	}
	// ensure no extra data
	if dec.More() {
		return errors.New("invalid body")
	}
	return nil
}

func (s *Server) generateToken() (string, error) {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

func isoNow() string {
	return time.Now().UTC().Truncate(time.Second).Format(time.RFC3339)
}

func (s *Server) withAuth(handler func(http.ResponseWriter, *http.Request, *User)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		cookie, err := r.Cookie("session_id")
		if err != nil || cookie.Value == "" {
			writeError(w, http.StatusUnauthorized, "Authentication required")
			return
		}
		s.mu.Lock()
		uid, ok := s.sessions[cookie.Value]
		var user *User
		if ok {
			user = s.usersByID[uid]
		}
		s.mu.Unlock()
		if !ok || user == nil {
			writeError(w, http.StatusUnauthorized, "Authentication required")
			return
		}
		handler(w, r, user)
	}
}

func (s *Server) handleRegister(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "Method not allowed")
		return
	}
	var body struct {
		Username string `json:"username"`
		Password string `json:"password"`
	}
	if err := parseJSONBody(r, &body); err != nil {
		writeError(w, http.StatusBadRequest, "Invalid JSON")
		return
	}
	body.Username = strings.TrimSpace(body.Username)
	if !usernameRE.MatchString(body.Username) {
		writeError(w, http.StatusBadRequest, "Invalid username")
		return
	}
	if len(body.Password) < 8 {
		writeError(w, http.StatusBadRequest, "Password too short")
		return
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	if _, exists := s.usersByName[body.Username]; exists {
		writeError(w, http.StatusConflict, "Username already exists")
		return
	}
	s.userSeq++
	u := &User{ID: s.userSeq, Username: body.Username, Password: body.Password}
	s.usersByID[u.ID] = u
	s.usersByName[u.Username] = u

	writeJSON(w, http.StatusCreated, map[string]interface{}{
		"id":       u.ID,
		"username": u.Username,
	})
}

func (s *Server) handleLogin(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "Method not allowed")
		return
	}
	var body struct {
		Username string `json:"username"`
		Password string `json:"password"`
	}
	if err := parseJSONBody(r, &body); err != nil {
		writeError(w, http.StatusBadRequest, "Invalid JSON")
		return
	}
	body.Username = strings.TrimSpace(body.Username)

	s.mu.Lock()
	u, ok := s.usersByName[body.Username]
	if !ok || u.Password != body.Password {
		s.mu.Unlock()
		writeError(w, http.StatusUnauthorized, "Invalid credentials")
		return
	}
	tok, err := s.generateToken()
	if err != nil {
		s.mu.Unlock()
		writeError(w, http.StatusInternalServerError, "Internal error")
		return
	}
	s.sessions[tok] = u.ID
	s.mu.Unlock()

	cookie := &http.Cookie{Name: "session_id", Value: tok, Path: "/", HttpOnly: true}
	http.SetCookie(w, cookie)
	writeJSON(w, http.StatusOK, map[string]interface{}{
		"id":       u.ID,
		"username": u.Username,
	})
}

func (s *Server) handleLogout(w http.ResponseWriter, r *http.Request, user *User) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "Method not allowed")
		return
	}
	cookie, err := r.Cookie("session_id")
	if err == nil && cookie.Value != "" {
		s.mu.Lock()
		delete(s.sessions, cookie.Value)
		s.mu.Unlock()
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{})
}

func (s *Server) handleMe(w http.ResponseWriter, r *http.Request, user *User) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "Method not allowed")
		return
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{
		"id":       user.ID,
		"username": user.Username,
	})
}

func (s *Server) handlePassword(w http.ResponseWriter, r *http.Request, user *User) {
	if r.Method != http.MethodPut {
		writeError(w, http.StatusMethodNotAllowed, "Method not allowed")
		return
	}
	var body struct {
		OldPassword string `json:"old_password"`
		NewPassword string `json:"new_password"`
	}
	if err := parseJSONBody(r, &body); err != nil {
		writeError(w, http.StatusBadRequest, "Invalid JSON")
		return
	}
	if len(body.NewPassword) < 8 {
		writeError(w, http.StatusBadRequest, "Password too short")
		return
	}
	// verify old password
	s.mu.Lock()
	defer s.mu.Unlock()
	if user.Password != body.OldPassword {
		writeError(w, http.StatusUnauthorized, "Invalid credentials")
		return
	}
	user.Password = body.NewPassword
	writeJSON(w, http.StatusOK, map[string]interface{}{})
}

func (s *Server) handleTodos(w http.ResponseWriter, r *http.Request, user *User) {
	switch r.Method {
	case http.MethodGet:
		s.mu.Lock()
		list := make([]*Todo, 0)
		for _, t := range s.todosByID {
			if t.UserID == user.ID {
				copy := *t
				list = append(list, &copy)
			}
		}
		s.mu.Unlock()
		sort.Slice(list, func(i, j int) bool { return list[i].ID < list[j].ID })
		writeJSON(w, http.StatusOK, list)
	case http.MethodPost:
		var body struct {
			Title       string `json:"title"`
			Description string `json:"description"`
		}
		if err := parseJSONBody(r, &body); err != nil {
			writeError(w, http.StatusBadRequest, "Invalid JSON")
			return
		}
		body.Title = strings.TrimSpace(body.Title)
		if body.Title == "" {
			writeError(w, http.StatusBadRequest, "Title is required")
			return
		}
		if body.Description == "" {
			body.Description = ""
		}
		now := isoNow()
		s.mu.Lock()
		s.todoSeq++
		t := &Todo{
			ID:          s.todoSeq,
			Title:       body.Title,
			Description: body.Description,
			Completed:   false,
			CreatedAt:   now,
			UpdatedAt:   now,
			UserID:      user.ID,
		}
		s.todosByID[t.ID] = t
		s.mu.Unlock()
		writeJSON(w, http.StatusCreated, t)
	default:
		writeError(w, http.StatusMethodNotAllowed, "Method not allowed")
	}
}

func (s *Server) parseTodoID(path string) (int, bool) {
	// Expect path like /todos/:id optionally with trailing slash
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

func (s *Server) handleTodoByID(w http.ResponseWriter, r *http.Request, user *User) {
	id, ok := s.parseTodoID(r.URL.Path)
	if !ok {
		writeError(w, http.StatusNotFound, "Not found")
		return
	}

	s.mu.Lock()
	t, exists := s.todosByID[id]
	if !exists || t.UserID != user.ID {
		s.mu.Unlock()
		writeError(w, http.StatusNotFound, "Todo not found")
		return
	}

	switch r.Method {
	case http.MethodGet:
		copy := *t
		s.mu.Unlock()
		writeJSON(w, http.StatusOK, &copy)
	case http.MethodPut:
		var body struct {
			Title       *string `json:"title"`
			Description *string `json:"description"`
			Completed   *bool   `json:"completed"`
		}
		if err := parseJSONBody(r, &body); err != nil {
			s.mu.Unlock()
			writeError(w, http.StatusBadRequest, "Invalid JSON")
			return
		}
		if body.Title != nil {
			trim := strings.TrimSpace(*body.Title)
			if trim == "" {
				s.mu.Unlock()
				writeError(w, http.StatusBadRequest, "Title is required")
				return
			}
			t.Title = trim
		}
		if body.Description != nil {
			t.Description = *body.Description
		}
		if body.Completed != nil {
			t.Completed = *body.Completed
		}
		t.UpdatedAt = isoNow()
		copy := *t
		s.mu.Unlock()
		writeJSON(w, http.StatusOK, &copy)
	case http.MethodDelete:
		delete(s.todosByID, id)
		s.mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusNoContent)
		// no body
	default:
		s.mu.Unlock()
		writeError(w, http.StatusMethodNotAllowed, "Method not allowed")
	}
}

func (s *Server) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/register", s.handleRegister)
	mux.HandleFunc("/login", s.handleLogin)
	mux.HandleFunc("/logout", s.withAuth(s.handleLogout))
	mux.HandleFunc("/me", s.withAuth(s.handleMe))
	mux.HandleFunc("/password", s.withAuth(s.handlePassword))
	// Todos collection and individual
	mux.HandleFunc("/todos", s.withAuth(s.handleTodos))
	mux.HandleFunc("/todos/", s.withAuth(s.handleTodoByID))
	// catch-all for invalid paths to ensure JSON content type
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		writeError(w, http.StatusNotFound, "Not found")
	})
	return loggingMiddleware(mux)
}

func loggingMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		next.ServeHTTP(w, r)
		log.Printf("%s %s %s", r.Method, r.URL.Path, time.Since(start))
	})
}

func main() {
	port := flag.Int("port", 8080, "port to listen on")
	flag.Parse()
	addr := fmt.Sprintf("0.0.0.0:%d", *port)
	server := NewServer()
	log.Printf("listening on %s", addr)
	if err := http.ListenAndServe(addr, server.routes()); err != nil {
		log.Fatal(err)
	}
}
