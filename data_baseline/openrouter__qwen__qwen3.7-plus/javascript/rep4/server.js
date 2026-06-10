const express = require('express');
const cookieParser = require('cookie-parser');
const crypto = require('crypto');

const app = express();
app.use(express.json());
app.use(cookieParser());

const users = [];
const sessions = new Map();
const todos = [];
let nextUserId = 1;
let nextTodoId = 1;

function hash(str) {
  return crypto.createHash('sha256').update(str).digest('hex');
}

function getTimestamp() {
  return new Date().toISOString().replace(/\.\d{3}Z$/, 'Z');
}

function formatTodo(todo) {
  return {
    id: todo.id,
    title: todo.title,
    description: todo.description,
    completed: todo.completed,
    created_at: todo.created_at,
    updated_at: todo.updated_at
  };
}

function authenticate(req, res, next) {
  const sessionId = req.cookies.session_id;
  if (!sessionId || !sessions.has(sessionId)) {
    return res.status(401).json({ error: "Authentication required" });
  }
  req.userId = sessions.get(sessionId);
  next();
}

app.post('/register', (req, res) => {
  const { username, password } = req.body || {};
  if (!username || typeof username !== 'string' || !/^[a-zA-Z0-9_]{3,50}$/.test(username)) {
    return res.status(400).json({ error: "Invalid username" });
  }
  if (!password || typeof password !== 'string' || password.length < 8) {
    return res.status(400).json({ error: "Password too short" });
  }
  if (users.some(u => u.username === username)) {
    return res.status(409).json({ error: "Username already exists" });
  }
  const user = { id: nextUserId++, username, password: hash(password) };
  users.push(user);
  res.status(201).json({ id: user.id, username: user.username });
});

app.post('/login', (req, res) => {
  const { username, password } = req.body || {};
  const user = users.find(u => u.username === username);
  if (!user || user.password !== hash(password)) {
    return res.status(401).json({ error: "Invalid credentials" });
  }
  const token = crypto.randomBytes(32).toString('hex');
  sessions.set(token, user.id);
  res.setHeader('Set-Cookie', `session_id=${token}; Path=/; HttpOnly`);
  res.json({ id: user.id, username: user.username });
});

app.post('/logout', authenticate, (req, res) => {
  const token = req.cookies.session_id;
  if (token) sessions.delete(token);
  res.json({});
});

app.get('/me', authenticate, (req, res) => {
  const user = users.find(u => u.id === req.userId);
  if (!user) return res.status(401).json({ error: "Authentication required" });
  res.json({ id: user.id, username: user.username });
});

app.put('/password', authenticate, (req, res) => {
  const { old_password, new_password } = req.body || {};
  const user = users.find(u => u.id === req.userId);
  if (!user || typeof old_password !== 'string' || user.password !== hash(old_password)) {
    return res.status(401).json({ error: "Invalid credentials" });
  }
  if (typeof new_password !== 'string' || new_password.length < 8) {
    return res.status(400).json({ error: "Password too short" });
  }
  user.password = hash(new_password);
  res.json({});
});

app.get('/todos', authenticate, (req, res) => {
  const userTodos = todos.filter(t => t.userId === req.userId).sort((a, b) => a.id - b.id);
  res.json(userTodos.map(formatTodo));
});

app.post('/todos', authenticate, (req, res) => {
  const { title, description } = req.body || {};
  if (!title || typeof title !== 'string' || title.trim() === '') {
    return res.status(400).json({ error: "Title is required" });
  }
  const now = getTimestamp();
  const todo = {
    id: nextTodoId++,
    userId: req.userId,
    title,
    description: (description === undefined || description === null) ? "" : String(description),
    completed: false,
    created_at: now,
    updated_at: now
  };
  todos.push(todo);
  res.status(201).json(formatTodo(todo));
});

app.get('/todos/:id', authenticate, (req, res) => {
  const id = parseInt(req.params.id, 10);
  const todo = todos.find(t => t.id === id);
  if (!todo || todo.userId !== req.userId) {
    return res.status(404).json({ error: "Todo not found" });
  }
  res.json(formatTodo(todo));
});

app.put('/todos/:id', authenticate, (req, res) => {
  const id = parseInt(req.params.id, 10);
  const todo = todos.find(t => t.id === id);
  if (!todo || todo.userId !== req.userId) {
    return res.status(404).json({ error: "Todo not found" });
  }
  const { title, description, completed } = req.body || {};
  if (title !== undefined && (typeof title !== 'string' || title.trim() === '')) {
    return res.status(400).json({ error: "Title is required" });
  }
  if (title !== undefined) todo.title = title;
  if (description !== undefined) todo.description = String(description);
  if (completed !== undefined) todo.completed = Boolean(completed);
  todo.updated_at = getTimestamp();
  res.json(formatTodo(todo));
});

app.delete('/todos/:id', authenticate, (req, res) => {
  const id = parseInt(req.params.id, 10);
  const todoIndex = todos.findIndex(t => t.id === id);
  if (todoIndex === -1 || todos[todoIndex].userId !== req.userId) {
    return res.status(404).json({ error: "Todo not found" });
  }
  todos.splice(todoIndex, 1);
  res.status(204).end();
});

const PORT = process.argv.includes('--port') ? parseInt(process.argv[process.argv.indexOf('--port') + 1], 10) : 3000;

app.listen(PORT, '0.0.0.0', () => {
  console.log(`Server running on port ${PORT}`);
});