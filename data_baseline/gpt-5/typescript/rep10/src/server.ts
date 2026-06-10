import express, { Request, Response, NextFunction } from 'express';
import { v4 as uuidv4 } from 'uuid';

// Types
interface User {
  id: number;
  username: string;
  password: string; // stored plain in-memory for this exercise only
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
const sessions: Map<string, number> = new Map(); // session_id -> userId
const todos: Todo[] = [];
let nextUserId = 1;
let nextTodoId = 1;

// Helpers
function jsonContent(res: Response) {
  res.setHeader('Content-Type', 'application/json');
}

function nowIsoSeconds(): string {
  const d = new Date();
  // Ensure seconds precision, UTC
  const iso = d.toISOString(); // e.g., 2025-01-15T09:30:00.123Z
  return iso.replace(/\..+Z$/, 'Z'); // strip milliseconds
}

function sendError(res: Response, code: number, message: string) {
  jsonContent(res);
  res.status(code).send(JSON.stringify({ error: message }));
}

function parsePortArg(): number {
  const args = process.argv.slice(2);
  const portIndex = args.indexOf('--port');
  let port = 3000;
  if (portIndex !== -1 && args[portIndex + 1]) {
    const val = Number(args[portIndex + 1]);
    if (!Number.isNaN(val) && val > 0 && val < 65536) {
      port = val;
    }
  }
  return port;
}

function getAuthUser(req: Request): User | null {
  const cookieHeader = req.headers['cookie'];
  if (!cookieHeader) return null;
  const cookies = Object.fromEntries(cookieHeader.split(';').map(p => {
    const [k, ...rest] = p.trim().split('=');
    return [k, rest.join('=')];
  }));
  const token = cookies['session_id'];
  if (!token) return null;
  const userId = sessions.get(token);
  if (!userId) return null;
  return users.find(u => u.id === userId) || null;
}

function authRequired(req: Request, res: Response, next: NextFunction) {
  const user = getAuthUser(req);
  if (!user) {
    return sendError(res, 401, 'Authentication required');
  }
  // @ts-ignore attach
  (req as any).user = user;
  next();
}

const app = express();
app.use(express.json({ type: '*/*' }));

// Ensure all responses have application/json except DELETE 204
app.use((req, res, next) => {
  // We'll set explicitly in handlers; this middleware is a safety net for non-DELETE
  if (req.method !== 'DELETE') {
    jsonContent(res);
  }
  next();
});

// POST /register
app.post('/register', (req: Request, res: Response) => {
  const { username, password } = req.body || {};
  const usernameRegex = /^[a-zA-Z0-9_]{3,50}$/;
  if (!username || typeof username !== 'string' || !usernameRegex.test(username)) {
    return sendError(res, 400, 'Invalid username');
  }
  if (!password || typeof password !== 'string' || password.length < 8) {
    return sendError(res, 400, 'Password too short');
  }
  if (users.some(u => u.username === username)) {
    return sendError(res, 409, 'Username already exists');
  }
  const user: User = { id: nextUserId++, username, password };
  users.push(user);
  res.status(201).send(JSON.stringify({ id: user.id, username: user.username }));
});

// POST /login
app.post('/login', (req: Request, res: Response) => {
  const { username, password } = req.body || {};
  const user = users.find(u => u.username === username);
  if (!user || user.password !== password) {
    return sendError(res, 401, 'Invalid credentials');
  }
  const token = uuidv4().replace(/-/g, '');
  sessions.set(token, user.id);
  res.setHeader('Set-Cookie', `session_id=${token}; Path=/; HttpOnly`);
  res.status(200).send(JSON.stringify({ id: user.id, username: user.username }));
});

// POST /logout
app.post('/logout', authRequired, (req: Request, res: Response) => {
  const cookieHeader = req.headers['cookie'] || '';
  const cookies = Object.fromEntries(cookieHeader.split(';').filter(Boolean).map(p => {
    const [k, ...rest] = p.trim().split('=');
    return [k, rest.join('=')];
  }));
  const token = cookies['session_id'];
  if (token) {
    sessions.delete(token);
  }
  res.status(200).send(JSON.stringify({}));
});

// GET /me
app.get('/me', authRequired, (req: Request, res: Response) => {
  const user = (req as any).user as User;
  res.status(200).send(JSON.stringify({ id: user.id, username: user.username }));
});

// PUT /password
app.put('/password', authRequired, (req: Request, res: Response) => {
  const user = (req as any).user as User;
  const { old_password, new_password } = req.body || {};
  if (!old_password || user.password !== old_password) {
    return sendError(res, 401, 'Invalid credentials');
  }
  if (!new_password || typeof new_password !== 'string' || new_password.length < 8) {
    return sendError(res, 400, 'Password too short');
  }
  user.password = new_password;
  res.status(200).send(JSON.stringify({}));
});

// GET /todos
app.get('/todos', authRequired, (req: Request, res: Response) => {
  const user = (req as any).user as User;
  const userTodos = todos.filter(t => t.userId === user.id).sort((a, b) => a.id - b.id);
  res.status(200).send(JSON.stringify(userTodos.map(({ userId, ...rest }) => rest)));
});

// POST /todos
app.post('/todos', authRequired, (req: Request, res: Response) => {
  const user = (req as any).user as User;
  const { title, description } = req.body || {};
  if (!title || typeof title !== 'string' || title.trim() === '') {
    return sendError(res, 400, 'Title is required');
  }
  const now = nowIsoSeconds();
  const todo: Todo = {
    id: nextTodoId++,
    userId: user.id,
    title: title,
    description: typeof description === 'string' ? description : '',
    completed: false,
    created_at: now,
    updated_at: now,
  };
  todos.push(todo);
  const { userId, ...publicTodo } = todo;
  res.status(201).send(JSON.stringify(publicTodo));
});

function findOwnedTodo(userId: number, idParam: string): Todo | null {
  const id = Number(idParam);
  if (!Number.isInteger(id) || id <= 0) return null;
  const todo = todos.find(t => t.id === id);
  if (!todo || todo.userId !== userId) return null;
  return todo;
}

// GET /todos/:id
app.get('/todos/:id', authRequired, (req: Request, res: Response) => {
  const user = (req as any).user as User;
  const todo = findOwnedTodo(user.id, req.params.id);
  if (!todo) {
    return sendError(res, 404, 'Todo not found');
  }
  const { userId, ...publicTodo } = todo;
  res.status(200).send(JSON.stringify(publicTodo));
});

// PUT /todos/:id (partial update)
app.put('/todos/:id', authRequired, (req: Request, res: Response) => {
  const user = (req as any).user as User;
  const todo = findOwnedTodo(user.id, req.params.id);
  if (!todo) {
    return sendError(res, 404, 'Todo not found');
  }
  const { title, description, completed } = req.body || {};
  if (title !== undefined) {
    if (typeof title !== 'string' || title.trim() === '') {
      return sendError(res, 400, 'Title is required');
    }
    todo.title = title;
  }
  if (description !== undefined) {
    if (typeof description !== 'string') {
      // Coerce to string? Spec doesn't say; better to reject subtly? We'll coerce to string to be robust
      todo.description = String(description);
    } else {
      todo.description = description;
    }
  }
  if (completed !== undefined) {
    if (typeof completed !== 'boolean') {
      // Try to coerce "true"/"false" strings
      if (completed === 'true') todo.completed = true as any;
      else if (completed === 'false') todo.completed = false as any;
      else return sendError(res, 400, 'Invalid payload');
    } else {
      todo.completed = completed;
    }
  }
  todo.updated_at = nowIsoSeconds();
  const { userId, ...publicTodo } = todo;
  res.status(200).send(JSON.stringify(publicTodo));
});

// DELETE /todos/:id
app.delete('/todos/:id', authRequired, (req: Request, res: Response) => {
  const user = (req as any).user as User;
  const id = Number(req.params.id);
  if (!Number.isInteger(id) || id <= 0) {
    return sendError(res, 404, 'Todo not found');
  }
  const idx = todos.findIndex(t => t.id === id && t.userId === user.id);
  if (idx === -1) {
    return sendError(res, 404, 'Todo not found');
  }
  todos.splice(idx, 1);
  // No content and no JSON header body per spec
  res.status(204).end();
});

// 404 handler for other routes
app.use((req, res) => {
  sendError(res, 404, 'Not found');
});

const port = parsePortArg();
app.listen(port, '0.0.0.0', () => {
  console.log(`Server listening on 0.0.0.0:${port}`);
});
