import express, { Request, Response, NextFunction } from 'express';
import cookieParser from 'cookie-parser';
import crypto from 'crypto';

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
  userId: number;
}

interface AuthRequest extends Request {
  user?: User;
}

const app = express();
app.use(express.json());
app.use(cookieParser());

const users: User[] = [];
const todos: Todo[] = [];
const sessions = new Map<string, Session>();

let nextUserId = 1;
let nextTodoId = 1;

const getTimestamp = () => new Date().toISOString().replace(/\.\d{3}Z$/, 'Z');

const requireAuth = (req: AuthRequest, res: Response, next: NextFunction) => {
  const sessionId = req.cookies?.session_id;
  if (!sessionId || !sessions.has(sessionId)) {
    return res.status(401).json({ error: 'Authentication required' });
  }
  const session = sessions.get(sessionId)!;
  const user = users.find(u => u.id === session.userId);
  if (!user) {
    sessions.delete(sessionId);
    return res.status(401).json({ error: 'Authentication required' });
  }
  req.user = user;
  next();
};

// POST /register
app.post('/register', (req: Request, res: Response) => {
  const { username, password } = req.body;
  
  if (!username || typeof username !== 'string' || !/^[a-zA-Z0-9_]{3,50}$/.test(username)) {
    return res.status(400).json({ error: 'Invalid username' });
  }
  
  if (!password || typeof password !== 'string' || password.length < 8) {
    return res.status(400).json({ error: 'Password too short' });
  }

  if (users.some(u => u.username === username)) {
    return res.status(409).json({ error: 'Username already exists' });
  }

  const newUser: User = {
    id: nextUserId++,
    username,
    password
  };
  users.push(newUser);

  res.status(201).json({ id: newUser.id, username: newUser.username });
});

// POST /login
app.post('/login', (req: Request, res: Response) => {
  const { username, password } = req.body;

  const user = users.find(u => u.username === username && u.password === password);
  if (!user) {
    return res.status(401).json({ error: 'Invalid credentials' });
  }

  const sessionId = crypto.randomUUID();
  sessions.set(sessionId, { userId: user.id });

  res.cookie('session_id', sessionId, { path: '/', httpOnly: true });
  res.status(200).json({ id: user.id, username: user.username });
});

// POST /logout
app.post('/logout', requireAuth, (req: AuthRequest, res: Response) => {
  const sessionId = req.cookies.session_id;
  sessions.delete(sessionId);
  res.status(200).json({});
});

// GET /me
app.get('/me', requireAuth, (req: AuthRequest, res: Response) => {
  const user = req.user!;
  res.status(200).json({ id: user.id, username: user.username });
});

// PUT /password
app.put('/password', requireAuth, (req: AuthRequest, res: Response) => {
  const { old_password, new_password } = req.body;
  const user = req.user!;

  if (user.password !== old_password) {
    return res.status(401).json({ error: 'Invalid credentials' });
  }

  if (!new_password || typeof new_password !== 'string' || new_password.length < 8) {
    return res.status(400).json({ error: 'Password too short' });
  }

  user.password = new_password;
  res.status(200).json({});
});

// GET /todos
app.get('/todos', requireAuth, (req: AuthRequest, res: Response) => {
  const user = req.user!;
  const userTodos = todos
    .filter(t => t.userId === user.id)
    .sort((a, b) => a.id - b.id)
    .map(({ id, title, description, completed, created_at, updated_at }) => ({
      id, title, description, completed, created_at, updated_at
    }));
  res.status(200).json(userTodos);
});

// POST /todos
app.post('/todos', requireAuth, (req: AuthRequest, res: Response) => {
  const { title, description } = req.body;
  const user = req.user!;

  if (!title || typeof title !== 'string' || title.trim() === '') {
    return res.status(400).json({ error: 'Title is required' });
  }

  const now = getTimestamp();

  const newTodo: Todo = {
    id: nextTodoId++,
    userId: user.id,
    title,
    description: description !== undefined ? String(description) : '',
    completed: false,
    created_at: now,
    updated_at: now
  };
  todos.push(newTodo);

  res.status(201).json({
    id: newTodo.id,
    title: newTodo.title,
    description: newTodo.description,
    completed: newTodo.completed,
    created_at: newTodo.created_at,
    updated_at: newTodo.updated_at
  });
});

const getTodoResponse = (todo: Todo) => ({
  id: todo.id,
  title: todo.title,
  description: todo.description,
  completed: todo.completed,
  created_at: todo.created_at,
  updated_at: todo.updated_at
});

// GET /todos/:id
app.get('/todos/:id', requireAuth, (req: AuthRequest, res: Response) => {
  const user = req.user!;
  const todoId = parseInt(req.params.id, 10);

  if (isNaN(todoId)) {
    return res.status(404).json({ error: 'Todo not found' });
  }

  const todo = todos.find(t => t.id === todoId && t.userId === user.id);
  if (!todo) {
    return res.status(404).json({ error: 'Todo not found' });
  }

  res.status(200).json(getTodoResponse(todo));
});

// PUT /todos/:id
app.put('/todos/:id', requireAuth, (req: AuthRequest, res: Response) => {
  const user = req.user!;
  const todoId = parseInt(req.params.id, 10);

  if (isNaN(todoId)) {
    return res.status(404).json({ error: 'Todo not found' });
  }

  const todo = todos.find(t => t.id === todoId && t.userId === user.id);
  if (!todo) {
    return res.status(404).json({ error: 'Todo not found' });
  }

  const { title, description, completed } = req.body;

  if (title !== undefined) {
    if (typeof title !== 'string' || title.trim() === '') {
      return res.status(400).json({ error: 'Title is required' });
    }
    todo.title = title;
  }
  
  if (description !== undefined) {
    todo.description = String(description);
  }
  
  if (completed !== undefined) {
    todo.completed = Boolean(completed);
  }

  todo.updated_at = getTimestamp();

  res.status(200).json(getTodoResponse(todo));
});

// DELETE /todos/:id
app.delete('/todos/:id', requireAuth, (req: AuthRequest, res: Response) => {
  const user = req.user!;
  const todoId = parseInt(req.params.id, 10);

  if (isNaN(todoId)) {
    return res.status(404).json({ error: 'Todo not found' });
  }

  const todoIndex = todos.findIndex(t => t.id === todoId && t.userId === user.id);
  if (todoIndex === -1) {
    return res.status(404).json({ error: 'Todo not found' });
  }

  todos.splice(todoIndex, 1);
  res.removeHeader('Content-Type');
  res.status(204).end();
});

const args = process.argv.slice(2);
let port = 3000;
for (let i = 0; i < args.length; i++) {
  if (args[i] === '--port' && args[i + 1]) {
    port = parseInt(args[i + 1], 10);
    i++;
  }
}

app.listen(port, '0.0.0.0', () => {
  console.log(`Server running on http://0.0.0.0:${port}`);
});
