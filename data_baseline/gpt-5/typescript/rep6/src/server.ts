import express, { Request, Response, NextFunction } from 'express';
import cookieParser from 'cookie-parser';
import { v4 as uuidv4 } from 'uuid';

// Types
interface User { id: number; username: string; password: string; }
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

// In-memory stores
const users: User[] = [];
let nextUserId = 1;

const sessions = new Map<string, number>(); // session_id -> userId

const todos: Todo[] = [];
let nextTodoId = 1;

// Helpers
function toPublicUser(u: User): PublicUser { return { id: u.id, username: u.username }; }

function nowIso(): string {
  const d = new Date();
  // Ensure second precision and UTC with Z
  const iso = new Date(Math.floor(d.getTime() / 1000) * 1000).toISOString();
  return iso.replace(/\..+Z$/, 'Z');
}

function json(res: Response, status: number, body: any) {
  res.status(status);
  res.setHeader('Content-Type', 'application/json');
  res.send(JSON.stringify(body));
}

function error(res: Response, status: number, message: string) {
  json(res, status, { error: message });
}

function findUserByUsername(username: string): User | undefined {
  return users.find(u => u.username === username);
}

function authMiddleware(req: Request, res: Response, next: NextFunction) {
  const token = req.cookies?.['session_id'];
  if (!token) {
    return error(res, 401, 'Authentication required');
  }
  const userId = sessions.get(token);
  if (!userId) {
    return error(res, 401, 'Authentication required');
  }
  const user = users.find(u => u.id === userId);
  if (!user) {
    // If somehow user missing, treat as invalid session
    sessions.delete(token);
    return error(res, 401, 'Authentication required');
  }
  // attach to req
  (req as any).user = user;
  (req as any).sessionToken = token;
  next();
}

const app = express();
app.use(express.json());
app.use(cookieParser());

// Ensure all non-DELETE responses have application/json content-type
app.use((req, res, next) => {
  // We'll set explicitly in json()/error(), but this ensures default
  if (req.method !== 'DELETE') {
    res.setHeader('Content-Type', 'application/json');
  }
  next();
});

// Routes
// POST /register
app.post('/register', (req: Request, res: Response) => {
  const { username, password } = req.body || {};
  const usernameRegex = /^[a-zA-Z0-9_]{3,50}$/;
  if (typeof username !== 'string' || !usernameRegex.test(username)) {
    return error(res, 400, 'Invalid username');
  }
  if (typeof password !== 'string' || password.length < 8) {
    return error(res, 400, 'Password too short');
  }
  if (findUserByUsername(username)) {
    return error(res, 409, 'Username already exists');
  }
  const user: User = { id: nextUserId++, username, password };
  users.push(user);
  return json(res, 201, toPublicUser(user));
});

// POST /login
app.post('/login', (req: Request, res: Response) => {
  const { username, password } = req.body || {};
  const user = findUserByUsername(username);
  if (!user || user.password !== password) {
    return error(res, 401, 'Invalid credentials');
  }
  // create session
  const token = uuidv4().replace(/-/g, '');
  sessions.set(token, user.id);
  res.cookie('session_id', token, { httpOnly: true, path: '/' });
  return json(res, 200, toPublicUser(user));
});

// POST /logout
app.post('/logout', authMiddleware, (req: Request, res: Response) => {
  const token = (req as any).sessionToken as string | undefined;
  if (token) {
    sessions.delete(token);
  }
  return json(res, 200, {});
});

// GET /me
app.get('/me', authMiddleware, (req: Request, res: Response) => {
  const user = (req as any).user as User;
  return json(res, 200, toPublicUser(user));
});

// PUT /password
app.put('/password', authMiddleware, (req: Request, res: Response) => {
  const user = (req as any).user as User;
  const { old_password, new_password } = req.body || {};
  if (typeof old_password !== 'string' || user.password !== old_password) {
    return error(res, 401, 'Invalid credentials');
  }
  if (typeof new_password !== 'string' || new_password.length < 8) {
    return error(res, 400, 'Password too short');
  }
  user.password = new_password;
  return json(res, 200, {});
});

// GET /todos
app.get('/todos', authMiddleware, (req: Request, res: Response) => {
  const user = (req as any).user as User;
  const userTodos = todos.filter(t => t.userId === user.id).sort((a, b) => a.id - b.id);
  return json(res, 200, userTodos.map(({ userId, ...rest }) => rest));
});

// POST /todos
app.post('/todos', authMiddleware, (req: Request, res: Response) => {
  const user = (req as any).user as User;
  const { title, description } = req.body || {};
  if (typeof title !== 'string' || title.trim() === '') {
    return error(res, 400, 'Title is required');
  }
  const now = nowIso();
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
  return json(res, 201, publicTodo);
});

function getTodoForUser(idParam: string, user: User): Todo | undefined {
  const id = Number(idParam);
  if (!Number.isInteger(id) || id <= 0) return undefined;
  const t = todos.find(td => td.id === id);
  if (!t) return undefined;
  if (t.userId !== user.id) return undefined; // return undefined to map to 404
  return t;
}

// GET /todos/:id
app.get('/todos/:id', authMiddleware, (req: Request, res: Response) => {
  const user = (req as any).user as User;
  const t = getTodoForUser(req.params.id, user);
  if (!t) return error(res, 404, 'Todo not found');
  const { userId, ...publicTodo } = t;
  return json(res, 200, publicTodo);
});

// PUT /todos/:id (partial update)
app.put('/todos/:id', authMiddleware, (req: Request, res: Response) => {
  const user = (req as any).user as User;
  const t = getTodoForUser(req.params.id, user);
  if (!t) return error(res, 404, 'Todo not found');
  const { title, description, completed } = req.body || {};
  if (title !== undefined) {
    if (typeof title !== 'string' || title.trim() === '') {
      return error(res, 400, 'Title is required');
    }
    t.title = title;
  }
  if (description !== undefined) {
    if (typeof description !== 'string') {
      // Enforce string type for description
      return error(res, 400, 'Invalid description');
    }
    t.description = description;
  }
  if (completed !== undefined) {
    if (typeof completed !== 'boolean') {
      return error(res, 400, 'Invalid completed');
    }
    t.completed = completed;
  }
  t.updated_at = nowIso();
  const { userId, ...publicTodo } = t;
  return json(res, 200, publicTodo);
});

// DELETE /todos/:id
app.delete('/todos/:id', authMiddleware, (req: Request, res: Response) => {
  const user = (req as any).user as User;
  const id = Number(req.params.id);
  if (!Number.isInteger(id) || id <= 0) {
    return error(res, 404, 'Todo not found');
  }
  const idx = todos.findIndex(td => td.id === id && td.userId === user.id);
  if (idx === -1) {
    return error(res, 404, 'Todo not found');
  }
  todos.splice(idx, 1);
  res.status(204);
  return res.end();
});

// CLI arg parsing for --port
function parsePortArg(argv: string[]): number {
  const portFlagIndex = argv.indexOf('--port');
  if (portFlagIndex !== -1 && argv.length > portFlagIndex + 1) {
    const p = Number(argv[portFlagIndex + 1]);
    if (Number.isInteger(p) && p > 0 && p < 65536) return p;
  }
  // Default to 3000 if not provided
  return 3000;
}

const port = parsePortArg(process.argv);
app.listen(port, '0.0.0.0', () => {
  console.log(`Server listening on 0.0.0.0:${port}`);
});
