#!/usr/bin/env node
"use strict";

const http = require('http');
const url = require('url');
const crypto = require('crypto');

// In-memory storage
let users = []; // {id, username, password}
let nextUserId = 1;

let sessions = new Map(); // token -> userId

let todos = []; // {id, userId, title, description, completed, created_at, updated_at}
let nextTodoId = 1;

function isoNowSeconds() {
  const d = new Date();
  d.setMilliseconds(0);
  return d.toISOString();
}

function parseCookies(cookieHeader) {
  const out = {};
  if (!cookieHeader) return out;
  const parts = cookieHeader.split(';');
  for (const part of parts) {
    const idx = part.indexOf('=');
    if (idx === -1) continue;
    const k = part.slice(0, idx).trim();
    const v = part.slice(idx + 1).trim();
    out[k] = decodeURIComponent(v);
  }
  return out;
}

function generateToken() {
  if (typeof crypto.randomUUID === 'function') {
    return crypto.randomUUID().replace(/-/g, '');
  }
  return crypto.randomBytes(16).toString('hex');
}

function sendJSON(res, statusCode, obj, headers = {}) {
  const body = JSON.stringify(obj);
  res.statusCode = statusCode;
  res.setHeader('Content-Type', 'application/json');
  for (const [k, v] of Object.entries(headers)) {
    res.setHeader(k, v);
  }
  res.end(body);
}

function sendNoContent(res) {
  res.statusCode = 204;
  // No body, do not set Content-Type
  res.end();
}

function notFound(res) {
  sendJSON(res, 404, { error: 'Not found' });
}

function readRequestBody(req) {
  return new Promise((resolve, reject) => {
    let data = '';
    req.on('data', chunk => {
      data += String(chunk);
      // Prevent too large bodies (1MB)
      if (data.length > 1_000_000) {
        reject(new Error('Payload too large'));
        req.destroy();
      }
    });
    req.on('end', () => resolve(data));
    req.on('error', reject);
  });
}

async function parseJSONBody(req, res) {
  try {
    const text = await readRequestBody(req);
    if (!text) return {};
    const obj = JSON.parse(text);
    if (obj === null || typeof obj !== 'object' || Array.isArray(obj)) {
      sendJSON(res, 400, { error: 'Invalid JSON' });
      return null;
    }
    return obj;
  } catch (e) {
    if (e && e.message === 'Payload too large') {
      sendJSON(res, 413, { error: 'Payload too large' });
    } else {
      sendJSON(res, 400, { error: 'Invalid JSON' });
    }
    return null;
  }
}

function getAuthenticatedUser(req, res) {
  const cookies = parseCookies(req.headers['cookie'] || '');
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
  const user = users.find(u => u.id === userId);
  if (!user) {
    // Session refers to unknown user; invalidate
    sessions.delete(token);
    sendJSON(res, 401, { error: 'Authentication required' });
    return null;
  }
  // Attach token for logout invalidation convenience
  return { user, token };
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

function publicUser(u) {
  return { id: u.id, username: u.username };
}

const server = http.createServer(async (req, res) => {
  try {
    const parsed = url.parse(req.url, true);
    const pathname = parsed.pathname || '/';
    const method = req.method || 'GET';

    if (method === 'POST' && pathname === '/register') {
      const body = await parseJSONBody(req, res);
      if (body == null) return; // error sent
      const { username, password } = body;
      if (!validateUsername(username)) {
        return sendJSON(res, 400, { error: 'Invalid username' });
      }
      if (!validatePassword(password)) {
        return sendJSON(res, 400, { error: 'Password too short' });
      }
      if (users.some(u => u.username === username)) {
        return sendJSON(res, 409, { error: 'Username already exists' });
      }
      const user = { id: nextUserId++, username, password };
      users.push(user);
      return sendJSON(res, 201, publicUser(user));
    }

    if (method === 'POST' && pathname === '/login') {
      const body = await parseJSONBody(req, res);
      if (body == null) return;
      const { username, password } = body || {};
      const user = users.find(u => u.username === username && u.password === password);
      if (!user) {
        return sendJSON(res, 401, { error: 'Invalid credentials' });
      }
      const token = generateToken();
      sessions.set(token, user.id);
      const cookie = `session_id=${encodeURIComponent(token)}; Path=/; HttpOnly`;
      return sendJSON(res, 200, publicUser(user), { 'Set-Cookie': cookie });
    }

    if (method === 'POST' && pathname === '/logout') {
      const auth = getAuthenticatedUser(req, res);
      if (!auth) return;
      const { token } = auth;
      sessions.delete(token);
      return sendJSON(res, 200, {});
    }

    if (method === 'GET' && pathname === '/me') {
      const auth = getAuthenticatedUser(req, res);
      if (!auth) return;
      return sendJSON(res, 200, publicUser(auth.user));
    }

    if (method === 'PUT' && pathname === '/password') {
      const auth = getAuthenticatedUser(req, res);
      if (!auth) return;
      const body = await parseJSONBody(req, res);
      if (body == null) return;
      const { old_password, new_password } = body;
      if (auth.user.password !== old_password) {
        return sendJSON(res, 401, { error: 'Invalid credentials' });
      }
      if (!validatePassword(new_password)) {
        return sendJSON(res, 400, { error: 'Password too short' });
      }
      auth.user.password = new_password;
      return sendJSON(res, 200, {});
    }

    if (method === 'GET' && pathname === '/todos') {
      const auth = getAuthenticatedUser(req, res);
      if (!auth) return;
      const list = todos
        .filter(t => t.userId === auth.user.id)
        .sort((a, b) => a.id - b.id)
        .map(t => ({ id: t.id, title: t.title, description: t.description, completed: t.completed, created_at: t.created_at, updated_at: t.updated_at }));
      return sendJSON(res, 200, list);
    }

    if (method === 'POST' && pathname === '/todos') {
      const auth = getAuthenticatedUser(req, res);
      if (!auth) return;
      const body = await parseJSONBody(req, res);
      if (body == null) return;
      let { title, description } = body;
      if (typeof title !== 'string' || title.trim() === '') {
        return sendJSON(res, 400, { error: 'Title is required' });
      }
      title = title.trim();
      if (typeof description !== 'string') description = '';
      const now = isoNowSeconds();
      const todo = { id: nextTodoId++, userId: auth.user.id, title, description, completed: false, created_at: now, updated_at: now };
      todos.push(todo);
      const pub = { id: todo.id, title: todo.title, description: todo.description, completed: todo.completed, created_at: todo.created_at, updated_at: todo.updated_at };
      return sendJSON(res, 201, pub);
    }

    // /todos/:id routes
    if (pathname.startsWith('/todos/')) {
      const idStr = pathname.slice('/todos/'.length);
      const id = parseInt(idStr, 10);
      if (!Number.isInteger(id) || id <= 0) {
        return sendJSON(res, 404, { error: 'Todo not found' });
      }
      const auth = getAuthenticatedUser(req, res);
      if (!auth) return;
      const todo = todos.find(t => t.id === id);
      if (!todo || todo.userId !== auth.user.id) {
        // Important: Return 404, not 403
        return sendJSON(res, 404, { error: 'Todo not found' });
      }

      if (method === 'GET') {
        const pub = { id: todo.id, title: todo.title, description: todo.description, completed: todo.completed, created_at: todo.created_at, updated_at: todo.updated_at };
        return sendJSON(res, 200, pub);
      }
      if (method === 'PUT') {
        const body = await parseJSONBody(req, res);
        if (body == null) return;
        const upd = {};
        if ('title' in body) {
          if (typeof body.title !== 'string' || body.title.trim() === '') {
            return sendJSON(res, 400, { error: 'Title is required' });
          }
          upd.title = body.title.trim();
        }
        if ('description' in body) {
          if (typeof body.description !== 'string') {
            upd.description = '';
          } else {
            upd.description = body.description;
          }
        }
        if ('completed' in body) {
          if (typeof body.completed !== 'boolean') {
            return sendJSON(res, 400, { error: 'Invalid JSON' });
          }
          upd.completed = body.completed;
        }
        Object.assign(todo, upd);
        todo.updated_at = isoNowSeconds();
        const pub = { id: todo.id, title: todo.title, description: todo.description, completed: todo.completed, created_at: todo.created_at, updated_at: todo.updated_at };
        return sendJSON(res, 200, pub);
      }
      if (method === 'DELETE') {
        // Delete and return 204 no body
        const idx = todos.findIndex(t => t.id === id);
        if (idx === -1 || todos[idx].userId !== auth.user.id) {
          return sendJSON(res, 404, { error: 'Todo not found' });
        }
        todos.splice(idx, 1);
        return sendNoContent(res);
      }
    }

    // Fallback 404 JSON
    return sendJSON(res, 404, { error: 'Not found' });
  } catch (err) {
    // Robust error handling: avoid leaking stack
    try {
      return sendJSON(res, 500, { error: 'Internal server error' });
    } catch (_) {
      res.statusCode = 500;
      res.end();
    }
  }
});

function parseArgs(argv) {
  const out = {};
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--port' && i + 1 < argv.length) {
      out.port = parseInt(argv[i + 1], 10);
      i++;
    }
  }
  return out;
}

const args = parseArgs(process.argv);
const port = Number.isInteger(args.port) ? args.port : 3000;

server.listen(port, '0.0.0.0', () => {
  // eslint-disable-next-line no-console
  console.log(`Server listening on 0.0.0.0:${port}`);
});
