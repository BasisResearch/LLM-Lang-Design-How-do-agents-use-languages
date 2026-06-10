#!/usr/bin/env node
'use strict';

const http = require('http');
const crypto = require('crypto');
const { URL } = require('url');

// In-memory storage
const db = {
  users: [], // {id, username, password}
  todos: [], // {id, user_id, title, description, completed, created_at, updated_at}
  sessions: new Map(), // token -> user_id
  nextUserId: 1,
  nextTodoId: 1,
};

function isoNowSeconds() {
  const s = new Date().toISOString();
  return s.replace(/\.\d{3}Z$/, 'Z');
}

function parseCookies(header) {
  const result = {};
  if (!header) return result;
  const parts = header.split(';');
  for (const part of parts) {
    const [k, ...vparts] = part.trim().split('=');
    if (!k) continue;
    result[k] = decodeURIComponent((vparts.join('=') || '').trim());
  }
  return result;
}

function sendJson(res, status, obj, extraHeaders={}) {
  const body = JSON.stringify(obj);
  res.statusCode = status;
  res.setHeader('Content-Type', 'application/json');
  for (const [k,v] of Object.entries(extraHeaders)) res.setHeader(k, v);
  res.setHeader('Content-Length', Buffer.byteLength(body));
  res.end(body);
}

function sendError(res, status, message) {
  return sendJson(res, status, { error: message });
}

function notFound(res) {
  return sendError(res, 404, 'Not found');
}

function readJson(req) {
  return new Promise((resolve, reject) => {
    let data = '';
    req.on('data', chunk => {
      data += chunk;
      if (data.length > 1e6) { // 1MB limit
        req.destroy();
        reject(new Error('Payload too large'));
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
    req.on('error', err => reject(err));
  });
}

function validateUsername(username) {
  if (typeof username !== 'string') return false;
  if (username.length < 3 || username.length > 50) return false;
  if (!/^[a-zA-Z0-9_]+$/.test(username)) return false;
  return true;
}

function validatePassword(password) {
  return typeof password === 'string' && password.length >= 8;
}

function authUser(req) {
  const cookies = parseCookies(req.headers['cookie'] || '');
  const token = cookies['session_id'];
  if (!token) return null;
  const userId = db.sessions.get(token);
  if (!userId) return null;
  const user = db.users.find(u => u.id === userId);
  if (!user) return null;
  return { user, token };
}

function generateToken() {
  return crypto.randomBytes(16).toString('hex');
}

function route(req, res) {
  const parsedUrl = new URL(req.url, `http://localhost`);
  const method = req.method.toUpperCase();
  const pathname = parsedUrl.pathname;

  // Preflight/unknown methods -> 405 with JSON
  const allowedMethods = new Set(['GET','POST','PUT','DELETE','OPTIONS']);
  if (!allowedMethods.has(method)) {
    return sendError(res, 405, 'Method not allowed');
  }
  if (method === 'OPTIONS') {
    res.statusCode = 204;
    res.end();
    return;
  }

  // Routing
  if (method === 'POST' && pathname === '/register') return handleRegister(req, res);
  if (method === 'POST' && pathname === '/login') return handleLogin(req, res);
  if (method === 'POST' && pathname === '/logout') return handleLogout(req, res);
  if (method === 'GET' && pathname === '/me') return handleMe(req, res);
  if (method === 'PUT' && pathname === '/password') return handlePassword(req, res);
  if (pathname === '/todos' && method === 'GET') return handleTodosList(req, res);
  if (pathname === '/todos' && method === 'POST') return handleTodosCreate(req, res);

  // /todos/:id
  const todoMatch = pathname.match(/^\/todos\/(\d+)$/);
  if (todoMatch) {
    const id = parseInt(todoMatch[1], 10);
    if (Number.isNaN(id)) return notFound(res);
    if (method === 'GET') return handleTodosGet(req, res, id);
    if (method === 'PUT') return handleTodosUpdate(req, res, id);
    if (method === 'DELETE') return handleTodosDelete(req, res, id);
  }

  return notFound(res);
}

async function handleRegister(req, res) {
  try {
    const body = await readJson(req);
    const { username, password } = body || {};
    if (!validateUsername(username)) {
      return sendError(res, 400, 'Invalid username');
    }
    if (!validatePassword(password)) {
      return sendError(res, 400, 'Password too short');
    }
    const exists = db.users.find(u => u.username.toLowerCase() === String(username).toLowerCase());
    if (exists) {
      return sendError(res, 409, 'Username already exists');
    }
    const user = { id: db.nextUserId++, username: String(username), password: String(password) };
    db.users.push(user);
    return sendJson(res, 201, { id: user.id, username: user.username });
  } catch (e) {
    if (e && e.message === 'Invalid JSON') return sendError(res, 400, 'Invalid JSON');
    if (e && e.message === 'Payload too large') return sendError(res, 413, 'Payload too large');
    return sendError(res, 500, 'Internal server error');
  }
}

async function handleLogin(req, res) {
  try {
    const body = await readJson(req);
    const { username, password } = body || {};
    const user = db.users.find(u => u.username === username);
    if (!user || user.password !== password) {
      return sendError(res, 401, 'Invalid credentials');
    }
    // create session
    const token = generateToken();
    db.sessions.set(token, user.id);
    const headers = { 'Set-Cookie': `session_id=${token}; Path=/; HttpOnly` };
    return sendJson(res, 200, { id: user.id, username: user.username }, headers);
  } catch (e) {
    if (e && e.message === 'Invalid JSON') return sendError(res, 400, 'Invalid JSON');
    if (e && e.message === 'Payload too large') return sendError(res, 413, 'Payload too large');
    return sendError(res, 500, 'Internal server error');
  }
}

async function handleLogout(req, res) {
  const auth = authUser(req);
  if (!auth) return sendError(res, 401, 'Authentication required');
  // Invalidate session
  if (auth.token) db.sessions.delete(auth.token);
  return sendJson(res, 200, {});
}

async function handleMe(req, res) {
  const auth = authUser(req);
  if (!auth) return sendError(res, 401, 'Authentication required');
  const { user } = auth;
  return sendJson(res, 200, { id: user.id, username: user.username });
}

async function handlePassword(req, res) {
  const auth = authUser(req);
  if (!auth) return sendError(res, 401, 'Authentication required');
  try {
    const body = await readJson(req);
    const { old_password, new_password } = body || {};
    if (auth.user.password !== old_password) {
      return sendError(res, 401, 'Invalid credentials');
    }
    if (!validatePassword(new_password)) {
      return sendError(res, 400, 'Password too short');
    }
    auth.user.password = String(new_password);
    return sendJson(res, 200, {});
  } catch (e) {
    if (e && e.message === 'Invalid JSON') return sendError(res, 400, 'Invalid JSON');
    if (e && e.message === 'Payload too large') return sendError(res, 413, 'Payload too large');
    return sendError(res, 500, 'Internal server error');
  }
}

async function handleTodosList(req, res) {
  const auth = authUser(req);
  if (!auth) return sendError(res, 401, 'Authentication required');
  const items = db.todos
    .filter(t => t.user_id === auth.user.id)
    .sort((a,b) => a.id - b.id)
    .map(stripTodoOwner);
  return sendJson(res, 200, items);
}

function stripTodoOwner(todo) {
  const { user_id, ...rest } = todo;
  return rest;
}

async function handleTodosCreate(req, res) {
  const auth = authUser(req);
  if (!auth) return sendError(res, 401, 'Authentication required');
  try {
    const body = await readJson(req);
    const title = body && typeof body.title === 'string' ? body.title : undefined;
    if (!title || title.trim() === '') {
      return sendError(res, 400, 'Title is required');
    }
    const description = body && typeof body.description === 'string' ? body.description : '';
    const now = isoNowSeconds();
    const todo = {
      id: db.nextTodoId++,
      user_id: auth.user.id,
      title: title,
      description: description,
      completed: false,
      created_at: now,
      updated_at: now,
    };
    db.todos.push(todo);
    return sendJson(res, 201, stripTodoOwner(todo));
  } catch (e) {
    if (e && e.message === 'Invalid JSON') return sendError(res, 400, 'Invalid JSON');
    if (e && e.message === 'Payload too large') return sendError(res, 413, 'Payload too large');
    return sendError(res, 500, 'Internal server error');
  }
}

async function handleTodosGet(req, res, id) {
  const auth = authUser(req);
  if (!auth) return sendError(res, 401, 'Authentication required');
  const todo = db.todos.find(t => t.id === id && t.user_id === auth.user.id);
  if (!todo) return sendError(res, 404, 'Todo not found');
  return sendJson(res, 200, stripTodoOwner(todo));
}

async function handleTodosUpdate(req, res, id) {
  const auth = authUser(req);
  if (!auth) return sendError(res, 401, 'Authentication required');
  const todo = db.todos.find(t => t.id === id && t.user_id === auth.user.id);
  if (!todo) return sendError(res, 404, 'Todo not found');
  try {
    const body = await readJson(req);
    if (Object.prototype.hasOwnProperty.call(body || {}, 'title')) {
      const title = body.title;
      if (typeof title !== 'string' || title.trim() === '') {
        return sendError(res, 400, 'Title is required');
      }
      todo.title = title;
    }
    if (Object.prototype.hasOwnProperty.call(body || {}, 'description')) {
      const description = body.description;
      if (typeof description === 'string') todo.description = description;
      else if (description === undefined) { /* ignore */ }
      else todo.description = String(description);
    }
    if (Object.prototype.hasOwnProperty.call(body || {}, 'completed')) {
      todo.completed = Boolean(body.completed);
    }
    todo.updated_at = isoNowSeconds();
    return sendJson(res, 200, stripTodoOwner(todo));
  } catch (e) {
    if (e && e.message === 'Invalid JSON') return sendError(res, 400, 'Invalid JSON');
    if (e && e.message === 'Payload too large') return sendError(res, 413, 'Payload too large');
    return sendError(res, 500, 'Internal server error');
  }
}

async function handleTodosDelete(req, res, id) {
  const auth = authUser(req);
  if (!auth) {
    // For DELETE with no body, we still return JSON for errors per spec.
    return sendError(res, 401, 'Authentication required');
  }
  const idx = db.todos.findIndex(t => t.id === id && t.user_id === auth.user.id);
  if (idx === -1) return sendError(res, 404, 'Todo not found');
  db.todos.splice(idx, 1);
  res.statusCode = 204;
  // No body, and per spec, don't need Content-Type for DELETE success
  res.end();
}

function startServer(port) {
  const server = http.createServer((req, res) => {
    // Ensure default headers for JSON are applied by handlers.
    // Also, ensure we don't crash on unexpected errors.
    try {
      route(req, res);
    } catch (e) {
      try {
        sendError(res, 500, 'Internal server error');
      } catch (_) {
        // ignore
      }
    }
  });
  server.listen({ host: '0.0.0.0', port }, () => {
    console.log(`Server listening on 0.0.0.0:${port}`);
  });
  return server;
}

function parseArgs(argv) {
  const args = { port: 3000 };
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--port') {
      const p = argv[i+1];
      i++;
      args.port = p ? Number(p) : NaN;
    }
  }
  if (!args.port || Number.isNaN(args.port)) {
    console.error('Invalid or missing --port');
    process.exit(1);
  }
  return args;
}

if (require.main === module) {
  const { port } = parseArgs(process.argv);
  startServer(port);
}

module.exports = { startServer, db, isoNowSeconds };
