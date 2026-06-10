const http = require('http');
const crypto = require('crypto');

let nextUserId = 1;
let nextTodoId = 1;
const users = new Map();
const usernameToId = new Map();
const todos = new Map();
const sessions = new Map();

function getTimestamp() {
    return new Date().toISOString().slice(0, 19) + 'Z';
}

function generateToken() {
    return crypto.randomBytes(16).toString('hex');
}

function parseCookies(cookieHeader) {
    if (!cookieHeader) return {};
    const cookies = {};
    cookieHeader.split(';').forEach(cookie => {
        const parts = cookie.trim().split('=');
        const name = parts[0].trim();
        const value = parts.slice(1).join('=').trim();
        if (name) {
            cookies[name] = value;
        }
    });
    return cookies;
}

function getUserFromReq(req) {
    const cookies = parseCookies(req.headers.cookie);
    const token = cookies['session_id'];
    if (token && sessions.has(token)) {
        const userId = sessions.get(token);
        return users.get(userId);
    }
    return null;
}

function sendJson(res, statusCode, data) {
    res.writeHead(statusCode, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(data));
}

function sendError(res, statusCode, message) {
    sendJson(res, statusCode, { error: message });
}

function parseBody(req) {
    return new Promise((resolve, reject) => {
        let body = '';
        req.on('data', chunk => body += chunk.toString());
        req.on('end', () => {
            try {
                resolve(body ? JSON.parse(body) : {});
            } catch (e) {
                resolve({});
            }
        });
        req.on('error', reject);
    });
}

async function handleRegister(req, res) {
    const body = await parseBody(req);
    const { username, password } = body;
    
    if (!username || typeof username !== 'string' || !/^[a-zA-Z0-9_]{3,50}$/.test(username)) {
        return sendError(res, 400, "Invalid username");
    }
    if (!password || typeof password !== 'string' || password.length < 8) {
        return sendError(res, 400, "Password too short");
    }
    if (usernameToId.has(username)) {
        return sendError(res, 409, "Username already exists");
    }
    
    const id = nextUserId++;
    const user = { id, username, password };
    users.set(id, user);
    usernameToId.set(username, id);
    
    sendJson(res, 201, { id, username });
}

async function handleLogin(req, res) {
    const body = await parseBody(req);
    const { username, password } = body;
    
    const userId = usernameToId.get(username);
    if (!userId) {
        return sendError(res, 401, "Invalid credentials");
    }
    
    const user = users.get(userId);
    if (user.password !== password) {
        return sendError(res, 401, "Invalid credentials");
    }
    
    const token = generateToken();
    sessions.set(token, userId);
    
    res.writeHead(200, {
        'Content-Type': 'application/json',
        'Set-Cookie': `session_id=${token}; Path=/; HttpOnly`
    });
    res.end(JSON.stringify({ id: user.id, username: user.username }));
}

async function handleLogout(req, res) {
    const user = getUserFromReq(req);
    if (!user) return sendError(res, 401, "Authentication required");
    
    const cookies = parseCookies(req.headers.cookie);
    const token = cookies['session_id'];
    sessions.delete(token);
    
    sendJson(res, 200, {});
}

async function handleMe(req, res) {
    const user = getUserFromReq(req);
    if (!user) return sendError(res, 401, "Authentication required");
    
    sendJson(res, 200, { id: user.id, username: user.username });
}

async function handlePassword(req, res) {
    const user = getUserFromReq(req);
    if (!user) return sendError(res, 401, "Authentication required");
    
    const body = await parseBody(req);
    const { old_password, new_password } = body;
    
    if (user.password !== old_password) {
        return sendError(res, 401, "Invalid credentials");
    }
    if (typeof new_password !== 'string' || new_password.length < 8) {
        return sendError(res, 400, "Password too short");
    }
    
    user.password = new_password;
    sendJson(res, 200, {});
}

async function handleGetTodos(req, res) {
    const user = getUserFromReq(req);
    if (!user) return sendError(res, 401, "Authentication required");
    
    const userTodos = [];
    for (const todo of todos.values()) {
        if (todo.user_id === user.id) {
            userTodos.push({
                id: todo.id,
                title: todo.title,
                description: todo.description,
                completed: todo.completed,
                created_at: todo.created_at,
                updated_at: todo.updated_at
            });
        }
    }
    userTodos.sort((a, b) => a.id - b.id);
    
    sendJson(res, 200, userTodos);
}

async function handleCreateTodo(req, res) {
    const user = getUserFromReq(req);
    if (!user) return sendError(res, 401, "Authentication required");
    
    const body = await parseBody(req);
    const { title, description } = body;
    
    if (typeof title !== 'string' || title.length === 0) {
        return sendError(res, 400, "Title is required");
    }
    
    const id = nextTodoId++;
    const now = getTimestamp();
    const todo = {
        id,
        user_id: user.id,
        title,
        description: description !== undefined ? description : "",
        completed: false,
        created_at: now,
        updated_at: now
    };
    todos.set(id, todo);
    
    sendJson(res, 201, {
        id: todo.id,
        title: todo.title,
        description: todo.description,
        completed: todo.completed,
        created_at: todo.created_at,
        updated_at: todo.updated_at
    });
}

async function handleGetTodo(req, res, id) {
    const user = getUserFromReq(req);
    if (!user) return sendError(res, 401, "Authentication required");
    
    const todoId = parseInt(id, 10);
    const todo = todos.get(todoId);
    
    if (!todo || todo.user_id !== user.id) {
        return sendError(res, 404, "Todo not found");
    }
    
    sendJson(res, 200, {
        id: todo.id,
        title: todo.title,
        description: todo.description,
        completed: todo.completed,
        created_at: todo.created_at,
        updated_at: todo.updated_at
    });
}

async function handleUpdateTodo(req, res, id) {
    const user = getUserFromReq(req);
    if (!user) return sendError(res, 401, "Authentication required");
    
    const todoId = parseInt(id, 10);
    const todo = todos.get(todoId);
    
    if (!todo || todo.user_id !== user.id) {
        return sendError(res, 404, "Todo not found");
    }
    
    const body = await parseBody(req);
    
    if (body.title !== undefined) {
        if (typeof body.title !== 'string' || body.title === '') {
            return sendError(res, 400, "Title is required");
        }
        todo.title = body.title;
    }
    if (body.description !== undefined) {
        todo.description = body.description;
    }
    if (body.completed !== undefined) {
        todo.completed = body.completed;
    }
    
    todo.updated_at = getTimestamp();
    
    sendJson(res, 200, {
        id: todo.id,
        title: todo.title,
        description: todo.description,
        completed: todo.completed,
        created_at: todo.created_at,
        updated_at: todo.updated_at
    });
}

async function handleDeleteTodo(req, res, id) {
    const user = getUserFromReq(req);
    if (!user) return sendError(res, 401, "Authentication required");
    
    const todoId = parseInt(id, 10);
    const todo = todos.get(todoId);
    
    if (!todo || todo.user_id !== user.id) {
        return sendError(res, 404, "Todo not found");
    }
    
    todos.delete(todoId);
    res.writeHead(204);
    res.end();
}

const server = http.createServer(async (req, res) => {
    const url = new URL(req.url, `http://${req.headers.host}`);
    const path = url.pathname;
    const method = req.method;
    
    try {
        if (method === 'POST' && path === '/register') {
            await handleRegister(req, res);
        } else if (method === 'POST' && path === '/login') {
            await handleLogin(req, res);
        } else if (method === 'POST' && path === '/logout') {
            await handleLogout(req, res);
        } else if (method === 'GET' && path === '/me') {
            await handleMe(req, res);
        } else if (method === 'PUT' && path === '/password') {
            await handlePassword(req, res);
        } else if (method === 'GET' && path === '/todos') {
            await handleGetTodos(req, res);
        } else if (method === 'POST' && path === '/todos') {
            await handleCreateTodo(req, res);
        } else {
            const todoMatch = path.match(/^\/todos\/(\d+)$/);
            if (todoMatch) {
                const id = todoMatch[1];
                if (method === 'GET') {
                    await handleGetTodo(req, res, id);
                } else if (method === 'PUT') {
                    await handleUpdateTodo(req, res, id);
                } else if (method === 'DELETE') {
                    await handleDeleteTodo(req, res, id);
                } else {
                    sendError(res, 405, "Method not allowed");
                }
            } else {
                sendError(res, 404, "Not found");
            }
        }
    } catch (err) {
        console.error(err);
        sendError(res, 500, "Internal server error");
    }
});

const portArgIndex = process.argv.indexOf('--port');
const port = portArgIndex !== -1 ? parseInt(process.argv[portArgIndex + 1], 10) : 3000;

server.listen(port, '0.0.0.0', () => {
    console.log(`Server listening on 0.0.0.0:${port}`);
});
