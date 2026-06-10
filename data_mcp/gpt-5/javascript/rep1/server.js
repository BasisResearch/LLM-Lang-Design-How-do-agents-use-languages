#!/usr/bin/env node
"use strict";

const http = require('http');
const url = require('url');
const crypto = require('crypto');

// In-memory storage
const users = []; // {id, username, password}
const sessions = new Map(); // token -> userId
const todos = []; // {id, userId, title, description, completed, created_at, updated_at}
let nextUserId = 1;
let nextTodoId = 1;

function isoNowSeconds() {
  // Returns ISO 8601 UTC with second precision
  const s = new Date().toISOString();
  return s.split('.')[0] + 'Z';
}

function parseCookies(cookieHeader) {
  const cookies = {};
  if (!cookieHeader) return cookies;
  const parts = cookieHeader.split(';');
  for (const part of parts) {
    const idx = part.indexOf('=');
    if (idx === -1) continue;
    const key = part.substring(0, idx).trim();
    const val = part.substring(idx + 1).trim();
    cookies[key] = val;
  }
  return cookies;
}

function sendJSON(res, statusCode, obj, extraHeaders = {}) {
  const body = JSON.stringify(obj);
  res.statusCode = statusCode;
  res.setHeader('Content-Type', 'application/json');
  for (const [k, v] of Object.entries(extraHeaders)) {
    res.setHeader(k, v);
  }
  res.end(body);
}

function sendNoContent(res, statusCode = 204, extraHeaders = {}) {
  res.statusCode = statusCode;
  for (const [k, v] of Object.entries(extraHeaders)) {
    res.setHeader(k, v);
  }
  // No body per spec for DELETE
  res.end();
}

function readBodyJSON(req, res) {
  return new Promise((resolve, reject) => {
    let data = '';
    const MAX = 1 * 1024 * 1024; // 1MB
    req.on('data', chunk => {
      data += chunk;
      if (data.length > MAX) {
        reject({ code: 413, error: 'Payload too large' });
        req.destroy();
      }
    });
    req.on('end', () => {
      if (!data) {
        resolve({});
        return;
      }
      try {
        const obj = JSON.parse(data);
        resolve(obj);
      } catch (e) {
        reject({ code: 400, error: 'Invalid JSON' });
      }
    });
    req.on('error', (err) => {
      reject({ code: 400, error: 'Invalid request' });
    });
  });
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
    // Invalidate dangling session
    sessions.delete(token);
    sendJSON(res, 401, { error: 'Authentication required' });
    return null;
  }
  // Attach token for logout invalidation
  req._sessionToken = token;
  return user;
}

function validateUsername(username) {
  if (typeof username !== 'string') return false;
  if (username.length < 3 || username.length > 50) return false;
  if (!/^[a-zA-Z0-9_]+$/.test(username)) return false;
  return true;
}

function createServer() {
  const server = http.createServer(async (req, res) => {
    try {
      const parsedUrl = url.parse(req.url, true);
      const path = parsedUrl.pathname || '/';
      const method = req.method || 'GET';

      // Route handling
      // Ensure only JSON content type responses except DELETE (204)

      // POST /register
      if (method === 'POST' && path === '/register') {
        let body;
        try {
          body = await readBodyJSON(req, res);
        } catch (e) {
          const code = e.code || 400;
          return sendJSON(res, code, { error: e.error || 'Invalid JSON' });
        }
        const { username, password } = body || {};
        if (!validateUsername(username)) {
          return sendJSON(res, 400, { error: 'Invalid username' });
        }
        if (typeof password !== 'string' || password.length < 8) {
          return sendJSON(res, 400, { error: 'Password too short' });
        }
        if (users.some(u => u.username === username)) {
          return sendJSON(res, 409, { error: 'Username already exists' });
        }
        const user = { id: nextUserId++, username, password };
        users.push(user);
        const resp = { id: user.id, username: user.username };
        return sendJSON(res, 201, resp);
      }

      // POST /login
      if (method === 'POST' && path === '/login') {
        let body;
        try {
          body = await readBodyJSON(req, res);
        } catch (e) {
          const code = e.code || 400;
          return sendJSON(res, code, { error: e.error || 'Invalid JSON' });
        }
        const { username, password } = body || {};
        const user = users.find(u => u.username === username);
        if (!user || user.password !== password) {
          return sendJSON(res, 401, { error: 'Invalid credentials' });
        }
        const token = crypto.randomBytes(16).toString('hex');
        sessions.set(token, user.id);
        const headers = {
          'Set-Cookie': `session_id=${token}; Path=/; HttpOnly`
        };
        return sendJSON(res, 200, { id: user.id, username: user.username }, headers);
      }

      // POST /logout
      if (method === 'POST' && path === '/logout') {
        const user = getAuthenticatedUser(req, res);
        if (!user) return; // response sent
        const token = req._sessionToken;
        if (token) sessions.delete(token);
        return sendJSON(res, 200, {});
      }

      // GET /me
      if (method === 'GET' && path === '/me') {
        const user = getAuthenticatedUser(req, res);
        if (!user) return;
        return sendJSON(res, 200, { id: user.id, username: user.username });
      }

      // PUT /password
      if (method === 'PUT' && path === '/password') {
        const user = getAuthenticatedUser(req, res);
        if (!user) return;
        let body;
        try {
          body = await readBodyJSON(req, res);
        } catch (e) {
          const code = e.code || 400;
          return sendJSON(res, code, { error: e.error || 'Invalid JSON' });
        }
        const { old_password, new_password } = body || {};
        if (user.password !== old_password) {
          return sendJSON(res, 401, { error: 'Invalid credentials' });
        }
        if (typeof new_password !== 'string' || new_password.length < 8) {
          return sendJSON(res, 400, { error: 'Password too short' });
        }
        user.password = new_password;
        return sendJSON(res, 200, {});
      }

      // GET /todos
      if (method === 'GET' && path === '/todos') {
        const user = getAuthenticatedUser(req, res);
        if (!user) return;
        const list = todos.filter(t => t.userId === user.id).sort((a, b) => a.id - b.id).map(t => ({
          id: t.id,
          title: t.title,
          description: t.description,
          completed: t.completed,
          created_at: t.created_at,
          updated_at: t.updated_at
        }));
        return sendJSON(res, 200, list);
      }

      // POST /todos
      if (method === 'POST' && path === '/todos') {
        const user = getAuthenticatedUser(req, res);
        if (!user) return;
        let body;
        try {
          body = await readBodyJSON(req, res);
        } catch (e) {
          const code = e.code || 400;
          return sendJSON(res, code, { error: e.error || 'Invalid JSON' });
        }
        const title = body && typeof body.title === 'string' ? body.title : undefined;
        const description = body && typeof body.description === 'string' ? body.description : '';
        if (!title || title.trim() === '') {
          return sendJSON(res, 400, { error: 'Title is required' });
        }
        const now = isoNowSeconds();
        const todo = {
          id: nextTodoId++,
          userId: user.id,
          title: title,
          description: description || '',
          completed: false,
          created_at: now,
          updated_at: now
        };
        todos.push(todo);
        const resp = {
          id: todo.id,
          title: todo.title,
          description: todo.description,
          completed: todo.completed,
          created_at: todo.created_at,
          updated_at: todo.updated_at
        };
        return sendJSON(res, 201, resp);
      }

      // Routes with /todos/:id
      if (path.startsWith('/todos/')) {
        const idStr = path.substring('/todos/'.length);
        const id = parseInt(idStr, 10);
        if (!Number.isInteger(id) || id <= 0) {
          // All these should look like not found per security
          if (method === 'DELETE') {
            // even if invalid id, follow same 404 json error
            return sendJSON(res, 404, { error: 'Todo not found' });
          } else {
            return sendJSON(res, 404, { error: 'Todo not found' });
          }
        }
        const user = getAuthenticatedUser(req, res);
        if (!user) return;
        const todo = todos.find(t => t.id === id);
        if (!todo || todo.userId !== user.id) {
          return sendJSON(res, 404, { error: 'Todo not found' });
        }

        if (method === 'GET') {
          const resp = {
            id: todo.id,
            title: todo.title,
            description: todo.description,
            completed: todo.completed,
            created_at: todo.created_at,
            updated_at: todo.updated_at
          };
          return sendJSON(res, 200, resp);
        }

        if (method === 'PUT') {
          let body;
          try {
            body = await readBodyJSON(req, res);
          } catch (e) {
            const code = e.code || 400;
            return sendJSON(res, code, { error: e.error || 'Invalid JSON' });
          }
          if (body && Object.prototype.hasOwnProperty.call(body, 'title')) {
            if (typeof body.title !== 'string' || body.title.trim() === '') {
              return sendJSON(res, 400, { error: 'Title is required' });
            }
            todo.title = body.title;
          }
          if (body && Object.prototype.hasOwnProperty.call(body, 'description')) {
            if (typeof body.description !== 'string') {
              // Normalize to string; but spec does not forbid non-string; treat as invalid JSON fields? Here coerce to string
              todo.description = String(body.description);
            } else {
              todo.description = body.description;
            }
          }
          if (body && Object.prototype.hasOwnProperty.call(body, 'completed')) {
            todo.completed = Boolean(body.completed);
          }
          todo.updated_at = isoNowSeconds();
          const resp = {
            id: todo.id,
            title: todo.title,
            description: todo.description,
            completed: todo.completed,
            created_at: todo.created_at,
            updated_at: todo.updated_at
          };
          return sendJSON(res, 200, resp);
        }

        if (method === 'DELETE') {
          const idx = todos.findIndex(t => t.id === id && t.userId === user.id);
          if (idx === -1) {
            return sendJSON(res, 404, { error: 'Todo not found' });
          }
          todos.splice(idx, 1);
          return sendNoContent(res, 204);
        }
      }

      // Fallback 404
      return sendJSON(res, 404, { error: 'Not found' });
    } catch (err) {
      // Internal error safety net
      try {
        return sendJSON(res, 500, { error: 'Internal server error' });
      } catch (_) {
        res.statusCode = 500;
        res.end();
      }
    }
  });
  return server;
}

function parseArgs(argv) {
  const args = { port: 3000 };
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--port' && i + 1 < argv.length) {
      const p = parseInt(argv[++i], 10);
      if (!Number.isFinite(p) || p <= 0 || p >= 65536) {
        console.error('Invalid port');
        process.exit(1);
      }
      args.port = p;
    }
  }
  return args;
}

if (require.main === module) {
  const { port } = parseArgs(process.argv);
  const server = createServer();
  server.listen(port, '0.0.0.0', () => {
    console.log(`Server listening on 0.0.0.0:${port}`);
  });
}

module.exports = { createServer };
