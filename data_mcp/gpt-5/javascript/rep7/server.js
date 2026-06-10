#!/usr/bin/env node

// Todo App REST API Server
// In-memory storage, cookie-based sessions

const http = require('http');
const crypto = require('crypto');
const { URL } = require('url');

// In-memory data stores
const users = []; // {id, username, passwordHash}
let nextUserId = 1;

const todos = []; // {id, userId, title, description, completed, created_at, updated_at}
let nextTodoId = 1;

// session_id token -> userId
const sessions = new Map();

// Utilities
function sha256(input) {
  return crypto.createHash('sha256').update(input).digest('hex');
}

function generateToken() {
  return crypto.randomBytes(16).toString('hex');
}

function parseCookies(header) {
  const cookies = {};
  if (!header) return cookies;
  const parts = header.split(';');
  for (const part of parts) {
    const idx = part.indexOf('=');
    if (idx === -1) continue;
    const key = part.slice(0, idx).trim();
    const val = part.slice(idx + 1).trim();
    cookies[key] = decodeURIComponent(val);
  }
  return cookies;
}

function isoNowSeconds() {
  const d = new Date();
  d.setMilliseconds(0);
  return d.toISOString();
}

function sendJSON(res, code, obj) {
  const body = JSON.stringify(obj);
  res.statusCode = code;
  res.setHeader('Content-Type', 'application/json');
  res.setHeader('Content-Length', Buffer.byteLength(body));
  res.end(body);
}

function sendError(res, code, message) {
  sendJSON(res, code, { error: message });
}

function readBody(req, limitBytes = 1 * 1024 * 1024) {
  return new Promise((resolve, reject) => {
    let body = '';
    let received = 0;
    req.on('data', chunk => {
      received += chunk.length;
      if (received > limitBytes) {
        reject(new Error('Payload too large'));
        req.destroy();
        return;
      }
      body += chunk.toString('utf8');
    });
    req.on('end', () => {
      resolve(body);
    });
    req.on('error', err => reject(err));
  });
}

async function readJSON(req) {
  const raw = await readBody(req).catch(() => {
    throw new Error('Invalid request');
  });
  if (!raw) return {};
  try {
    return JSON.parse(raw);
  } catch (e) {
    throw new Error('Invalid JSON');
  }
}

function getAuthUser(req) {
  const cookies = parseCookies(req.headers['cookie'] || '');
  const token = cookies['session_id'];
  if (!token) return null;
  const userId = sessions.get(token);
  if (!userId) return null;
  const user = users.find(u => u.id === userId);
  if (!user) return null;
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

function notFoundJSON(res) {
  sendError(res, 404, 'Not found');
}

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, 'http://localhost');
    const method = req.method || 'GET';

    // Routes
    if (method === 'POST' && url.pathname === '/register') {
      let body;
      try {
        body = await readJSON(req);
      } catch (e) {
        return sendError(res, 400, 'Invalid JSON');
      }
      const { username, password } = body || {};
      if (!validateUsername(username)) {
        return sendError(res, 400, 'Invalid username');
      }
      if (!validatePassword(password)) {
        return sendError(res, 400, 'Password too short');
      }
      if (users.some(u => u.username === username)) {
        return sendError(res, 409, 'Username already exists');
      }
      const user = { id: nextUserId++, username, passwordHash: sha256(password) };
      users.push(user);
      return sendJSON(res, 201, userPublic(user));
    }

    if (method === 'POST' && url.pathname === '/login') {
      let body;
      try {
        body = await readJSON(req);
      } catch (e) {
        return sendError(res, 400, 'Invalid JSON');
      }
      const { username, password } = body || {};
      const user = users.find(u => u.username === username);
      if (!user || user.passwordHash !== sha256(password || '')) {
        return sendError(res, 401, 'Invalid credentials');
      }
      const token = generateToken();
      sessions.set(token, user.id);
      res.setHeader('Set-Cookie', `session_id=${encodeURIComponent(token)}; Path=/; HttpOnly`);
      return sendJSON(res, 200, userPublic(user));
    }

    if (method === 'POST' && url.pathname === '/logout') {
      const auth = getAuthUser(req);
      if (!auth) return sendError(res, 401, 'Authentication required');
      // Invalidate token
      sessions.delete(auth.token);
      return sendJSON(res, 200, {});
    }

    if (method === 'GET' && url.pathname === '/me') {
      const auth = getAuthUser(req);
      if (!auth) return sendError(res, 401, 'Authentication required');
      return sendJSON(res, 200, userPublic(auth.user));
    }

    if (method === 'PUT' && url.pathname === '/password') {
      const auth = getAuthUser(req);
      if (!auth) return sendError(res, 401, 'Authentication required');
      let body;
      try {
        body = await readJSON(req);
      } catch (e) {
        return sendError(res, 400, 'Invalid JSON');
      }
      const { old_password, new_password } = body || {};
      if (sha256(old_password || '') !== auth.user.passwordHash) {
        return sendError(res, 401, 'Invalid credentials');
      }
      if (!validatePassword(new_password)) {
        return sendError(res, 400, 'Password too short');
      }
      auth.user.passwordHash = sha256(new_password);
      return sendJSON(res, 200, {});
    }

    if (method === 'GET' && url.pathname === '/todos') {
      const auth = getAuthUser(req);
      if (!auth) return sendError(res, 401, 'Authentication required');
      const list = todos
        .filter(t => t.userId === auth.user.id)
        .sort((a, b) => a.id - b.id)
        .map(todoPublic);
      return sendJSON(res, 200, list);
    }

    if (method === 'POST' && url.pathname === '/todos') {
      const auth = getAuthUser(req);
      if (!auth) return sendError(res, 401, 'Authentication required');
      let body;
      try {
        body = await readJSON(req);
      } catch (e) {
        return sendError(res, 400, 'Invalid JSON');
      }
      const title = (body && body.title) || '';
      const description = typeof body?.description === 'string' ? body.description : '';
      if (typeof title !== 'string' || title.trim() === '') {
        return sendError(res, 400, 'Title is required');
      }
      const now = isoNowSeconds();
      const todo = {
        id: nextTodoId++,
        userId: auth.user.id,
        title: title,
        description: description,
        completed: false,
        created_at: now,
        updated_at: now,
      };
      todos.push(todo);
      return sendJSON(res, 201, todoPublic(todo));
    }

    // Routes with ID parameter
    const todoIdMatch = url.pathname.match(/^\/todos\/(\d+)$/);

    if (todoIdMatch) {
      const id = parseInt(todoIdMatch[1], 10);
      const auth = getAuthUser(req);
      if (!auth) return sendError(res, 401, 'Authentication required');
      const todo = todos.find(t => t.id === id);

      if (method === 'GET') {
        if (!todo || todo.userId !== auth.user.id) {
          return sendError(res, 404, 'Todo not found');
        }
        return sendJSON(res, 200, todoPublic(todo));
      }

      if (method === 'PUT') {
        if (!todo || todo.userId !== auth.user.id) {
          return sendError(res, 404, 'Todo not found');
        }
        let body;
        try {
          body = await readJSON(req);
        } catch (e) {
          return sendError(res, 400, 'Invalid JSON');
        }
        if (Object.prototype.hasOwnProperty.call(body, 'title')) {
          const title = body.title;
          if (typeof title !== 'string' || title.trim() === '') {
            return sendError(res, 400, 'Title is required');
          }
          todo.title = title;
        }
        if (Object.prototype.hasOwnProperty.call(body, 'description')) {
          todo.description = typeof body.description === 'string' ? body.description : '';
        }
        if (Object.prototype.hasOwnProperty.call(body, 'completed')) {
          todo.completed = Boolean(body.completed);
        }
        todo.updated_at = isoNowSeconds();
        return sendJSON(res, 200, todoPublic(todo));
      }

      if (method === 'DELETE') {
        if (!todo || todo.userId !== auth.user.id) {
          // 404 with JSON? Spec says DELETE returns no body on success. For errors, JSON is fine.
          return sendError(res, 404, 'Todo not found');
        }
        const idx = todos.findIndex(t => t.id === id);
        if (idx !== -1) todos.splice(idx, 1);
        // 204 No Content, with no body and no Content-Type header
        res.statusCode = 204;
        return res.end();
      }
    }

    // Default 404 JSON for other routes
    return notFoundJSON(res);
  } catch (err) {
    // Generic error handler
    try {
      return sendError(res, 500, 'Internal server error');
    } catch (_) {
      // ignore
    }
  }
});

// Parse CLI args
function parsePortArg(argv) {
  const args = argv.slice(2);
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--port' && i + 1 < args.length) {
      const p = parseInt(args[i + 1], 10);
      if (!Number.isNaN(p) && p > 0 && p < 65536) return p;
    }
  }
  // Default port if not provided
  return 3000;
}

const port = parsePortArg(process.argv);

server.listen(port, '0.0.0.0', () => {
  // eslint-disable-next-line no-console
  console.log(`Server listening on http://0.0.0.0:${port}`);
});
