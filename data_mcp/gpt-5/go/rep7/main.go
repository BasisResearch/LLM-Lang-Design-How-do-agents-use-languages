package main

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
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
}

type userRecord struct {
	User
	Salt         []byte
	PasswordHash []byte
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
	usersByID   map[int]*userRecord
	usersByName map[string]*userRecord
	nextUserID  int
	sessions    map[string]int // session token -> userID
	todosByID   map[int]*Todo
	userTodos   map[int]map[int]*Todo // userID -> todoID -> *Todo
	nextTodoID  int
}

func NewStore() *Store {
	return &Store{
		usersByID:   make(map[int]*userRecord),
		usersByName: make(map[string]*userRecord),
		sessions:    make(map[string]int),
		todosByID:   make(map[int]*Todo),
		userTodos:  make(map[int]map[int]*Todo),
		nextUserID:  1,
		nextTodoID:  1,
	}
}

func nowISO8601() string {
	return time.Now().UTC().Format("2006-01-02T15:04:05Z")
}

func randBytes(n int) []byte {
	b := make([]byte, n)
	if _, err := io.ReadFull(rand.Reader, b); err != nil {
		panic(err)
	}
	return b
}

func hashPassword(password string, salt []byte) []byte {
	h := sha256.New()
	h.Write(salt)
	h.Write([]byte(password))
	return h.Sum(nil)
}

func (s *Store) createUser(username, password string) (*User, error) {
	if _, exists := s.usersByName[username]; exists {
		return nil, fmt.Errorf("username exists")
	}
	salt := randBytes(16)
	hash := hashPassword(password, salt)
	u := &userRecord{User: User{ID: s.nextUserID, Username: username}, Salt: salt, PasswordHash: hash}
	s.usersByID[u.ID] = u
	s.usersByName[username] = u
	s.nextUserID++
	return &u.User, nil
}

func (s *Store) authenticate(username, password string) (*User, error) {
	rec, ok := s.usersByName[username]
	if !ok {
		return nil, errors.New("invalid")
	}
	expected := rec.PasswordHash
	actual := hashPassword(password, rec.Salt)
	if subtle.ConstantTimeCompare(expected, actual) != 1 {
		return nil, errors.New("invalid")
	}
	return &rec.User, nil
}

func (s *Store) setPassword(userID int, newPassword string) error {
	rec, ok := s.usersByID[userID]
	if !ok {
		return errors.New("user not found")
	}
	rec.Salt = randBytes(16)
	rec.PasswordHash = hashPassword(newPassword, rec.Salt)
	return nil
}

func (s *Store) createSession(userID int) string {
	b := randBytes(16)
	tok := hex.EncodeToString(b)
	s.sessions[tok] = userID
	return tok
}

func (s *Store) getUserBySession(token string) (*User, bool) {
	uid, ok := s.sessions[token]
	if !ok {
		return nil, false
	}
	u, ok := s.usersByID[uid]
	if !ok {
		return nil, false
	}
	return &u.User, true
}

func (s *Store) invalidateSession(token string) {
	delete(s.sessions, token)
}

func (s *Store) createTodo(userID int, title, description string) *Todo {
	now := nowISO8601()
	t := &Todo{
		ID:          s.nextTodoID,
		Title:       title,
		Description: description,
		Completed:   false,
		CreatedAt:   now,
		UpdatedAt:   now,
		UserID:      userID,
	}
	s.todosByID[t.ID] = t
	if _, ok := s.userTodos[userID]; !ok {
		s.userTodos[userID] = make(map[int]*Todo)
	}
	s.userTodos[userID][t.ID] = t
	s.nextTodoID++
	return t
}

func (s *Store) listTodos(userID int) []*Todo {
	list := make([]*Todo, 0)
	for _, t := range s.userTodos[userID] {
		list = append(list, t)
	}
	sort.Slice(list, func(i, j int) bool { return list[i].ID < list[j].ID })
	return list
}

func (s *Store) getTodo(userID, todoID int) (*Todo, bool) {
	t, ok := s.todosByID[todoID]
	if !ok || t.UserID != userID {
		return nil, false
	}
	return t, true
}

func (s *Store) updateTodo(todo *Todo, title *string, desc *string, completed *bool) {
	if title != nil {
		todo.Title = *title
	}
	if desc != nil {
		todo.Description = *desc
	}
	if completed != nil {
		todo.Completed = *completed
	}
	todo.UpdatedAt = nowISO8601()
}

func (s *Store) deleteTodo(userID, todoID int) bool {
	t, ok := s.todosByID[todoID]
	if !ok || t.UserID != userID {
		return false
	}
	delete(s.todosByID, todoID)
	if umap, ok := s.userTodos[userID]; ok {
		delete(umap, todoID)
	}
	return true
}

// Server and handlers

type Server struct {
	store *Store
}

func NewServer() *Server {
	return &Server{store: NewStore()}
}

var usernameRe = regexp.MustCompile(`^[a-zA-Z0-9_]{3,50}$`)

func writeJSON(w http.ResponseWriter, status int, v interface{}) {
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

func parseJSON(w http.ResponseWriter, r *http.Request, dst interface{}) bool {
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(dst); err != nil {
		writeError(w, http.StatusBadRequest, "Invalid JSON")
		return false
	}
	return true
}

func (s *Server) requireAuth(next func(http.ResponseWriter, *http.Request, *User, string)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		cookie, err := r.Cookie("session_id")
		if err != nil || cookie.Value == "" {
			writeError(w, http.StatusUnauthorized, "Authentication required")
			return
		}
		s.store.mu.RLock()
		user, ok := s.store.getUserBySession(cookie.Value)
		s.store.mu.RUnlock()
		if !ok {
			writeError(w, http.StatusUnauthorized, "Authentication required")
			return
		}
		next(w, r, user, cookie.Value)
	}
}

// Handlers

func (s *Server) handleRegister(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "Method not allowed")
		return
	}
	var req struct{ Username, Password string }
	if !parseJSON(w, r, &req) {
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
	user, err := s.store.createUser(req.Username, req.Password)
	if err != nil {
		log.Println("createUser error:", err)
		writeError(w, http.StatusInternalServerError, "Internal server error")
		return
	}
	writeJSON(w, http.StatusCreated, user)
}

func (s *Server) handleLogin(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "Method not allowed")
		return
	}
	var req struct{ Username, Password string }
	if !parseJSON(w, r, &req) {
		return
	}
	s.store.mu.Lock()
	defer s.store.mu.Unlock()
	user, err := s.store.authenticate(req.Username, req.Password)
	if err != nil {
		// avoid timing attacks revealing presence of username
		_ = subtle.ConstantTimeCompare([]byte("a"), []byte("a"))
		writeError(w, http.StatusUnauthorized, "Invalid credentials")
		return
	}
	tok := s.store.createSession(user.ID)
	cookie := &http.Cookie{
		Name:     "session_id",
		Value:    tok,
		Path:     "/",
		HttpOnly: true,
	}
	http.SetCookie(w, cookie)
	writeJSON(w, http.StatusOK, user)
}

func (s *Server) handleLogout(w http.ResponseWriter, r *http.Request, user *User, token string) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "Method not allowed")
		return
	}
	s.store.mu.Lock()
	s.store.invalidateSession(token)
	s.store.mu.Unlock()
	writeJSON(w, http.StatusOK, map[string]interface{}{})
}

func (s *Server) handleMe(w http.ResponseWriter, r *http.Request, user *User, token string) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "Method not allowed")
		return
	}
	writeJSON(w, http.StatusOK, user)
}

func (s *Server) handlePassword(w http.ResponseWriter, r *http.Request, user *User, token string) {
	if r.Method != http.MethodPut {
		writeError(w, http.StatusMethodNotAllowed, "Method not allowed")
		return
	}
	var req struct {
		Old string `json:"old_password"`
		New string `json:"new_password"`
	}
	if !parseJSON(w, r, &req) {
		return
	}
	if len(req.New) < 8 {
		writeError(w, http.StatusBadRequest, "Password too short")
		return
	}
	s.store.mu.Lock()
	defer s.store.mu.Unlock()
	rec := s.store.usersByID[user.ID]
	expected := rec.PasswordHash
	actual := hashPassword(req.Old, rec.Salt)
	if subtle.ConstantTimeCompare(expected, actual) != 1 {
		writeError(w, http.StatusUnauthorized, "Invalid credentials")
		return
	}
	if err := s.store.setPassword(user.ID, req.New); err != nil {
		writeError(w, http.StatusInternalServerError, "Internal server error")
		return
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{})
}

func (s *Server) handleTodos(w http.ResponseWriter, r *http.Request, user *User, token string) {
	s.store.mu.Lock()
	defer s.store.mu.Unlock()
	switch r.Method {
	case http.MethodGet:
		list := s.store.listTodos(user.ID)
		writeJSON(w, http.StatusOK, list)
	case http.MethodPost:
		var req struct {
			Title       *string `json:"title"`
			Description *string `json:"description"`
		}
		if !parseJSON(w, r, &req) {
			return
		}
		if req.Title == nil || strings.TrimSpace(*req.Title) == "" {
			writeError(w, http.StatusBadRequest, "Title is required")
			return
		}
		desc := ""
		if req.Description != nil {
			desc = *req.Description
		}
		t := s.store.createTodo(user.ID, strings.TrimSpace(*req.Title), desc)
		writeJSON(w, http.StatusCreated, t)
	default:
		writeError(w, http.StatusMethodNotAllowed, "Method not allowed")
	}
}

func (s *Server) handleTodoByID(w http.ResponseWriter, r *http.Request, user *User, token string) {
	// path: /todos/:id
	idStr := strings.TrimPrefix(r.URL.Path, "/todos/")
	id, err := strconv.Atoi(idStr)
	if err != nil || id <= 0 {
		writeError(w, http.StatusNotFound, "Todo not found")
		return
	}
	s.store.mu.Lock()
	defer s.store.mu.Unlock()
	switch r.Method {
	case http.MethodGet:
		if t, ok := s.store.getTodo(user.ID, id); ok {
			writeJSON(w, http.StatusOK, t)
			return
		}
		writeError(w, http.StatusNotFound, "Todo not found")
	case http.MethodPut:
		var req struct {
			Title       *string `json:"title"`
			Description *string `json:"description"`
			Completed   *bool   `json:"completed"`
		}
		if !parseJSON(w, r, &req) {
			return
		}
		t, ok := s.store.getTodo(user.ID, id)
		if !ok {
			writeError(w, http.StatusNotFound, "Todo not found")
			return
		}
		if req.Title != nil && strings.TrimSpace(*req.Title) == "" {
			writeError(w, http.StatusBadRequest, "Title is required")
			return
		}
		title := req.Title
		if title != nil {
			trim := strings.TrimSpace(*title)
			title = &trim
		}
		s.store.updateTodo(t, title, req.Description, req.Completed)
		writeJSON(w, http.StatusOK, t)
	case http.MethodDelete:
		if ok := s.store.deleteTodo(user.ID, id); !ok {
			writeError(w, http.StatusNotFound, "Todo not found")
			return
		}
		w.WriteHeader(http.StatusNoContent)
	default:
		writeError(w, http.StatusMethodNotAllowed, "Method not allowed")
	}
}

func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	// route
	if r.URL.Path == "/register" {
		s.handleRegister(w, r)
		return
	}
	if r.URL.Path == "/login" {
		s.handleLogin(w, r)
		return
	}
	if r.URL.Path == "/logout" {
		s.requireAuth(s.handleLogout)(w, r)
		return
	}
	if r.URL.Path == "/me" {
		s.requireAuth(s.handleMe)(w, r)
		return
	}
	if r.URL.Path == "/password" {
		s.requireAuth(s.handlePassword)(w, r)
		return
	}
	if r.URL.Path == "/todos" {
		s.requireAuth(s.handleTodos)(w, r)
		return
	}
	if strings.HasPrefix(r.URL.Path, "/todos/") {
		s.requireAuth(s.handleTodoByID)(w, r)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	writeError(w, http.StatusNotFound, "Not found")
}

func main() {
	port := 0
	flag.IntVar(&port, "port", 8080, "port to listen on")
	flag.Parse()
	if port <= 0 || port > 65535 {
		fmt.Fprintln(os.Stderr, "invalid port")
		os.Exit(1)
	}
	srv := &http.Server{
		Addr:    fmt.Sprintf("0.0.0.0:%d", port),
		Handler: NewServer(),
	}
	log.Printf("listening on %s\n", srv.Addr)
	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}
