import express, { Request, Response, NextFunction } from 'express';
import crypto from 'crypto';

declare global {
  namespace Express {
    interface Request {
      userId?: number;
    }
  }
}

interface User {
  id: number;
  username: string;
  passwordHash: string;
  salt: string;
}

interface Todo {
  id: number;
  userId: number;
  title: string;
  description: string;
  completed: boolean;
  created_at: string;
  updated_at: string;
}

interface Session {
  token: string;
  userId: number;
}

const users: User[] = [];
const todos: Todo[] = [];
const sessions = new Map<string, Session>();
let nextUserId = 1;
let nextTodoId = 1;

function generateToken(): string {
  return crypto.randomBytes(32).toString('hex');
}

function hashPassword(password: string, salt?: string): { hash: string; salt: string } {
  const actualSalt = salt || crypto.randomBytes(16).toString('hex');
  const hash = crypto.pbkdf2Sync(password, actualSalt, 100000, 64, 'sha512').toString('hex');
  return { hash, salt: actualSalt };
}

function formatTimestamp(date: Date): string {
  return date.toISOString().slice(0, 19) + 'Z';
}

function parseCookie(cookieHeader: string): Record<string, string> {
  if (!cookieHeader) return {};
  return cookieHeader.split(';').reduce((acc, part) => {
    const [key, ...val] = part.trim().split('=');
    if (key) {
      acc[key] = val.join('=');
    }
    return acc;
  }, {} as Record<string, string>);
}

const app = express();
app.use(express.json());

const requireAuth = (req: Request, res: Response, next: NextFunction) => {
  const cookieHeader = req.headers.cookie;
  const cookies = parseCookie(cookieHeader || '');
  const sessionId = cookies.session_id;

  if (!sessionId || !sessions.has(sessionId)) {
    return res.status(401).json({ error: "Authentication required" });
  }

  req.userId = sessions.get(sessionId)!.userId;
  next();
};

app.post('/register', (req, res) => {
  const { username, password } = req.body;

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
  const newUser: User = {
    id: nextUserId++,
    username,
    passwordHash: hash,
    salt
  };
  users.push(newUser);

  res.status(201).json({ id: newUser.id, username: newUser.username });
});

app.post('/login', (req, res) => {
  const { username, password } = req.body;

  if (typeof username !== 'string' || typeof password !== 'string') {
    return res.status(401).json({ error: "Invalid credentials" });
  }

  const user = users.find(u => u.username === username);
  if (!user) {
    return res.status(401).json({ error: "Invalid credentials" });
  }

  const { hash } = hashPassword(password, user.salt);
  if (hash !== user.passwordHash) {
    return res.status(401).json({ error: "Invalid credentials" });
  }

  const token = generateToken();
  sessions.set(token, { token, userId: user.id });

  res.cookie('session_id', token, { httpOnly: true, path: '/' });
  res.status(200).json({ id: user.id, username: user.username });
});

app.post('/logout', requireAuth, (req, res) => {
  const cookieHeader = req.headers.cookie;
  const cookies = parseCookie(cookieHeader || '');
  const sessionId = cookies.session_id;
  
  if (sessionId) {
    sessions.delete(sessionId);
  }
  
  res.clearCookie('session_id', { path: '/' });
  res.status(200).json({});
});

app.get('/me', requireAuth, (req, res) => {
  const user = users.find(u => u.id === req.userId);
  if (!user) {
    return res.status(401).json({ error: "Authentication required" });
  }
  res.status(200).json({ id: user.id, username: user.username });
});

app.put('/password', requireAuth, (req, res) => {
  const { old_password, new_password } = req.body;
  const user = users.find(u => u.id === req.userId);
  
  if (!user) {
    return res.status(401).json({ error: "Authentication required" });
  }

  if (typeof old_password !== 'string' || typeof new_password !== 'string') {
    return res.status(400).json({ error: "Invalid request" });
  }

  const { hash } = hashPassword(old_password, user.salt);
  if (hash !== user.passwordHash) {
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
  const userTodos = todos
    .filter(t => t.userId === req.userId)
    .sort((a, b) => a.id - b.id)
    .map(({ userId, ...rest }) => rest);
  res.status(200).json(userTodos);
});

app.post('/todos', requireAuth, (req, res) => {
  const { title, description } = req.body;

  if (typeof title !== 'string' || title === '') {
    return res.status(400).json({ error: "Title is required" });
  }

  const now = formatTimestamp(new Date());
  const newTodo: Todo = {
    id: nextTodoId++,
    userId: req.userId!,
    title,
    description: typeof description === 'string' ? description : "",
    completed: false,
    created_at: now,
    updated_at: now
  };

  todos.push(newTodo);

  const { userId, ...rest } = newTodo;
  res.status(201).json(rest);
});

app.get('/todos/:id', requireAuth, (req, res) => {
  const todoId = parseInt(req.params.id, 10);
  const todo = todos.find(t => t.id === todoId);

  if (!todo || todo.userId !== req.userId) {
    return res.status(404).json({ error: "Todo not found" });
  }

  const { userId, ...rest } = todo;
  res.status(200).json(rest);
});

app.put('/todos/:id', requireAuth, (req, res) => {
  const todoId = parseInt(req.params.id, 10);
  const todo = todos.find(t => t.id === todoId);

  if (!todo || todo.userId !== req.userId) {
    return res.status(404).json({ error: "Todo not found" });
  }

  const { title, description, completed } = req.body;

  if (title !== undefined) {
    if (typeof title !== 'string' || title === '') {
      return res.status(400).json({ error: "Title is required" });
    }
    todo.title = title;
  }

  if (description !== undefined) {
    todo.description = typeof description === 'string' ? description : String(description);
  }

  if (completed !== undefined) {
    todo.completed = Boolean(completed);
  }

  todo.updated_at = formatTimestamp(new Date());

  const { userId, ...rest } = todo;
  res.status(200).json(rest);
});

app.delete('/todos/:id', requireAuth, (req, res) => {
  const todoId = parseInt(req.params.id, 10);
  const todoIndex = todos.findIndex(t => t.id === todoId);

  if (todoIndex === -1 || todos[todoIndex].userId !== req.userId) {
    return res.status(404).json({ error: "Todo not found" });
  }

  todos.splice(todoIndex, 1);
  res.removeHeader('Content-Type');
  res.status(204).end();
});

const portArgIndex = process.argv.indexOf('--port');
const port = portArgIndex !== -1 && process.argv[portArgIndex + 1] 
  ? parseInt(process.argv[portArgIndex + 1], 10) 
  : 3000;

app.listen(port, '0.0.0.0', () => {
  console.log(`Server listening on 0.0.0.0:${port}`);
});
