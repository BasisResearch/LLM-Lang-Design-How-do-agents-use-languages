#!/usr/bin/env node

const http = require('http');
const crypto = require('crypto');
const { URL } = require('url');

// In-memory storage
const db = {
  users: [], // {id, username, password}
  usernameIndex: new Map(), // username -> user
  todos: [], // {id, userId, title, description, completed, created_at, updated_at}
  sessions: new Map(), // token -> userId
  nextUserId: 1,
  nextTodoId: 1,
};

function formatTimestamp(date = new Date()) {
  // ISO 8601 UTC with second precision
  return date.toISOString().replace(/\.\d{3}Z$/, 'Z');
}

function json(res, statusCode, obj) {
  const body = JSON.stringify(obj);
  res.statusCode = statusCode;
  res.setHeader('Content-Type', 'application/json');
  res.setHeader('Content-Length', Buffer.byteLength(body));
  res.end(body);
}

function jsonError(res, statusCode, message) {
  json(res, statusCode, { error: message });
}

function noContent(res) {
  res.statusCode = 204;
  // No body, do not set Content-Type as per spec
  res.end();
}

function parseCookies(req) {
  const header = req.headers['cookie'];
  const cookies = {};
  if (!header) return cookies;
  const parts = header.split(';');
  for (const part of parts) {
    const [name, ...rest] = part.trim().split('=');
    const value = rest.join('=');
    if (!name) continue;
    cookies[name] = decodeURIComponent(value || '');
  }
  return cookies;
}

function getAuthUser(req) {
  const cookies = parseCookies(req);
  const token = cookies['session_id'];
  if (!token) return { user: null, token: null };
  const userId = db.sessions.get(token);
  if (!userId) return { user: null, token };
  const user = db.users.find(u => u.id === userId) || null;
  return { user, token };
}

function requireAuth(req, res) {
  const { user, token } = getAuthUser(req);
  if (!user) {
    jsonError(res, 401, 'Authentication required');
    return null;
  }
  return { user, token };
}

function readJsonBody(req) {
  return new Promise((resolve, reject) => {
    let data = '';
    const MAX = 1 * 1024 * 1024; // 1MB limit
    req.on('data', chunk => {
      data += chunk;
      if (data.length > MAX) {
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

function setSessionCookie(res, token) {
  // Set-Cookie: session_id=<token>; Path=/; HttpOnly
  res.setHeader('Set-Cookie', `session_id=${token}; Path=/; HttpOnly`);
}

function generateToken() {
  return crypto.randomBytes(16).toString('hex');
}

function serializeUser(user) {
  return { id: user.id, username: user.username };
}

function serializeTodo(todo) {
  return {
    id: todo.id,
    title: todo.title,
    description: todo.description,
    completed: todo.completed,
    created_at: todo.created_at,
    updated_at: todo.updated_at,
  };
}

function notFound(res) {
  jsonError(res, 404, 'Not found');
}

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, `http://${req.headers.host}`);
    const method = req.method || 'GET';
    const path = url.pathname;

    // Route handling
    if (method === 'POST' && path === '/register') {
      let body;
      try {
        body = await readJsonBody(req);
      } catch (e) {
        if (e.message === 'Invalid JSON') return jsonError(res, 400, 'Invalid JSON');
        return jsonError(res, 400, e.message);
      }
      const username = typeof body.username === 'string' ? body.username : '';
      const password = typeof body.password === 'string' ? body.password : '';

      const usernameRegex = /^[A-Za-z0-9_]{3,50}$/;
      if (!usernameRegex.test(username)) {
        return jsonError(res, 400, 'Invalid username');
      }
      if (password.length < 8) {
        return jsonError(res, 400, 'Password too short');
      }
      if (db.usernameIndex.has(username)) {
        return jsonError(res, 409, 'Username already exists');
      }
      const user = { id: db.nextUserId++, username, password };
      db.users.push(user);
      db.usernameIndex.set(username, user);
      return json(res, 201, serializeUser(user));
    }

    if (method === 'POST' && path === '/login') {
      let body;
      try {
        body = await readJsonBody(req);
      } catch (e) {
        if (e.message === 'Invalid JSON') return jsonError(res, 400, 'Invalid JSON');
        return jsonError(res, 400, e.message);
      }
      const username = typeof body.username === 'string' ? body.username : '';
      const password = typeof body.password === 'string' ? body.password : '';
      const user = db.usernameIndex.get(username);
      if (!user || user.password !== password) {
        return jsonError(res, 401, 'Invalid credentials');
      }
      // create session
      const token = generateToken();
      db.sessions.set(token, user.id);
      setSessionCookie(res, token);
      return json(res, 200, serializeUser(user));
    }

    if (method === 'POST' && path === '/logout') {
      const auth = requireAuth(req, res);
      if (!auth) return; // response sent
      // invalidate session
      if (auth.token) {
        db.sessions.delete(auth.token);
      }
      return json(res, 200, {});
    }

    if (method === 'GET' && path === '/me') {
      const auth = requireAuth(req, res);
      if (!auth) return;
      return json(res, 200, serializeUser(auth.user));
    }

    if (method === 'PUT' && path === '/password') {
      const auth = requireAuth(req, res);
      if (!auth) return;
      let body;
      try {
        body = await readJsonBody(req);
      } catch (e) {
        if (e.message === 'Invalid JSON') return jsonError(res, 400, 'Invalid JSON');
        return jsonError(res, 400, e.message);
      }
      const old_password = typeof body.old_password === 'string' ? body.old_password : '';
      const new_password = typeof body.new_password === 'string' ? body.new_password : '';
      if (auth.user.password !== old_password) {
        return jsonError(res, 401, 'Invalid credentials');
      }
      if (new_password.length < 8) {
        return jsonError(res, 400, 'Password too short');
      }
      auth.user.password = new_password;
      return json(res, 200, {});
    }

    if (method === 'GET' && path === '/todos') {
      const auth = requireAuth(req, res);
      if (!auth) return;
      const list = db.todos
        .filter(t => t.userId === auth.user.id)
        .sort((a, b) => a.id - b.id)
        .map(serializeTodo);
      return json(res, 200, list);
    }

    if (method === 'POST' && path === '/todos') {
      const auth = requireAuth(req, res);
      if (!auth) return;
      let body;
      try {
        body = await readJsonBody(req);
      } catch (e) {
        if (e.message === 'Invalid JSON') return jsonError(res, 400, 'Invalid JSON');
        return jsonError(res, 400, e.message);
      }
      const title = body && typeof body.title === 'string' ? body.title.trim() : '';
      if (!title) {
        return jsonError(res, 400, 'Title is required');
      }
      const description = body && typeof body.description === 'string' ? body.description : '';
      const now = formatTimestamp(new Date());
      const todo = {
        id: db.nextTodoId++,
        userId: auth.user.id,
        title,
        description,
        completed: false,
        created_at: now,
        updated_at: now,
      };
      db.todos.push(todo);
      return json(res, 201, serializeTodo(todo));
    }

    if ((method === 'GET' || method === 'PUT' || method === 'DELETE') && path.startsWith('/todos/')) {
      const idStr = path.slice('/todos/'.length);
      if (!/^\d+$/.test(idStr)) {
        // Not a numeric id
        return notFound(res);
      }
      const id = parseInt(idStr, 10);
      const auth = requireAuth(req, res);
      if (!auth) return;
      const todo = db.todos.find(t => t.id === id);
      if (!todo || todo.userId !== auth.user.id) {
        // Hide existence if belongs to another user
        if (method === 'DELETE') return jsonError(res, 404, 'Todo not found');
        if (method === 'GET') return jsonError(res, 404, 'Todo not found');
        if (method === 'PUT') return jsonError(res, 404, 'Todo not found');
      }

      if (method === 'GET') {
        return json(res, 200, serializeTodo(todo));
      }

      if (method === 'PUT') {
        let body;
        try {
          body = await readJsonBody(req);
        } catch (e) {
          if (e.message === 'Invalid JSON') return jsonError(res, 400, 'Invalid JSON');
          return jsonError(res, 400, e.message);
        }
        if (Object.prototype.hasOwnProperty.call(body, 'title')) {
          const t = typeof body.title === 'string' ? body.title.trim() : '';
          if (!t) return jsonError(res, 400, 'Title is required');
          todo.title = t;
        }
        if (Object.prototype.hasOwnProperty.call(body, 'description')) {
          if (typeof body.description === 'string') {
            todo.description = body.description;
          } else if (body.description === null) {
            todo.description = '';
          } else {
            // Coerce other types to string for safety
            todo.description = String(body.description);
          }
        }
        if (Object.prototype.hasOwnProperty.call(body, 'completed')) {
          if (typeof body.completed !== 'boolean') {
            return jsonError(res, 400, 'Invalid completed');
          }
          todo.completed = body.completed;
        }
        todo.updated_at = formatTimestamp(new Date());
        return json(res, 200, serializeTodo(todo));
      }

      if (method === 'DELETE') {
        const idx = db.todos.findIndex(t => t.id === id && t.userId === auth.user.id);
        if (idx === -1) return jsonError(res, 404, 'Todo not found');
        db.todos.splice(idx, 1);
        return noContent(res);
      }
    }

    // Fallback 404
    return notFound(res);
  } catch (err) {
    // Unexpected error
    try {
      return jsonError(res, 500, 'Internal server error');
    } catch (_) {
      // ignore
    }
  }
});

function parseArgs(argv) {
  const out = { port: 3000 };
  for (let i = 2; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === '--port') {
      const val = argv[i + 1];
      if (!val) {
        console.error('Missing value for --port');
        process.exit(1);
      }
      const p = parseInt(val, 10);
      if (!Number.isInteger(p) || p <= 0 || p > 65535) {
        console.error('Invalid port');
        process.exit(1);
      }
      out.port = p;
      i++;
    }
  }
  return out;
}

if (require.main === module) {
  const { port } = parseArgs(process.argv);
  server.listen(port, '0.0.0.0', () => {
    console.log(`Server listening on 0.0.0.0:${port}`);
  });
}

module.exports = { server, db };
