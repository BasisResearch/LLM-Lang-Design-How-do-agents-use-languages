const express = require('express');
const crypto = require('crypto');

const app = express();
app.use(express.json());

// In-memory storage
const users = new Map(); // id -> { id, username, password }
const usernameToId = new Map(); // username -> id
const todos = new Map(); // id -> { id, userId, title, description, completed, created_at, updated_at }
const sessions = new Map(); // token -> userId

let nextUserId = 1;
let nextTodoId = 1;

// Helper: generate token
function generateToken() {
  return crypto.randomUUID();
}

// Helper: get timestamp in YYYY-MM-DDTHH:MM:SSZ format
function getTimestamp() {
  return new Date().toISOString().replace(/\.\d{3}Z$/, 'Z');
}

// Middleware: Auth
function requireAuth(req, res, next) {
  const cookies = req.headers.cookie;
  let token = null;
  if (cookies) {
    const parts = cookies.split(';');
    for (const part of parts) {
      const [key, value] = part.trim().split('=');
      if (key === 'session_id') {
        token = value;
        break;
      }
    }
  }

  if (!token || !sessions.has(token)) {
    return res.status(401).json({ error: 'Authentication required' });
  }

  req.userId = sessions.get(token);
  next();
}

app.post('/register', (req, res) => {
  const { username, password } = req.body || {};
  if (typeof username !== 'string' || !/^[a-zA-Z0-9_]{3,50}$/.test(username)) {
    return res.status(400).json({ error: 'Invalid username' });
  }
  if (typeof password !== 'string' || password.length < 8) {
    return res.status(400).json({ error: 'Password too short' });
  }
  if (usernameToId.has(username)) {
    return res.status(409).json({ error: 'Username already exists' });
  }
  
  const id = nextUserId++;
  users.set(id, { id, username, password });
  usernameToId.set(username, id);
  
  res.status(201).json({ id, username });
});

app.post('/login', (req, res) => {
  const { username, password } = req.body || {};
  const userId = usernameToId.get(username);
  const user = users.get(userId);
  
  if (!user || user.password !== password) {
    return res.status(401).json({ error: 'Invalid credentials' });
  }
  
  const token = generateToken();
  sessions.set(token, userId);
  
  res.setHeader('Set-Cookie', `session_id=${token}; Path=/; HttpOnly`);
  res.status(200).json({ id: user.id, username: user.username });
});

app.post('/logout', requireAuth, (req, res) => {
  const cookies = req.headers.cookie;
  let token = null;
  if (cookies) {
    for (const part of cookies.split(';')) {
      const [key, value] = part.trim().split('=');
      if (key === 'session_id') {
        token = value;
        break;
      }
    }
  }
  if (token) {
    sessions.delete(token);
  }
  res.status(200).json({});
});

app.get('/me', requireAuth, (req, res) => {
  const user = users.get(req.userId);
  res.status(200).json({ id: user.id, username: user.username });
});

app.put('/password', requireAuth, (req, res) => {
  const { old_password, new_password } = req.body || {};
  const user = users.get(req.userId);
  
  if (!user || user.password !== old_password) {
    return res.status(401).json({ error: 'Invalid credentials' });
  }
  if (typeof new_password !== 'string' || new_password.length < 8) {
    return res.status(400).json({ error: 'Password too short' });
  }
  
  user.password = new_password;
  res.status(200).json({});
});

app.get('/todos', requireAuth, (req, res) => {
  const userTodos = [];
  for (const todo of todos.values()) {
    if (todo.userId === req.userId) {
      const { userId, ...rest } = todo;
      userTodos.push(rest);
    }
  }
  userTodos.sort((a, b) => a.id - b.id);
  res.status(200).json(userTodos);
});

app.post('/todos', requireAuth, (req, res) => {
  const { title, description } = req.body || {};
  if (typeof title !== 'string' || title.length === 0) {
    return res.status(400).json({ error: 'Title is required' });
  }
  
  const id = nextTodoId++;
  const now = getTimestamp();
  const newTodo = {
    id,
    userId: req.userId,
    title,
    description: typeof description === 'string' ? description : '',
    completed: false,
    created_at: now,
    updated_at: now
  };
  todos.set(id, newTodo);
  
  const { userId, ...rest } = newTodo;
  res.status(201).json(rest);
});

app.get('/todos/:id', requireAuth, (req, res) => {
  const id = parseInt(req.params.id, 10);
  const todo = todos.get(id);
  if (!todo || todo.userId !== req.userId) {
    return res.status(404).json({ error: 'Todo not found' });
  }
  const { userId, ...rest } = todo;
  res.status(200).json(rest);
});

app.put('/todos/:id', requireAuth, (req, res) => {
  const id = parseInt(req.params.id, 10);
  const todo = todos.get(id);
  if (!todo || todo.userId !== req.userId) {
    return res.status(404).json({ error: 'Todo not found' });
  }
  
  const { title, description, completed } = req.body || {};
  
  if (title !== undefined) {
    if (typeof title !== 'string' || title.length === 0) {
      return res.status(400).json({ error: 'Title is required' });
    }
    todo.title = title;
  }
  if (description !== undefined) {
    todo.description = description;
  }
  if (completed !== undefined) {
    todo.completed = Boolean(completed);
  }
  
  todo.updated_at = getTimestamp();
  
  const { userId, ...rest } = todo;
  res.status(200).json(rest);
});

app.delete('/todos/:id', requireAuth, (req, res) => {
  const id = parseInt(req.params.id, 10);
  const todo = todos.get(id);
  if (!todo || todo.userId !== req.userId) {
    return res.status(404).json({ error: 'Todo not found' });
  }
  
  todos.delete(id);
  res.status(204).send();
});

const portArg = process.argv.indexOf('--port');
const port = portArg !== -1 ? parseInt(process.argv[portArg + 1], 10) : 3000;

app.listen(port, '0.0.0.0', () => {
  console.log(`Server listening on 0.0.0.0:${port}`);
});
