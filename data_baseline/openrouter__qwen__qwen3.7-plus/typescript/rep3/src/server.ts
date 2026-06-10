import express, { Request, Response, NextFunction } from 'express';
import cookieParser from 'cookie-parser';
import { v4 as uuidv4 } from 'uuid';
import bcrypt from 'bcryptjs';

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

interface CustomRequest extends Request {
  userId?: number;
}

const users = new Map<number, User>();
const usersByUsername = new Map<string, User>();
const sessions = new Map<string, number>();
const todos = new Map<number, Todo>();

let nextUserId = 1;
let nextTodoId = 1;

const app = express();
app.use(express.json());
app.use(cookieParser());

const getTimestamp = (): string => {
  return new Date().toISOString().replace(/\.\d{3}Z$/, 'Z');
};

const requireAuth = (req: CustomRequest, res: Response, next: NextFunction) => {
  const sessionId = req.cookies.session_id;
  if (!sessionId || !sessions.has(sessionId)) {
    return res.status(401).json({ error: 'Authentication required' });
  }
  req.userId = sessions.get(sessionId);
  next();
};

app.post('/register', async (req: Request, res: Response) => {
  const { username, password } = req.body || {};
  if (!username || typeof username !== 'string' || !/^[a-zA-Z0-9_]+$/.test(username) || username.length < 3 || username.length > 50) {
    return res.status(400).json({ error: 'Invalid username' });
  }
  if (!password || typeof password !== 'string' || password.length < 8) {
    return res.status(400).json({ error: 'Password too short' });
  }
  if (usersByUsername.has(username)) {
    return res.status(409).json({ error: 'Username already exists' });
  }
  const id = nextUserId++;
  const hashedPassword = await bcrypt.hash(password, 10);
  const user: User = { id, username, password: hashedPassword };
  users.set(id, user);
  usersByUsername.set(username, user);
  res.status(201).json({ id, username });
});

app.post('/login', async (req: Request, res: Response) => {
  const { username, password } = req.body || {};
  const user = usersByUsername.get(username);
  if (!user || !(await bcrypt.compare(password, user.password))) {
    return res.status(401).json({ error: 'Invalid credentials' });
  }
  const sessionId = uuidv4();
  sessions.set(sessionId, user.id);
  res.cookie('session_id', sessionId, { path: '/', httpOnly: true });
  res.status(200).json({ id: user.id, username: user.username });
});

app.post('/logout', requireAuth, (req: CustomRequest, res: Response) => {
  const sessionId = req.cookies.session_id;
  sessions.delete(sessionId);
  res.status(200).json({});
});

app.get('/me', requireAuth, (req: CustomRequest, res: Response) => {
  const user = users.get(req.userId!);
  res.status(200).json({ id: user!.id, username: user!.username });
});

app.put('/password', requireAuth, async (req: CustomRequest, res: Response) => {
  const { old_password, new_password } = req.body || {};
  const user = users.get(req.userId!);
  if (!user || !(await bcrypt.compare(old_password, user.password))) {
    return res.status(401).json({ error: 'Invalid credentials' });
  }
  if (!new_password || typeof new_password !== 'string' || new_password.length < 8) {
    return res.status(400).json({ error: 'Password too short' });
  }
  user.password = await bcrypt.hash(new_password, 10);
  res.status(200).json({});
});

app.get('/todos', requireAuth, (req: CustomRequest, res: Response) => {
  const userId = req.userId!;
  const userTodos = Array.from(todos.values())
    .filter(t => t.userId === userId)
    .sort((a, b) => a.id - b.id);
  res.status(200).json(userTodos);
});

app.post('/todos', requireAuth, (req: CustomRequest, res: Response) => {
  const { title, description } = req.body || {};
  if (typeof title !== 'string' || title.length === 0) {
    return res.status(400).json({ error: 'Title is required' });
  }
  const id = nextTodoId++;
  const now = getTimestamp();
  const todo: Todo = {
    id,
    userId: req.userId!,
    title,
    description: typeof description === 'string' ? description : '',
    completed: false,
    created_at: now,
    updated_at: now
  };
  todos.set(id, todo);
  res.status(201).json(todo);
});

app.get('/todos/:id', requireAuth, (req: CustomRequest, res: Response) => {
  const id = parseInt(req.params.id as string, 10);
  const todo = todos.get(id);
  if (!todo || todo.userId !== req.userId) {
    return res.status(404).json({ error: 'Todo not found' });
  }
  res.status(200).json(todo);
});

app.put('/todos/:id', requireAuth, (req: CustomRequest, res: Response) => {
  const id = parseInt(req.params.id as string, 10);
  const todo = todos.get(id);
  if (!todo || todo.userId !== req.userId) {
    return res.status(404).json({ error: 'Todo not found' });
  }
  const { title, description, completed } = req.body || {};
  if (title !== undefined) {
    if (typeof title !== 'string' || title.length === 0) {
      return res.status(400).json({ error: 'Title is required' });
    }
    todo.title = title;
  }
  if (description !== undefined) {
    todo.description = description;
  }
  if (completed !== undefined) {
    todo.completed = completed;
  }
  todo.updated_at = getTimestamp();
  res.status(200).json(todo);
});

app.delete('/todos/:id', requireAuth, (req: CustomRequest, res: Response) => {
  const id = parseInt(req.params.id as string, 10);
  const todo = todos.get(id);
  if (!todo || todo.userId !== req.userId) {
    return res.status(404).json({ error: 'Todo not found' });
  }
  todos.delete(id);
  res.status(204).end();
});

const port = parseInt(process.env.PORT || '3000', 10);
app.listen(port, '0.0.0.0', () => {
  console.log(`Server listening on 0.0.0.0:${port}`);
});
