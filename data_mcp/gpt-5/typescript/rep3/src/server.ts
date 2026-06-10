import express, { Request, Response, NextFunction } from 'express';
import cookieParser from 'cookie-parser';
import { v4 as uuidv4 } from 'uuid';

// Types
interface User {
  id: number;
  username: string;
  password: string; // stored in-memory in plain text for this exercise
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

// In-memory stores
const users: User[] = [];
let nextUserId = 1;

const todos: Todo[] = [];
let nextTodoId = 1;

// session_id -> userId
const sessions = new Map<string, number>();

// Helpers
function isoUtcSeconds(date: Date = new Date()): string {
  const ms = Math.floor(date.getTime() / 1000) * 1000;
  return new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');
}

function sendJson(res: Response, status: number, body: any): void {
  res.status(status);
  if (status === 204) {
    // No body and no content-type for 204
    res.end();
    return;
  }
  res.setHeader('Content-Type', 'application/json');
  res.send(JSON.stringify(body));
}

function authMiddleware(req: Request, res: Response, next: NextFunction) {
  const token = req.cookies?.['session_id'];
  if (!token) {
    return sendJson(res, 401, { error: 'Authentication required' });
  }
  const userId = sessions.get(token);
  if (!userId) {
    return sendJson(res, 401, { error: 'Authentication required' });
  }
  (req as any).userId = userId;
  (req as any).sessionToken = token;
  next();
}

function validateUsername(username: any): boolean {
  if (typeof username !== 'string') return false;
  if (username.length < 3 || username.length > 50) return false;
  return /^[a-zA-Z0-9_]+$/.test(username);
}

function findUserByUsername(username: string): User | undefined {
  return users.find((u) => u.username === username);
}

function userPublic(u: User) {
  return { id: u.id, username: u.username };
}

function getTodoForUser(todoId: number, userId: number): Todo | undefined {
  const todo = todos.find((t) => t.id === todoId);
  if (!todo) return undefined;
  if (todo.userId !== userId) return undefined; // hide existence
  return todo;
}

const app = express();
app.use(express.json());
app.use(cookieParser());

// Ensure application/json content-type for all res.send calls by default
app.use((req, res, next) => {
  const originalSend = res.send.bind(res);
  (res as any).send = (body: any) => {
    if (!res.getHeader('Content-Type')) {
      res.setHeader('Content-Type', 'application/json');
    }
    return originalSend(body);
  };
  next();
});

// Routes
app.post('/register', (req: Request, res: Response) => {
  const { username, password } = req.body || {};
  if (!validateUsername(username)) {
    return sendJson(res, 400, { error: 'Invalid username' });
  }
  if (typeof password !== 'string' || password.length < 8) {
    return sendJson(res, 400, { error: 'Password too short' });
  }
  if (findUserByUsername(username)) {
    return sendJson(res, 409, { error: 'Username already exists' });
  }
  const user: User = { id: nextUserId++, username, password };
  users.push(user);
  return sendJson(res, 201, userPublic(user));
});

app.post('/login', (req: Request, res: Response) => {
  const { username, password } = req.body || {};
  const user = findUserByUsername(typeof username === 'string' ? username : '');
  if (!user || user.password !== password) {
    return sendJson(res, 401, { error: 'Invalid credentials' });
  }
  const token = uuidv4().replace(/-/g, '');
  sessions.set(token, user.id);
  res.setHeader('Set-Cookie', `session_id=${token}; Path=/; HttpOnly`);
  return sendJson(res, 200, userPublic(user));
});

app.post('/logout', authMiddleware, (req: Request, res: Response) => {
  const token: string = (req as any).sessionToken;
  sessions.delete(token);
  return sendJson(res, 200, {});
});

app.get('/me', authMiddleware, (req: Request, res: Response) => {
  const userId: number = (req as any).userId;
  const user = users.find((u) => u.id === userId)!;
  return sendJson(res, 200, userPublic(user));
});

app.put('/password', authMiddleware, (req: Request, res: Response) => {
  const userId: number = (req as any).userId;
  const user = users.find((u) => u.id === userId)!;
  const { old_password, new_password } = req.body || {};
  if (user.password !== old_password) {
    return sendJson(res, 401, { error: 'Invalid credentials' });
  }
  if (typeof new_password !== 'string' || new_password.length < 8) {
    return sendJson(res, 400, { error: 'Password too short' });
  }
  user.password = new_password;
  return sendJson(res, 200, {});
});

app.get('/todos', authMiddleware, (req: Request, res: Response) => {
  const userId: number = (req as any).userId;
  const list = todos
    .filter((t) => t.userId === userId)
    .sort((a, b) => a.id - b.id)
    .map(({ userId: _uid, ...rest }) => rest);
  return sendJson(res, 200, list);
});

app.post('/todos', authMiddleware, (req: Request, res: Response) => {
  const userId: number = (req as any).userId;
  const { title, description } = req.body || {};
  if (typeof title !== 'string' || title.trim() === '') {
    return sendJson(res, 400, { error: 'Title is required' });
  }
  const now = isoUtcSeconds();
  const todo: Todo = {
    id: nextTodoId++,
    userId,
    title: title,
    description: typeof description === 'string' ? description : '',
    completed: false,
    created_at: now,
    updated_at: now,
  };
  todos.push(todo);
  const { userId: _uid, ...publicTodo } = todo;
  return sendJson(res, 201, publicTodo);
});

app.get('/todos/:id', authMiddleware, (req: Request, res: Response) => {
  const userId: number = (req as any).userId;
  const id = Number(req.params.id);
  if (!Number.isInteger(id) || id < 1) {
    return sendJson(res, 404, { error: 'Todo not found' });
  }
  const todo = getTodoForUser(id, userId);
  if (!todo) {
    return sendJson(res, 404, { error: 'Todo not found' });
  }
  const { userId: _uid, ...publicTodo } = todo;
  return sendJson(res, 200, publicTodo);
});

app.put('/todos/:id', authMiddleware, (req: Request, res: Response) => {
  const userId: number = (req as any).userId;
  const id = Number(req.params.id);
  if (!Number.isInteger(id) || id < 1) {
    return sendJson(res, 404, { error: 'Todo not found' });
  }
  const todo = getTodoForUser(id, userId);
  if (!todo) {
    return sendJson(res, 404, { error: 'Todo not found' });
  }
  const body = req.body || {};
  if ('title' in body) {
    if (typeof body.title !== 'string' || body.title.trim() === '') {
      return sendJson(res, 400, { error: 'Title is required' });
    }
    todo.title = body.title;
  }
  if ('description' in body) {
    if (typeof body.description !== 'string') {
      todo.description = String(body.description);
    } else {
      todo.description = body.description;
    }
  }
  if ('completed' in body) {
    if (typeof body.completed !== 'boolean') {
      todo.completed = Boolean(body.completed);
    } else {
      todo.completed = body.completed;
    }
  }
  todo.updated_at = isoUtcSeconds();
  const { userId: _uid, ...publicTodo } = todo;
  return sendJson(res, 200, publicTodo);
});

app.delete('/todos/:id', authMiddleware, (req: Request, res: Response) => {
  const userId: number = (req as any).userId;
  const id = Number(req.params.id);
  if (!Number.isInteger(id) || id < 1) {
    return sendJson(res, 404, { error: 'Todo not found' });
  }
  const idx = todos.findIndex((t) => t.id === id && t.userId === userId);
  if (idx === -1) {
    return sendJson(res, 404, { error: 'Todo not found' });
  }
  todos.splice(idx, 1);
  res.status(204).end();
});

function parseArgs(argv: string[]): { port?: number } {
  let port: number | undefined;
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--port' && i + 1 < argv.length) {
      const p = Number(argv[i + 1]);
      if (Number.isInteger(p) && p > 0 && p < 65536) {
        port = p;
      }
    }
  }
  return { port };
}

export function startServer(port: number) {
  const server = app.listen(port, '0.0.0.0', () => {
    console.log(`Server listening on http://0.0.0.0:${port}`);
  });
  return server;
}

if (process.argv[1] && process.argv[1].includes('server')) {
  const { port } = parseArgs(process.argv.slice(2));
  const p = port ?? 3000;
  startServer(p);
}
