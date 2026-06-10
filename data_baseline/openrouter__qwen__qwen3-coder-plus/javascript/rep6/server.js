const http = require('http');
const url = require('url');
const crypto = require('crypto');
const querystring = require('querystring');

// In-memory storage
let users = {};
let todos = {};
let sessions = {}; // Maps session_id to user_id
let userIdCounter = 1;
let todoIdCounter = 1;

// Helper function to validate username
function isValidUsername(username) {
    if (!username || typeof username !== 'string') return false;
    if (username.length < 3 || username.length > 50) return false;
    if (!/^[a-zA-Z0-9_]+$/.test(username)) return false;
    return true;
}

// Helper function to generate timestamps
function getTimestamp() {
    return new Date().toISOString().replace(/\.\d+Z$/, 'Z');
}

// Helper to parse cookies
function parseCookies(cookieHeader) {
    const result = {};
    if (!cookieHeader) return result;
    
    cookieHeader.split(';').forEach(cookie => {
        const [key, value] = cookie.trim().split('=');
        result[key] = value;
    });
    
    return result;
}

// Helper to get user from session
function getUserFromSession(cookies) {
    const sessionId = cookies.session_id;
    if (!sessionId || !sessions[sessionId]) {
        return null;
    }
    return sessions[sessionId];
}

// Helper to send response
function sendResponse(res, statusCode, data, headers = {}) {
    res.writeHead(statusCode, {
        'Content-Type': 'application/json',
        ...headers
    });

    if (data !== undefined && data !== null) {
        res.write(JSON.stringify(data));
    }

    res.end();
}

// Helper to create an HTTP-only session cookie
function createSessionCookie(sessionId) {
    return `session_id=${sessionId}; Path=/; HttpOnly`;
}

// Main server handler
function handleRequest(req, res) {
    const parsedUrl = url.parse(req.url, true);
    const pathParts = parsedUrl.pathname.split('/');
    const method = req.method;
    
    // Extract route and ID if present
    let route = '';
    let idParam = null;
    
    if (pathParts.length >= 2) {
        route = pathParts.slice(1).join('/');
    }
    
    // Special handling for routes with IDs
    if (route.startsWith('todos/')) {
        const remaining = route.substring(6); // Remove 'todos/' prefix
        const slashIndex = remaining.indexOf('/');
        if (slashIndex === -1) {
            idParam = remaining;
            route = 'todos/id';
        } else {
            idParam = remaining.substring(0, slashIndex);
            route = 'todos/id'; // For consistency
        }
    }

    // Parse cookies
    const cookies = parseCookies(req.headers.cookie);

    // Read request body
    let body = '';
    req.on('data', chunk => {
        body += chunk.toString();
    });

    req.on('end', () => {
        try {
            // Default to parsing as JSON for most cases
            let requestBody = {};
            if (body) {
                try {
                    requestBody = JSON.parse(body);
                } catch (e) {
                    // If not JSON, try to parse as form-encoded
                    try {
                        requestBody = querystring.parse(body);
                    } catch (e2) {
                        // If neither, leave it as an empty object
                        requestBody = {};
                    }
                }
            }

            // Route handlers
            if (method === 'POST' && route === 'register') {
                return handleRegister(req, res, requestBody);
            } else if (method === 'POST' && route === 'login') {
                return handleLogin(req, res, requestBody);
            } else if (method === 'POST' && route === 'logout') {
                return handleLogout(req, res, cookies);
            } else if (method === 'GET' && route === 'me') {
                return handleMe(req, res, cookies);
            } else if (method === 'PUT' && route === 'password') {
                return handleChangePassword(req, res, cookies, requestBody);
            } else if (method === 'GET' && route === 'todos') {
                return handleGetTodos(req, res, cookies);
            } else if (method === 'POST' && route === 'todos') {
                return handleCreateTodo(req, res, cookies, requestBody);
            } else if (method === 'GET' && route === 'todos/id') {
                return handleGetTodoById(req, res, cookies, idParam);
            } else if (method === 'PUT' && route === 'todos/id') {
                return handleUpdateTodoById(req, res, cookies, idParam, requestBody);
            } else if (method === 'DELETE' && route === 'todos/id') {
                return handleDeleteTodoById(req, res, cookies, idParam);
            } else {
                // Unknown route
                sendResponse(res, 404, { error: 'Not Found' });
            }
        } catch (error) {
            console.error('Error processing request:', error);
            sendResponse(res, 500, { error: 'Internal server error' });
        }
    });
}

function handleRegister(req, res, requestBody) {
    const { username, password } = requestBody;

    if (!isValidUsername(username)) {
        return sendResponse(res, 400, { error: 'Invalid username' });
    }

    if (!password || typeof password !== 'string') {
        return sendResponse(res, 400, { error: 'Password too short' });
    }

    if (password.length < 8) {
        return sendResponse(res, 400, { error: 'Password too short' });
    }

    // Check if username exists
    for (const userId in users) {
        if (users[userId].username === username) {
            return sendResponse(res, 409, { error: 'Username already exists' });
        }
    }

    // Create new user
    const newUser = {
        id: userIdCounter,
        username: username,
        password: password // In reality, you would hash this
    };
    
    users[userIdCounter] = newUser;
    const returnUser = { id: newUser.id, username: newUser.username };
    
    // Increment counter for next user
    userIdCounter++;
    
    return sendResponse(res, 201, returnUser);
}

function handleLogin(req, res, requestBody) {
    const { username, password } = requestBody;

    let userId = null;
    for (const id in users) {
        if (users[id].username === username && users[id].password === password) {
            userId = parseInt(id);
            break;
        }
    }

    if (!userId) {
        return sendResponse(res, 401, { error: 'Invalid credentials' });
    }

    // Generate a session ID
    const sessionId = crypto.randomUUID();
    sessions[sessionId] = userId;

    const user = { id: users[userId].id, username: users[userId].username };

    return sendResponse(res, 200, user, { 
        'Set-Cookie': createSessionCookie(sessionId)
    });
}

function handleLogout(req, res, cookies) {
    const sessionId = cookies.session_id;
    if (!sessionId || !sessions[sessionId]) {
        return sendResponse(res, 401, { error: 'Authentication required' });
    }

    // Delete the session
    delete sessions[sessionId];

    return sendResponse(res, 200, {});
}

function handleMe(req, res, cookies) {
    const userId = getUserFromSession(cookies);
    if (!userId) {
        return sendResponse(res, 401, { error: 'Authentication required' });
    }

    const user = users[userId];
    if (!user) {
        return sendResponse(res, 401, { error: 'Authentication required' });
    }

    const resultUser = { id: user.id, username: user.username };
    return sendResponse(res, 200, resultUser);
}

function handleChangePassword(req, res, cookies, requestBody) {
    const userId = getUserFromSession(cookies);
    if (!userId) {
        return sendResponse(res, 401, { error: 'Authentication required' });
    }

    const currentUser = users[userId];
    if (!currentUser) {
        return sendResponse(res, 401, { error: 'Authentication required' });
    }

    const { old_password, new_password } = requestBody;

    if (currentUser.password !== old_password) {
        return sendResponse(res, 401, { error: 'Invalid credentials' });
    }

    if (!new_password || typeof new_password !== 'string' || new_password.length < 8) {
        return sendResponse(res, 400, { error: 'Password too short' });
    }

    currentUser.password = new_password;

    return sendResponse(res, 200, {});
}

function handleGetTodos(req, res, cookies) {
    const userId = getUserFromSession(cookies);
    if (!userId) {
        return sendResponse(res, 401, { error: 'Authentication required' });
    }

    // Filter todos by user
    const userTodos = [];
    for (const id in todos) {
        if (todos[id].user_id === userId) {
            // Send copy without internal user_id
            const { user_id, ...todo } = todos[id];
            userTodos.push(todo);
        }
    }

    // Sort by ID in ascending order
    userTodos.sort((a, b) => a.id - b.id);

    return sendResponse(res, 200, userTodos);
}

function handleCreateTodo(req, res, cookies, requestBody) {
    const userId = getUserFromSession(cookies);
    if (!userId) {
        return sendResponse(res, 401, { error: 'Authentication required' });
    }

    const { title, description = "" } = requestBody;

    if (!title || typeof title !== 'string' || title.trim() === '') {
        return sendResponse(res, 400, { error: 'Title is required' });
    }

    const timestamp = getTimestamp();

    const newTodo = {
        id: todoIdCounter,
        title: title,
        description: typeof description === 'string' ? description : "",
        completed: false,
        created_at: timestamp,
        updated_at: timestamp,
        user_id: userId  // Internal field to track owner
    };

    todos[todoIdCounter] = newTodo;
    const returnTodo = { ...newTodo }; // Copy for response
    delete returnTodo.user_id; // Don't include user_id in response
    
    // Increment counter for next todo
    todoIdCounter++;

    return sendResponse(res, 201, returnTodo);
}

function handleGetTodoById(req, res, cookies, idParam) {
    const userId = getUserFromSession(cookies);
    if (!userId) {
        return sendResponse(res, 401, { error: 'Authentication required' });
    }

    const todoId = parseInt(idParam);
    if (isNaN(todoId)) {
        return sendResponse(res, 404, { error: 'Todo not found' });
    }

    const todo = todos[todoId];
    if (!todo || todo.user_id !== userId) {
        return sendResponse(res, 404, { error: 'Todo not found' });
    }

    // Copy todo without the internal user_id
    const returnTodo = { ...todo };
    delete returnTodo.user_id;

    return sendResponse(res, 200, returnTodo);
}

function handleUpdateTodoById(req, res, cookies, idParam, requestBody) {
    const userId = getUserFromSession(cookies);
    if (!userId) {
        return sendResponse(res, 401, { error: 'Authentication required' });
    }

    const todoId = parseInt(idParam);
    if (isNaN(todoId)) {
        return sendResponse(res, 404, { error: 'Todo not found' });
    }

    const todo = todos[todoId];
    if (!todo || todo.user_id !== userId) {
        return sendResponse(res, 404, { error: 'Todo not found' });
    }

    // Validate completed field if exists (should be bool)
    if (requestBody.hasOwnProperty('completed') && typeof requestBody.completed !== 'boolean') {
        return sendResponse(res, 400, { error: 'Invalid completed status' });
    }

    // Update values if provided
    let updated = false;
    
    if (requestBody.hasOwnProperty('title')) {
        const newTitle = requestBody.title;
        if (typeof newTitle !== 'string' || newTitle.trim() === '') {
            return sendResponse(res, 400, { error: 'Title is required' });
        }
        todo.title = newTitle;
        updated = true;
    }
    
    if (requestBody.hasOwnProperty('description')) {
        const newDescription = typeof requestBody.description === 'string' ? requestBody.description : "";
        todo.description = newDescription;
        updated = true;
    }
    
    if (requestBody.hasOwnProperty('completed') && typeof requestBody.completed === 'boolean') {
        todo.completed = requestBody.completed;
        updated = true;
    }
    
    // Update the timestamp if anything was changed
    if (updated) {
        todo.updated_at = getTimestamp();
    }

    // Prepare response without internal user_id
    const returnTodo = { ...todo };
    delete returnTodo.user_id;

    return sendResponse(res, 200, returnTodo);
}

function handleDeleteTodoById(req, res, cookies, idParam) {
    const userId = getUserFromSession(cookies);
    if (!userId) {
        return sendResponse(res, 401, { error: 'Authentication required' });
    }

    const todoId = parseInt(idParam);
    if (isNaN(todoId)) {
        return sendResponse(res, 404, { error: 'Todo not found' });
    }

    const todo = todos[todoId];
    if (!todo || todo.user_id !== userId) {
        return sendResponse(res, 404, { error: 'Todo not found' });
    }

    // Delete the todo
    delete todos[todoId];

    // Use 204 with no body as specified
    res.writeHead(204, { 'Content-Type': 'application/json' });
    res.end();
}

// Parse command line arguments
let port = 3000; // Default fallback
for (let i = 0; i < process.argv.length; i++) {
    if (process.argv[i] === '--port' && i + 1 < process.argv.length) {
        port = parseInt(process.argv[i + 1]);
        break;
    }
}

// Create the HTTP server
const server = http.createServer(handleRequest);

// Start the server
server.listen(port, '0.0.0.0', () => {
    console.log(`Server running on 0.0.0.0:${port}`);
});