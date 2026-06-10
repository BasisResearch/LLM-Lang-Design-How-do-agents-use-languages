#!/usr/bin/env node
'use strict';

const http = require('http');
const url = require('url');
const crypto = require('crypto');

// In-memory storage
let nextUserId = 1;
let nextTodoId = 1;
const users = new Map(); // id -> {id, username, password}
const usersByUsername = new Map(); // username -> user
const sessions = new Map(); // token -> userId
const todos = new Map(); // id -> {id, title, description, completed, created_at, updated_at, user_id}

// Helpers
function nowIsoSeconds() {
  const d = new Date();
  return new Date(Math.floor(d.getTime() / 1000) * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');
}

function parseCookies(cookieHeader) {
  const cookies = {};
  if (!cookieHeader) return cookies;
  const parts = cookieHeader.split(';');
  for (const part of parts) {
    const [k, v] = part.split('=');
    if (k && v !== undefined) {
      const key = k.trim();
      const value = v.trim();
      cookies[key] = value;
    }
  }
  return cookies;
}

function readJsonBody(req, res) {
  return new Promise((resolve) => {
    let data = '';
    const max = 1 * 1024 * 1024; // 1MB limit
    req.on('data', (chunk) => {
      data += chunk;
      if (data.length > max) {
        sendJson(res, 413, { error: 'Payload too large' });
        req.destroy();
      }
    });
    req.on('end', () => {
      if (data.length === 0) {
        resolve({});
        return;
      }
      try {
        const obj = JSON.parse(data);
        resolve(obj);
      } catch (e) {
        sendJson(res, 400, { error: 'Invalid JSON' });
      }
    });
  });
}

function sendJson(res, status, obj, headers = {}) {
  const body = JSON.stringify(obj);
  const defaultHeaders = {
    'Content-Type': 'application/json',
    'Content-Length': Buffer.byteLength(body)
  };
  res.writeHead(status, { ...defaultHeaders, ...headers });
  res.end(body);
}

function sendNoContent(res) {
  // For DELETE success: 204 No Content with no body
  res.writeHead(204);
  res.end();
}

function getSessionUser(req) {
  const cookies = parseCookies(req.headers['cookie']);
  const token = cookies['session_id'];
  if (!token) return null;
  const userId = sessions.get(token);
  if (!userId) return null;
  const user = users.get(userId);
  if (!user) return null;
  return { user, token };
}

function requireAuth(req, res) {
  const sess = getSessionUser(req);
  if (!sess) {
    sendJson(res, 401, { error: 'Authentication required' });
    return null;
  }
  return sess;
}

function validateUsername(u) {
  if (typeof u !== 'string') return false;
  if (u.length < 3 || u.length > 50) return false;
  if (!/^[a-zA-Z0-9_]+$/.test(u)) return false;
  return true;
}

function generateToken() {
  if (crypto.randomUUID) return crypto.randomUUID().replace(/-/g, '');
  return crypto.randomBytes(16).toString('hex');
}

function userPublic(user) {
  return { id: user.id, username: user.username };
}

function todoPublic(todo) {
  return {
    id: todo.id,
    title: todo.title,
    description: todo.description,
    completed: todo.completed,
    created_at: todo.created_at,
    updated_at: todo.updated_at
  };
}

function route(req, res) {
  const parsed = url.parse(req.url, true);
  const pathname = parsed.pathname || '/';
  const method = req.method || 'GET';

  // Routing logic
  if (method === 'POST' && pathname === '/register') {
    return handleRegister(req, res);
  }
  if (method === 'POST' && pathname === '/login') {
    return handleLogin(req, res);
  }
  if (method === 'POST' && pathname === '/logout') {
    return handleLogout(req, res);
  }
  if (method === 'GET' && pathname === '/me') {
    return handleMe(req, res);
  }
  if (method === 'PUT' && pathname === '/password') {
    return handlePassword(req, res);
  }
  if (pathname === '/todos' && method === 'GET') {
    return handleTodosList(req, res);
  }
  if (pathname === '/todos' && method === 'POST') {
    return handleTodosCreate(req, res);
  }
  if (pathname.startsWith('/todos/')) {
    const idStr = pathname.slice('/todos/'.length);
    const id = parseInt(idStr, 10);
    if (!Number.isInteger(id) || id <= 0) {
      // For invalid ids, treat as not found to avoid enumeration hints
      if (method === 'DELETE') {
        // error responses still JSON per spec
        return sendJson(res, 404, { error: 'Todo not found' });
      }
      return sendJson(res, 404, { error: 'Todo not found' });
    }
    if (method === 'GET') return handleTodosGet(req, res, id);
    if (method === 'PUT') return handleTodosUpdate(req, res, id);
    if (method === 'DELETE') return handleTodosDelete(req, res, id);
  }

  // Default 404 JSON
  sendJson(res, 404, { error: 'Not found' });
}

// Handlers
async function handleRegister(req, res) {
  const body = await readJsonBody(req, res);
  if (res.writableEnded) return; // In case of JSON parse error already responded
  const { username, password } = body;
  if (!validateUsername(username)) {
    return sendJson(res, 400, { error: 'Invalid username' });
  }
  if (typeof password !== 'string' || password.length < 8) {
    return sendJson(res, 400, { error: 'Password too short' });
  }
  if (usersByUsername.has(username)) {
    return sendJson(res, 409, { error: 'Username already exists' });
  }
  const user = { id: nextUserId++, username, password };
  users.set(user.id, user);
  usersByUsername.set(username, user);
  return sendJson(res, 201, userPublic(user));
}

async function handleLogin(req, res) {
  const body = await readJsonBody(req, res);
  if (res.writableEnded) return;
  const { username, password } = body;
  const user = usersByUsername.get(username);
  if (!user || user.password !== password) {
    return sendJson(res, 401, { error: 'Invalid credentials' });
  }
  const token = generateToken();
  sessions.set(token, user.id);
  const cookie = `session_id=${token}; Path=/; HttpOnly`;
  return sendJson(res, 200, userPublic(user), { 'Set-Cookie': cookie });
}

async function handleLogout(req, res) {
  const sess = requireAuth(req, res);
  if (!sess) return;
  // Invalidate session server-side
  sessions.delete(sess.token);
  return sendJson(res, 200, {});
}

async function handleMe(req, res) {
  const sess = requireAuth(req, res);
  if (!sess) return;
  return sendJson(res, 200, userPublic(sess.user));
}

async function handlePassword(req, res) {
  const sess = requireAuth(req, res);
  if (!sess) return;
  const body = await readJsonBody(req, res);
  if (res.writableEnded) return;
  const { old_password, new_password } = body;
  if (typeof new_password !== 'string' || new_password.length < 8) {
    return sendJson(res, 400, { error: 'Password too short' });
  }
  if (typeof old_password !== 'string' || sess.user.password !== old_password) {
    return sendJson(res, 401, { error: 'Invalid credentials' });
  }
  sess.user.password = new_password;
  return sendJson(res, 200, {});
}

async function handleTodosList(req, res) {
  const sess = requireAuth(req, res);
  if (!sess) return;
  const list = [];
  for (const todo of todos.values()) {
    if (todo.user_id === sess.user.id) {
      list.push(todoPublic(todo));
    }
  }
  list.sort((a, b) => a.id - b.id);
  return sendJson(res, 200, list);
}

async function handleTodosCreate(req, res) {
  const sess = requireAuth(req, res);
  if (!sess) return;
  const body = await readJsonBody(req, res);
  if (res.writableEnded) return;
  let { title, description } = body;
  if (typeof title !== 'string' || title.trim().length === 0) {
    return sendJson(res, 400, { error: 'Title is required' });
  }
  if (description === undefined) description = '';
  if (typeof description !== 'string') description = String(description);
  const now = nowIsoSeconds();
  const todo = {
    id: nextTodoId++,
    title: title,
    description: description,
    completed: false,
    created_at: now,
    updated_at: now,
    user_id: sess.user.id
  };
  todos.set(todo.id, todo);
  return sendJson(res, 201, todoPublic(todo));
}

async function handleTodosGet(req, res, id) {
  const sess = requireAuth(req, res);
  if (!sess) return;
  const todo = todos.get(id);
  if (!todo || todo.user_id !== sess.user.id) {
    return sendJson(res, 404, { error: 'Todo not found' });
  }
  return sendJson(res, 200, todoPublic(todo));
}

async function handleTodosUpdate(req, res, id) {
  const sess = requireAuth(req, res);
  if (!sess) return;
  const todo = todos.get(id);
  if (!todo || todo.user_id !== sess.user.id) {
    return sendJson(res, 404, { error: 'Todo not found' });
  }
  const body = await readJsonBody(req, res);
  if (res.writableEnded) return;
  if ('title' in body) {
    const t = body.title;
    if (typeof t !== 'string' || t.trim().length === 0) {
      return sendJson(res, 400, { error: 'Title is required' });
    }
    todo.title = t;
  }
  if ('description' in body) {
    const d = body.description;
    todo.description = typeof d === 'string' ? d : String(d);
  }
  if ('completed' in body) {
    const c = body.completed;
    if (typeof c !== 'boolean') {
      return sendJson(res, 400, { error: 'Invalid field types' });
    }
    todo.completed = c;
  }
  todo.updated_at = nowIsoSeconds();
  return sendJson(res, 200, todoPublic(todo));
}

async function handleTodosDelete(req, res, id) {
  const sess = requireAuth(req, res);
  if (!sess) return;
  const todo = todos.get(id);
  if (!todo || todo.user_id !== sess.user.id) {
    return sendJson(res, 404, { error: 'Todo not found' });
  }
  todos.delete(id);
  return sendNoContent(res);
}

function parsePortArg(argv) {
  const idx = argv.indexOf('--port');
  if (idx !== -1 && idx + 1 < argv.length) {
    const p = parseInt(argv[idx + 1], 10);
    if (Number.isInteger(p) && p > 0 && p <= 65535) return p;
  }
  return null;
}

function main() {
  const port = parsePortArg(process.argv) || 3000;
  const server = http.createServer((req, res) => {
    route(req, res);
  });
  server.listen(port, '0.0.0.0', () => {
    // eslint-disable-next-line no-console
    console.log(`Server listening on 0.0.0.0:${port}`);
  });
}

if (require.main === module) {
  main();
}
