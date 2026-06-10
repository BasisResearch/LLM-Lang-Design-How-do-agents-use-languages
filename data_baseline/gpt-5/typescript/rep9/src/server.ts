import express, { Request, Response, NextFunction } from 'express';
import cookieParser from 'cookie-parser';
import crypto from 'crypto';

// Types
interface User {
  id: number;
  username: string;
  passwordHash: string; // store hash for in-memory demo
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

// In-memory storage
const users: User[] = [];
const usernames = new Map<string, User>();
let nextUserId = 1;

const todos: Todo[] = [];
let nextTodoId = 1;

// session_id -> userId
const sessions = new Map<string, number>();

// Utils
function nowIsoSeconds(): string {
  // ISO 8601 UTC timestamp with second precision
  const d = new Date();
  const iso = d.toISOString();
  return iso.replace(/\.\d{3}Z$/, 'Z');
}

function hashPassword(pw: string): string {
  return crypto.createHash('sha256').update(pw, 'utf8').digest('hex');
}

function generateToken(): string {
  return crypto.randomBytes(16).toString('hex');
}

// Express app
const app = express();
app.use(express.json());
app.use(cookieParser());

// Force JSON content-type on all responses except 204
app.use((req: Request, res: Response, next: NextFunction) => {
  const originalSend = res.send.bind(res);
  res.send = ((body?: any) => {
    if (!res.get('Content-Type') && res.statusCode !== 204) {
      res.type('application/json');
    }
    // Ensure string body for objects
    if (typeof body === 'object' && body !== null) {
      return originalSend(JSON.stringify(body));
    }
    return originalSend(body);
  }) as any;
  next();
});

// Helper to send error
function sendError(res: Response, code: number, message: string) {
  res.status(code).json({ error: message });
}

// Auth middleware
function requireAuth(req: Request, res: Response, next: NextFunction) {
  const token = req.cookies?.session_id as string | undefined;
  if (!token) {
    return sendError(res, 401, 'Authentication required');
  }
  const userId = sessions.get(token);
  if (!userId) {
    return sendError(res, 401, 'Authentication required');
  }
  const user = users.find(u => u.id === userId);
  if (!user) {
    return sendError(res, 401, 'Authentication required');
  }
  (req as any).user = user;
  (req as any).sessionToken = token;
  next();
}

// Routes
// POST /register
app.post('/register', (req: Request, res: Response) => {
  const { username, password } = req.body || {};
  // Validate username
  if (typeof username !== 'string' || username.length < 3 || username.length > 50 || !/^[a-zA-Z0-9_]+$/.test(username)) {
    return sendError(res, 400, 'Invalid username');
  }
  // Validate password
  if (typeof password !== 'string' || password.length < 8) {
    return sendError(res, 400, 'Password too short');
  }
  // Unique username
  if (usernames.has(username)) {
    return sendError(res, 409, 'Username already exists');
  }
  const user: User = {
    id: nextUserId++,
    username,
    passwordHash: hashPassword(password)
  };
  users.push(user);
  usernames.set(username, user);
  res.status(201).json({ id: user.id, username: user.username });
});

// POST /login
app.post('/login', (req: Request, res: Response) => {
  const { username, password } = req.body || {};
  const user = usernames.get(username);
  if (!user || hashPassword(password || '') !== user.passwordHash) {
    return sendError(res, 401, 'Invalid credentials');
  }
  const token = generateToken();
  sessions.set(token, user.id);
  res.setHeader('Set-Cookie', `session_id=${token}; Path=/; HttpOnly`);
  res.json({ id: user.id, username: user.username });
});

// POST /logout
app.post('/logout', requireAuth, (req: Request, res: Response) => {
  const token = (req as any).sessionToken as string;
  sessions.delete(token);
  res.json({});
});

// GET /me
app.get('/me', requireAuth, (req: Request, res: Response) => {
  const user = (req as any).user as User;
  res.json({ id: user.id, username: user.username });
});

// PUT /password
app.put('/password', requireAuth, (req: Request, res: Response) => {
  const user = (req as any).user as User;
  const { old_password, new_password } = req.body || {};
  if (hashPassword(old_password || '') !== user.passwordHash) {
    return sendError(res, 401, 'Invalid credentials');
  }
  if (typeof new_password !== 'string' || new_password.length < 8) {
    return sendError(res, 400, 'Password too short');
  }
  user.passwordHash = hashPassword(new_password);
  res.json({});
});

// GET /todos
app.get('/todos', requireAuth, (req: Request, res: Response) => {
  const user = (req as any).user as User;
  const list = todos.filter(t => t.userId === user.id).sort((a, b) => a.id - b.id);
  res.json(list.map(({ userId, ...rest }) => rest));
});

// POST /todos
app.post('/todos', requireAuth, (req: Request, res: Response) => {
  const user = (req as any).user as User;
  const { title, description } = req.body || {};
  if (typeof title !== 'string' || title.trim() === '') {
    return sendError(res, 400, 'Title is required');
  }
  const created = nowIsoSeconds();
  const todo: Todo = {
    id: nextTodoId++,
    userId: user.id,
    title: title,
    description: typeof description === 'string' ? description : '',
    completed: false,
    created_at: created,
    updated_at: created
  };
  todos.push(todo);
  const { userId, ...publicTodo } = todo;
  res.status(201).json(publicTodo);
});

function findUserTodoById(userId: number, idParam: string): { todo?: Todo, error?: { code: number, msg: string } } {
  const id = Number(idParam);
  if (!Number.isInteger(id) || id <= 0) {
    return { error: { code: 404, msg: 'Todo not found' } };
  }
  const todo = todos.find(t => t.id === id);
  if (!todo || todo.userId !== userId) {
    return { error: { code: 404, msg: 'Todo not found' } };
  }
  return { todo };
}

// GET /todos/:id
app.get('/todos/:id', requireAuth, (req: Request, res: Response) => {
  const user = (req as any).user as User;
  const { todo, error } = findUserTodoById(user.id, req.params.id);
  if (error) return sendError(res, error.code, error.msg);
  const { userId, ...publicTodo } = todo!;
  res.json(publicTodo);
});

// PUT /todos/:id (partial update)
app.put('/todos/:id', requireAuth, (req: Request, res: Response) => {
  const user = (req as any).user as User;
  const { todo, error } = findUserTodoById(user.id, req.params.id);
  if (error) return sendError(res, error.code, error.msg);

  const body = req.body || {};
  if ('title' in body) {
    if (typeof body.title !== 'string' || body.title.trim() === '') {
      return sendError(res, 400, 'Title is required');
    }
    todo!.title = body.title;
  }
  if ('description' in body) {
    if (typeof body.description !== 'string') {
      // coerce to string for robustness
      todo!.description = String(body.description);
    } else {
      todo!.description = body.description;
    }
  }
  if ('completed' in body) {
    if (typeof body.completed !== 'boolean') {
      return sendError(res, 400, 'Invalid request');
    }
    todo!.completed = body.completed;
  }
  todo!.updated_at = nowIsoSeconds();
  const { userId, ...publicTodo } = todo!;
  res.json(publicTodo);
});

// DELETE /todos/:id
app.delete('/todos/:id', requireAuth, (req: Request, res: Response) => {
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
  res.status(204).end();
});

// Error handling to ensure JSON responses
app.use((err: any, _req: Request, res: Response, _next: NextFunction) => {
  if (err?.type === 'entity.parse.failed' || err instanceof SyntaxError) {
    return sendError(res, 400, 'Invalid JSON');
  }
  console.error('Unhandled error:', err);
  return sendError(res, 500, 'Internal server error');
});

// 404 handler for unknown routes (JSON)
app.use((req: Request, res: Response) => {
  sendError(res, 404, 'Not found');
});

// Start server
function start(port: number) {
  const server = app.listen(port, '0.0.0.0', () => {
    console.log(`Server listening on 0.0.0.0:${port}`);
  });
  return server;
}

// CLI handling
if (process.argv[1] && process.argv[1].endsWith('server.js')) {
  // Running compiled JS directly
  const portArgIndex = process.argv.indexOf('--port');
  const port = portArgIndex !== -1 ? Number(process.argv[portArgIndex + 1]) : 3000;
  start(port);
}

export default start;
