#!/usr/bin/env node

// Todo App REST API Server
// Implements cookie-based authentication and in-memory storage
// All responses JSON except DELETE 204 no body.

const http = require('http');
const { URL } = require('url');
const crypto = require('crypto');

// In-memory storage
let users = new Map(); // id -> {id, username, passwordHash}
let usernameToId = new Map();
let userIdCounter = 1;

let sessions = new Map(); // token -> userId

let todos = new Map(); // id -> {id, user_id, title, description, completed, created_at, updated_at}
let todoIdCounter = 1;

// Utilities
function jsonHeader() {
  return { 'Content-Type': 'application/json' };
}

function sendJSON(res, statusCode, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(statusCode, jsonHeader());
  res.end(body);
}

function sendNoContent(res) {
  res.statusCode = 204;
  // No Content: do not send any body and do not set content-type
  res.end();
}

function parseBody(req) {
  return new Promise((resolve, reject) => {
    let data = '';
    const maxBytes = 1 * 1024 * 1024; // 1MB
    req.on('data', chunk => {
      data += chunk;
      if (data.length > maxBytes) {
        reject(new Error('Payload too large'));
        req.destroy();
      }
    });
    req.on('end', () => {
      if (!data) return resolve({});
      try {
        const obj = JSON.parse(data);
        resolve(obj);
      } catch (e) {
        reject(new Error('Invalid JSON'));
      }
    });
    req.on('error', (err) => reject(err));
  });
}

function parseCookies(req) {
  const header = req.headers['cookie'];
  const cookies = {};
  if (!header) return cookies;
  const parts = header.split(';');
  for (const p of parts) {
    const idx = p.indexOf('=');
    if (idx === -1) continue;
    const name = p.slice(0, idx).trim();
    const val = p.slice(idx + 1).trim();
    cookies[name] = decodeURIComponent(val);
  }
  return cookies;
}

function generateToken() {
  return crypto.randomBytes(16).toString('hex');
}

function hashPassword(pw) {
  // Simple hash for demo purposes (NOT for production security!)
  return crypto.createHash('sha256').update(pw, 'utf8').digest('hex');
}

function nowIsoSeconds() {
  const d = new Date();
  // Drop milliseconds
  const iso = d.toISOString();
  return iso.replace(/\.\d{3}Z$/, 'Z');
}

function getAuthUser(req, res) {
  const cookies = parseCookies(req);
  const token = cookies['session_id'];
  if (!token) {
    sendJSON(res, 401, { error: 'Authentication required' });
    return null;
  }
  const userId = sessions.get(token);
  if (!userId) {
    sendJSON(res, 401, { error: 'Authentication required' });
    return null;
  }
  const user = users.get(userId);
  if (!user) {
    // Should not happen, but treat as unauth
    sendJSON(res, 401, { error: 'Authentication required' });
    return null;
  }
  return { user, token };
}

function publicUser(u) {
  return { id: u.id, username: u.username };
}

function readIdParam(pathname, prefix) {
  // Expect paths like `${prefix}/:id` and nothing extra
  if (!pathname.startsWith(prefix + '/')) return null;
  const rest = pathname.slice(prefix.length + 1);
  if (rest.includes('/')) return null; // no extra segments
  const idNum = parseInt(rest, 10);
  if (!Number.isFinite(idNum) || idNum <= 0) return null;
  return idNum;
}

function setSessionCookie(res, token) {
  const cookie = `session_id=${token}; Path=/; HttpOnly`;
  res.setHeader('Set-Cookie', cookie);
}

function clearSessionCookie(res) {
  const cookie = `session_id=; Path=/; HttpOnly; Max-Age=0`;
  res.setHeader('Set-Cookie', cookie);
}

// Route handlers
async function handleRegister(req, res) {
  let body;
  try { body = await parseBody(req); } catch (e) {
    return sendJSON(res, 400, { error: e.message });
  }
  const username = typeof body.username === 'string' ? body.username : '';
  const password = typeof body.password === 'string' ? body.password : '';
  const usernameRegex = /^[a-zA-Z0-9_]{3,50}$/;
  if (!usernameRegex.test(username)) {
    return sendJSON(res, 400, { error: 'Invalid username' });
  }
  if (password.length < 8) {
    return sendJSON(res, 400, { error: 'Password too short' });
  }
  if (usernameToId.has(username)) {
    return sendJSON(res, 409, { error: 'Username already exists' });
  }
  const id = userIdCounter++;
  const user = { id, username, passwordHash: hashPassword(password) };
  users.set(id, user);
  usernameToId.set(username, id);
  return sendJSON(res, 201, publicUser(user));
}

async function handleLogin(req, res) {
  let body;
  try { body = await parseBody(req); } catch (e) {
    return sendJSON(res, 400, { error: e.message });
  }
  const username = typeof body.username === 'string' ? body.username : '';
  const password = typeof body.password === 'string' ? body.password : '';
  const id = usernameToId.get(username);
  if (!id) {
    return sendJSON(res, 401, { error: 'Invalid credentials' });
  }
  const user = users.get(id);
  if (!user || user.passwordHash !== hashPassword(password)) {
    return sendJSON(res, 401, { error: 'Invalid credentials' });
  }
  const token = generateToken();
  sessions.set(token, user.id);
  setSessionCookie(res, token);
  return sendJSON(res, 200, publicUser(user));
}

async function handleLogout(req, res) {
  const auth = getAuthUser(req, res);
  if (!auth) return; // response already sent
  // Invalidate the token
  sessions.delete(auth.token);
  clearSessionCookie(res);
  return sendJSON(res, 200, {});
}

async function handleMe(req, res) {
  const auth = getAuthUser(req, res);
  if (!auth) return;
  return sendJSON(res, 200, publicUser(auth.user));
}

async function handlePassword(req, res) {
  const auth = getAuthUser(req, res);
  if (!auth) return;
  let body;
  try { body = await parseBody(req); } catch (e) {
    return sendJSON(res, 400, { error: e.message });
  }
  const oldp = typeof body.old_password === 'string' ? body.old_password : '';
  const newp = typeof body.new_password === 'string' ? body.new_password : '';
  if (auth.user.passwordHash !== hashPassword(oldp)) {
    return sendJSON(res, 401, { error: 'Invalid credentials' });
  }
  if (newp.length < 8) {
    return sendJSON(res, 400, { error: 'Password too short' });
  }
  auth.user.passwordHash = hashPassword(newp);
  users.set(auth.user.id, auth.user);
  return sendJSON(res, 200, {});
}

async function handleTodosList(req, res) {
  const auth = getAuthUser(req, res);
  if (!auth) return;
  const list = Array.from(todos.values())
    .filter(t => t.user_id === auth.user.id)
    .sort((a, b) => a.id - b.id)
    .map(t => ({ id: t.id, title: t.title, description: t.description, completed: t.completed, created_at: t.created_at, updated_at: t.updated_at }));
  return sendJSON(res, 200, list);
}

async function handleTodosCreate(req, res) {
  const auth = getAuthUser(req, res);
  if (!auth) return;
  let body;
  try { body = await parseBody(req); } catch (e) {
    return sendJSON(res, 400, { error: e.message });
  }
  const title = typeof body.title === 'string' ? body.title.trim() : '';
  if (!title) {
    return sendJSON(res, 400, { error: 'Title is required' });
  }
  const description = typeof body.description === 'string' ? body.description : '';
  const now = nowIsoSeconds();
  const t = {
    id: todoIdCounter++,
    user_id: auth.user.id,
    title,
    description,
    completed: false,
    created_at: now,
    updated_at: now,
  };
  todos.set(t.id, t);
  const resp = { id: t.id, title: t.title, description: t.description, completed: t.completed, created_at: t.created_at, updated_at: t.updated_at };
  return sendJSON(res, 201, resp);
}

function getTodoForUser(id, userId) {
  const t = todos.get(id);
  if (!t) return null;
  if (t.user_id !== userId) return null; // hide existence
  return t;
}

async function handleTodoGet(req, res, id) {
  const auth = getAuthUser(req, res);
  if (!auth) return;
  const t = getTodoForUser(id, auth.user.id);
  if (!t) {
    return sendJSON(res, 404, { error: 'Todo not found' });
  }
  const resp = { id: t.id, title: t.title, description: t.description, completed: t.completed, created_at: t.created_at, updated_at: t.updated_at };
  return sendJSON(res, 200, resp);
}

async function handleTodoUpdate(req, res, id) {
  const auth = getAuthUser(req, res);
  if (!auth) return;
  const t = getTodoForUser(id, auth.user.id);
  if (!t) {
    return sendJSON(res, 404, { error: 'Todo not found' });
  }
  let body;
  try { body = await parseBody(req); } catch (e) {
    return sendJSON(res, 400, { error: e.message });
  }
  if (Object.prototype.hasOwnProperty.call(body, 'title')) {
    if (typeof body.title !== 'string' || body.title.trim() === '') {
      return sendJSON(res, 400, { error: 'Title is required' });
    }
    t.title = body.title.trim();
  }
  if (Object.prototype.hasOwnProperty.call(body, 'description')) {
    if (typeof body.description === 'string') {
      t.description = body.description;
    } else {
      // Ignore invalid types for description to avoid accidental type issues
      t.description = String(body.description);
    }
  }
  if (Object.prototype.hasOwnProperty.call(body, 'completed')) {
    t.completed = Boolean(body.completed);
  }
  t.updated_at = nowIsoSeconds();
  const resp = { id: t.id, title: t.title, description: t.description, completed: t.completed, created_at: t.created_at, updated_at: t.updated_at };
  return sendJSON(res, 200, resp);
}

async function handleTodoDelete(req, res, id) {
  const auth = getAuthUser(req, res);
  if (!auth) return;
  const t = getTodoForUser(id, auth.user.id);
  if (!t) {
    return sendJSON(res, 404, { error: 'Todo not found' });
  }
  todos.delete(id);
  return sendNoContent(res);
}

function notFound(res) {
  sendJSON(res, 404, { error: 'Not found' });
}

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, `http://${req.headers.host}`);
    const pathname = url.pathname;
    // Routing
    if (req.method === 'POST' && pathname === '/register') return handleRegister(req, res);
    if (req.method === 'POST' && pathname === '/login') return handleLogin(req, res);
    if (req.method === 'POST' && pathname === '/logout') return handleLogout(req, res);
    if (req.method === 'GET' && pathname === '/me') return handleMe(req, res);
    if (req.method === 'PUT' && pathname === '/password') return handlePassword(req, res);

    if (pathname === '/todos') {
      if (req.method === 'GET') return handleTodosList(req, res);
      if (req.method === 'POST') return handleTodosCreate(req, res);
    }

    const todoId = readIdParam(pathname, '/todos');
    if (todoId) {
      if (req.method === 'GET') return handleTodoGet(req, res, todoId);
      if (req.method === 'PUT') return handleTodoUpdate(req, res, todoId);
      if (req.method === 'DELETE') return handleTodoDelete(req, res, todoId);
    }

    // Default 404
    notFound(res);
  } catch (err) {
    // Internal server error
    try {
      sendJSON(res, 500, { error: 'Internal server error' });
    } catch (_) {
      // ignore
    }
    // For debugging, log error
    console.error('Unhandled error:', err);
  }
});

// CLI: --port PORT
function parsePortArg(argv) {
  const idx = argv.indexOf('--port');
  if (idx !== -1 && argv.length > idx + 1) {
    const p = parseInt(argv[idx + 1], 10);
    if (Number.isFinite(p) && p > 0 && p < 65536) return p;
  }
  return 3000;
}

const port = parsePortArg(process.argv);
server.listen(port, '0.0.0.0', () => {
  console.log(`Server listening on 0.0.0.0:${port}`);
});
