const http = require('http');
const url = require('url');
const crypto = require('crypto');
const querystring = require('querystring');

class TodoServer {
    constructor() {
        // In-memory storage
        this.users = new Map();  // username -> {id, username, password}
        this.sessions = new Map();  // session_id -> user_id
        this.todos = new Map();  // todo_id -> {id, title, description, completed, created_at, updated_at, user_id}
        this.nextUserId = 1;
        this.nextTodoId = 1;
    }

    // Utility function to get date in ISO format
    getISOString() {
        return new Date().toISOString().replace(/\.\d{3}Z$/, 'Z').replace(/\.\d{6}Z$/, 'Z');
    }

    // Validate username format
    isValidUsername(username) {
        if (!username || typeof username !== 'string') return false;
        return /^[a-zA-Z0-9_]+$/.test(username) && username.length >= 3 && username.length <= 50;
    }

    // Generate a secure random session ID
    generateSessionId() {
        return crypto.randomBytes(32).toString('hex');
    }

    // Parse cookies from header
    parseCookies(cookieHeader) {
        const cookies = {};
        if (cookieHeader) {
            cookieHeader.split(';').forEach(cookie => {
                const [key, value] = cookie.trim().split('=');
                cookies[key] = value;
            });
        }
        return cookies;
    }

    // Authenticate user from session
    authenticateUser(req) {
        const cookies = this.parseCookies(req.headers.cookie);
        const sessionId = cookies.session_id;
        
        if (!sessionId) {
            return { authenticated: false, userId: null };
        }
        
        const userId = this.sessions.get(sessionId);
        if (!userId) {
            return { authenticated: false, userId: null };
        }
        
        return { authenticated: true, userId };
    }

    // Handler functions for endpoints
    async handleRegister(req, res) {
        try {
            let body = '';
            req.on('data', chunk => {
                body += chunk.toString();
            });

            await new Promise((resolve) => {
                req.on('end', resolve);
            });

            const { username, password } = JSON.parse(body);

            // Validation checks
            if (!this.isValidUsername(username)) {
                return this.sendResponse(res, 400, { error: "Invalid username" });
            }

            if (!password || typeof password !== 'string' || password.length < 8) {
                return this.sendResponse(res, 400, { error: "Password too short" });
            }

            // Check if user already exists
            if (this.users.has(username)) {
                return this.sendResponse(res, 409, { error: "Username already exists" });
            }

            // Create the user
            const user = {
                id: this.nextUserId++,
                username: username,
                password: password  // In a real system, you'd hash passwords here
            };

            this.users.set(username, user);

            return this.sendResponse(res, 201, {
                id: user.id,
                username: user.username
            });
        } catch (error) {
            console.error("Register error:", error);
            return this.sendResponse(res, 500, { error: "Internal server error" });
        }
    }

    async handleLogin(req, res) {
        try {
            let body = '';
            req.on('data', chunk => {
                body += chunk.toString();
            });

            await new Promise((resolve) => {
                req.on('end', resolve);
            });

            const { username, password } = JSON.parse(body);

            const user = this.users.get(username);
            if (!user || user.password !== password) {
                return this.sendResponse(res, 401, { error: "Invalid credentials" });
            }

            // Generate session
            const sessionId = this.generateSessionId();
            this.sessions.set(sessionId, user.id);

            // Send response with cookie
            res.setHeader('Set-Cookie', `session_id=${sessionId}; Path=/; HttpOnly`);
            return this.sendResponse(res, 200, {
                id: user.id,
                username: user.username
            });
        } catch (error) {
            console.error("Login error:", error);
            return this.sendResponse(res, 500, { error: "Internal server error" });
        }
    }

    async handleLogout(req, res) {
        try {
            const authResult = this.authenticateUser(req);
            if (!authResult.authenticated) {
                return this.sendResponse(res, 401, { error: "Authentication required" });
            }

            const cookies = this.parseCookies(req.headers.cookie);
            const sessionId = cookies.session_id;

            if (sessionId) {
                this.sessions.delete(sessionId);
            }

            return this.sendResponse(res, 200, {});
        } catch (error) {
            console.error("Logout error:", error);
            return this.sendResponse(res, 500, { error: "Internal server error" });
        }
    }

    handleMe(req, res) {
        try {
            const authResult = this.authenticateUser(req);
            if (!authResult.authenticated) {
                return this.sendResponse(res, 401, { error: "Authentication required" });
            }

            const userId = authResult.userId;
            const userArray = Array.from(this.users.values());
            const user = userArray.find(u => u.id === userId);

            if (!user) {
                return this.sendResponse(res, 401, { error: "Authentication required" });
            }

            return this.sendResponse(res, 200, {
                id: user.id,
                username: user.username
            });
        } catch (error) {
            console.error("Me error:", error);
            return this.sendResponse(res, 500, { error: "Internal server error" });
        }
    }

    async handleUpdatePassword(req, res) {
        try {
            const authResult = this.authenticateUser(req);
            if (!authResult.authenticated) {
                return this.sendResponse(res, 401, { error: "Authentication required" });
            }

            let body = '';
            req.on('data', chunk => {
                body += chunk.toString();
            });

            await new Promise((resolve) => {
                req.on('end', resolve);
            });

            const { old_password, new_password } = JSON.parse(body);

            if (!new_password || typeof new_password !== 'string' || new_password.length < 8) {
                return this.sendResponse(res, 400, { error: "Password too short" });
            }

            const userId = authResult.userId;
            const usersArray = Array.from(this.users.entries());
            let userEntry = null;
            for (const [username, userData] of usersArray) {
                if (userData.id === userId) {
                    userEntry = { username, userData };
                    break;
                }
            }

            if (!userEntry || userEntry.userData.password !== old_password) {
                return this.sendResponse(res, 401, { error: "Invalid credentials" });
            }

            // Update password
            userEntry.userData.password = new_password;

            return this.sendResponse(res, 200, {});
        } catch (error) {
            console.error("Update password error:", error);
            return this.sendResponse(res, 500, { error: "Internal server error" });
        }
    }

    handleGetTodos(req, res) {
        try {
            const authResult = this.authenticateUser(req);
            if (!authResult.authenticated) {
                return this.sendResponse(res, 401, { error: "Authentication required" });
            }

            const userId = authResult.userId;
            const userTodos = [];
            
            for (const [, todo] of this.todos) {
                if (todo.user_id === userId) {
                    userTodos.push(todo);
                }
            }

            // Sort by ID ascending
            userTodos.sort((a, b) => a.id - b.id);

            return this.sendResponse(res, 200, userTodos);
        } catch (error) {
            console.error("Get todos error:", error);
            return this.sendResponse(res, 500, { error: "Internal server error" });
        }
    }

    async handleCreateTodo(req, res) {
        try {
            const authResult = this.authenticateUser(req);
            if (!authResult.authenticated) {
                return this.sendResponse(res, 401, { error: "Authentication required" });
            }

            let body = '';
            req.on('data', chunk => {
                body += chunk.toString();
            });

            await new Promise((resolve) => {
                req.on('end', resolve);
            });

            const { title, description } = JSON.parse(body);

            if (!title || typeof title !== 'string' || title.trim() === '') {
                return this.sendResponse(res, 400, { error: "Title is required" });
            }

            const newTodo = {
                id: this.nextTodoId++,
                title: title.trim(),
                description: description ? description.trim() : "",
                completed: false,
                created_at: this.getISOString(),
                updated_at: this.getISOString(),
                user_id: authResult.userId
            };

            this.todos.set(newTodo.id, newTodo);

            return this.sendResponse(res, 201, newTodo);
        } catch (error) {
            console.error("Create todo error:", error);
            return this.sendResponse(res, 500, { error: "Internal server error" });
        }
    }

    handleGetTodoById(req, res, todoId) {
        try {
            const authResult = this.authenticateUser(req);
            if (!authResult.authenticated) {
                return this.sendResponse(res, 401, { error: "Authentication required" });
            }

            const todo = this.todos.get(parseInt(todoId));
            if (!todo || todo.user_id !== authResult.userId) {
                return this.sendResponse(res, 404, { error: "Todo not found" });
            }

            return this.sendResponse(res, 200, todo);
        } catch (error) {
            console.error("Get todo by ID error:", error);
            return this.sendResponse(res, 500, { error: "Internal server error" });
        }
    }

    async handleUpdateTodo(req, res, todoId) {
        try {
            const authResult = this.authenticateUser(req);
            if (!authResult.authenticated) {
                return this.sendResponse(res, 401, { error: "Authentication required" });
            }

            const actualTodoId = parseInt(todoId);
            const existingTodo = this.todos.get(actualTodoId);

            if (!existingTodo || existingTodo.user_id !== authResult.userId) {
                return this.sendResponse(res, 404, { error: "Todo not found" });
            }

            let body = '';
            req.on('data', chunk => {
                body += chunk.toString();
            });

            await new Promise((resolve) => {
                req.on('end', resolve);
            });

            const updates = JSON.parse(body);

            // Validate title if provided
            if (updates.title !== undefined && (typeof updates.title !== 'string' || updates.title.trim() === '')) {
                return this.sendResponse(res, 400, { error: "Title is required" });
            }

            // Update the todo
            const updatedTodo = { ...existingTodo }; // Copy the existring todo
            
            if (updates.title !== undefined) {
                updatedTodo.title = updates.title.trim();
            }
            if (updates.description !== undefined) {
                updatedTodo.description = updates.description.trim();
            }
            if (updates.completed !== undefined) {
                updatedTodo.completed = Boolean(updates.completed);
            }
            updatedTodo.updated_at = this.getISOString(); // Always update timestamp on changes

            this.todos.set(actualTodoId, updatedTodo);

            return this.sendResponse(res, 200, updatedTodo);
        } catch (error) {
            console.error("Update todo error:", error);
            return this.sendResponse(res, 500, { error: "Internal server error" });
        }
    }

    handleDeleteTodo(req, res, todoId) {
        try {
            const authResult = this.authenticateUser(req);
            if (!authResult.authenticated) {
                return this.sendResponse(res, 401, { error: "Authentication required" });
            }

            const actualTodoId = parseInt(todoId);
            const todo = this.todos.get(actualTodoId);

            if (!todo || todo.user_id !== authResult.userId) {
                return this.sendResponse(res, 404, { error: "Todo not found" });
            }

            this.todos.delete(actualTodoId);
            
            res.statusCode = 204;
            res.end();

        } catch (error) {
            console.error("Delete todo error:", error);
            return this.sendResponse(res, 500, { error: "Internal server error" });
        }
    }

    sendResponse(res, statusCode, data) {
        res.setHeader('Content-Type', 'application/json');
        res.statusCode = statusCode;
        if (data) {
            res.end(JSON.stringify(data));
        } else {
            res.end();
        }
    }

    // Main request handler
    requestHandler(req, res) {
        const parsedUrl = url.parse(req.url, true);
        const path = parsedUrl.pathname;
        const method = req.method;
        
        // Add CORS headers for development purposes
        res.setHeader('Access-Control-Allow-Origin', '*');
        res.setHeader('Access-Control-Allow-Methods', 'GET, POST, PUT, DELETE');
        res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Cookie');

        // Handle preflight requests
        if (method === 'OPTIONS') {
            res.statusCode = 200;
            res.end();
            return;
        }

        const pathParts = path.split('/').filter(p => p !== '');
        
        // Route to correct handler
        if (method === 'POST' && path === '/register') {
            return this.handleRegister(req, res);
        } else if (method === 'POST' && path === '/login') {
            return this.handleLogin(req, res);
        } else if (method === 'POST' && path === '/logout') {
            return this.handleLogout(req, res);
        } else if (method === 'GET' && path === '/me') {
            return this.handleMe(req, res);
        } else if (method === 'PUT' && path === '/password') {
            return this.handleUpdatePassword(req, res);
        } else if (method === 'GET' && path === '/todos') {
            return this.handleGetTodos(req, res);
        } else if (method === 'POST' && path === '/todos') {
            return this.handleCreateTodo(req, res);
        } else if (method === 'GET' && path.startsWith('/todos/') && pathParts.length === 2 && pathParts[0] === 'todos') {
            const todoId = pathParts[1];
            return this.handleGetTodoById(req, res, todoId);
        } else if (method === 'PUT' && path.startsWith('/todos/') && pathParts.length === 2 && pathParts[0] === 'todos') {
            const todoId = pathParts[1];
            return this.handleUpdateTodo(req, res, todoId);
        } else if (method === 'DELETE' && path.startsWith('/todos/') && pathParts.length === 2 && pathParts[0] === 'todos') {
            const todoId = pathParts[1];
            return this.handleDeleteTodo(req, res, todoId);
        } else {
            // Handle 404 - Not Found
            res.statusCode = 404;
            res.setHeader('Content-Type', 'application/json');
            res.end(JSON.stringify({ error: "Not found" }));
        }
    }

    start(port) {
        const server = http.createServer((req, res) => {
            this.requestHandler(req, res);
        });
        
        server.listen(port, '0.0.0.0', () => {
            console.log(`Todo server running on http://0.0.0.0:${port}`);
        });
        
        return server;
    }
}

module.exports = TodoServer;