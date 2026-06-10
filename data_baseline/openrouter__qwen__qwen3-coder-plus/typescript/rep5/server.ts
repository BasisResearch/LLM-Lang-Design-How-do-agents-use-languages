import express, { Request, Response, NextFunction } from 'express';
import { v4 as uuidv4 } from 'uuid';
import * as bcrypt from 'bcryptjs';
import cookieParser from 'cookie-parser';

// Extended request interface
interface AuthenticatedRequest extends Request {
  userId: number;
  todoId: number;
}

// Types
interface User {
  id: number;
  username: string;
  passwordHash: string; 
}

interface Todo {
  id: number;
  title: string;
  description: string;
  completed: boolean;
  created_at: string;
  updated_at: string;
}

interface Session {
  userId: number;
  expiresAt: Date;
}

// In-memory stores
let users: User[] = [];
let todos: Map<number, Todo[]> = new Map(); // userId -> todos array
let sessions: Map<string, Session> = new Map(); // sessionId -> session
let nextUserId = 1;
let nextTodoId = 1;

const app = express();

// Middleware
app.use(express.json());
app.use(cookieParser());

// Helper functions
function generateTimestamp(): string {
  const now = new Date();
  return now.toISOString().slice(0, 19) + 'Z';
}

function validateUsername(username: string): boolean {
  const usernameRegex = /^[a-zA-Z0-9_]+$/;
  return username.length >= 3 && 
         username.length <= 50 && 
         usernameRegex.test(username);
}

function authenticate(req: AuthenticatedRequest, res: Response, next: NextFunction) {
  const sessionId = req.cookies?.session_id;
  if (!sessionId) {
    return res.status(401).json({ error: "Authentication required" });
  }

  const session = sessions.get(sessionId);
  if (!session || new Date() > session.expiresAt) {
    return res.status(401).json({ error: "Authentication required" });
  }

  req.userId = session.userId;
  next();
}

// Routes

// POST /register
app.post('/register', async (req, res) => {
  try {
    const { username, password } = req.body;

    // Validate username
    if (!username || !validateUsername(username)) {
      return res.status(400).json({ error: "Invalid username" });
    }

    // Validate password length
    if (!password || password.length < 8) {
      return res.status(400).json({ error: "Password too short" });
    }

    // Check if username exists
    if (users.find(user => user.username === username)) {
      return res.status(409).json({ error: "Username already exists" });
    }

    // Hash password
    const passwordHash = await bcrypt.hash(password, 10);

    // Create new user
    const newUser: User = {
      id: nextUserId++,
      username,
      passwordHash
    };

    users.push(newUser);
    
    // Initialize empty todos array for the user
    todos.set(newUser.id, []);

    res.status(201).json({
      id: newUser.id,
      username: newUser.username
    });
  } catch (error) {
    console.error('Register error:', error);
    res.status(500).json({ error: "Internal server error" });
  }
});

// POST /login
app.post('/login', async (req, res) => {
  try {
    const { username, password } = req.body;

    const user = users.find(u => u.username === username);
    if (!user || !(await bcrypt.compare(password, user.passwordHash))) {
      return res.status(401).json({ error: "Invalid credentials" });
    }

    // Create session
    const sessionId = uuidv4();
    const session: Session = {
      userId: user.id,
      expiresAt: new Date(Date.now() + 24 * 60 * 60 * 1000) // 24 hours
    };
    sessions.set(sessionId, session);

    res.cookie('session_id', sessionId, {
      httpOnly: true,
      path: '/',
      maxAge: 24 * 60 * 60 * 1000 // 24 hours in milliseconds
    });

    res.json({
      id: user.id,
      username: user.username
    });
  } catch (error) {
    console.error('Login error:', error);
    res.status(500).json({ error: "Internal server error" });
  }
});

// POST /logout
app.post('/logout', authenticate, (req: AuthenticatedRequest, res: Response) => {
  try {
    // Find and remove the session based on cookie
    const sessionId = req.cookies?.session_id;
    if (sessionId) {
      sessions.delete(sessionId);
    }

    res.json({});
  } catch (error) {
    console.error('Logout error:', error);
    res.status(500).json({ error: "Internal server error" });
  }
});

// GET /me
app.get('/me', authenticate, (req: AuthenticatedRequest, res: Response) => {
  try {
    const user = users.find(u => u.id === req.userId);
    if (!user) {
      return res.status(401).json({ error: "Authentication required" });
    }

    res.json({
      id: user.id,
      username: user.username
    });
  } catch (error) {
    console.error('Get me error:', error);
    res.status(500).json({ error: "Internal server error" });
  }
});

// PUT /password
app.put('/password', authenticate, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { old_password, new_password } = req.body;
    const user = users.find(u => u.id === req.userId);

    if (!user) {
      return res.status(401).json({ error: "Authentication required" });
    }

    // Validate new password length
    if (!new_password || new_password.length < 8) {
      return res.status(400).json({ error: "Password too short" });
    }

    // Authenticate with old password
    if (!(await bcrypt.compare(old_password, user.passwordHash))) {
      return res.status(401).json({ error: "Invalid credentials" });
    }

    // Update password hash
    const newPasswordHash = await bcrypt.hash(new_password, 10);
    user.passwordHash = newPasswordHash;

    res.json({});
  } catch (error) {
    console.error('Change password error:', error);
    res.status(500).json({ error: "Internal server error" });
  }
});

// GET /todos
app.get('/todos', authenticate, (req: AuthenticatedRequest, res: Response) => {
  try {
    const userTodos = todos.get(req.userId) || [];

    res.json(userTodos);
  } catch (error) {
    console.error('Get todos error:', error);
    res.status(500).json({ error: "Internal server error" });
  }
});

// POST /todos
app.post('/todos', authenticate, (req: AuthenticatedRequest, res: Response) => {
  try {
    const { title, description } = req.body;

    // Validate title
    if (!title || title.trim().length === 0) {
      return res.status(400).json({ error: "Title is required" });
    }

    const timestamp = generateTimestamp();
    
    const newTodo: Todo = {
      id: nextTodoId++,
      title,
      description: description || "",
      completed: false,
      created_at: timestamp,
      updated_at: timestamp
    };

    // Add to user's todos
    let userTodos = todos.get(req.userId);
    if (!userTodos) {
      userTodos = [];
      todos.set(req.userId, userTodos);
    }
    userTodos.push(newTodo);

    res.status(201).json(newTodo);
  } catch (error) {
    console.error('Create todo error:', error);
    res.status(500).json({ error: "Internal server error" });
  }
});

// Middleware to extract and validate todo ID
const validateTodoId = (req: AuthenticatedRequest, res: Response, next: NextFunction) => {
  if (!req.params.id) {
    return res.status(400).json({ error: "Todo ID is required" });
  }

  const id = parseInt(req.params.id, 10);
  if (isNaN(id) || id < 1) {
    return res.status(400).json({ error: "Invalid todo ID" });
  }

  req.todoId = id;
  next();
};

// GET /todos/:id
app.get('/todos/:id', authenticate, validateTodoId, (req: AuthenticatedRequest, res: Response) => {
  try {
    const userTodos = todos.get(req.userId) || [];
    const todo = userTodos.find(t => t.id === req.todoId);

    if (!todo) {
      return res.status(404).json({ error: "Todo not found" });
    }

    res.json(todo);
  } catch (error) {
    console.error('Get todo by ID error:', error);
    res.status(500).json({ error: "Internal server error" });
  }
});

// PUT /todos/:id
app.put('/todos/:id', authenticate, validateTodoId, (req: AuthenticatedRequest, res: Response) => {
  try {
    const { title, description, completed } = req.body;
    const userTodos = todos.get(req.userId) || [];
    const todoIndex = userTodos.findIndex(t => t.id === req.todoId);

    if (todoIndex === -1) {
      return res.status(404).json({ error: "Todo not found" });
    }

    // Validate title if provided
    if (title !== undefined && title.trim().length === 0) {
      return res.status(400).json({ error: "Title is required" });
    }

    // Update todo fields - only update if present in request
    const todo = userTodos[todoIndex];
    const updatedAt = generateTimestamp();
    
    todo.updated_at = updatedAt;

    if (title !== undefined) {
      todo.title = title;
    }
    if (description !== undefined) {
      todo.description = description;
    }
    if (completed !== undefined) {
      todo.completed = completed;
    }

    res.json(todo);
  } catch (error) {
    console.error('Update todo error:', error);
    res.status(500).json({ error: "Internal server error" });
  }
});

// DELETE /todos/:id
app.delete('/todos/:id', authenticate, validateTodoId, (req: AuthenticatedRequest, res: Response) => {
  try {
    const userTodos = todos.get(req.userId) || [];
    const todoIndex = userTodos.findIndex(t => t.id === req.todoId);

    if (todoIndex === -1) {
      return res.status(404).json({ error: "Todo not found" });
    }

    // Remove the todo from the user's todos array
    userTodos.splice(todoIndex, 1);

    res.status(204).send();
  } catch (error) {
    console.error('Delete todo error:', error);
    res.status(500).json({ error: "Internal server error" });
  }
});

export default app;

if (require.main === module) {
  const port = parseInt(process.argv[process.argv.indexOf('--port') + 1], 10) || 3000;
  app.listen(port, '0.0.0.0', () => {
    console.log(`Server running on http://0.0.0.0:${port}`);
  });
}