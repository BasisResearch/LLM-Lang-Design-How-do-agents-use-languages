const express = require('express');
const cookieParser = require('cookie-parser');
const crypto = require('crypto');

const app = express();
app.use(express.json());
app.use(cookieParser());

// In-memory storage
const users = new Map(); // id -> { id, username, password }
const todos = new Map(); // id -> { id, user_id, title, description, completed, created_at, updated_at }
const sessions = new Map(); // token -> user_id

let nextUserId = 1;
let nextTodoId = 1;

// Helper to get ISO8601 UTC string: YYYY-MM-DDTHH:MM:SSZ
function getTimestamp() {
  return new Date().toISOString().slice(0, 19) + 'Z';
}

// Auth middleware
function requireAuth(req, res, next) {
  const token = req.cookies.session_id;
  if (!token || !sessions.has(token)) {
    return res.status(401).json({ error: "Authentication required" });
  }
  req.userId = sessions.get(token);
  next();
}

// POST /register
app.post('/register', (req, res) => {
  const { username, password } = req.body;

  if (!username || !/^[a-zA-Z0-9_]{3,50}$/.test(username)) {
    return res.status(400).json({ error: "Invalid username" });
  }

  if (!password || typeof password !== 'string' || password.length < 8) {
    return res.status(400).json({ error: "Password too short" });
  }

  for (const user of users.values()) {
    if (user.username === username) {
      return res.status(409).json({ error: "Username already exists" });
    }
  }

  const id = nextUserId++;
  const newUser = { id, username, password };
  users.set(id, newUser);

  res.status(201).json({ id, username });
});

// POST /login
app.post('/login', (req, res) => {
  const { username, password } = req.body;

  let foundUser = null;
  for (const user of users.values()) {
    if (user.username === username && user.password === password) {
      foundUser = user;
      break;
    }
  }

  if (!foundUser) {
    return res.status(401).json({ error: "Invalid credentials" });
  }

  const token = crypto.randomUUID();
  sessions.set(token, foundUser.id);

  res.setHeader('Set-Cookie', `session_id=${token}; Path=/; HttpOnly`);
  res.status(200).json({ id: foundUser.id, username: foundUser.username });
});

// POST /logout
app.post('/logout', requireAuth, (req, res) => {
  const token = req.cookies.session_id;
  sessions.delete(token);
  res.status(200).json({});
});

// GET /me
app.get('/me', requireAuth, (req, res) => {
  const user = users.get(req.userId);
  res.status(200).json({ id: user.id, username: user.username });
});

// PUT /password
app.put('/password', requireAuth, (req, res) => {
  const { old_password, new_password } = req.body;
  const user = users.get(req.userId);

  if (!old_password || user.password !== old_password) {
    return res.status(401).json({ error: "Invalid credentials" });
  }

  if (!new_password || typeof new_password !== 'string' || new_password.length < 8) {
    return res.status(400).json({ error: "Password too short" });
  }

  user.password = new_password;
  res.status(200).json({});
});

// GET /todos
app.get('/todos', requireAuth, (req, res) => {
  const userTodos = [];
  for (const todo of todos.values()) {
    if (todo.user_id === req.userId) {
      const { user_id, ...todoWithoutUserId } = todo;
      userTodos.push(todoWithoutUserId);
    }
  }
  userTodos.sort((a, b) => a.id - b.id);
  res.status(200).json(userTodos);
});

// POST /todos
app.post('/todos', requireAuth, (req, res) => {
  const { title, description } = req.body;

  if (!title || typeof title !== 'string' || title.trim() === '') {
    return res.status(400).json({ error: "Title is required" });
  }

  const id = nextTodoId++;
  const now = getTimestamp();
  const newTodo = {
    id,
    user_id: req.userId,
    title,
    description: typeof description === 'string' ? description : "",
    completed: false,
    created_at: now,
    updated_at: now
  };
  todos.set(id, newTodo);

  const { user_id, ...todoWithoutUserId } = newTodo;
  res.status(201).json(todoWithoutUserId);
});

// GET /todos/:id
app.get('/todos/:id', requireAuth, (req, res) => {
  const todoId = parseInt(req.params.id, 10);
  const todo = todos.get(todoId);

  if (!todo || todo.user_id !== req.userId) {
    return res.status(404).json({ error: "Todo not found" });
  }

  const { user_id, ...todoWithoutUserId } = todo;
  res.status(200).json(todoWithoutUserId);
});

// PUT /todos/:id
app.put('/todos/:id', requireAuth, (req, res) => {
  const todoId = parseInt(req.params.id, 10);
  const todo = todos.get(todoId);

  if (!todo || todo.user_id !== req.userId) {
    return res.status(404).json({ error: "Todo not found" });
  }

  const { title, description, completed } = req.body;

  if (title !== undefined && (typeof title !== 'string' || title.trim() === '')) {
    return res.status(400).json({ error: "Title is required" });
  }

  if (title !== undefined) todo.title = title;
  if (description !== undefined) todo.description = typeof description === 'string' ? description : String(description);
  if (completed !== undefined) todo.completed = Boolean(completed);
  
  todo.updated_at = getTimestamp();

  const { user_id, ...todoWithoutUserId } = todo;
  res.status(200).json(todoWithoutUserId);
});

// DELETE /todos/:id
app.delete('/todos/:id', requireAuth, (req, res) => {
  const todoId = parseInt(req.params.id, 10);
  const todo = todos.get(todoId);

  if (!todo || todo.user_id !== req.userId) {
    return res.status(404).json({ error: "Todo not found" });
  }

  todos.delete(todoId);
  res.status(204).end();
});

// Start server
const portArgIndex = process.argv.indexOf('--port');
const port = portArgIndex !== -1 ? parseInt(process.argv[portArgIndex + 1], 10) : 3000;

app.listen(port, '0.0.0.0', () => {
  console.log(`Server listening on 0.0.0.0:${port}`);
});