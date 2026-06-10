import express, { Request, Response, NextFunction } from 'express';
import { randomUUID } from 'crypto';

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

const users = new Map<number, User>();
let nextUserId = 1;

const todos = new Map<number, Todo>();
let nextTodoId = 1;

const sessions = new Map<string, Session>();

function getTimestamp(): string {
  return new Date().toISOString().replace(/\.\d{3}Z$/, 'Z');
}

function requireAuth(req: Request, res: Response, next: NextFunction) {
  const cookieHeader = req.headers.cookie;
  let token: string | undefined;
  
  if (cookieHeader) {
    const cookies = cookieHeader.split(';');
    for (const cookie of cookies) {
      const parts = cookie.trim().split('=');
      if (parts[0] === 'session_id' && parts.length > 1) {
        token = parts.slice(1).join('=');
        break;
      }
    }
  }

  if (!token || !sessions.has(token)) {
    return res.status(401).json({ error: "Authentication required" });
  }

  const session = sessions.get(token)!;
  (req as any).userId = session.userId;
  (req as any).token = token;
  next();
}

const app = express();
app.use(express.json());

app.post('/register', (req: Request, res: Response) => {
  const { username, password } = req.body || {};
  
  if (typeof username !== 'string' || username.length < 3 || username.length > 50 || !/^[a-zA-Z0-9_]+$/.test(username)) {
    return res.status(400).json({ error: "Invalid username" });
  }
  
  if (typeof password !== 'string' || password.length < 8) {
    return res.status(400).json({ error: "Password too short" });
  }

  for (const user of users.values()) {
    if (user.username === username) {
      return res.status(409).json({ error: "Username already exists" });
    }
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
  const { username, password } = req.body || {};
  
  if (typeof username !== 'string' || typeof password !== 'string') {
    return res.status(401).json({ error: "Invalid credentials" });
  }

  for (const user of users.values()) {
    if (user.username === username && user.password === password) {
      const token = randomUUID();
      sessions.set(token, { userId: user.id });
      res.setHeader('Set-Cookie', `session_id=${token}; Path=/; HttpOnly`);
      return res.status(200).json({ id: user.id, username: user.username });
    }
  }
  
  res.status(401).json({ error: "Invalid credentials" });
});

app.post('/logout', requireAuth, (req: Request, res: Response) => {
  const token = (req as any).token;
  sessions.delete(token);
  res.status(200).json({});
});

app.get('/me', requireAuth, (req: Request, res: Response) => {
  const userId = (req as any).userId;
  const user = users.get(userId);
  if (!user) {
    return res.status(401).json({ error: "Authentication required" });
  }
  res.status(200).json({ id: user.id, username: user.username });
});

app.put('/password', requireAuth, (req: Request, res: Response) => {
  const userId = (req as any).userId;
  const user = users.get(userId);
  const { old_password, new_password } = req.body || {};

  if (typeof old_password !== 'string' || !user || user.password !== old_password) {
    return res.status(401).json({ error: "Invalid credentials" });
  }

  if (typeof new_password !== 'string' || new_password.length < 8) {
    return res.status(400).json({ error: "Password too short" });
  }

  user.password = new_password;
  res.status(200).json({});
});

app.get('/todos', requireAuth, (req: Request, res: Response) => {
  const userId = (req as any).userId;
  const userTodos = Array.from(todos.values())
    .filter(t => t.userId === userId)
    .sort((a, b) => a.id - b.id);
  res.status(200).json(userTodos);
});

app.post('/todos', requireAuth, (req: Request, res: Response) => {
  const userId = (req as any).userId;
  const { title, description } = req.body || {};

  if (typeof title !== 'string' || title === '') {
    return res.status(400).json({ error: "Title is required" });
  }

  const now = getTimestamp();
  const newTodo: Todo = {
    id: nextTodoId++,
    userId,
    title,
    description: typeof description === 'string' ? description : "",
    completed: false,
    created_at: now,
    updated_at: now
  };
  todos.set(newTodo.id, newTodo);
  res.status(201).json(newTodo);
});

function getParamId(req: Request): number {
  const idParam = req.params.id;
  return parseInt(Array.isArray(idParam) ? idParam[0] : idParam, 10);
}

app.get('/todos/:id', requireAuth, (req: Request, res: Response) => {
  const userId = (req as any).userId;
  const id = getParamId(req);
  const todo = todos.get(id);
  
  if (!todo || todo.userId !== userId) {
    return res.status(404).json({ error: "Todo not found" });
  }
  
  res.status(200).json(todo);
});

app.put('/todos/:id', requireAuth, (req: Request, res: Response) => {
  const userId = (req as any).userId;
  const id = getParamId(req);
  const todo = todos.get(id);
  
  if (!todo || todo.userId !== userId) {
    return res.status(404).json({ error: "Todo not found" });
  }

  const { title, description, completed } = req.body || {};

  if (title !== undefined) {
    if (typeof title !== 'string' || title === '') {
      return res.status(400).json({ error: "Title is required" });
    }
    todo.title = title;
  }

  if (description !== undefined) {
    todo.description = typeof description === 'string' ? description : "";
  }

  if (completed !== undefined) {
    todo.completed = !!completed;
  }

  todo.updated_at = getTimestamp();
  res.status(200).json(todo);
});

app.delete('/todos/:id', requireAuth, (req: Request, res: Response) => {
  const userId = (req as any).userId;
  const id = getParamId(req);
  const todo = todos.get(id);
  
  if (!todo || todo.userId !== userId) {
    return res.status(404).json({ error: "Todo not found" });
  }

  todos.delete(id);
  res.status(204).end();
});

const args = process.argv.slice(2);
let port = 3000;
for (let i = 0; i < args.length; i++) {
  if (args[i] === '--port' && i + 1 < args.length) {
    port = parseInt(args[i + 1], 10);
    break;
  }
}

app.listen(port, '0.0.0.0', () => {
  console.log(`Server running on http://0.0.0.0:${port}`);
});
