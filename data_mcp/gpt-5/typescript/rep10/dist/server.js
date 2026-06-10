"use strict";
var __importDefault = (this && this.__importDefault) || function (mod) {
    return (mod && mod.__esModule) ? mod : { "default": mod };
};
Object.defineProperty(exports, "__esModule", { value: true });
const express_1 = __importDefault(require("express"));
const uuid_1 = require("uuid");
// In-memory storage
const users = [];
const sessions = new Map(); // token -> userId
const todos = [];
let nextUserId = 1;
let nextTodoId = 1;
// Helpers
function isoNowSeconds() {
    const d = new Date();
    // Ensure UTC ISO 8601 with seconds precision and Z
    const iso = d.toISOString(); // e.g., 2025-01-15T09:30:00.123Z
    return iso.replace(/\..+Z$/, 'Z');
}
function setJson(res) {
    res.setHeader('Content-Type', 'application/json');
}
function parseCookies(req) {
    const header = req.headers['cookie'];
    const result = {};
    if (!header)
        return result;
    const parts = header.split(';');
    for (const part of parts) {
        const [k, ...rest] = part.trim().split('=');
        const v = rest.join('=');
        if (k)
            result[k] = decodeURIComponent(v || '');
    }
    return result;
}
function requireAuth(req, res, next) {
    const cookies = parseCookies(req);
    const token = cookies['session_id'];
    if (!token) {
        setJson(res);
        return res.status(401).send(JSON.stringify({ error: 'Authentication required' }));
    }
    const userId = sessions.get(token);
    if (!userId) {
        setJson(res);
        return res.status(401).send(JSON.stringify({ error: 'Authentication required' }));
    }
    req.userId = userId;
    req.sessionToken = token;
    next();
}
function validateUsername(username) {
    return typeof username === 'string' && username.length >= 3 && username.length <= 50 && /^[a-zA-Z0-9_]+$/.test(username);
}
function validatePassword(password) {
    return typeof password === 'string' && password.length >= 8;
}
function userPublic(u) {
    return { id: u.id, username: u.username };
}
function todoPublic(t) {
    return {
        id: t.id,
        title: t.title,
        description: t.description,
        completed: t.completed,
        created_at: t.created_at,
        updated_at: t.updated_at,
    };
}
const app = (0, express_1.default)();
app.use(express_1.default.json());
// Ensure JSON content-type for responses by default
app.use((req, res, next) => {
    // We will set for all except DELETE which might purposefully return no body, but we still set header and send no content.
    setJson(res);
    next();
});
// Health/root endpoint for readiness
app.get('/', (req, res) => {
    return res.status(200).send(JSON.stringify({ ok: true }));
});
// Routes
app.post('/register', (req, res) => {
    const { username, password } = req.body || {};
    if (!validateUsername(username)) {
        return res.status(400).send(JSON.stringify({ error: 'Invalid username' }));
    }
    if (!validatePassword(password)) {
        return res.status(400).send(JSON.stringify({ error: 'Password too short' }));
    }
    if (users.some(u => u.username === username)) {
        return res.status(409).send(JSON.stringify({ error: 'Username already exists' }));
    }
    const user = { id: nextUserId++, username, password };
    users.push(user);
    return res.status(201).send(JSON.stringify(userPublic(user)));
});
app.post('/login', (req, res) => {
    const { username, password } = req.body || {};
    const user = users.find(u => u.username === username);
    if (!user || user.password !== password) {
        return res.status(401).send(JSON.stringify({ error: 'Invalid credentials' }));
    }
    const token = (0, uuid_1.v4)().replace(/-/g, ''); // opaque token (hex like)
    sessions.set(token, user.id);
    res.setHeader('Set-Cookie', `session_id=${token}; Path=/; HttpOnly`);
    return res.status(200).send(JSON.stringify(userPublic(user)));
});
app.post('/logout', requireAuth, (req, res) => {
    const token = req.sessionToken;
    sessions.delete(token);
    return res.status(200).send(JSON.stringify({}));
});
app.get('/me', requireAuth, (req, res) => {
    const userId = req.userId;
    const user = users.find(u => u.id === userId);
    return res.status(200).send(JSON.stringify(userPublic(user)));
});
app.put('/password', requireAuth, (req, res) => {
    const userId = req.userId;
    const { old_password, new_password } = req.body || {};
    const user = users.find(u => u.id === userId);
    if (typeof old_password !== 'string' || user.password !== old_password) {
        return res.status(401).send(JSON.stringify({ error: 'Invalid credentials' }));
    }
    if (typeof new_password !== 'string' || new_password.length < 8) {
        return res.status(400).send(JSON.stringify({ error: 'Password too short' }));
    }
    user.password = new_password;
    return res.status(200).send(JSON.stringify({}));
});
app.get('/todos', requireAuth, (req, res) => {
    const userId = req.userId;
    const list = todos
        .filter(t => t.userId === userId)
        .sort((a, b) => a.id - b.id)
        .map(todoPublic);
    return res.status(200).send(JSON.stringify(list));
});
app.post('/todos', requireAuth, (req, res) => {
    const userId = req.userId;
    const { title, description } = req.body || {};
    if (typeof title !== 'string' || title.trim() === '') {
        return res.status(400).send(JSON.stringify({ error: 'Title is required' }));
    }
    const now = isoNowSeconds();
    const todo = {
        id: nextTodoId++,
        userId,
        title,
        description: typeof description === 'string' ? description : '',
        completed: false,
        created_at: now,
        updated_at: now,
    };
    todos.push(todo);
    return res.status(201).send(JSON.stringify(todoPublic(todo)));
});
function getOwnedTodo(todoIdParam, userId) {
    const id = Number(todoIdParam);
    if (!Number.isInteger(id) || id < 1)
        return undefined;
    const t = todos.find(tt => tt.id === id);
    if (!t || t.userId !== userId)
        return undefined;
    return t;
}
app.get('/todos/:id', requireAuth, (req, res) => {
    const userId = req.userId;
    const t = getOwnedTodo(req.params.id, userId);
    if (!t) {
        return res.status(404).send(JSON.stringify({ error: 'Todo not found' }));
    }
    return res.status(200).send(JSON.stringify(todoPublic(t)));
});
app.put('/todos/:id', requireAuth, (req, res) => {
    const userId = req.userId;
    const t = getOwnedTodo(req.params.id, userId);
    if (!t) {
        return res.status(404).send(JSON.stringify({ error: 'Todo not found' }));
    }
    const { title, description, completed } = req.body || {};
    if (title !== undefined) {
        if (typeof title !== 'string' || title.trim() === '') {
            return res.status(400).send(JSON.stringify({ error: 'Title is required' }));
        }
        t.title = title;
    }
    if (description !== undefined) {
        if (typeof description !== 'string') {
            // Keep behavior strict; but we will coerce to string to avoid crash while still allowing update
            t.description = String(description);
        }
        else {
            t.description = description;
        }
    }
    if (completed !== undefined) {
        if (typeof completed !== 'boolean') {
            return res.status(400).send(JSON.stringify({ error: 'Invalid completed flag' }));
        }
        t.completed = completed;
    }
    t.updated_at = isoNowSeconds();
    return res.status(200).send(JSON.stringify(todoPublic(t)));
});
app.delete('/todos/:id', requireAuth, (req, res) => {
    const userId = req.userId;
    const id = Number(req.params.id);
    if (!Number.isInteger(id) || id < 1) {
        return res.status(404).end();
    }
    const idx = todos.findIndex(t => t.id === id && t.userId === userId);
    if (idx === -1) {
        return res.status(404).send(JSON.stringify({ error: 'Todo not found' }));
    }
    todos.splice(idx, 1);
    // DELETE must return 204 and no body, but ensure no JSON body is sent.
    res.status(204);
    res.removeHeader('Content-Type');
    return res.end();
});
function startServer(port) {
    const server = app.listen(port, '0.0.0.0', () => {
        console.log(`Server listening on 0.0.0.0:${port}`);
    });
    return server;
}
if (require.main === module) {
    const args = process.argv.slice(2);
    let port = 3000;
    for (let i = 0; i < args.length; i++) {
        if (args[i] === '--port' && i + 1 < args.length) {
            const p = Number(args[i + 1]);
            if (!Number.isFinite(p) || p <= 0 || p > 65535) {
                console.error('Invalid port');
                process.exit(1);
            }
            port = p;
            i++;
        }
    }
    startServer(port);
}
exports.default = app;
