const http = require('http');
const url = require('url');
const crypto = require('crypto');
const querystring = require('querystring');

// In-memory storage
let users = {};
let sessions = {};
let todos = {};
let userIdCounter = 1;
let todoIdCounter = 1;

// Helper function for generating session IDs
function generateSessionId() {
    return crypto.randomUUID();
}

// Helper function for getting current timestamp in ISO 8601 format with second precision
function getCurrentTimestamp() {
    const now = new Date();
    // Round down to the nearest second
    now.setMilliseconds(0);
    return now.toISOString().replace(/\.\d{3}Z$/, 'Z');
}

// Helper function to validate username
function isValidUsername(username) {
    if (!username || typeof username !== 'string') return false;
    if (username.length < 3 || username.length > 50) return false;
    // Check alphanumeric and underscore only
    const regex = /^[a-zA-Z0-9_]+$/;
    return regex.test(username);
}

// Helper function to parse cookies
function parseCookies(request) {
    const cookies = {};
    const cookieHeader = request.headers.cookie;

    if (cookieHeader) {
        cookieHeader.split(';').forEach(cookie => {
            const parts = cookie.trim().split('=');
            const key = parts[0];
            const value = parts.slice(1).join('=');
            cookies[key] = value;
        });
    }

    return cookies;
}

// Helper function to get user by session ID
function getUserBySession(sessionId) {
    if (!sessionId) return null;
    const userId = sessions[sessionId];
    return userId ? users[userId] : null;
}

// Helper function to send response
function sendResponse(res, statusCode, body, headers = {}) {
    res.writeHead(statusCode, {
        'Content-Type': 'application/json',
        ...headers
    });

    if (statusCode !== 204) { // DELETE has no body
        res.end(JSON.stringify(body));
    } else {
        res.end();
    }
}

// Helper function to create a todo object
function createTodo(userId, title, description = "") {
    const now = getCurrentTimestamp();
    return {
        id: todoIdCounter++,
        title,
        description,
        completed: false,
        created_at: now,
        updated_at: now
    };
}

// Helper function to authenticate request
function authenticateRequest(req) {
    const cookies = parseCookies(req);
    const sessionId = cookies.session_id;
    
    if (!sessionId) {
        return null;
    }
    
    const user = getUserBySession(sessionId);
    return user ? { user, sessionId } : null;
}

// Main request handler
function handleRequest(req, res) {
    const parsedUrl = url.parse(req.url, true);
    const path = parsedUrl.pathname;
    const method = req.method;

    // Extract the ID from the path for endpoints that include :id
    let todoId = null;
    if (path.startsWith('/todos/')) {
        const parts = path.split('/');
        if (parts.length >= 3) {
            todoId = parseInt(parts[2], 10);
        }
    }

    // Helper for reading JSON body
    function readJsonBody(request, callback) {
        let body = '';
        
        request.on('data', chunk => {
            body += chunk.toString();
        });
        
        request.on('end', () => {
            try {
                const json = body.length > 0 ? JSON.parse(body) : {};
                callback(null, json);
            } catch (e) {
                callback(new Error('Invalid JSON'));
            }
        });
    }

    // Route handlers
    const routes = {
        '/register': {
            POST: (req, res) => {
                readJsonBody(req, (err, data) => {
                    if (err) {
                        return sendResponse(res, 400, { error: 'Invalid JSON' });
                    }

                    const { username, password } = data;

                    // Validation checks
                    if (!isValidUsername(username)) {
                        return sendResponse(res, 400, { error: 'Invalid username' });
                    }

                    if (!password || typeof password !== 'string' || password.length < 8) {
                        return sendResponse(res, 400, { error: 'Password too short' });
                    }

                    // Check if username already exists
                    for (const u of Object.values(users)) {
                        if (u.username === username) {
                            return sendResponse(res, 409, { error: 'Username already exists' });
                        }
                    }

                    // Create user
                    const newUser = {
                        id: userIdCounter++,
                        username: username
                    };

                    // Store password (in a real app, we'd hash this, but for simplicity we store as-is)
                    newUser.password = password; // Note: In a production system you would hash this!

                    users[newUser.id] = newUser;

                    return sendResponse(res, 201, {
                        id: newUser.id,
                        username: newUser.username
                    });
                });
            }
        },
        '/login': {
            POST: (req, res) => {
                readJsonBody(req, (err, data) => {
                    if (err) {
                        return sendResponse(res, 400, { error: 'Invalid JSON' });
                    }

                    const { username, password } = data;

                    let authenticatedUser = null;
                    
                    // Find user by username
                    for (const u of Object.values(users)) {
                        if (u.username === username && u.password === password) {
                            authenticatedUser = u;
                            break;
                        }
                    }

                    if (!authenticatedUser) {
                        return sendResponse(res, 401, { error: 'Invalid credentials' });
                    }

                    // Generate session
                    const sessionId = generateSessionId();
                    sessions[sessionId] = authenticatedUser.id;

                    // Set the session cookie in response headers
                    const headers = {
                        'Set-Cookie': `session_id=${sessionId}; Path=/; HttpOnly`
                    };

                    return sendResponse(res, 200, {
                        id: authenticatedUser.id,
                        username: authenticatedUser.username
                    }, headers);
                });
            }
        },
        '/logout': {
            POST: (req, res) => {
                const authResult = authenticateRequest(req);
                
                if (!authResult) {
                    return sendResponse(res, 401, { error: 'Authentication required' });
                }

                // Remove session from server-side tracking
                const { sessionId } = authResult;
                delete sessions[sessionId];

                return sendResponse(res, 200, {});
            }
        },
        '/me': {
            GET: (req, res) => {
                const authResult = authenticateRequest(req);
                
                if (!authResult) {
                    return sendResponse(res, 401, { error: 'Authentication required' });
                }

                const { user } = authResult;

                return sendResponse(res, 200, {
                    id: user.id,
                    username: user.username
                });
            }
        },
        '/password': {
            PUT: (req, res) => {
                readJsonBody(req, (err, data) => {
                    if (err) {
                        return sendResponse(res, 400, { error: 'Invalid JSON' });
                    }

                    const authResult = authenticateRequest(req);
                    
                    if (!authResult) {
                        return sendResponse(res, 401, { error: 'Authentication required' });
                    }

                    const { user } = authResult;
                    const { old_password, new_password } = data;

                    if (!old_password || user.password !== old_password) {
                        return sendResponse(res, 401, { error: 'Invalid credentials' });
                    }

                    if (!new_password || new_password.length < 8) {
                        return sendResponse(res, 400, { error: 'Password too short' });
                    }

                    // Update password
                    user.password = new_password;

                    return sendResponse(res, 200, {});
                });
            }
        },
        '/todos': {
            GET: (req, res) => {
                const authResult = authenticateRequest(req);
                
                if (!authResult) {
                    return sendResponse(res, 401, { error: 'Authentication required' });
                }

                const { user } = authResult;
                
                // Filter todos for this user
                const userTodos = Object.values(todos)
                    .filter(todo => todo.userId === user.id)
                    .sort((a, b) => a.id - b.id);

                return sendResponse(res, 200, userTodos);
            },
            POST: (req, res) => {
                readJsonBody(req, (err, data) => {
                    if (err) {
                        return sendResponse(res, 400, { error: 'Invalid JSON' });
                    }

                    const authResult = authenticateRequest(req);
                    
                    if (!authResult) {
                        return sendResponse(res, 401, { error: 'Authentication required' });
                    }

                    const { user } = authResult;
                    const { title, description } = data;

                    if (!title || title.trim() === '') {
                        return sendResponse(res, 400, { error: 'Title is required' });
                    }

                    // Create a new todo for this user
                    const newTodo = createTodo(user.id, title, description || "");
                    // Add user id for ownership tracking
                    newTodo.userId = user.id;
                    
                    todos[newTodo.id] = newTodo;

                    return sendResponse(res, 201, newTodo);
                });
            }
        }
    };

    // Handle specific todo routes (with ID)
    if (path.startsWith('/todos/') && path !== '/todos') {
        const route = {
            GET: (req, res) => {
                const authResult = authenticateRequest(req);
                
                if (!authResult) {
                    return sendResponse(res, 401, { error: 'Authentication required' });
                }

                const { user } = authResult;
                
                const todo = todos[todoId];
                
                if (!todo || todo.userId !== user.id) {
                    return sendResponse(res, 404, { error: 'Todo not found' });
                }

                return sendResponse(res, 200, todo);
            },
            PUT: (req, res) => {
                readJsonBody(req, (err, data) => {
                    if (err) {
                        return sendResponse(res, 400, { error: 'Invalid JSON' });
                    }

                    const authResult = authenticateRequest(req);
                    
                    if (!authResult) {
                        return sendResponse(res, 401, { error: 'Authentication required' });
                    }

                    const { user } = authResult;
                    
                    const todo = todos[todoId];
                    
                    if (!todo || todo.userId !== user.id) {
                        return sendResponse(res, 404, { error: 'Todo not found' });
                    }

                    // Validate partial updates
                    if ('title' in data && (typeof data.title !== 'string' || data.title.trim() === '')) {
                        return sendResponse(res, 400, { error: 'Title is required' });
                    }

                    // Apply partial updates
                    if ('title' in data) {
                        todo.title = data.title;
                    }
                    if ('description' in data) {
                        todo.description = data.description;
                    }
                    if ('completed' in data) {
                        todo.completed = Boolean(data.completed);
                    }
                    
                    // Update timestamp
                    todo.updated_at = getCurrentTimestamp();

                    return sendResponse(res, 200, todo);
                });
            },
            DELETE: (req, res) => {
                const authResult = authenticateRequest(req);
                
                if (!authResult) {
                    return sendResponse(res, 401, { error: 'Authentication required' });
                }

                const { user } = authResult;
                
                const todo = todos[todoId];
                
                if (!todo || todo.userId !== user.id) {
                    return sendResponse(res, 404, { error: 'Todo not found' });
                }

                // Delete the todo
                delete todos[todoId];
                
                return sendResponse(res, 204, null); // No content for DELETE
            }
        };

        if (route[method]) {
            return route[method](req, res);
        } else {
            return sendResponse(res, 405, { error: `Method ${method} not allowed for this endpoint` });
        }
    }

    // Handle other routes without ID
    if (routes[path] && routes[path][method]) {
        return routes[path][method](req, res);
    }

    // 404 not found
    return sendResponse(res, 404, { error: 'Endpoint not found' });
}

// Parse process.argv for --port option
let port = 3000;
for (let i = 2; i < process.argv.length; i++) {
    if (process.argv[i] === '--port' && process.argv[i + 1]) {
        port = parseInt(process.argv[i + 1], 10);
        break;
    }
}

// Create server
const server = http.createServer(handleRequest);

server.listen(port, '0.0.0.0', () => {
    console.log(`Server running at http://0.0.0.0:${port}/`);
});

module.exports = { server, handleRequest };