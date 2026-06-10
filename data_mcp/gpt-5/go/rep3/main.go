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

	"golang.org/x/crypto/bcrypt"
)

const (
	cookieName = "session_id"
	isoLayout  = "2006-01-02T15:04:05Z"
)

type User struct {
	ID       int    `json:"id"`
	Username string `json:"username"`
	// internal only
	PasswordHash []byte `json:"-"`
}

type Todo struct {
	ID          int    `json:"id"`
	Title       string `json:"title"`
	Description string `json:"description"`
	Completed   bool   `json:"completed"`
	CreatedAt   string `json:"created_at"`
	UpdatedAt   string `json:"updated_at"`
	// internal
	UserID int `json:"-"`
}

type Store struct {
	mu             sync.RWMutex
	nextUserID     int
	nextTodoID     int
	usersByID      map[int]*User
	usersByName    map[string]*User
	sessions       map[string]int // token -> userID
	todosByID      map[int]*Todo
}

func NewStore() *Store {
	return &Store{
		nextUserID:  1,
		nextTodoID:  1,
		usersByID:   make(map[int]*User),
		usersByName: make(map[string]*User),
		sessions:    make(map[string]int),
		todosByID:   make(map[int]*Todo),
	}
}

// Helpers
func writeJSON(w http.ResponseWriter, status int, v interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	enc := json.NewEncoder(w)
	_ = enc.Encode(v)
}

func writeError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}

func generateToken(n int) (string, error) {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

var usernameRE = regexp.MustCompile(`^[a-zA-Z0-9_]{3,50}$`)

func validateUsername(u string) bool {
	if len(u) < 3 || len(u) > 50 {
		return false
	}
	return usernameRE.MatchString(u)
}

func validatePassword(p string) bool {
	return len(p) >= 8
}

// Authentication helpers
func (s *Store) getUserFromRequest(r *http.Request) (*User, string) {
	cookie, err := r.Cookie(cookieName)
	if err != nil || cookie.Value == "" {
		return nil, ""
	}
	// lookup session
	s.mu.RLock()
	uid, ok := s.sessions[cookie.Value]
	s.mu.RUnlock()
	if !ok {
		return nil, cookie.Value
	}
	s.mu.RLock()
	u := s.usersByID[uid]
	s.mu.RUnlock()
	return u, cookie.Value
}

func (s *Store) requireAuth(w http.ResponseWriter, r *http.Request) (*User, string, bool) {
	u, token := s.getUserFromRequest(r)
	if u == nil {
		writeError(w, http.StatusUnauthorized, "Authentication required")
		return nil, token, false
	}
	return u, token, true
}

// Handlers
func (s *Store) handleRegister(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusNotFound, "Not found")
		return
	}
	var req struct {
		Username string `json:"username"`
		Password string `json:"password"`
	}
	dec := json.NewDecoder(r.Body)
	if err := dec.Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "Invalid JSON")
		return
	}
	if !validateUsername(req.Username) {
		writeError(w, http.StatusBadRequest, "Invalid username")
		return
	}
	if !validatePassword(req.Password) {
		writeError(w, http.StatusBadRequest, "Password too short")
		return
	}
	hash, err := bcrypt.GenerateFromPassword([]byte(req.Password), bcrypt.DefaultCost)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "Internal server error")
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, exists := s.usersByName[req.Username]; exists {
		writeError(w, http.StatusConflict, "Username already exists")
		return
	}
	id := s.nextUserID
	s.nextUserID++
	u := &User{ID: id, Username: req.Username, PasswordHash: hash}
	s.usersByID[id] = u
	s.usersByName[req.Username] = u
	writeJSON(w, http.StatusCreated, map[string]interface{}{"id": u.ID, "username": u.Username})
}

func (s *Store) handleLogin(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusNotFound, "Not found")
		return
	}
	var req struct {
		Username string `json:"username"`
		Password string `json:"password"`
	}
	dec := json.NewDecoder(r.Body)
	if err := dec.Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "Invalid JSON")
		return
	}
	s.mu.RLock()
	u := s.usersByName[req.Username]
	s.mu.RUnlock()
	if u == nil || bcrypt.CompareHashAndPassword(u.PasswordHash, []byte(req.Password)) != nil {
		writeError(w, http.StatusUnauthorized, "Invalid credentials")
		return
	}
	tok, err := generateToken(32)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "Internal server error")
		return
	}
	s.mu.Lock()
	s.sessions[tok] = u.ID
	s.mu.Unlock()
	cookie := &http.Cookie{Name: cookieName, Value: tok, Path: "/", HttpOnly: true}
	http.SetCookie(w, cookie)
	writeJSON(w, http.StatusOK, map[string]interface{}{"id": u.ID, "username": u.Username})
}

func (s *Store) handleLogout(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusNotFound, "Not found")
		return
	}
	u, token, ok := s.requireAuth(w, r)
	_ = u
	if !ok {
		return
	}
	if token != "" {
		s.mu.Lock()
		delete(s.sessions, token)
		s.mu.Unlock()
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{})
}

func (s *Store) handleMe(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusNotFound, "Not found")
		return
	}
	u, _, ok := s.requireAuth(w, r)
	if !ok {
		return
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{"id": u.ID, "username": u.Username})
}

func (s *Store) handlePassword(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPut {
		writeError(w, http.StatusNotFound, "Not found")
		return
	}
	u, _, ok := s.requireAuth(w, r)
	if !ok {
		return
	}
	var req struct {
		OldPassword string `json:"old_password"`
		NewPassword string `json:"new_password"`
	}
	dec := json.NewDecoder(r.Body)
	if err := dec.Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "Invalid JSON")
		return
	}
	if bcrypt.CompareHashAndPassword(u.PasswordHash, []byte(req.OldPassword)) != nil {
		writeError(w, http.StatusUnauthorized, "Invalid credentials")
		return
	}
	if !validatePassword(req.NewPassword) {
		writeError(w, http.StatusBadRequest, "Password too short")
		return
	}
	hash, err := bcrypt.GenerateFromPassword([]byte(req.NewPassword), bcrypt.DefaultCost)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "Internal server error")
		return
	}
	s.mu.Lock()
	u.PasswordHash = hash
	s.mu.Unlock()
	writeJSON(w, http.StatusOK, map[string]interface{}{})
}

func (s *Store) handleTodos(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		s.listTodos(w, r)
	case http.MethodPost:
		s.createTodo(w, r)
	default:
		writeError(w, http.StatusNotFound, "Not found")
	}
}

func nowISO() string {
	return time.Now().UTC().Format(isoLayout)
}

func (s *Store) listTodos(w http.ResponseWriter, r *http.Request) {
	u, _, ok := s.requireAuth(w, r)
	if !ok {
		return
	}
	// Gather todos for user
	s.mu.RLock()
	list := make([]*Todo, 0)
	for _, t := range s.todosByID {
		if t.UserID == u.ID {
			// copy struct to avoid exposing internal pointer that may be modified concurrently
			copy := *t
			list = append(list, &copy)
		}
	}
	s.mu.RUnlock()
	sort.Slice(list, func(i, j int) bool { return list[i].ID < list[j].ID })
	writeJSON(w, http.StatusOK, list)
}

func (s *Store) createTodo(w http.ResponseWriter, r *http.Request) {
	u, _, ok := s.requireAuth(w, r)
	if !ok {
		return
	}
	var req struct {
		Title       string `json:"title"`
		Description string `json:"description"`
	}
	dec := json.NewDecoder(r.Body)
	if err := dec.Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "Invalid JSON")
		return
	}
	if strings.TrimSpace(req.Title) == "" {
		writeError(w, http.StatusBadRequest, "Title is required")
		return
	}
	if req.Description == "" {
		// default to empty string already
	}
	created := nowISO()
	s.mu.Lock()
	id := s.nextTodoID
	s.nextTodoID++
	t := &Todo{
		ID:          id,
		Title:       req.Title,
		Description: req.Description,
		Completed:   false,
		CreatedAt:   created,
		UpdatedAt:   created,
		UserID:      u.ID,
	}
	s.todosByID[id] = t
	s.mu.Unlock()
	writeJSON(w, http.StatusCreated, t)
}

func parseTodoID(path string) (int, error) {
	// Expect /todos/:id exactly, no trailing segments
	parts := strings.Split(strings.Trim(path, "/"), "/")
	if len(parts) != 2 || parts[0] != "todos" {
		return 0, errors.New("not a todo item path")
	}
	id, err := strconv.Atoi(parts[1])
	if err != nil {
		return 0, err
	}
	return id, nil
}

func (s *Store) handleTodoItem(w http.ResponseWriter, r *http.Request) {
	id, err := parseTodoID(r.URL.Path)
	if err != nil {
		writeError(w, http.StatusNotFound, "Not found")
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
		writeError(w, http.StatusNotFound, "Not found")
	}
}

func (s *Store) findUserTodo(u *User, id int) (*Todo, bool) {
	s.mu.RLock()
	t, ok := s.todosByID[id]
	if ok && t.UserID != u.ID {
		ok = false
		t = nil
	}
	s.mu.RUnlock()
	return t, ok
}

func (s *Store) getTodo(w http.ResponseWriter, r *http.Request, id int) {
	u, _, ok := s.requireAuth(w, r)
	if !ok {
		return
	}
	t, ok := s.findUserTodo(u, id)
	if !ok {
		writeError(w, http.StatusNotFound, "Todo not found")
		return
	}
	// return a copy
	copy := *t
	writeJSON(w, http.StatusOK, &copy)
}

func (s *Store) updateTodo(w http.ResponseWriter, r *http.Request, id int) {
	u, _, ok := s.requireAuth(w, r)
	if !ok {
		return
	}
	// check existence/ownership
	s.mu.RLock()
	t, exists := s.todosByID[id]
	ownerOK := exists && t.UserID == u.ID
	s.mu.RUnlock()
	if !ownerOK {
		writeError(w, http.StatusNotFound, "Todo not found")
		return
	}
	// decode into map to detect presence
	var raw map[string]json.RawMessage
	dec := json.NewDecoder(r.Body)
	if err := dec.Decode(&raw); err != nil {
		writeError(w, http.StatusBadRequest, "Invalid JSON")
		return
	}
	var newTitle *string
	var newDesc *string
	var newCompleted *bool
	if v, ok := raw["title"]; ok {
		var sVal string
		if err := json.Unmarshal(v, &sVal); err != nil {
			writeError(w, http.StatusBadRequest, "Invalid JSON")
			return
		}
		if strings.TrimSpace(sVal) == "" {
			writeError(w, http.StatusBadRequest, "Title is required")
			return
		}
		newTitle = &sVal
	}
	if v, ok := raw["description"]; ok {
		var sVal string
		if err := json.Unmarshal(v, &sVal); err != nil {
			writeError(w, http.StatusBadRequest, "Invalid JSON")
			return
		}
		newDesc = &sVal
	}
	if v, ok := raw["completed"]; ok {
		var bVal bool
		if err := json.Unmarshal(v, &bVal); err != nil {
			writeError(w, http.StatusBadRequest, "Invalid JSON")
			return
		}
		newCompleted = &bVal
	}
	// apply updates
	s.mu.Lock()
	if newTitle != nil {
		t.Title = *newTitle
	}
	if newDesc != nil {
		t.Description = *newDesc
	}
	if newCompleted != nil {
		t.Completed = *newCompleted
	}
	t.UpdatedAt = nowISO()
	s.mu.Unlock()
	// return copy
	copy := *t
	writeJSON(w, http.StatusOK, &copy)
}

func (s *Store) deleteTodo(w http.ResponseWriter, r *http.Request, id int) {
	u, _, ok := s.requireAuth(w, r)
	if !ok {
		return
	}
	s.mu.Lock()
	t, exists := s.todosByID[id]
	if !exists || t.UserID != u.ID {
		s.mu.Unlock()
		// Return 404 with JSON error
		writeError(w, http.StatusNotFound, "Todo not found")
		return
	}
	delete(s.todosByID, id)
	s.mu.Unlock()
	// DELETE success: 204 no body
	w.WriteHeader(http.StatusNoContent)
}

// Custom mux
type apiServer struct {
	store *Store
	mux   *http.ServeMux
}

func newAPIServer(store *Store) *apiServer {
	mux := http.NewServeMux()
	s := &apiServer{store: store, mux: mux}
	mux.HandleFunc("/register", store.handleRegister)
	mux.HandleFunc("/login", store.handleLogin)
	mux.HandleFunc("/logout", store.handleLogout)
	mux.HandleFunc("/me", store.handleMe)
	mux.HandleFunc("/password", store.handlePassword)
	// Route /todos and /todos/:id using separate patterns
	mux.HandleFunc("/todos", store.handleTodos)
	mux.HandleFunc("/todos/", store.handleTodoItem)
	// NotFound handler override
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		writeError(w, http.StatusNotFound, "Not found")
	})
	return s
}

func (s *apiServer) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	// Ensure content-type for all JSON responses. We'll set in handlers when writing.
	s.mux.ServeHTTP(w, r)
}

func main() {
	port := flag.Int("port", 8080, "port to listen on")
	flag.Parse()
	addr := fmt.Sprintf("0.0.0.0:%d", *port)
	store := NewStore()
	server := newAPIServer(store)
	// Use a server with reasonable timeouts
	hs := &http.Server{
		Addr:              addr,
		Handler:           server,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      10 * time.Second,
		IdleTimeout:       60 * time.Second,
	}
	log.Printf("Server listening on %s", addr)
	if err := hs.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatalf("server error: %v", err)
	}
}
