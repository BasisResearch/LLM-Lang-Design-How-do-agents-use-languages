const http = require('http');
const url = require('url');
const crypto = require('crypto');
const querystring = require('querystring');

// In-memory storage
let users = {};
let todos = {};
let sessions = {};

// Autoincrement counters
let nextUserId = 1;
let nextTodoId = 1;

// Helper function to validate username
function isValidUsername(username) {
    if (!username || typeof username !== 'string') return false;
    return /^[a-zA-Z0-9_]+$/.test(username) && username.length >= 3 && username.length <= 50;
}

// Helper function to get session id from cookies
function getSessionIdFromCookies(cookies) {
    if (!cookies) return null;
    
    const cookiePairs = cookies.split(';');
    for (const pair of cookiePairs) {
        const trimmedPair = pair.trim();
        if (trimmedPair.startsWith('session_id=')) {
            return trimmedPair.substring('session_id='.length);
        }
    }
    return null;
}

// Helper function to get authenticated user
function getAuthenticatedUser(req) {
    const cookies = req.headers.cookie;
    const sessionId = getSessionIdFromCookies(cookies);
    
    if (!sessionId || !sessions[sessionId]) {
        return null;
    }
    
    const userId = sessions[sessionId];
    return users[userId];
}

// Helper function to create a new timestamp
function getCurrentTimestamp() {
    const now = new Date();
    // Format to ISO 8601 with second precision: YYYY-MM-DDTHH:MM:SSZ
    return now.toISOString().replace(/\.\d{3}Z$/, 'Z');
}

// Helper function to send JSON response
function sendJsonResponse(res, statusCode, data) {
    res.writeHead(statusCode, {
        'Content-Type': 'application/json'
    });
    
    if (data !== undefined) {
        res.end(JSON.stringify(data));
    } else {
        res.end();
    }
}

// Helper function to send error response
function sendErrorResponse(res, statusCode, message) {
    sendJsonResponse(res, statusCode, { error: message });
}

// Main request handler
function handleRequest(req, res) {
    const parsedUrl = url.parse(req.url, true);
    const pathname = parsedUrl.pathname;
    const method = req.method;

    // Parse body if needed and route exists
    if ((method === 'POST' || method === 'PUT') && (
        pathname === '/register' || 
        pathname === '/login' || 
        pathname === '/password' || 
        pathname === '/todos' || 
        /^\/todos\/\d+$/.test(pathname)
    )) {
        
        let body = '';
        req.on('data', chunk => {
            body += chunk.toString();
        });
        req.on('end', () => {
            continueWithBody(req, res, body);
        });
        req.on('error', (err) => {
            sendErrorResponse(res, 400, 'Request error');
        });
    } else {
        // For GET, DELETE and other routes without body
        continueWithBody(req, res, '');
    }
}

// Process request after body is received
function continueWithBody(req, res, body) {
    const parsedUrl = url.parse(req.url, true);
    const pathname = parsedUrl.pathname;
    const method = req.method;

    const routeMatch = pathname.match(/^\/todos\/(\d+)$/);
    
    // Public routes
    if (method === 'POST' && pathname === '/register') {
        registerHandler(req, res, body);
    } else if (method === 'POST' && pathname === '/login') {
        loginHandler(req, res, body);
    // Protected routes
    } else if (method === 'POST' && pathname === '/logout') {
        logoutHandler(req, res);
    } else if (method === 'GET' && pathname === '/me') {
        meHandler(req, res);
    } else if (method === 'PUT' && pathname === '/password') {
        passwordHandler(req, res, body);
    } else if (method === 'GET' && pathname === '/todos') {
        getTodosHandler(req, res);
    } else if (method === 'POST' && pathname === '/todos') {
        createTodoHandler(req, res, body);
    } else if (routeMatch && method === 'GET') {
        const todoId = parseInt(routeMatch[1]);
        getTodoHandler(req, res, todoId);
    } else if (routeMatch && method === 'PUT') {
        const todoId = parseInt(routeMatch[1]);
        updateTodoHandler(req, res, todoId, body);
    } else if (routeMatch && method === 'DELETE') {
        const todoId = parseInt(routeMatch[1]);
        deleteTodoHandler(req, res, todoId);
    } else {
        // Unknown route
        sendErrorResponse(res, 404, 'Endpoint not found');
    }
}

// POST /register
function registerHandler(req, res, body) {
    try {
        const { username, password } = JSON.parse(body);

        // Validation
        if (!isValidUsername(username)) {
            return sendErrorResponse(res, 400, 'Invalid username');
        }

        if (!password || password.length < 8) {
            return sendErrorResponse(res, 400, 'Password too short');
        }

        // Check if username already exists
        for (const user of Object.values(users)) {
            if (user.username === username) {
                return sendErrorResponse(res, 409, 'Username already exists');
            }
        }

        // Create new user
        const userId = nextUserId++;
        const newUser = {
            id: userId,
            username,
            password: password // In a real app, this should be hashed
        };
        users[userId] = newUser;

        // Remove password from response - user object should not include password
        const responseUser = { id: userId, username: newUser.username };
        sendJsonResponse(res, 201, responseUser);
    } catch (err) {
        sendErrorResponse(res, 400, 'Invalid request body');
    }
}

// POST /login
function loginHandler(req, res, body) {
    try {
        const { username, password } = JSON.parse(body);

        let user = null;
        for (const u of Object.values(users)) {
            if (u.username === username && u.password === password) {
                user = u;
                break;
            }
        }

        if (!user) {
            return sendErrorResponse(res, 401, 'Invalid credentials');
        }

        // Generate session ID and store session
        const sessionId = crypto.randomUUID();
        sessions[sessionId] = user.id;

        // Remove password from response and send user data with proper IDs
        const responseUser = { id: user.id, username: user.username };

        // Set cookie and send response
        res.writeHead(200, {
            'Content-Type': 'application/json',
            'Set-Cookie': `session_id=${sessionId}; Path=/; HttpOnly`
        });
        res.end(JSON.stringify(responseUser));
    } catch (err) {
        sendErrorResponse(res, 400, 'Invalid request body');
    }
}

// POST /logout
function logoutHandler(req, res) {
    const authenticatedUser = getAuthenticatedUser(req);
    
    if (!authenticatedUser) {
        return sendErrorResponse(res, 401, 'Authentication required');
    }

    // Get session ID and delete it
    const cookies = req.headers.cookie;
    const sessionId = getSessionIdFromCookies(cookies);
    
    if (sessionId && sessions[sessionId]) {
        delete sessions[sessionId];
    }

    sendJsonResponse(res, 200, {});
}

// GET /me
function meHandler(req, res) {
    const authenticatedUser = getAuthenticatedUser(req);
    
    if (!authenticatedUser) {
        return sendErrorResponse(res, 401, 'Authentication required');
    }

    // Send user with proper fields
    const responseUser = { id: authenticatedUser.id, username: authenticatedUser.username };
    sendJsonResponse(res, 200, responseUser);
}

// PUT /password
function passwordHandler(req, res, body) {
    const authenticatedUser = getAuthenticatedUser(req);
    
    if (!authenticatedUser) {
        return sendErrorResponse(res, 401, 'Authentication required');
    }

    try {
        const { old_password, new_password } = JSON.parse(body);

        if (authenticatedUser.password !== old_password) {
            return sendErrorResponse(res, 401, 'Invalid credentials');
        }

        if (!new_password || new_password.length < 8) {
            return sendErrorResponse(res, 400, 'Password too short');
        }

        // Update password
        authenticatedUser.password = new_password;
        sendJsonResponse(res, 200, {});
    } catch (err) {
        sendErrorResponse(res, 400, 'Invalid request body');
    }
}

// GET /todos
function getTodosHandler(req, res) {
    const authenticatedUser = getAuthenticatedUser(req);
    
    if (!authenticatedUser) {
        return sendErrorResponse(res, 401, 'Authentication required');
    }

    // Get all todos for the authenticated user
    const userTodos = [];
    for (const todo of Object.values(todos)) {
        if (todo.userId === authenticatedUser.id) {
            // Remove internal userId from response
            const todoCopy = {...todo};
            delete todoCopy.userId;
            userTodos.push(todoCopy);
        }
    }
    
    // Sort by id ascending
    userTodos.sort((a, b) => a.id - b.id);
    sendJsonResponse(res, 200, userTodos);
}

// POST /todos
function createTodoHandler(req, res, body) {
    const authenticatedUser = getAuthenticatedUser(req);
    
    if (!authenticatedUser) {
        return sendErrorResponse(res, 401, 'Authentication required');
    }

    try {
        const { title, description } = JSON.parse(body);

        if (!title) {
            return sendErrorResponse(res, 400, 'Title is required');
        }

        // Create new todo
        const todoId = nextTodoId++;
        const createdAt = getCurrentTimestamp();
        const updatedAt = createdAt;
        
        const newTodo = {
            id: todoId,
            title,
            description: description || '',
            completed: false,
            created_at: createdAt,
            updated_at: updatedAt,
            userId: authenticatedUser.id
        };
        
        todos[todoId] = newTodo;

        // Send back without userId field (implementation detail)
        const responseTodo = { ...newTodo };
        delete responseTodo.userId;
        
        sendJsonResponse(res, 201, responseTodo);
    } catch (err) {
        sendErrorResponse(res, 400, 'Invalid request body');
    }
}

// GET /todos/:id
function getTodoHandler(req, res, todoId) {
    const authenticatedUser = getAuthenticatedUser(req);
    
    if (!authenticatedUser) {
        return sendErrorResponse(res, 401, 'Authentication required');
    }

    const todo = todos[todoId];
    
    // Check if todo exists and belongs to authenticated user
    if (!todo || todo.userId !== authenticatedUser.id) {
        return sendErrorResponse(res, 404, 'Todo not found');
    }

    // Send back without userId field
    const responseTodo = { ...todo };
    delete responseTodo.userId;
    
    sendJsonResponse(res, 200, responseTodo);
}

// PUT /todos/:id
function updateTodoHandler(req, res, todoId, body) {
    const authenticatedUser = getAuthenticatedUser(req);
    
    if (!authenticatedUser) {
        return sendErrorResponse(res, 401, 'Authentication required');
    }

    const existingTodo = todos[todoId];
    
    // Check if todo exists and belongs to authenticated user
    if (!existingTodo || existingTodo.userId !== authenticatedUser.id) {
        return sendErrorResponse(res, 404, 'Todo not found');
    }

    try {
        const updates = JSON.parse(body);

        // Validate if title is provided and is empty
        if (updates.hasOwnProperty('title') && updates.title !== undefined && 
            (typeof updates.title !== 'string' || updates.title === '')) {
            return sendErrorResponse(res, 400, 'Title is required');
        }

        // Apply updates (partial update)
        if (updates.title !== undefined) {
            existingTodo.title = updates.title;
        }
        if (updates.description !== undefined) {
            existingTodo.description = updates.description;
        }
        if (updates.completed !== undefined) {
            existingTodo.completed = updates.completed;
        }
        
        // Update timestamp
        existingTodo.updated_at = getCurrentTimestamp();

        // Send back without userId field
        const responseTodo = { ...existingTodo };
        delete responseTodo.userId;
        
        sendJsonResponse(res, 200, responseTodo);
    } catch (err) {
        sendErrorResponse(res, 400, 'Invalid request body');
    }
}

// DELETE /todos/:id
function deleteTodoHandler(req, res, todoId) {
    const authenticatedUser = getAuthenticatedUser(req);
    
    if (!authenticatedUser) {
        return sendErrorResponse(res, 401, 'Authentication required');
    }

    const todo = todos[todoId];
    
    // Check if todo exists and belongs to authenticated user
    if (!todo || todo.userId !== authenticatedUser.id) {
        return sendErrorResponse(res, 404, 'Todo not found');
    }

    // Delete the todo
    delete todos[todoId];
    
    // Status code 204 No Content as per spec
    res.writeHead(204);
    res.end();
}

// Create and start server
function startServer(port) {
    const server = http.createServer(handleRequest);
    
    server.listen(port, '0.0.0.0', () => {
        console.log(`Server running on 0.0.0.0:${port}`);
    });
    
    // Handle graceful shutdowns
    server.on('error', (err) => {
        console.error(`Server error: ${err}`);
        process.exit(1);
    });

    return server;
}

module.exports = { startServer };

if (require.main === module) {
    const args = process.argv.slice(2);
    let port = 3000; // default port
    
    for (let i = 0; i < args.length; i++) {
        if (args[i] === '--port' && args[i+1]) {
            port = parseInt(args[i+1]);
            i++;
        }
    }

    startServer(port);
}