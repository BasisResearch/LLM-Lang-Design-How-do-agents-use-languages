#!/usr/bin/env node
'use strict';

const http = require('http');
const url = require('url');
const crypto = require('crypto');

// In-memory storage
let users = []; // {id, username, password}
let nextUserId = 1;

let sessions = new Map(); // token -> userId

let todos = []; // {id, user_id, title, description, completed, created_at, updated_at}
let nextTodoId = 1;

function iso8601Seconds(date = new Date()) {
  // Ensure UTC, second precision
  const d = new Date(date.getTime());
  const y = d.getUTCFullYear();
  const m = String(d.getUTCMonth() + 1).padStart(2, '0');
  const day = String(d.getUTCDate()).padStart(2, '0');
  const hh = String(d.getUTCHours()).padStart(2, '0');
  const mm = String(d.getUTCMinutes()).padStart(2, '0');
  const ss = String(d.getUTCSeconds()).padStart(2, '0');
  return `${y}-${m}-${day}T${hh}:${mm}:${ss}Z`;
}

function parseCookies(cookieHeader) {
  const cookies = {};
  if (!cookieHeader) return cookies;
  const parts = cookieHeader.split(';');
  for (const part of parts) {
    const idx = part.indexOf('=');
    if (idx === -1) continue;
    const key = part.slice(0, idx).trim();
    const val = part.slice(idx + 1).trim();
    cookies[key] = decodeURIComponent(val);
  }
  return cookies;
}

function setJsonHeader(res) {
  res.setHeader('Content-Type', 'application/json');
}

function sendJson(res, statusCode, obj) {
  if (statusCode !== 204) setJsonHeader(res);
  res.statusCode = statusCode;
  if (statusCode === 204) {
    res.end();
  } else {
    res.end(JSON.stringify(obj));
  }
}

function notFound(res) {
  sendJson(res, 404, { error: 'Not found' });
}

function readJsonBody(req) {
  return new Promise((resolve, reject) => {
    let data = '';
    req.on('data', chunk => {
      data += chunk;
      if (data.length > 1e6) { // 1MB limit
        reject({ code: 413, message: 'Payload too large' });
        req.destroy();
      }
    });
    req.on('end', () => {
      if (!data) return resolve({});
      try {
        const obj = JSON.parse(data);
        resolve(obj);
      } catch (e) {
        reject({ code: 400, message: 'Invalid JSON' });
      }
    });
    req.on('error', (err) => reject({ code: 400, message: 'Invalid request' }));
  });
}

function validateUsername(u) {
  if (typeof u !== 'string') return false;
  if (u.length < 3 || u.length > 50) return false;
  if (!/^[a-zA-Z0-9_]+$/.test(u)) return false;
  return true;
}

function generateToken() {
  return crypto.randomBytes(16).toString('hex');
}

function getAuthUser(req) {
  const cookies = parseCookies(req.headers['cookie']);
  const token = cookies['session_id'];
  if (!token) return null;
  const userId = sessions.get(token);
  if (!userId) return null;
  const user = users.find(u => u.id === userId);
  if (!user) return null;
  return { user, token };
}

function route(req, res) {
  const parsedUrl = url.parse(req.url, true);
  const method = req.method;
  const pathname = parsedUrl.pathname || '/';

  // Routing
  if (method === 'POST' && pathname === '/register') return handleRegister(req, res);
  if (method === 'POST' && pathname === '/login') return handleLogin(req, res);
  if (method === 'POST' && pathname === '/logout') return requireAuth(req, res, handleLogout);
  if (method === 'GET' && pathname === '/me') return requireAuth(req, res, handleMe);
  if (method === 'PUT' && pathname === '/password') return requireAuth(req, res, handlePassword);

  if (pathname === '/todos' && method === 'GET') return requireAuth(req, res, handleListTodos);
  if (pathname === '/todos' && method === 'POST') return requireAuth(req, res, handleCreateTodo);

  // /todos/:id
  const todoIdMatch = pathname.match(/^\/todos\/(\d+)$/);
  if (todoIdMatch) {
    const id = parseInt(todoIdMatch[1], 10);
    if (method === 'GET') return requireAuth(req, res, (req, res, auth) => handleGetTodo(req, res, auth, id));
    if (method === 'PUT') return requireAuth(req, res, (req, res, auth) => handleUpdateTodo(req, res, auth, id));
    if (method === 'DELETE') return requireAuth(req, res, (req, res, auth) => handleDeleteTodo(req, res, auth, id));
  }

  notFound(res);
}

function requireAuth(req, res, handler) {
  const auth = getAuthUser(req);
  if (!auth) {
    sendJson(res, 401, { error: 'Authentication required' });
    return;
  }
  handler(req, res, auth);
}

// Handlers
async function handleRegister(req, res) {
  try {
    const body = await readJsonBody(req);
    const { username, password } = body;
    if (!validateUsername(username)) {
      return sendJson(res, 400, { error: 'Invalid username' });
    }
    if (typeof password !== 'string' || password.length < 8) {
      return sendJson(res, 400, { error: 'Password too short' });
    }
    const exists = users.some(u => u.username.toLowerCase() === String(username).toLowerCase());
    if (exists) {
      return sendJson(res, 409, { error: 'Username already exists' });
    }
    const newUser = { id: nextUserId++, username: String(username), password: String(password) };
    users.push(newUser);
    return sendJson(res, 201, { id: newUser.id, username: newUser.username });
  } catch (e) {
    if (e && e.code) return sendJson(res, e.code, { error: e.message });
    return sendJson(res, 400, { error: 'Invalid request' });
  }
}

async function handleLogin(req, res) {
  try {
    const body = await readJsonBody(req);
    const { username, password } = body || {};
    const user = users.find(u => u.username === username);
    if (!user || user.password !== password) {
      return sendJson(res, 401, { error: 'Invalid credentials' });
    }
    const token = generateToken();
    sessions.set(token, user.id);
    // Set-Cookie header
    res.setHeader('Set-Cookie', `session_id=${encodeURIComponent(token)}; Path=/; HttpOnly`);
    return sendJson(res, 200, { id: user.id, username: user.username });
  } catch (e) {
    if (e && e.code) return sendJson(res, e.code, { error: e.message });
    return sendJson(res, 400, { error: 'Invalid request' });
  }
}

function handleLogout(req, res, auth) {
  const { token } = auth;
  if (token) {
    sessions.delete(token);
  }
  return sendJson(res, 200, {});
}

function handleMe(req, res, auth) {
  const { user } = auth;
  return sendJson(res, 200, { id: user.id, username: user.username });
}

async function handlePassword(req, res, auth) {
  try {
    const body = await readJsonBody(req);
    const { old_password, new_password } = body || {};
    const { user } = auth;
    if (user.password !== old_password) {
      return sendJson(res, 401, { error: 'Invalid credentials' });
    }
    if (typeof new_password !== 'string' || new_password.length < 8) {
      return sendJson(res, 400, { error: 'Password too short' });
    }
    user.password = new_password;
    return sendJson(res, 200, {});
  } catch (e) {
    if (e && e.code) return sendJson(res, e.code, { error: e.message });
    return sendJson(res, 400, { error: 'Invalid request' });
  }
}

function handleListTodos(req, res, auth) {
  const { user } = auth;
  const list = todos.filter(t => t.user_id === user.id).sort((a, b) => a.id - b.id).map(stripTodoOwner);
  return sendJson(res, 200, list);
}

async function handleCreateTodo(req, res, auth) {
  try {
    const body = await readJsonBody(req);
    const title = body && body.title;
    let description = '';
    if (body && typeof body.description === 'string') description = body.description;

    if (typeof title !== 'string' || title.trim() === '') {
      return sendJson(res, 400, { error: 'Title is required' });
    }
    const now = iso8601Seconds(new Date());
    const todo = {
      id: nextTodoId++,
      user_id: auth.user.id,
      title: String(title),
      description: String(description || ''),
      completed: false,
      created_at: now,
      updated_at: now,
    };
    todos.push(todo);
    return sendJson(res, 201, stripTodoOwner(todo));
  } catch (e) {
    if (e && e.code) return sendJson(res, e.code, { error: e.message });
    return sendJson(res, 400, { error: 'Invalid request' });
  }
}

function findOwnTodoOr404(id, userId) {
  const todo = todos.find(t => t.id === id);
  if (!todo) return null;
  if (todo.user_id !== userId) return null;
  return todo;
}

function stripTodoOwner(todo) {
  const { user_id, ...rest } = todo;
  return rest;
}

function handleGetTodo(req, res, auth, id) {
  const todo = findOwnTodoOr404(id, auth.user.id);
  if (!todo) return sendJson(res, 404, { error: 'Todo not found' });
  return sendJson(res, 200, stripTodoOwner(todo));
}

async function handleUpdateTodo(req, res, auth, id) {
  try {
    const todo = findOwnTodoOr404(id, auth.user.id);
    if (!todo) return sendJson(res, 404, { error: 'Todo not found' });
    const body = await readJsonBody(req);
    if (Object.prototype.hasOwnProperty.call(body, 'title')) {
      const t = body.title;
      if (typeof t !== 'string' || t.trim() === '') {
        return sendJson(res, 400, { error: 'Title is required' });
      }
      todo.title = t;
    }
    if (Object.prototype.hasOwnProperty.call(body, 'description')) {
      const d = body.description;
      if (typeof d === 'string') todo.description = d;
      else todo.description = String(d);
    }
    if (Object.prototype.hasOwnProperty.call(body, 'completed')) {
      const c = body.completed;
      if (typeof c !== 'boolean') {
        return sendJson(res, 400, { error: 'Invalid completed value' });
      }
      todo.completed = c;
    }
    todo.updated_at = iso8601Seconds(new Date());
    return sendJson(res, 200, stripTodoOwner(todo));
  } catch (e) {
    if (e && e.code) return sendJson(res, e.code, { error: e.message });
    return sendJson(res, 400, { error: 'Invalid request' });
  }
}

function handleDeleteTodo(req, res, auth, id) {
  const idx = todos.findIndex(t => t.id === id && t.user_id === auth.user.id);
  if (idx === -1) return sendJson(res, 404, { error: 'Todo not found' });
  todos.splice(idx, 1);
  // 204 No Content, no body and no Content-Type
  res.statusCode = 204;
  res.end();
}

function startServer(port) {
  const server = http.createServer((req, res) => {
    // Enforce JSON responses for all but 204 handled specifically
    try {
      route(req, res);
    } catch (err) {
      try {
        sendJson(res, 500, { error: 'Internal server error' });
      } catch (_) {}
    }
  });
  server.listen(port, '0.0.0.0', () => {
    console.log(`Server listening on 0.0.0.0:${port}`);
  });
}

function parseArgsAndStart() {
  const args = process.argv.slice(2);
  let port = 3000;
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--port') {
      const p = parseInt(args[i + 1], 10);
      if (!isNaN(p)) port = p;
    }
  }
  startServer(port);
}

if (require.main === module) {
  parseArgsAndStart();
}
