import express, { Request, Response, NextFunction } from 'express';
import cookieParser from 'cookie-parser';
import crypto from 'crypto';

// --- Types ---
interface User {
  id: number;
  username: string;
  password: string;
}

interface Todo {
  id: number;
  user_id: number;
  title: string;
  description: string;
  completed: boolean;
  created_at: string;
  updated_at: string;
}

interface Store {
  users: User[];
  todos: Todo[];
  sessions: Map<string, number>;
  nextUserId: number;
  nextTodoId: number;
}

const store: Store = {
  users: [],
  todos: [],
  sessions: new Map(),
  nextUserId: 1,
  nextTodoId: 1,
};

// --- Helpers ---
function getTimestamp(): string {
  return new Date().toISOString().replace(/\.\d{3}Z$/, 'Z');
}

function generateToken(): string {
  return crypto.randomBytes(32).toString('hex');
}

// --- Middleware ---
function requireAuth(req: Request, res: Response, next: NextFunction) {
  const sessionId = req.cookies?.session_id;
  if (!sessionId || !store.sessions.has(sessionId)) {
    res.set('Content-Type', 'application/json');
    res.status(401).json({ error: 'Authentication required' });
    return;
  }
  next();
}

function setContentType(req: Request, res: Response, next: NextFunction) {
  res.set('Content-Type', 'application/json');
  next();
}

// --- App ---
const app = express();
app.use(setContentType);
app.use(express.json());
app.use(cookieParser());

// --- Endpoints ---

// POST /register
app.post('/register', (req: Request, res: Response) => {
  const { username, password } = req.body;

  if (!username || typeof username !== 'string' || !/^[a-zA-Z0-9_]{3,50}$/.test(username)) {
    res.status(400).json({ error: 'Invalid username' });
    return;
  }

  if (!password || typeof password !== 'string' || password.length < 8) {
    res.status(400).json({ error: 'Password too short' });
    return;
  }

  if (store.users.some((u) => u.username === username)) {
    res.status(409).json({ error: 'Username already exists' });
    return;
  }

  const newUser: User = {
    id: store.nextUserId++,
    username,
    password,
  };
  store.users.push(newUser);

  res.status(201).json({ id: newUser.id, username: newUser.username });
});

// POST /login
app.post('/login', (req: Request, res: Response) => {
  const { username, password } = req.body;

  const user = store.users.find((u) => u.username === username && u.password === password);
  if (!user) {
    res.status(401).json({ error: 'Invalid credentials' });
    return;
  }

  const token = generateToken();
  store.sessions.set(token, user.id);

  res.cookie('session_id', token, { path: '/', httpOnly: true });
  res.status(200).json({ id: user.id, username: user.username });
});

// POST /logout
app.post('/logout', requireAuth, (req: Request, res: Response) => {
  const sessionId = req.cookies.session_id;
  if (sessionId) {
    store.sessions.delete(sessionId);
  }
  res.status(200).json({});
});

// GET /me
app.get('/me', requireAuth, (req: Request, res: Response) => {
  const sessionId = req.cookies.session_id;
  const userId = store.sessions.get(sessionId);
  const user = store.users.find((u) => u.id === userId);

  if (!user) {
    res.status(401).json({ error: 'Authentication required' });
    return;
  }

  res.status(200).json({ id: user.id, username: user.username });
});

// PUT /password
app.put('/password', requireAuth, (req: Request, res: Response) => {
  const { old_password, new_password } = req.body;
  const sessionId = req.cookies.session_id;
  const userId = store.sessions.get(sessionId);
  const user = store.users.find((u) => u.id === userId);

  if (!user || user.password !== old_password) {
    res.status(401).json({ error: 'Invalid credentials' });
    return;
  }

  if (!new_password || typeof new_password !== 'string' || new_password.length < 8) {
    res.status(400).json({ error: 'Password too short' });
    return;
  }

  user.password = new_password;
  res.status(200).json({});
});

// GET /todos
app.get('/todos', requireAuth, (req: Request, res: Response) => {
  const sessionId = req.cookies.session_id;
  const userId = store.sessions.get(sessionId);

  const userTodos = store.todos
    .filter((t) => t.user_id === userId)
    .map(({ user_id, ...rest }) => rest)
    .sort((a, b) => a.id - b.id);

  res.status(200).json(userTodos);
});

// POST /todos
app.post('/todos', requireAuth, (req: Request, res: Response) => {
  const { title, description } = req.body;
  const sessionId = req.cookies.session_id;
  const userId = store.sessions.get(sessionId);

  if (!title || typeof title !== 'string' || title.trim() === '') {
    res.status(400).json({ error: 'Title is required' });
    return;
  }

  const now = getTimestamp();
  const newTodo: Todo = {
    id: store.nextTodoId++,
    user_id: userId,
    title,
    description: description || '',
    completed: false,
    created_at: now,
    updated_at: now,
  };
  store.todos.push(newTodo);

  const { user_id, ...rest } = newTodo;
  res.status(201).json(rest);
});

// GET /todos/:id
app.get('/todos/:id', requireAuth, (req: Request, res: Response) => {
  const todoId = parseInt(req.params.id, 10);
  const sessionId = req.cookies.session_id;
  const userId = store.sessions.get(sessionId);

  const todo = store.todos.find((t) => t.id === todoId && t.user_id === userId);
  if (!todo) {
    res.status(404).json({ error: 'Todo not found' });
    return;
  }

  const { user_id, ...rest } = todo;
  res.status(200).json(rest);
});

// PUT /todos/:id
app.put('/todos/:id', requireAuth, (req: Request, res: Response) => {
  const todoId = parseInt(req.params.id, 10);
  const sessionId = req.cookies.session_id;
  const userId = store.sessions.get(sessionId);

  const todo = store.todos.find((t) => t.id === todoId && t.user_id === userId);
  if (!todo) {
    res.status(404).json({ error: 'Todo not found' });
    return;
  }

  const { title, description, completed } = req.body;

  if (title !== undefined && (typeof title !== 'string' || title.trim() === '')) {
    res.status(400).json({ error: 'Title is required' });
    return;
  }

  if (title !== undefined) todo.title = title;
  if (description !== undefined) todo.description = description;
  if (completed !== undefined) todo.completed = Boolean(completed);
  todo.updated_at = getTimestamp();

  const { user_id, ...rest } = todo;
  res.status(200).json(rest);
});

// DELETE /todos/:id
app.delete('/todos/:id', requireAuth, (req: Request, res: Response) => {
  const todoId = parseInt(req.params.id, 10);
  const sessionId = req.cookies.session_id;
  const userId = store.sessions.get(sessionId);

  const todoIndex = store.todos.findIndex((t) => t.id === todoId && t.user_id === userId);
  if (todoIndex === -1) {
    res.status(404).json({ error: 'Todo not found' });
    return;
  }

  store.todos.splice(todoIndex, 1);
  res.status(204).send();
});

// --- Server Start ---
const PORT = process.env.PORT || 3000;
app.listen(PORT, '0.0.0.0', () => {
  console.log(`Server running on http://0.0.0.0:${PORT}`);
});

export default app;
