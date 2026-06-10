#!/usr/bin/env node
'use strict';

const http = require('http');
const { URL } = require('url');
const crypto = require('crypto');

// In-memory storage
const db = {
  users: [], // {id, username, passwordHash, salt}
  nextUserId: 1,
  sessions: new Map(), // token -> userId
  todos: new Map(), // id -> {id, userId, title, description, completed, created_at, updated_at}
  nextTodoId: 1,
};

// Utilities
function nowIsoSeconds() {
  return new Date().toISOString().replace(/\.\d{3}Z$/, 'Z');
}

function sendJson(res, status, obj, extraHeaders = {}) {
  const payload = JSON.stringify(obj);
  const headers = Object.assign({
    'Content-Type': 'application/json',
    'Content-Length': Buffer.byteLength(payload),
  }, extraHeaders);
  res.writeHead(status, headers);
  res.end(payload);
}

function sendNoContent(res) {
  // For DELETE 204 with no body
  res.writeHead(204, { 'Content-Length': 0 });
  res.end();
}

function parseCookies(req) {
  const header = req.headers['cookie'];
  const cookies = {};
  if (!header) return cookies;
  const parts = header.split(';');
  for (const part of parts) {
    const [k, v] = part.split('=');
    if (k && v !== undefined) {
      const key = k.trim();
      const val = v.trim();
      try {
        cookies[key] = decodeURIComponent(val);
      } catch (_) {
        cookies[key] = val;
      }
    }
  }
  return cookies;
}

function readJsonBody(req, maxBytes = 1 * 1024 * 1024) {
  return new Promise((resolve, reject) => {
    let total = 0;
    const chunks = [];
    req.on('data', (chunk) => {
      total += chunk.length;
      if (total > maxBytes) {
        reject({ code: 413, error: 'Payload too large' });
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => {
      try {
        if (chunks.length === 0) {
          resolve(null);
          return;
        }
        const buf = Buffer.concat(chunks);
        const raw = buf.toString('utf8');
        try {
          const obj = JSON.parse(raw);
          resolve(obj);
        } catch (e) {
          // Log diagnostic safely
          try {
            console.error('Invalid JSON payload length=%d hex=%s', buf.length, buf.toString('hex'));
          } catch (_) {}
          reject({ code: 400, error: 'Invalid JSON' });
        }
      } catch (e) {
        reject({ code: 400, error: 'Invalid request' });
      }
    });
    req.on('error', () => {
      reject({ code: 400, error: 'Invalid request' });
    });
  });
}

function validateUsername(username) {
  if (typeof username !== 'string') return false;
  if (username.length < 3 || username.length > 50) return false;
  return /^[A-Za-z0-9_]+$/.test(username);
}

function hashPassword(password, saltHex) {
  // Use scrypt with 64-byte key
  const salt = Buffer.from(saltHex, 'hex');
  const dk = crypto.scryptSync(password, salt, 64);
  return dk.toString('hex');
}

function createPasswordRecord(password) {
  const salt = crypto.randomBytes(16).toString('hex');
  const passwordHash = hashPassword(password, salt);
  return { salt, passwordHash };
}

function authenticate(req) {
  const cookies = parseCookies(req);
  const token = cookies['session_id'];
  if (!token) return null;
  const userId = db.sessions.get(token);
  if (!userId) return null;
  const user = db.users.find(u => u.id === userId);
  if (!user) return null;
  return { user, token };
}

function publicUser(user) {
  return { id: user.id, username: user.username };
}

function todoPublic(todo) {
  return {
    id: todo.id,
    title: todo.title,
    description: todo.description,
    completed: todo.completed,
    created_at: todo.created_at,
    updated_at: todo.updated_at,
  };
}

function getTodoForUser(todoId, userId) {
  const todo = db.todos.get(todoId);
  if (!todo) return null;
  if (todo.userId !== userId) return null; // treat as not found
  return todo;
}

function parseIdSegment(seg) {
  if (!seg) return null;
  if (!/^\d+$/.test(seg)) return null;
  const id = parseInt(seg, 10);
  if (id <= 0) return null;
  return id;
}

// Router
async function handleRequest(req, res) {
  try {
    const url = new URL(req.url, `http://localhost`);
    const pathname = url.pathname;

    if (req.method === 'POST' && pathname === '/register') {
      const body = await readJsonBody(req).catch(err => { throw err; });
      const username = body && body.username;
      const password = body && body.password;

      if (!validateUsername(username)) {
        return sendJson(res, 400, { error: 'Invalid username' });
      }
      if (typeof password !== 'string' || password.length < 8) {
        return sendJson(res, 400, { error: 'Password too short' });
      }
      const existing = db.users.find(u => u.username === username);
      if (existing) {
        return sendJson(res, 409, { error: 'Username already exists' });
      }
      const { salt, passwordHash } = createPasswordRecord(password);
      const user = { id: db.nextUserId++, username, passwordHash, salt };
      db.users.push(user);
      return sendJson(res, 201, publicUser(user));
    }

    if (req.method === 'POST' && pathname === '/login') {
      const body = await readJsonBody(req).catch(err => { throw err; });
      const username = body && body.username;
      const password = body && body.password;

      const user = db.users.find(u => u.username === username);
      if (!user) {
        return sendJson(res, 401, { error: 'Invalid credentials' });
      }
      if (typeof password !== 'string' || password.length === 0) {
        return sendJson(res, 401, { error: 'Invalid credentials' });
      }
      const computed = hashPassword(password, user.salt);
      if (computed !== user.passwordHash) {
        return sendJson(res, 401, { error: 'Invalid credentials' });
      }
      // Create session token
      const token = crypto.randomBytes(32).toString('hex');
      db.sessions.set(token, user.id);
      const cookie = `session_id=${token}; Path=/; HttpOnly`;
      return sendJson(res, 200, publicUser(user), { 'Set-Cookie': cookie });
    }

    if (req.method === 'POST' && pathname === '/logout') {
      const auth = authenticate(req);
      if (!auth) {
        return sendJson(res, 401, { error: 'Authentication required' });
      }
      // Invalidate token
      db.sessions.delete(auth.token);
      return sendJson(res, 200, {});
    }

    if (req.method === 'GET' && pathname === '/me') {
      const auth = authenticate(req);
      if (!auth) {
        return sendJson(res, 401, { error: 'Authentication required' });
      }
      return sendJson(res, 200, publicUser(auth.user));
    }

    if (req.method === 'PUT' && pathname === '/password') {
      const auth = authenticate(req);
      if (!auth) {
        return sendJson(res, 401, { error: 'Authentication required' });
      }
      const body = await readJsonBody(req).catch(err => { throw err; });
      const old_password = body && body.old_password;
      const new_password = body && body.new_password;
      if (typeof old_password !== 'string') {
        return sendJson(res, 401, { error: 'Invalid credentials' });
      }
      const computed = hashPassword(old_password, auth.user.salt);
      if (computed !== auth.user.passwordHash) {
        return sendJson(res, 401, { error: 'Invalid credentials' });
      }
      if (typeof new_password !== 'string' || new_password.length < 8) {
        return sendJson(res, 400, { error: 'Password too short' });
      }
      const rec = createPasswordRecord(new_password);
      auth.user.salt = rec.salt;
      auth.user.passwordHash = rec.passwordHash;
      return sendJson(res, 200, {});
    }

    if (req.method === 'GET' && pathname === '/todos') {
      const auth = authenticate(req);
      if (!auth) {
        return sendJson(res, 401, { error: 'Authentication required' });
      }
      const list = [];
      for (const todo of db.todos.values()) {
        if (todo.userId === auth.user.id) list.push(todoPublic(todo));
      }
      list.sort((a, b) => a.id - b.id);
      return sendJson(res, 200, list);
    }

    if (req.method === 'POST' && pathname === '/todos') {
      const auth = authenticate(req);
      if (!auth) {
        return sendJson(res, 401, { error: 'Authentication required' });
      }
      const body = await readJsonBody(req).catch(err => { throw err; });
      const title = body && body.title;
      let description = '';
      if (body && typeof body.description === 'string') description = body.description;
      if (typeof title !== 'string' || title.trim() === '') {
        return sendJson(res, 400, { error: 'Title is required' });
      }
      const now = nowIsoSeconds();
      const todo = {
        id: db.nextTodoId++,
        userId: auth.user.id,
        title: title,
        description: description || '',
        completed: false,
        created_at: now,
        updated_at: now,
      };
      db.todos.set(todo.id, todo);
      return sendJson(res, 201, todoPublic(todo));
    }

    // Routes with ID: /todos/:id
    if (pathname.startsWith('/todos/')) {
      const parts = pathname.split('/').filter(Boolean); // [ 'todos', ':id' ]
      if (parts.length === 2) {
        const id = parseIdSegment(parts[1]);
        if (!id) {
          // Invalid ID format -> treat as not found (to avoid enumeration)
          return sendJson(res, 404, { error: 'Todo not found' });
        }
        const auth = authenticate(req);
        if (!auth) {
          return sendJson(res, 401, { error: 'Authentication required' });
        }
        if (req.method === 'GET') {
          const todo = getTodoForUser(id, auth.user.id);
          if (!todo) return sendJson(res, 404, { error: 'Todo not found' });
          return sendJson(res, 200, todoPublic(todo));
        }
        if (req.method === 'PUT') {
          const todo = getTodoForUser(id, auth.user.id);
          if (!todo) return sendJson(res, 404, { error: 'Todo not found' });
          const body = await readJsonBody(req).catch(err => { throw err; });
          if (body && Object.prototype.hasOwnProperty.call(body, 'title')) {
            const title = body.title;
            if (typeof title !== 'string' || title.trim() === '') {
              return sendJson(res, 400, { error: 'Title is required' });
            }
            todo.title = title;
          }
          if (body && Object.prototype.hasOwnProperty.call(body, 'description')) {
            const description = body.description;
            if (typeof description === 'string') {
              todo.description = description;
            }
          }
          if (body && Object.prototype.hasOwnProperty.call(body, 'completed')) {
            const completed = body.completed;
            if (typeof completed === 'boolean') {
              todo.completed = completed;
            }
          }
          todo.updated_at = nowIsoSeconds();
          return sendJson(res, 200, todoPublic(todo));
        }
        if (req.method === 'DELETE') {
          const todo = getTodoForUser(id, auth.user.id);
          if (!todo) {
            return sendJson(res, 404, { error: 'Todo not found' });
          }
          db.todos.delete(id);
          return sendNoContent(res);
        }
      }
    }

    // Fallback for unmatched routes
    sendJson(res, 404, { error: 'Not found' });
  } catch (err) {
    if (err && typeof err === 'object' && 'code' in err && 'error' in err) {
      const status = typeof err.code === 'number' ? err.code : 400;
      return sendJson(res, status, { error: err.error });
    }
    // Unexpected error
    try {
      return sendJson(res, 500, { error: 'Internal server error' });
    } catch (_) {
      // If headers already sent
      res.destroy();
    }
  }
}

function parseArgs(argv) {
  const args = { port: 3000 };
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--port') {
      const v = argv[++i];
      const p = v ? parseInt(v, 10) : NaN;
      if (!v || !Number.isInteger(p) || p <= 0 || p > 65535) {
        console.error('Invalid --port');
        process.exit(2);
      }
      args.port = p;
    }
  }
  return args;
}

function main() {
  const { port } = parseArgs(process.argv);
  const server = http.createServer((req, res) => {
    handleRequest(req, res);
  });
  server.listen(port, '0.0.0.0', () => {
    console.log(`Server listening on 0.0.0.0:${port}`);
  });
}

if (require.main === module) {
  main();
}
