import express, { Request, Response } from 'express';
import { v4 as uuidv4 } from 'uuid';
import * as bcrypt from 'bcryptjs';

// Parse command line arguments for port
let PORT = 3000;
for (let i = 0; i < process.argv.length; i++) {
  if (process.argv[i] === '--port' && i + 1 < process.argv.length) {
    PORT = parseInt(process.argv[i + 1], 10);
    break;
  }
}

// Database models (in-memory storage)
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
  userId: number;
}

// Type guard to help with type checking
type ValidatedSession = { userId: number; valid: true };

class TodoApp {
  // In-memory databases
  private users: Map<number, User> = new Map();
  private todos: Map<number, Todo> = new Map();
  private sessions: Map<string, { userId: number }> = new Map();
  
  private nextUserId: number = 1;
  private nextTodoId: number = 1;

  constructor() {
    // Empty constructor - for initialization if needed
  }

  async register(username: string, password: string): Promise<User | null> {
    // Check if username already exists
    for (const user of this.users.values()) {
      if (user.username === username) {
        return null; // Username exists
      }
    }

    // Validate username format
    const usernameRegex = /^[a-zA-Z0-9_]+$/;
    if (!username || username.length < 3 || username.length > 50 || !usernameRegex.test(username)) {
      return null; // Invalid username
    }

    // Validate password length
    if (!password || password.length < 8) {
      return null; // Password too short
    }

    const passwordHash = await bcrypt.hash(password, 10);
    const id = this.nextUserId++;
    
    const newUser: User = {
      id,
      username,
      passwordHash
    };
    
    this.users.set(id, newUser);
    return newUser;
  }

  async authenticate(username: string, password: string): Promise<User | null> {
    for (const user of this.users.values()) {
      if (user.username === username) {
        const isValid = await bcrypt.compare(password, user.passwordHash);
        if (isValid) {
          return user;
        }
      }
    }
    return null; // No user found or wrong password
  }

  createUserSession(userId: number): string {
    const sessionId = uuidv4();
    this.sessions.set(sessionId, { userId });
    return sessionId;
  }

  validateSession(sessionId: string): ValidatedSession | null {
    const session = this.sessions.get(sessionId);
    if (session) {
      return { userId: session.userId, valid: true };
    }
    return null;
  }

  invalidateSession(sessionId: string): void {
    this.sessions.delete(sessionId);
  }

  changePassword(userId: number, oldPassword: string, newPassword: string): boolean {
    const user = this.users.get(userId);
    
    if (!user) {
      return false; // User doesn't exist
    }

    const isValid = bcrypt.compareSync(oldPassword, user.passwordHash);
    if (!isValid) {
      return false; // Old password is incorrect
    }

    // Validate new password length
    if (!newPassword || newPassword.length < 8) {
      return false; // New password too short
    }

    const newPasswordHash = bcrypt.hashSync(newPassword, 10);
    user.passwordHash = newPasswordHash;
    return true;
  }

  findUserById(id: number): User | undefined {
    return this.users.get(id);
  }

  getTodosByUser(userId: number): Todo[] {
    return Array.from(this.todos.values())
      .filter(todo => todo.userId === userId)
      .sort((a, b) => a.id - b.id); // Order by id ascending
  }

  createTodoForUser(userId: number, title: string, description: string = ""): Todo {
    // Validate title
    if (!title || title.trim() === "") {
      throw new Error("Title is required");
    }

    const now = this.generateTimestamp();
    const id = this.nextTodoId++;
    
    const newTodo: Todo = {
      id,
      title,
      description,
      completed: false,
      created_at: now,
      updated_at: now,
      userId
    };
    
    this.todos.set(id, newTodo);
    return newTodo;
  }

  getTodoById(todoId: number): Todo | null {
    const todo = this.todos.get(todoId);
    if (!todo) {
      return null;
    }
    return todo;
  }

  updateTodo(todoId: number, updates: Partial<Omit<Todo, 'id' | 'userId' | 'created_at'>>): Todo | null {
    const existingTodo = this.todos.get(todoId);
    if (!existingTodo) {
      return null;
    }

    // Validate title if it's being updated
    if (updates.title !== undefined && updates.title.trim() === "") {
      throw new Error("Title is required");
    }

    const updatedTodo: Todo = {
      ...existingTodo,
      ...updates,
      updated_at: this.generateTimestamp() // Always update the timestamp
    };

    this.todos.set(todoId, updatedTodo);
    return updatedTodo;
  }

  deleteTodo(todoId: number): boolean {
    return this.todos.delete(todoId);
  }

  private generateTimestamp(): string {
    const date = new Date();
    return date.toISOString().slice(0, 19) + 'Z'; // Format: YYYY-MM-DDTHH:MM:SSZ
  }
}

// Create the Express app instance
const app = express();
app.use(express.json());

// Global instance (in a real application you might handle this differently)
const todoApp = new TodoApp();

// Utility function to extract session ID from cookie header
const getSessionId = (req: Request): string | null => {
  if (!req.headers.cookie) {
    return null;
  }

  const cookies = req.headers.cookie.split(';');
  for (const cookie of cookies) {
    const [key, ...valueParts] = cookie.trim().split('=');
    if (key === 'session_id') {
      return valueParts.join('=').trim();
    }
  }
  return null;
};

// Helper middleware for authentication
const authMiddleware = (req: Request, res: Response, next: () => void) => {
  const sessionId = getSessionId(req);
  if (!sessionId) {
    res.status(401).json({ error: "Authentication required" });
    return;
  }

  const sessionData = todoApp.validateSession(sessionId);
  if (!sessionData) {
    res.status(401).json({ error: "Authentication required" });
    return;
  }

  // Store user ID in request for later use
  (req as any).userId = sessionData.userId;
  next();
};

// POST /register
app.post('/register', async (req, res) => {
  const { username, password } = req.body;

  try {
    const registeredUser = await todoApp.register(username, password);
    
    if (!registeredUser) {
      // Determine the reason for failure
      if (!username || username.length < 3 || username.length > 50 || !/^[a-zA-Z0-9_]+$/.test(username)) {
        return res.status(400).json({ error: "Invalid username" });
      }
      
      if (!password || password.length < 8) {
        return res.status(400).json({ error: "Password too short" });
      }
      
      // If we get here, the only remaining reason is that the username already exists
      return res.status(409).json({ error: "Username already exists" });
    }

    res.status(201).json({
      id: registeredUser.id,
      username: registeredUser.username
    });
  } catch (error) {
    console.error('Error registering user:', error);
    res.status(500).json({ error: "Internal server error" });
  }
});

// POST /login
app.post('/login', async (req, res) => {
  const { username, password } = req.body;

  try {
    const user = await todoApp.authenticate(username, password);
    
    if (!user) {
      return res.status(401).json({ error: "Invalid credentials" });
    }

    const sessionId = todoApp.createUserSession(user.id);
    
    res
      .status(200)
      .cookie('session_id', sessionId, { 
        httpOnly: true, 
        path: '/',
        secure: false // In production, enable this if using HTTPS
      })
      .json({
        id: user.id,
        username: user.username
      });
  } catch (error) {
    console.error('Error logging in:', error);
    res.status(500).json({ error: "Internal server error" });
  }
});

// POST /logout
app.post('/logout', authMiddleware, (req, res) => {
  const sessionId = getSessionId(req);
  if (sessionId) {
    todoApp.invalidateSession(sessionId);
  }

  res.status(200).json({});
});

// GET /me
app.get('/me', authMiddleware, (req, res) => {
  const userId = (req as any).userId;
  const user = todoApp.findUserById(userId);

  if (!user) {
    // This shouldn't happen due to auth middleware, but let's be safe
    return res.status(404).json({ error: "User not found" });
  }

  res.status(200).json({
    id: user.id,
    username: user.username
  });
});

// PUT /password
app.put('/password', authMiddleware, (req, res) => {
  const { old_password, new_password } = req.body;
  const userId = (req as any).userId;

  // Validate inputs
  if (!old_password) {
    return res.status(400).json({ error: "Missing old password" });
  }
  
  if (!new_password || new_password.length < 8) {
    return res.status(400).json({ error: "Password too short" });
  }

  try {
    const success = todoApp.changePassword(userId, old_password, new_password);
    
    if (!success) {
      return res.status(401).json({ error: "Invalid credentials" });
    }

    res.status(200).json({});
  } catch (error) {
    console.error('Error changing password:', error);
    res.status(500).json({ error: "Internal server error" });
  }
});

// GET /todos
app.get('/todos', authMiddleware, (req, res) => {
  const userId = (req as any).userId;
  const todos = todoApp.getTodosByUser(userId);

  res.status(200).json(todos);
});

// POST /todos
app.post('/todos', authMiddleware, (req, res) => {
  const { title, description = "" } = req.body;
  const userId = (req as any).userId;

  if (!title || title.trim() === "") {
    return res.status(400).json({ error: "Title is required" });
  }

  try {
    const todo = todoApp.createTodoForUser(userId, title, description);
    
    res.status(201).json(todo);
  } catch (error) {
    if (error instanceof Error && error.message === "Title is required") {
      return res.status(400).json({ error: "Title is required" });
    }
    
    res.status(500).json({ error: "Internal server error" });
  }
});

// GET /todos/:id
app.get('/todos/:id', authMiddleware, (req, res) => {
  const userId = (req as any).userId;
  const todoId = parseInt(req.params.id, 10);

  if (isNaN(todoId)) {
    return res.status(400).json({ error: "Invalid todo ID" });
  }

  const todo = todoApp.getTodoById(todoId);

  if (!todo || todo.userId !== userId) {
    return res.status(404).json({ error: "Todo not found" });
  }

  res.status(200).json(todo);
});

// PUT /todos/:id
app.put('/todos/:id', authMiddleware, (req, res) => {
  const userId = (req as any).userId;
  const todoId = parseInt(req.params.id, 10);
  const updates = req.body;

  if (isNaN(todoId)) {
    return res.status(400).json({ error: "Invalid todo ID" });
  }

  try {
    // Check if todo exists and belongs to the logged-in user
    const existingTodo = todoApp.getTodoById(todoId);
    if (!existingTodo || existingTodo.userId !== userId) {
      return res.status(404).json({ error: "Todo not found" });
    }

    // Validate title if it's being updated
    if (updates.title !== undefined && updates.title.trim() === "") {
      return res.status(400).json({ error: "Title is required" });
    }

    const updatedTodo = todoApp.updateTodo(todoId, updates);
    
    if (!updatedTodo) {
      return res.status(404).json({ error: "Todo not found" });
    }

    res.status(200).json(updatedTodo);
  } catch (error) {
    if (error instanceof Error && error.message === "Title is required") {
      return res.status(400).json({ error: "Title is required" });
    }
    
    res.status(500).json({ error: "Internal server error" });
  }
});

// DELETE /todos/:id
app.delete('/todos/:id', authMiddleware, (req, res) => {
  const userId = (req as any).userId;
  const todoId = parseInt(req.params.id, 10);

  if (isNaN(todoId)) {
    return res.status(400).json({ error: "Invalid todo ID" });
  }

  const todo = todoApp.getTodoById(todoId);
  
  if (!todo || todo.userId !== userId) {
    return res.status(404).json({ error: "Todo not found" });
  }

  todoApp.deleteTodo(todoId);
  res.status(204).send(); // No content response
});

// Start the server
app.listen(PORT, '0.0.0.0', () => {
  console.log(`Server listening on 0.0.0.0:${PORT}`);
});

export default app;