import express, { Request, Response, NextFunction } from 'express';
import { v4 as uuidv4 } from 'uuid';
import cookieParser from 'cookie-parser';

interface User {
  id: number;
  username: string;
  password: string;
}

interface Todo {
  id: number;
  title: string;
  description: string;
  completed: boolean;
  created_at: string;
  updated_at: string;
  userId: number;
}

let nextUserId = 1;
const users: User[] = [];
let nextTodoId = 1;
const todos: Todo[] = [];
const sessions = new Map<string, number>();

const app = express();
app.use(express.json());
app.use(cookieParser());

const getTimestamp = () => {
  return new Date().toISOString().slice(0, 19) + 'Z';
};

const authMiddleware = (req: Request, res: Response, next: NextFunction) => {
  const sessionId = req.cookies.session_id;
  if (!sessionId || !sessions.has(sessionId)) {
    return res.status(401).json({ error: 'Authentication required' });
  }
  const userId = sessions.get(sessionId);
  if (userId === undefined) {
    return res.status(401).json({ error: 'Authentication required' });
  }
  (req as any).userId = userId;
  next();
};

const jsonError = (res: Response, status: number, message: string) => {
  return res.status(status).json({ error: message });
};

app.post('/register', (req, res) => {
  const { username, password } = req.body;
  if (typeof username !== 'string' || !/^[a-zA-Z0-9_]{3,50}$/.test(username)) {
    return jsonError(res, 400, 'Invalid username');
  }
  if (typeof password !== 'string' || password.length < 8) {
    return jsonError(res, 400, 'Password too short');
  }
  if (users.find(u => u.username === username)) {
    return jsonError(res, 409, 'Username already exists');
  }
  const newUser: User = {
    id: nextUserId++,
    username,
    password
  };
  users.push(newUser);
  res.status(201).json({ id: newUser.id, username: newUser.username });
});

app.post('/login', (req, res) => {
  const { username, password } = req.body;
  const user = users.find(u => u.username === username && u.password === password);
  if (!user) {
    return jsonError(res, 401, 'Invalid credentials');
  }
  const token = uuidv4();
  sessions.set(token, user.id);
  res.setHeader('Set-Cookie', `session_id=${token}; Path=/; HttpOnly`);
  res.status(200).json({ id: user.id, username: user.username });
});

app.post('/logout', authMiddleware, (req, res) => {
  const sessionId = req.cookies.session_id;
  sessions.delete(sessionId);
  res.status(200).json({});
});

app.get('/me', authMiddleware, (req: any, res) => {
  const user = users.find(u => u.id === req.userId);
  if (!user) {
    return jsonError(res, 401, 'Authentication required');
  }
  res.status(200).json({ id: user.id, username: user.username });
});

app.put('/password', authMiddleware, (req: any, res) => {
  const user = users.find(u => u.id === req.userId);
  if (!user) {
    return jsonError(res, 401, 'Authentication required');
  }
  const { old_password, new_password } = req.body;
  if (user.password !== old_password) {
    return jsonError(res, 401, 'Invalid credentials');
  }
  if (typeof new_password !== 'string' || new_password.length < 8) {
    return jsonError(res, 400, 'Password too short');
  }
  user.password = new_password;
  res.status(200).json({});
});

app.get('/todos', authMiddleware, (req: any, res) => {
  const userTodos = todos.filter(t => t.userId === req.userId).sort((a, b) => a.id - b.id);
  res.status(200).json(userTodos);
});

app.post('/todos', authMiddleware, (req: any, res) => {
  const { title } = req.body;
  const description = typeof req.body.description === 'string' ? req.body.description : '';
  
  if (typeof title !== 'string' || title === '') {
    return jsonError(res, 400, 'Title is required');
  }
  
  const now = getTimestamp();
  const newTodo: Todo = {
    id: nextTodoId++,
    title,
    description,
    completed: false,
    created_at: now,
    updated_at: now,
    userId: req.userId
  };
  todos.push(newTodo);
  res.status(201).json(newTodo);
});

app.get('/todos/:id', authMiddleware, (req: any, res) => {
  const todoId = parseInt(req.params.id, 10);
  const todo = todos.find(t => t.id === todoId && t.userId === req.userId);
  if (!todo) {
    return jsonError(res, 404, 'Todo not found');
  }
  res.status(200).json(todo);
});

app.put('/todos/:id', authMiddleware, (req: any, res) => {
  const todoId = parseInt(req.params.id, 10);
  const todoIndex = todos.findIndex(t => t.id === todoId && t.userId === req.userId);
  if (todoIndex === -1) {
    return jsonError(res, 404, 'Todo not found');
  }
  const todo = todos[todoIndex];
  const { title, description, completed } = req.body;
  
  if (title !== undefined) {
    if (typeof title !== 'string' || title === '') {
      return jsonError(res, 400, 'Title is required');
    }
    todo.title = title;
  }
  if (description !== undefined) {
    todo.description = typeof description === 'string' ? description : '';
  }
  if (completed !== undefined) {
    todo.completed = completed;
  }
  todo.updated_at = getTimestamp();
  res.status(200).json(todo);
});

app.delete('/todos/:id', authMiddleware, (req: any, res) => {
  const todoId = parseInt(req.params.id, 10);
  const todoIndex = todos.findIndex(t => t.id === todoId && t.userId === req.userId);
  if (todoIndex === -1) {
    return jsonError(res, 404, 'Todo not found');
  }
  todos.splice(todoIndex, 1);
  res.status(204).send();
});

const portArg = process.argv.findIndex(arg => arg === '--port');
const port = portArg !== -1 ? parseInt(process.argv[portArg + 1], 10) : 3000;

app.listen(port, '0.0.0.0', () => {
  console.log(`Server listening on 0.0.0.0:${port}`);
});