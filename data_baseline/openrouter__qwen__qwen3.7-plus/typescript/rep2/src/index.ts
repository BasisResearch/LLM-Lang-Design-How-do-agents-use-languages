import express, { Request, Response, NextFunction } from 'express';
import cookieParser from 'cookie-parser';
import { v4 as uuidv4 } from 'uuid';
import crypto from 'crypto';

const app = express();
app.use(express.json());
app.use(cookieParser());

interface User {
  id: number;
  username: string;
  password: string;
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
const sessions: Session[] = [];
let nextUserId = 1;
let nextTodoId = 1;

function getNow(): string {
  return new Date().toISOString().replace(/\.\d{3}Z$/, 'Z');
}

function hashPassword(password: string): string {
  return crypto.createHash('sha256').update(password).digest('hex');
}

const requireAuth = (req: Request, res: Response, next: NextFunction) => {
  const token = req.cookies['session_id'];
  if (!token) {
    return res.status(401).json({ error: "Authentication required" });
  }
  const session = sessions.find(s => s.token === token);
  if (!session) {
    return res.status(401).json({ error: "Authentication required" });
  }
  (req as any).userId = session.userId;
  next();
};

app.post('/register', (req: Request, res: Response) => {
  const { username, password } = req.body || {};
  if (!username || !/^[a-zA-Z0-9_]{3,50}$/.test(username)) {
    return res.status(400).json({ error: "Invalid username" });
  }
  if (!password || password.length < 8) {
    return res.status(400).json({ error: "Password too short" });
  }
  if (users.find(u => u.username === username)) {
    return res.status(409).json({ error: "Username already exists" });
  }
  
  const newUser: User = {
    id: nextUserId++,
    username,
    password: hashPassword(password)
  };
  users.push(newUser);
  res.status(201).json({ id: newUser.id, username: newUser.username });
});

app.post('/login', (req: Request, res: Response) => {
  const { username, password } = req.body || {};
  const hashedPassword = hashPassword(password || '');
  const user = users.find(u => u.username === username && u.password === hashedPassword);
  if (!user) {
    return res.status(401).json({ error: "Invalid credentials" });
  }
  
  const token = uuidv4();
  sessions.push({ token, userId: user.id });
  res.cookie('session_id', token, { httpOnly: true, path: '/' });
  res.status(200).json({ id: user.id, username: user.username });
});

app.post('/logout', requireAuth, (req: Request, res: Response) => {
  const token = req.cookies['session_id'];
  const index = sessions.findIndex(s => s.token === token);
  if (index !== -1) {
    sessions.splice(index, 1);
  }
  res.clearCookie('session_id', { path: '/' });
  res.status(200).json({});
});

app.get('/me', requireAuth, (req: Request, res: Response) => {
  const user = users.find(u => u.id === (req as any).userId);
  if (!user) {
    return res.status(401).json({ error: "Authentication required" });
  }
  res.status(200).json({ id: user.id, username: user.username });
});

app.put('/password', requireAuth, (req: Request, res: Response) => {
  const { old_password, new_password } = req.body || {};
  const user = users.find(u => u.id === (req as any).userId);
  if (!user || user.password !== hashPassword(old_password || '')) {
    return res.status(401).json({ error: "Invalid credentials" });
  }
  if (!new_password || new_password.length < 8) {
    return res.status(400).json({ error: "Password too short" });
  }
  user.password = hashPassword(new_password);
  res.status(200).json({});
});

app.get('/todos', requireAuth, (req: Request, res: Response) => {
  const userTodos = todos
    .filter(t => t.userId === (req as any).userId)
    .sort((a, b) => a.id - b.id);
  res.status(200).json(userTodos);
});

app.post('/todos', requireAuth, (req: Request, res: Response) => {
  const { title, description } = req.body || {};
  if (title === undefined || typeof title !== 'string' || title.trim() === '') {
    return res.status(400).json({ error: "Title is required" });
  }
  const now = getNow();
  const newTodo: Todo = {
    id: nextTodoId++,
    userId: (req as any).userId,
    title,
    description: description !== undefined && description !== null ? String(description) : "",
    completed: false,
    created_at: now,
    updated_at: now
  };
  todos.push(newTodo);
  res.status(201).json(newTodo);
});

app.get('/todos/:id', requireAuth, (req: Request, res: Response) => {
  const todoId = parseInt(req.params.id, 10);
  const todo = todos.find(t => t.id === todoId && t.userId === (req as any).userId);
  if (!todo) {
    return res.status(404).json({ error: "Todo not found" });
  }
  res.status(200).json(todo);
});

app.put('/todos/:id', requireAuth, (req: Request, res: Response) => {
  const todoId = parseInt(req.params.id, 10);
  const todo = todos.find(t => t.id === todoId && t.userId === (req as any).userId);
  if (!todo) {
    return res.status(404).json({ error: "Todo not found" });
  }
  
  const { title, description, completed } = req.body || {};
  if (title !== undefined) {
    if (typeof title !== 'string' || title.trim() === '') {
      return res.status(400).json({ error: "Title is required" });
    }
    todo.title = title;
  }
  if (description !== undefined) {
    todo.description = String(description);
  }
  if (completed !== undefined) {
    todo.completed = completed;
  }
  
  todo.updated_at = getNow();
  res.status(200).json(todo);
});

app.delete('/todos/:id', requireAuth, (req: Request, res: Response) => {
  const todoId = parseInt(req.params.id, 10);
  const index = todos.findIndex(t => t.id === todoId && t.userId === (req as any).userId);
  if (index === -1) {
    return res.status(404).json({ error: "Todo not found" });
  }
  todos.splice(index, 1);
  res.status(204).end();
});

let targetPort = 3000;
const portIndex = process.argv.indexOf('--port');
if (portIndex !== -1 && process.argv[portIndex + 1]) {
  targetPort = parseInt(process.argv[portIndex + 1], 10);
}

app.listen(targetPort, '0.0.0.0', () => {
  console.log(`Server running on 0.0.0.0:${targetPort}`);
});
