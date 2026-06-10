import express, { Request, Response, NextFunction } from 'express';
import cookieParser from 'cookie-parser';
import crypto from 'crypto';

interface User {
  id: number;
  username: string;
  passwordHash: string;
  salt: string;
}

interface Todo {
  id: number;
  title: string;
  description: string;
  completed: boolean;
  created_at: string;
  updated_at: string;
  userId: number;
}

const users: User[] = [];
const todos: Todo[] = [];
const sessions: Map<string, number> = new Map();

let nextUserId = 1;
let nextTodoId = 1;

function hashPassword(password: string, salt?: string): { hash: string, salt: string } {
  const s = salt || crypto.randomBytes(16).toString('hex');
  const hash = crypto.pbkdf2Sync(password, s, 100000, 64, 'sha512').toString('hex');
  return { hash, salt: s };
}

function getIsoNow(): string {
  return new Date().toISOString().slice(0, 19) + 'Z';
}

const app = express();
app.use(express.json());
app.use(cookieParser());

app.use((err: any, req: Request, res: Response, next: NextFunction) => {
  if (err instanceof SyntaxError && 'body' in err) {
    return res.status(400).json({ error: "Invalid JSON" });
  }
  next(err);
});

function requireAuth(req: Request, res: Response, next: NextFunction) {
  const sessionId = req.cookies?.session_id;
  if (!sessionId || !sessions.has(sessionId)) {
    return res.status(401).json({ error: "Authentication required" });
  }
  (req as any).userId = sessions.get(sessionId);
  next();
}

app.post('/register', (req, res) => {
  const { username, password } = req.body || {};
  if (typeof username !== 'string' || !/^[a-zA-Z0-9_]{3,50}$/.test(username)) {
    return res.status(400).json({ error: "Invalid username" });
  }
  if (typeof password !== 'string' || password.length < 8) {
    return res.status(400).json({ error: "Password too short" });
  }
  if (users.some(u => u.username === username)) {
    return res.status(409).json({ error: "Username already exists" });
  }
  const { hash, salt } = hashPassword(password);
  const user: User = { id: nextUserId++, username, passwordHash: hash, salt };
  users.push(user);
  res.status(201).json({ id: user.id, username: user.username });
});

app.post('/login', (req, res) => {
  const { username, password } = req.body || {};
  const user = users.find(u => u.username === username);
  if (!user) {
    return res.status(401).json({ error: "Invalid credentials" });
  }
  const { hash } = hashPassword(password, user.salt);
  const valid = crypto.timingSafeEqual(Buffer.from(hash), Buffer.from(user.passwordHash));
  if (!valid) {
    return res.status(401).json({ error: "Invalid credentials" });
  }
  const token = crypto.randomBytes(32).toString('hex');
  sessions.set(token, user.id);
  res.cookie('session_id', token, { path: '/', httpOnly: true });
  res.status(200).json({ id: user.id, username: user.username });
});

app.post('/logout', requireAuth, (req, res) => {
  const sessionId = req.cookies?.session_id;
  if (sessionId) {
    sessions.delete(sessionId);
  }
  res.status(200).json({});
});

app.get('/me', requireAuth, (req, res) => {
  const userId = (req as any).userId;
  const user = users.find(u => u.id === userId);
  if (!user) {
    return res.status(401).json({ error: "Authentication required" });
  }
  res.status(200).json({ id: user.id, username: user.username });
});

app.put('/password', requireAuth, (req, res) => {
  const userId = (req as any).userId;
  const { old_password, new_password } = req.body || {};
  const user = users.find(u => u.id === userId);
  if (!user) {
    return res.status(401).json({ error: "Authentication required" });
  }
  if (typeof old_password !== 'string' || typeof new_password !== 'string') {
    return res.status(400).json({ error: "Invalid request" });
  }
  const { hash } = hashPassword(old_password, user.salt);
  if (!crypto.timingSafeEqual(Buffer.from(hash), Buffer.from(user.passwordHash))) {
    return res.status(401).json({ error: "Invalid credentials" });
  }
  if (new_password.length < 8) {
    return res.status(400).json({ error: "Password too short" });
  }
  const { hash: newHash, salt: newSalt } = hashPassword(new_password);
  user.passwordHash = newHash;
  user.salt = newSalt;
  res.status(200).json({});
});

app.get('/todos', requireAuth, (req, res) => {
  const userId = (req as any).userId;
  const userTodos = todos
    .filter(t => t.userId === userId)
    .sort((a, b) => a.id - b.id)
    .map(({ userId: _, ...rest }) => rest);
  res.status(200).json(userTodos);
});

app.post('/todos', requireAuth, (req, res) => {
  const userId = (req as any).userId;
  const { title, description } = req.body || {};
  if (typeof title !== 'string' || title === '') {
    return res.status(400).json({ error: "Title is required" });
  }
  const now = getIsoNow();
  const newTodo: Todo = {
    id: nextTodoId++,
    title,
    description: typeof description === 'string' ? description : "",
    completed: false,
    created_at: now,
    updated_at: now,
    userId
  };
  todos.push(newTodo);
  const { userId: _, ...rest } = newTodo;
  res.status(201).json(rest);
});

app.get('/todos/:id', requireAuth, (req, res) => {
  const userId = (req as any).userId;
  const todoId = parseInt(req.params.id, 10);
  const todo = todos.find(t => t.id === todoId);
  if (!todo || todo.userId !== userId) {
    return res.status(404).json({ error: "Todo not found" });
  }
  const { userId: _, ...rest } = todo;
  res.status(200).json(rest);
});

app.put('/todos/:id', requireAuth, (req, res) => {
  const userId = (req as any).userId;
  const todoId = parseInt(req.params.id, 10);
  const todo = todos.find(t => t.id === todoId);
  if (!todo || todo.userId !== userId) {
    return res.status(404).json({ error: "Todo not found" });
  }
  const { title, description, completed } = req.body || {};
  if (title !== undefined) {
    if (typeof title !== 'string' || title === '') {
      return res.status(400).json({ error: "Title is required" });
    }
    todo.title = title;
  }
  if (description !== undefined) {
    if (typeof description === 'string') {
      todo.description = description;
    }
  }
  if (completed !== undefined) {
    if (typeof completed === 'boolean') {
      todo.completed = completed;
    }
  }
  todo.updated_at = getIsoNow();
  const { userId: _, ...rest } = todo;
  res.status(200).json(rest);
});

app.delete('/todos/:id', requireAuth, (req, res) => {
  const userId = (req as any).userId;
  const todoId = parseInt(req.params.id, 10);
  const index = todos.findIndex(t => t.id === todoId);
  if (index === -1 || todos[index].userId !== userId) {
    return res.status(404).json({ error: "Todo not found" });
  }
  todos.splice(index, 1);
  res.status(204).set('Content-Type', 'application/json').send();
});

const args = process.argv.slice(2);
let port = 3000;
for (let i = 0; i < args.length; i++) {
  if (args[i] === '--port' && args[i + 1]) {
    const parsed = parseInt(args[i + 1], 10);
    if (!isNaN(parsed)) {
      port = parsed;
    }
    break;
  }
}

app.listen(port, '0.0.0.0', () => {
  console.log(`Server running on http://0.0.0.0:${port}`);
});
