import express, { Request, Response, NextFunction } from 'express';
import cookieParser from 'cookie-parser';
import { randomUUID } from 'crypto';

interface User {
  id: number;
  username: string;
  password: string;
}

interface Todo {
  id: number;
  user_id: number;
  title: string;
  description: string;
  completed: boolean;
  created_at: string;
  updated_at: string;
}

const users: User[] = [];
const todos: Todo[] = [];
const sessions: Map<string, number> = new Map();

let nextUserId = 1;
let nextTodoId = 1;

function getTimestamp(): string {
  return new Date().toISOString().split('.')[0] + 'Z';
}

const app = express();

app.use(cookieParser());
app.use(express.json());

interface AuthRequest extends Request {
  userId?: number;
}

function authenticate(req: AuthRequest, res: Response, next: NextFunction) {
  const token = req.cookies?.session_id;
  if (!token || !sessions.has(token)) {
    return res.status(401).json({ error: 'Authentication required' });
  }
  req.userId = sessions.get(token);
  next();
}

app.post('/register', (req: Request, res: Response) => {
  const { username, password } = req.body;
  if (!username || typeof username !== 'string' || !/^[a-zA-Z0-9_]+$/.test(username) || username.length < 3 || username.length > 50) {
    return res.status(400).json({ error: 'Invalid username' });
  }
  if (!password || typeof password !== 'string' || password.length < 8) {
    return res.status(400).json({ error: 'Password too short' });
  }
  if (users.some((u) => u.username === username)) {
    return res.status(409).json({ error: 'Username already exists' });
  }
  const newUser: User = {
    id: nextUserId++,
    username,
    password,
  };
  users.push(newUser);
  res.status(201).json({ id: newUser.id, username: newUser.username });
});

app.post('/login', (req: Request, res: Response) => {
  const { username, password } = req.body;
  const user = users.find((u) => u.username === username && u.password === password);
  if (!user) {
    return res.status(401).json({ error: 'Invalid credentials' });
  }
  const token = randomUUID();
  sessions.set(token, user.id);
  res.cookie('session_id', token, { path: '/', httpOnly: true });
  res.status(200).json({ id: user.id, username: user.username });
});

app.post('/logout', authenticate, (req: AuthRequest, res: Response) => {
  const token = req.cookies?.session_id;
  if (token) {
    sessions.delete(token);
  }
  res.status(200).json({});
});

app.get('/me', authenticate, (req: AuthRequest, res: Response) => {
  const user = users.find((u) => u.id === req.userId);
  if (!user) {
    return res.status(401).json({ error: 'Invalid credentials' });
  }
  res.status(200).json({ id: user.id, username: user.username });
});

app.put('/password', authenticate, (req: AuthRequest, res: Response) => {
  const user = users.find((u) => u.id === req.userId);
  if (!user) {
    return res.status(401).json({ error: 'Invalid credentials' });
  }
  const { old_password, new_password } = req.body;
  if (user.password !== old_password) {
    return res.status(401).json({ error: 'Invalid credentials' });
  }
  if (!new_password || typeof new_password !== 'string' || new_password.length < 8) {
    return res.status(400).json({ error: 'Password too short' });
  }
  user.password = new_password;
  res.status(200).json({});
});

app.get('/todos', authenticate, (req: AuthRequest, res: Response) => {
  const userTodos = todos.filter((t) => t.user_id === req.userId).sort((a, b) => a.id - b.id);
  const formattedTodos = userTodos.map((t) => ({
    id: t.id,
    title: t.title,
    description: t.description,
    completed: t.completed,
    created_at: t.created_at,
    updated_at: t.updated_at,
  }));
  res.status(200).json(formattedTodos);
});

app.post('/todos', authenticate, (req: AuthRequest, res: Response) => {
  const { title, description } = req.body;
  if (!title || typeof title !== 'string' || title === '') {
    return res.status(400).json({ error: 'Title is required' });
  }
  const now = getTimestamp();
  const newTodo: Todo = {
    id: nextTodoId++,
    user_id: req.userId!,
    title,
    description: typeof description === 'string' ? description : '',
    completed: false,
    created_at: now,
    updated_at: now,
  };
  todos.push(newTodo);
  res.status(201).json({
    id: newTodo.id,
    title: newTodo.title,
    description: newTodo.description,
    completed: newTodo.completed,
    created_at: newTodo.created_at,
    updated_at: newTodo.updated_at,
  });
});

app.get('/todos/:id', authenticate, (req: AuthRequest, res: Response) => {
  const todoId = parseInt(req.params.id, 10);
  const todo = todos.find((t) => t.id === todoId && t.user_id === req.userId);
  if (!todo) {
    return res.status(404).json({ error: 'Todo not found' });
  }
  res.status(200).json({
    id: todo.id,
    title: todo.title,
    description: todo.description,
    completed: todo.completed,
    created_at: todo.created_at,
    updated_at: todo.updated_at,
  });
});

app.put('/todos/:id', authenticate, (req: AuthRequest, res: Response) => {
  const todoId = parseInt(req.params.id, 10);
  const todo = todos.find((t) => t.id === todoId && t.user_id === req.userId);
  if (!todo) {
    return res.status(404).json({ error: 'Todo not found' });
  }

  const { title, description, completed } = req.body;

  if (title !== undefined) {
    if (typeof title !== 'string' || title === '') {
      return res.status(400).json({ error: 'Title is required' });
    }
    todo.title = title;
  }
  if (description !== undefined) {
    todo.description = typeof description === 'string' ? description : '';
  }
  if (completed !== undefined) {
    todo.completed = Boolean(completed);
  }

  todo.updated_at = getTimestamp();

  res.status(200).json({
    id: todo.id,
    title: todo.title,
    description: todo.description,
    completed: todo.completed,
    created_at: todo.created_at,
    updated_at: todo.updated_at,
  });
});

app.delete('/todos/:id', authenticate, (req: AuthRequest, res: Response) => {
  const todoId = parseInt(req.params.id, 10);
  const index = todos.findIndex((t) => t.id === todoId && t.user_id === req.userId);
  if (index === -1) {
    return res.status(404).json({ error: 'Todo not found' });
  }
  todos.splice(index, 1);
  res.status(204).send();
});

const portArg = process.argv.indexOf('--port');
const port = portArg !== -1 ? parseInt(process.argv[portArg + 1], 10) : 3000;

app.listen(port, '0.0.0.0', () => {
  console.log(`Server listening on 0.0.0.0:${port}`);
});
