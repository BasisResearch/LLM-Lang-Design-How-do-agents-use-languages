#!/usr/bin/env node
'use strict';

const http = require('http');
const crypto = require('crypto');

// In-memory stores
const users = []; // {id, username, passwordHash, salt}
let nextUserId = 1;

const sessions = new Map(); // token -> userId

const todos = []; // {id, userId, title, description, completed, created_at, updated_at}
let nextTodoId = 1;

function jsonTimestampNow() {
  // ISO 8601 UTC timestamp with second precision
  const d = new Date();
  return new Date(Math.floor(d.getTime() / 1000) * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');
}

function sendJson(res, statusCode, obj, headers = {}) {
  const body = JSON.stringify(obj);
  const baseHeaders = {
    'Content-Type': 'application/json',
    'Content-Length': Buffer.byteLength(body).toString(),
  };
  res.writeHead(statusCode, { ...baseHeaders, ...headers });
  res.end(body);
}

function sendNoContent(res, headers = {}) {
  // 204 No Content
  res.writeHead(204, headers);
  res.end();
}

function notFound(res) {
  sendJson(res, 404, { error: 'Not found' });
}

function parseCookies(req) {
  const header = req.headers['cookie'];
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

function parseBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let total = 0;
    const limit = 1 * 1024 * 1024; // 1MB limit
    req.on('data', (chunk) => {
      total += chunk.length;
      if (total > limit) {
        reject(new Error('Payload too large'));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => {
      const raw = Buffer.concat(chunks).toString('utf8');
      if (!raw) return resolve({});
      try {
        const obj = JSON.parse(raw);
        resolve(obj);
      } catch (e) {
        reject(new Error('Invalid JSON'));
      }
    });
    req.on('error', (err) => reject(err));
  });
}

function hashPassword(password, salt) {
  const s = salt || crypto.randomBytes(16).toString('hex');
  const hash = crypto.scryptSync(password, s, 64).toString('hex');
  return { hash, salt: s };
}

function validateUsername(username) {
  if (typeof username !== 'string') return false;
  if (username.length < 3 || username.length > 50) return false;
  if (!/^[a-zA-Z0-9_]+$/.test(username)) return false;
  return true;
}

function requireAuth(req, res) {
  const cookies = parseCookies(req);
  const token = cookies['session_id'];
  if (!token) {
    sendJson(res, 401, { error: 'Authentication required' });
    return null;
  }
  const userId = sessions.get(token);
  if (!userId) {
    sendJson(res, 401, { error: 'Authentication required' });
    return null;
  }
  const user = users.find(u => u.id === userId);
  if (!user) {
    // Should not happen, but invalidate session just in case
    sessions.delete(token);
    sendJson(res, 401, { error: 'Authentication required' });
    return null;
  }
  return { user, token };
}

function getUserPublic(user) {
  return { id: user.id, username: user.username };
}

function getUserTodos(userId) {
  return todos.filter(t => t.userId === userId).sort((a, b) => a.id - b.id).map(stripTodoUser);
}

function stripTodoUser(todo) {
  const { userId, ...rest } = todo;
  return rest;
}

function findTodoOwnedBy(id, userId) {
  const todo = todos.find(t => t.id === id);
  if (!todo) return null;
  if (todo.userId !== userId) return null;
  return todo;
}

function setCookieHeader(token) {
  // Set-Cookie: session_id=<token>; Path=/; HttpOnly
  return `session_id=${encodeURIComponent(token)}; Path=/; HttpOnly`;
}

function createServer() {
  const server = http.createServer(async (req, res) => {
    // Ensure all non-DELETE responses default to JSON on error paths
    try {
      const url = new URL(req.url, `http://${req.headers.host}`);
      const method = req.method || 'GET';

      // Routing
      if (url.pathname === '/register' && method === 'POST') {
        let body;
        try {
          body = await parseBody(req);
        } catch (e) {
          return sendJson(res, 400, { error: 'Invalid JSON' });
        }
        const { username, password } = body || {};
        if (!validateUsername(username)) {
          return sendJson(res, 400, { error: 'Invalid username' });
        }
        if (typeof password !== 'string' || password.length < 8) {
          return sendJson(res, 400, { error: 'Password too short' });
        }
        const existing = users.find(u => u.username === username);
        if (existing) {
          return sendJson(res, 409, { error: 'Username already exists' });
        }
        const { hash, salt } = hashPassword(password);
        const user = { id: nextUserId++, username, passwordHash: hash, salt };
        users.push(user);
        return sendJson(res, 201, getUserPublic(user));
      }

      if (url.pathname === '/login' && method === 'POST') {
        let body;
        try {
          body = await parseBody(req);
        } catch (e) {
          return sendJson(res, 400, { error: 'Invalid JSON' });
        }
        const { username, password } = body || {};
        const user = users.find(u => u.username === username);
        if (!user) {
          return sendJson(res, 401, { error: 'Invalid credentials' });
        }
        const { hash } = hashPassword(password || '', user.salt);
        if (hash !== user.passwordHash) {
          return sendJson(res, 401, { error: 'Invalid credentials' });
        }
        const token = crypto.randomBytes(16).toString('hex');
        sessions.set(token, user.id);
        return sendJson(res, 200, getUserPublic(user), { 'Set-Cookie': setCookieHeader(token) });
      }

      if (url.pathname === '/logout' && method === 'POST') {
        const auth = requireAuth(req, res);
        if (!auth) return; // response already sent
        // Invalidate current session
        sessions.delete(auth.token);
        return sendJson(res, 200, {});
      }

      if (url.pathname === '/me' && method === 'GET') {
        const auth = requireAuth(req, res);
        if (!auth) return;
        return sendJson(res, 200, getUserPublic(auth.user));
      }

      if (url.pathname === '/password' && method === 'PUT') {
        const auth = requireAuth(req, res);
        if (!auth) return;
        let body;
        try {
          body = await parseBody(req);
        } catch (e) {
          return sendJson(res, 400, { error: 'Invalid JSON' });
        }
        const { old_password, new_password } = body || {};
        const { hash } = hashPassword(old_password || '', auth.user.salt);
        if (hash !== auth.user.passwordHash) {
          return sendJson(res, 401, { error: 'Invalid credentials' });
        }
        if (typeof new_password !== 'string' || new_password.length < 8) {
          return sendJson(res, 400, { error: 'Password too short' });
        }
        const hp = hashPassword(new_password);
        auth.user.passwordHash = hp.hash;
        auth.user.salt = hp.salt;
        return sendJson(res, 200, {});
      }

      if (url.pathname === '/todos' && method === 'GET') {
        const auth = requireAuth(req, res);
        if (!auth) return;
        return sendJson(res, 200, getUserTodos(auth.user.id));
      }

      if (url.pathname === '/todos' && method === 'POST') {
        const auth = requireAuth(req, res);
        if (!auth) return;
        let body;
        try {
          body = await parseBody(req);
        } catch (e) {
          return sendJson(res, 400, { error: 'Invalid JSON' });
        }
        let { title, description } = body || {};
        if (typeof title !== 'string' || title.trim() === '') {
          return sendJson(res, 400, { error: 'Title is required' });
        }
        if (typeof description !== 'string') description = '';
        const now = jsonTimestampNow();
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
        return sendJson(res, 201, stripTodoUser(todo));
      }

      // Routes with /todos/:id
      if (url.pathname.startsWith('/todos/')) {
        const auth = requireAuth(req, res);
        if (!auth) return;
        const idStr = url.pathname.slice('/todos/'.length);
        const id = parseInt(idStr, 10);
        if (!Number.isInteger(id) || id <= 0) {
          // Treat invalid id as not found
          if (method === 'DELETE') {
            // For consistency, still return 404 JSON
            return sendJson(res, 404, { error: 'Todo not found' });
          }
          return sendJson(res, 404, { error: 'Todo not found' });
        }

        if (method === 'GET') {
          const todo = findTodoOwnedBy(id, auth.user.id);
          if (!todo) return sendJson(res, 404, { error: 'Todo not found' });
          return sendJson(res, 200, stripTodoUser(todo));
        }

        if (method === 'PUT') {
          let body;
          try {
            body = await parseBody(req);
          } catch (e) {
            return sendJson(res, 400, { error: 'Invalid JSON' });
          }
          const todo = findTodoOwnedBy(id, auth.user.id);
          if (!todo) return sendJson(res, 404, { error: 'Todo not found' });
          if (Object.prototype.hasOwnProperty.call(body || {}, 'title')) {
            const t = body.title;
            if (typeof t !== 'string' || t.trim() === '') {
              return sendJson(res, 400, { error: 'Title is required' });
            }
            todo.title = t;
          }
          if (Object.prototype.hasOwnProperty.call(body || {}, 'description')) {
            const d = body.description;
            if (typeof d === 'string') todo.description = d;
            else todo.description = '';
          }
          if (Object.prototype.hasOwnProperty.call(body || {}, 'completed')) {
            const c = body.completed;
            if (typeof c !== 'boolean') {
              return sendJson(res, 400, { error: 'Invalid completed value' });
            }
            todo.completed = c;
          }
          todo.updated_at = jsonTimestampNow();
          return sendJson(res, 200, stripTodoUser(todo));
        }

        if (method === 'DELETE') {
          const idx = todos.findIndex(t => t.id === id && t.userId === auth.user.id);
          if (idx === -1) {
            return sendJson(res, 404, { error: 'Todo not found' });
          }
          todos.splice(idx, 1);
          return sendNoContent(res);
        }
      }

      // If method matched none of the above
      return notFound(res);
    } catch (err) {
      // Unexpected error handler
      try {
        return sendJson(res, 500, { error: 'Internal server error' });
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
    if (a === '--port') {
      const p = argv[i + 1];
      i++;
      if (!p) throw new Error('Missing value for --port');
      const n = parseInt(p, 10);
      if (!Number.isInteger(n) || n <= 0 || n > 65535) throw new Error('Invalid port');
      args.port = n;
    }
  }
  return args;
}

if (require.main === module) {
  let port = 3000;
  try {
    const args = parseArgs(process.argv);
    port = args.port;
  } catch (e) {
    console.error(e.message);
    process.exit(1);
  }
  const server = createServer();
  server.listen(port, '0.0.0.0', () => {
    console.log(`Server listening on 0.0.0.0:${port}`);
  });
}

module.exports = { createServer };
