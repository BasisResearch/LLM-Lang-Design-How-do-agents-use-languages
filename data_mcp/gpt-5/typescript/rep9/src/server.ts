import express, { Request, Response, NextFunction } from 'express';
import crypto from 'crypto';

// Types
interface User { id: number; username: string; passwordHash: string }
interface PublicUser { id: number; username: string }
interface Todo {
  id: number;
  userId: number;
  title: string;
  description: string;
  completed: boolean;
  created_at: string;
  updated_at: string;
}

// In-memory storage
const users: User[] = [];
const sessions: Map<string, number> = new Map(); // token -> userId
const todos: Todo[] = [];
let nextUserId = 1;
let nextTodoId = 1;

// Helpers
function isoNow(): string {
  // Ensure second precision in UTC
  const iso = new Date().toISOString();
  return iso.replace(/\.\d{3}Z$/, 'Z');
}

function hashPassword(pw: string): string {
  return crypto.createHash('sha256').update(pw).digest('hex');
}

function validateUsername(username: any): username is string {
  if (typeof username !== 'string') return false;
  if (username.length < 3 || username.length > 50) return false;
  if (!/^[a-zA-Z0-9_]+$/.test(username)) return false;
  return true;
}

function json(res: Response, code: number, body: any) {
  res.status(code).type('application/json').send(JSON.stringify(body));
}

function error(res: Response, code: number, message: string) {
  json(res, code, { error: message });
}

function setSessionCookie(res: Response, token: string) {
  // Minimal cookie attributes as specified
  res.setHeader('Set-Cookie', `session_id=${token}; Path=/; HttpOnly`);
}

function requireAuth(req: Request, res: Response, next: NextFunction) {
  const cookieHeader = req.headers['cookie'] || '';
  const cookies: Record<string, string> = {};
  cookieHeader.split(';').forEach((part) => {
    const [k, v] = part.trim().split('=');
    if (k) cookies[k] = v;
  });
  const token = cookies['session_id'];
  if (!token) {
    return error(res, 401, 'Authentication required');
  }
  const userId = sessions.get(token);
  if (!userId) {
    return error(res, 401, 'Authentication required');
  }
  const user = users.find(u => u.id === userId);
  if (!user) {
    // invalidate token if user missing
    sessions.delete(token);
    return error(res, 401, 'Authentication required');
  }
  (req as any).user = user;
  (req as any).sessionToken = token;
  next();
}

const app = express();
app.use(express.json({ type: '*/*' })); // accept any content-type with JSON body

// Ensure JSON content-type for all responses by default
app.use((req, res, next) => {
  res.type('application/json');
  next();
});

// Optional health root
app.get('/', (_req: Request, res: Response) => {
  json(res, 200, { status: 'ok' });
});

// Routes
app.post('/register', (req: Request, res: Response) => {
  const { username, password } = req.body || {};
  if (!validateUsername(username)) {
    return error(res, 400, 'Invalid username');
  }
  if (typeof password !== 'string' || password.length < 8) {
    return error(res, 400, 'Password too short');
  }
  if (users.some(u => u.username === username)) {
    return error(res, 409, 'Username already exists');
  }
  const user: User = { id: nextUserId++, username, passwordHash: hashPassword(password) };
  users.push(user);
  const pub: PublicUser = { id: user.id, username: user.username };
  json(res, 201, pub);
});

app.post('/login', (req: Request, res: Response) => {
  const { username, password } = req.body || {};
  const user = users.find(u => u.username === username);
  if (!user || typeof password !== 'string' || user.passwordHash !== hashPassword(password)) {
    return error(res, 401, 'Invalid credentials');
  }
  // generate opaque token
  const token = crypto.randomBytes(16).toString('hex');
  sessions.set(token, user.id);
  setSessionCookie(res, token);
  const pub: PublicUser = { id: user.id, username: user.username };
  json(res, 200, pub);
});

app.post('/logout', requireAuth, (req: Request, res: Response) => {
  const token = (req as any).sessionToken as string;
  sessions.delete(token);
  json(res, 200, {});
});

app.get('/me', requireAuth, (req: Request, res: Response) => {
  const user = (req as any).user as User;
  const pub: PublicUser = { id: user.id, username: user.username };
  json(res, 200, pub);
});

app.put('/password', requireAuth, (req: Request, res: Response) => {
  const user = (req as any).user as User;
  const { old_password, new_password } = req.body || {};
  if (typeof old_password !== 'string' || user.passwordHash !== hashPassword(old_password)) {
    return error(res, 401, 'Invalid credentials');
  }
  if (typeof new_password !== 'string' || new_password.length < 8) {
    return error(res, 400, 'Password too short');
  }
  user.passwordHash = hashPassword(new_password);
  json(res, 200, {});
});

app.get('/todos', requireAuth, (req: Request, res: Response) => {
  const user = (req as any).user as User;
  const list = todos.filter(t => t.userId === user.id).sort((a, b) => a.id - b.id);
  json(res, 200, list.map(({ userId, ...rest }) => rest));
});

app.post('/todos', requireAuth, (req: Request, res: Response) => {
  const user = (req as any).user as User;
  const { title, description } = req.body || {};
  if (typeof title !== 'string' || title.trim() === '') {
    return error(res, 400, 'Title is required');
  }
  const now = isoNow();
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
  const { userId, ...pub } = todo;
  json(res, 201, pub);
});

function findOwnedTodo(userId: number, idParam: string): Todo | undefined {
  const id = Number(idParam);
  if (!Number.isInteger(id) || id < 1) return undefined;
  const todo = todos.find(t => t.id === id);
  if (!todo || todo.userId !== userId) return undefined;
  return todo;
}

app.get('/todos/:id', requireAuth, (req: Request, res: Response) => {
  const user = (req as any).user as User;
  const todo = findOwnedTodo(user.id, req.params.id);
  if (!todo) return error(res, 404, 'Todo not found');
  const { userId, ...pub } = todo;
  json(res, 200, pub);
});

app.put('/todos/:id', requireAuth, (req: Request, res: Response) => {
  const user = (req as any).user as User;
  const todo = findOwnedTodo(user.id, req.params.id);
  if (!todo) return error(res, 404, 'Todo not found');
  const body = req.body || {};
  if (Object.prototype.hasOwnProperty.call(body, 'title')) {
    if (typeof body.title !== 'string' || body.title.trim() === '') {
      return error(res, 400, 'Title is required');
    }
    todo.title = body.title;
  }
  if (Object.prototype.hasOwnProperty.call(body, 'description')) {
    if (typeof body.description === 'string') todo.description = body.description;
  }
  if (Object.prototype.hasOwnProperty.call(body, 'completed')) {
    if (typeof body.completed === 'boolean') todo.completed = body.completed;
  }
  todo.updated_at = isoNow();
  const { userId, ...pub } = todo;
  json(res, 200, pub);
});

app.delete('/todos/:id', requireAuth, (req: Request, res: Response) => {
  const user = (req as any).user as User;
  const id = Number(req.params.id);
  if (!Number.isInteger(id) || id < 1) return error(res, 404, 'Todo not found');
  const idx = todos.findIndex(t => t.id === id && t.userId === user.id);
  if (idx === -1) return error(res, 404, 'Todo not found');
  todos.splice(idx, 1);
  // DELETE should return no body; override default json content-type by ending the response
  res.status(204);
  res.removeHeader('Content-Type');
  res.end();
});

// Catch-all 404 in JSON
app.use((req: Request, res: Response) => {
  error(res, 404, 'Not found');
});

// CLI: --port PORT
function getPortArg(): number | undefined {
  const args = process.argv.slice(2);
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--port' && i + 1 < args.length) {
      const p = Number(args[i + 1]);
      if (Number.isInteger(p) && p > 0 && p < 65536) return p;
    }
  }
  return undefined;
}

const port = getPortArg() ?? 3000;

const server = app.listen(port, '0.0.0.0', () => {
  console.log(`Server listening on 0.0.0.0:${port}`);
});

export default server;
