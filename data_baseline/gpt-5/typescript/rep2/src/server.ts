import express, { Request, Response, NextFunction } from 'express';
import cookieParser from 'cookie-parser';
import { v4 as uuidv4 } from 'uuid';

// Types
interface User {
  id: number;
  username: string;
  password: string; // stored in-memory plain per spec; in real systems hash it
}

interface Todo {
  id: number;
  userId: number;
  title: string;
  description: string;
  completed: boolean;
  created_at: string; // ISO 8601 UTC with seconds precision
  updated_at: string;
}

// In-memory storage
const users: User[] = [];
const todos: Todo[] = [];
const sessions = new Map<string, number>(); // sessionId -> userId
let nextUserId = 1;
let nextTodoId = 1;

// Helpers
function nowIsoSeconds(): string {
  const d = new Date();
  // Ensure seconds precision, UTC
  return new Date(Math.floor(d.getTime() / 1000) * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');
}

function isValidUsername(username: unknown): username is string {
  return typeof username === 'string' && username.length >= 3 && username.length <= 50 && /^[a-zA-Z0-9_]+$/.test(username);
}

function sendJson(res: Response, status: number, body: any) {
  res.status(status).type('application/json');
  // DELETE endpoints may send no body; however our helper not used there
  res.send(JSON.stringify(body));
}

function sendError(res: Response, status: number, message: string) {
  sendJson(res, status, { error: message });
}

// Middleware for auth
function requireAuth(req: Request, res: Response, next: NextFunction) {
  const token = req.cookies?.['session_id'];
  if (!token || !sessions.has(token)) {
    res.status(401).type('application/json').send(JSON.stringify({ error: 'Authentication required' }));
    return;
  }
  const userId = sessions.get(token)!;
  const user = users.find(u => u.id === userId);
  if (!user) {
    // Safety: invalidate stray session
    sessions.delete(token);
    res.status(401).type('application/json').send(JSON.stringify({ error: 'Authentication required' }));
    return;
  }
  (req as any).user = user;
  (req as any).sessionToken = token;
  next();
}

// Create app
const app = express();
app.use(express.json());
app.use(cookieParser());

// Ensure JSON content-type for all responses except 204 deletes
app.use((req, res, next) => {
  // We'll set content-type explicitly in handlers. This ensures default.
  res.type('application/json');
  next();
});

// Routes
app.post('/register', (req: Request, res: Response) => {
  const { username, password } = req.body || {};
  if (!isValidUsername(username)) {
    return sendError(res, 400, 'Invalid username');
  }
  if (typeof password !== 'string' || password.length < 8) {
    return sendError(res, 400, 'Password too short');
  }
  const existing = users.find(u => u.username === username);
  if (existing) {
    return sendError(res, 409, 'Username already exists');
  }
  const user: User = { id: nextUserId++, username, password };
  users.push(user);
  return sendJson(res, 201, { id: user.id, username: user.username });
});

app.post('/login', (req: Request, res: Response) => {
  const { username, password } = req.body || {};
  const user = users.find(u => u.username === username);
  if (!user || user.password !== password) {
    return sendError(res, 401, 'Invalid credentials');
  }
  const token = uuidv4().replace(/-/g, '');
  sessions.set(token, user.id);
  res.setHeader('Set-Cookie', `session_id=${token}; Path=/; HttpOnly`);
  return sendJson(res, 200, { id: user.id, username: user.username });
});

app.post('/logout', requireAuth, (req: Request, res: Response) => {
  const token: string = (req as any).sessionToken;
  sessions.delete(token);
  return sendJson(res, 200, {});
});

app.get('/me', requireAuth, (req: Request, res: Response) => {
  const user: User = (req as any).user;
  return sendJson(res, 200, { id: user.id, username: user.username });
});

app.put('/password', requireAuth, (req: Request, res: Response) => {
  const user: User = (req as any).user;
  const { old_password, new_password } = req.body || {};
  if (typeof old_password !== 'string' || user.password !== old_password) {
    return sendError(res, 401, 'Invalid credentials');
  }
  if (typeof new_password !== 'string' || new_password.length < 8) {
    return sendError(res, 400, 'Password too short');
  }
  user.password = new_password;
  return sendJson(res, 200, {});
});

app.get('/todos', requireAuth, (req: Request, res: Response) => {
  const user: User = (req as any).user;
  const list = todos.filter(t => t.userId === user.id).sort((a, b) => a.id - b.id).map(({ userId, ...rest }) => rest);
  return sendJson(res, 200, list);
});

app.post('/todos', requireAuth, (req: Request, res: Response) => {
  const user: User = (req as any).user;
  const { title, description } = req.body || {};
  if (typeof title !== 'string' || title.trim() === '') {
    return sendError(res, 400, 'Title is required');
  }
  const desc = typeof description === 'string' ? description : '';
  const timestamp = nowIsoSeconds();
  const todo: Todo = {
    id: nextTodoId++,
    userId: user.id,
    title,
    description: desc,
    completed: false,
    created_at: timestamp,
    updated_at: timestamp,
  };
  todos.push(todo);
  const { userId, ...visible } = todo;
  return sendJson(res, 201, visible);
});

function findOwnedTodo(userId: number, idStr: string | undefined): Todo | undefined {
  const id = Number(idStr);
  if (!Number.isInteger(id) || id < 1) return undefined;
  const t = todos.find(td => td.id === id);
  if (!t || t.userId !== userId) return undefined;
  return t;
}

app.get('/todos/:id', requireAuth, (req: Request, res: Response) => {
  const user: User = (req as any).user;
  const t = findOwnedTodo(user.id, req.params.id);
  if (!t) return sendError(res, 404, 'Todo not found');
  const { userId, ...visible } = t;
  return sendJson(res, 200, visible);
});

app.put('/todos/:id', requireAuth, (req: Request, res: Response) => {
  const user: User = (req as any).user;
  const t = findOwnedTodo(user.id, req.params.id);
  if (!t) return sendError(res, 404, 'Todo not found');
  const body = req.body || {};
  if ('title' in body) {
    if (typeof body.title !== 'string' || body.title.trim() === '') {
      return sendError(res, 400, 'Title is required');
    }
    t.title = body.title;
  }
  if ('description' in body) {
    if (typeof body.description !== 'string') {
      // Coerce to string only if provided string else set empty string? Spec doesn't say invalid types; be strict.
      return sendError(res, 400, 'Invalid description');
    }
    t.description = body.description;
  }
  if ('completed' in body) {
    if (typeof body.completed !== 'boolean') {
      return sendError(res, 400, 'Invalid completed');
    }
    t.completed = body.completed;
  }
  t.updated_at = nowIsoSeconds();
  const { userId, ...visible } = t;
  return sendJson(res, 200, visible);
});

app.delete('/todos/:id', requireAuth, (req: Request, res: Response) => {
  const user: User = (req as any).user;
  const id = Number(req.params.id);
  if (!Number.isInteger(id) || id < 1) {
    return sendError(res, 404, 'Todo not found');
  }
  const idx = todos.findIndex(td => td.id === id && td.userId === user.id);
  if (idx === -1) return sendError(res, 404, 'Todo not found');
  todos.splice(idx, 1);
  // 204 no content; ensure no body and no JSON content-type body
  res.status(204);
  // For safety still set content-type json per spec exception says DELETE returns no body
  res.end();
});

// Port from CLI
function parsePortArg(): number {
  const args = process.argv.slice(2);
  let port: number | undefined;
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--port' && i + 1 < args.length) {
      const p = Number(args[i + 1]);
      if (Number.isInteger(p) && p > 0 && p < 65536) {
        port = p;
      }
    }
  }
  return port ?? 3000;
}

const port = parsePortArg();
app.listen(port, '0.0.0.0', () => {
  console.log(`Server listening on 0.0.0.0:${port}`);
});
