import express, { Request, Response, NextFunction } from 'express';
import { v4 as uuidv4 } from 'uuid';

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
  token: string;
  userId: number;
}

const users: Map<number, User> = new Map();
const todos: Map<number, Todo> = new Map();
const sessions: Map<string, Session> = new Map();

let nextUserId = 1;
let nextTodoId = 1;

function getTimestamp(): string {
  return new Date().toISOString().replace(/\.\d{3}Z$/, 'Z');
}

const app = express();

app.use(express.json());

// Middleware to ensure Content-Type: application/json for all responses
app.use((req, res, next) => {
  if (!res.headersSent) {
    res.setHeader('Content-Type', 'application/json');
  }
  next();
});

const authMiddleware = (req: Request, res: Response, next: NextFunction) => {
  const cookieHeader = req.headers.cookie;
  let sessionId = '';
  if (cookieHeader) {
    const match = cookieHeader.match(/session_id=([^;]+)/);
    if (match) sessionId = match[1];
  }

  if (!sessionId || !sessions.has(sessionId)) {
    return res.status(401).json({ error: "Authentication required" });
  }
  
  const session = sessions.get(sessionId)!;
  (req as any).session = session;
  next();
};

app.post('/register', (req: Request, res: Response) => {
  const { username, password } = req.body;

  if (!username || typeof username !== 'string' || !/^[a-zA-Z0-9_]+$/.test(username) || username.length < 3 || username.length > 50) {
    return res.status(400).json({ error: "Invalid username" });
  }

  if (!password || typeof password !== 'string' || password.length < 8) {
    return res.status(400).json({ error: "Password too short" });
  }

  const userExists = Array.from(users.values()).some(u => u.username === username);
  if (userExists) {
    return res.status(409).json({ error: "Username already exists" });
  }

  const newUser: User = {
    id: nextUserId++,
    username,
    password
  };

  users.set(newUser.id, newUser);
  res.status(201).json({ id: newUser.id, username: newUser.username });
});

app.post('/login', (req: Request, res: Response) => {
  const { username, password } = req.body;

  const user = Array.from(users.values()).find(u => u.username === username && u.password === password);
  if (!user) {
    return res.status(401).json({ error: "Invalid credentials" });
  }

  const token = uuidv4();
  sessions.set(token, { token, userId: user.id });

  res.setHeader('Set-Cookie', `session_id=${token}; Path=/; HttpOnly`);
  res.status(200).json({ id: user.id, username: user.username });
});

app.post('/logout', authMiddleware, (req: Request, res: Response) => {
  const sessionId = (req as any).session.token;
  sessions.delete(sessionId);
  res.status(200).json({});
});

app.get('/me', authMiddleware, (req: Request, res: Response) => {
  const session = (req as any).session;
  const user = users.get(session.userId)!;
  res.status(200).json({ id: user.id, username: user.username });
});

app.put('/password', authMiddleware, (req: Request, res: Response) => {
  const session = (req as any).session;
  const user = users.get(session.userId)!;
  const { old_password, new_password } = req.body;

  if (user.password !== old_password) {
    return res.status(401).json({ error: "Invalid credentials" });
  }

  if (!new_password || typeof new_password !== 'string' || new_password.length < 8) {
    return res.status(400).json({ error: "Password too short" });
  }

  user.password = new_password;
  res.status(200).json({});
});

app.get('/todos', authMiddleware, (req: Request, res: Response) => {
  const session = (req as any).session;
  const userTodos = Array.from(todos.values())
    .filter(t => t.userId === session.userId)
    .sort((a, b) => a.id - b.id);
  
  const responseTodos = userTodos.map(({ userId, ...todo }) => todo);
  res.status(200).json(responseTodos);
});

app.post('/todos', authMiddleware, (req: Request, res: Response) => {
  const session = (req as any).session;
  const { title, description } = req.body;

  if (!title || typeof title !== 'string' || title.trim() === '') {
    return res.status(400).json({ error: "Title is required" });
  }

  const now = getTimestamp();

  const newTodo: Todo = {
    id: nextTodoId++,
    userId: session.userId,
    title,
    description: (typeof description === 'string') ? description : '',
    completed: false,
    created_at: now,
    updated_at: now
  };

  todos.set(newTodo.id, newTodo);
  
  const { userId, ...todoWithoutUserId } = newTodo;
  res.status(201).json(todoWithoutUserId);
});

app.get('/todos/:id', authMiddleware, (req: Request, res: Response) => {
  const session = (req as any).session;
  const todoId = parseInt(req.params.id, 10);

  const todo = todos.get(todoId);
  if (!todo || todo.userId !== session.userId) {
    return res.status(404).json({ error: "Todo not found" });
  }

  const { userId, ...todoWithoutUserId } = todo;
  res.status(200).json(todoWithoutUserId);
});

app.put('/todos/:id', authMiddleware, (req: Request, res: Response) => {
  const session = (req as any).session;
  const todoId = parseInt(req.params.id, 10);

  const todo = todos.get(todoId);
  if (!todo || todo.userId !== session.userId) {
    return res.status(404).json({ error: "Todo not found" });
  }

  const { title, description, completed } = req.body;

  if (title !== undefined) {
    if (typeof title !== 'string' || title.trim() === '') {
      return res.status(400).json({ error: "Title is required" });
    }
    todo.title = title;
  }

  if (description !== undefined) {
    todo.description = typeof description === 'string' ? description : '';
  }

  if (completed !== undefined) {
    todo.completed = typeof completed === 'boolean' ? completed : Boolean(completed);
  }

  todo.updated_at = getTimestamp();

  const { userId, ...todoWithoutUserId } = todo;
  res.status(200).json(todoWithoutUserId);
});

app.delete('/todos/:id', authMiddleware, (req: Request, res: Response) => {
  const session = (req as any).session;
  const todoId = parseInt(req.params.id, 10);

  const todo = todos.get(todoId);
  if (!todo || todo.userId !== session.userId) {
    return res.status(404).json({ error: "Todo not found" });
  }

  todos.delete(todoId);
  res.removeHeader('Content-Type');
  res.status(204).end();
});

const portArg = process.argv.indexOf('--port');
const port = portArg !== -1 ? parseInt(process.argv[portArg + 1], 10) : 3000;

app.listen(port, '0.0.0.0', () => {
  console.log(`Server listening on 0.0.0.0:${port}`);
});
