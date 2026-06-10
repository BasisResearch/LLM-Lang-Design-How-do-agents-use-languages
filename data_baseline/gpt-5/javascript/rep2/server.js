const http = require('http');
const crypto = require('crypto');
const { URL } = require('url');

// In-memory data stores
let nextUserId = 1;
let nextTodoId = 1;
const usersById = new Map(); // id -> {id, username, passwordHash}
const usersByUsername = new Map(); // username -> id
const sessions = new Map(); // token -> userId
const todosById = new Map(); // id -> {id, userId, title, description, completed, created_at, updated_at}

function sha256(s) {
  return crypto.createHash('sha256').update(s).digest('hex');
}

function newSessionToken() {
  return crypto.randomBytes(32).toString('hex');
}

function nowIsoSeconds() {
  return new Date().toISOString().replace(/\.\d{3}Z$/, 'Z');
}

function setJsonHeader(res, statusCode, extraHeaders={}) {
  const headers = Object.assign({ 'Content-Type': 'application/json' }, extraHeaders);
  res.writeHead(statusCode, headers);
}

function sendJson(res, statusCode, obj, extraHeaders={}) {
  const body = JSON.stringify(obj);
  const headers = Object.assign({ 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) }, extraHeaders);
  res.writeHead(statusCode, headers);
  res.end(body);
}

function sendError(res, statusCode, message) {
  sendJson(res, statusCode, { error: message });
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

function getAuthUser(req) {
  const cookies = parseCookies(req);
  const token = cookies['session_id'];
  if (!token) return null;
  const userId = sessions.get(token);
  if (!userId) return null;
  const user = usersById.get(userId);
  if (!user) return null;
  return { user, token };
}

function readJsonBody(req) {
  return new Promise((resolve, reject) => {
    let data = '';
    req.on('data', chunk => {
      data += chunk;
      // for safety limit body to 1MB
      if (data.length > 1_000_000) {
        reject(new Error('Payload too large'));
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

function ensureAuth(req, res) {
  const au = getAuthUser(req);
  if (!au) {
    sendError(res, 401, 'Authentication required');
    return null;
  }
  return au;
}

function toPublicUser(user) {
  return { id: user.id, username: user.username };
}

function toPublicTodo(todo) {
  return {
    id: todo.id,
    title: todo.title,
    description: todo.description,
    completed: todo.completed,
    created_at: todo.created_at,
    updated_at: todo.updated_at,
  };
}

function route(req, res) {
  const url = new URL(req.url, 'http://localhost');
  const method = req.method.toUpperCase();
  const path = url.pathname;

  // POST /register
  if (method === 'POST' && path === '/register') {
    readJsonBody(req).then(body => {
      const { username, password } = body || {};
      if (!validateUsername(username)) {
        return sendError(res, 400, 'Invalid username');
      }
      if (typeof password !== 'string' || password.length < 8) {
        return sendError(res, 400, 'Password too short');
      }
      if (usersByUsername.has(username)) {
        return sendError(res, 409, 'Username already exists');
      }
      const user = { id: nextUserId++, username, passwordHash: sha256(password) };
      usersById.set(user.id, user);
      usersByUsername.set(username, user.id);
      return sendJson(res, 201, toPublicUser(user));
    }).catch(err => {
      if (err.message === 'Invalid JSON') return sendError(res, 400, 'Invalid JSON');
      if (err.message === 'Payload too large') return sendError(res, 413, 'Payload too large');
      return sendError(res, 400, 'Invalid request');
    });
    return;
  }

  // POST /login
  if (method === 'POST' && path === '/login') {
    readJsonBody(req).then(body => {
      const { username, password } = body || {};
      const userId = usersByUsername.get(username);
      if (!userId) return sendError(res, 401, 'Invalid credentials');
      const user = usersById.get(userId);
      if (!user || user.passwordHash !== sha256(String(password))) {
        return sendError(res, 401, 'Invalid credentials');
      }
      const token = newSessionToken();
      sessions.set(token, user.id);
      const cookie = `session_id=${encodeURIComponent(token)}; Path=/; HttpOnly`;
      return sendJson(res, 200, toPublicUser(user), { 'Set-Cookie': cookie });
    }).catch(err => {
      if (err.message === 'Invalid JSON') return sendError(res, 400, 'Invalid JSON');
      if (err.message === 'Payload too large') return sendError(res, 413, 'Payload too large');
      return sendError(res, 400, 'Invalid request');
    });
    return;
  }

  // POST /logout
  if (method === 'POST' && path === '/logout') {
    const au = ensureAuth(req, res);
    if (!au) return;
    // Invalidate session token
    sessions.delete(au.token);
    return sendJson(res, 200, {});
  }

  // GET /me
  if (method === 'GET' && path === '/me') {
    const au = ensureAuth(req, res);
    if (!au) return;
    return sendJson(res, 200, toPublicUser(au.user));
  }

  // PUT /password
  if (method === 'PUT' && path === '/password') {
    const au = ensureAuth(req, res);
    if (!au) return;
    readJsonBody(req).then(body => {
      const { old_password, new_password } = body || {};
      if (au.user.passwordHash !== sha256(String(old_password))) {
        return sendError(res, 401, 'Invalid credentials');
      }
      if (typeof new_password !== 'string' || new_password.length < 8) {
        return sendError(res, 400, 'Password too short');
      }
      au.user.passwordHash = sha256(new_password);
      return sendJson(res, 200, {});
    }).catch(err => {
      if (err.message === 'Invalid JSON') return sendError(res, 400, 'Invalid JSON');
      if (err.message === 'Payload too large') return sendError(res, 413, 'Payload too large');
      return sendError(res, 400, 'Invalid request');
    });
    return;
  }

  // GET /todos
  if (method === 'GET' && path === '/todos') {
    const au = ensureAuth(req, res);
    if (!au) return;
    const list = [];
    for (const todo of todosById.values()) {
      if (todo.userId === au.user.id) list.push(toPublicTodo(todo));
    }
    list.sort((a, b) => a.id - b.id);
    return sendJson(res, 200, list);
  }

  // POST /todos
  if (method === 'POST' && path === '/todos') {
    const au = ensureAuth(req, res);
    if (!au) return;
    readJsonBody(req).then(body => {
      const title = body && typeof body.title === 'string' ? body.title : undefined;
      const description = body && typeof body.description === 'string' ? body.description : '';
      if (!title || title.trim().length === 0) {
        return sendError(res, 400, 'Title is required');
      }
      const now = nowIsoSeconds();
      const todo = {
        id: nextTodoId++,
        userId: au.user.id,
        title: title,
        description: description,
        completed: false,
        created_at: now,
        updated_at: now,
      };
      todosById.set(todo.id, todo);
      return sendJson(res, 201, toPublicTodo(todo));
    }).catch(err => {
      if (err.message === 'Invalid JSON') return sendError(res, 400, 'Invalid JSON');
      if (err.message === 'Payload too large') return sendError(res, 413, 'Payload too large');
      return sendError(res, 400, 'Invalid request');
    });
    return;
  }

  // GET /todos/:id, PUT /todos/:id, DELETE /todos/:id
  const todoIdMatch = path.match(/^\/todos\/(\d+)$/);
  if (todoIdMatch) {
    const id = parseInt(todoIdMatch[1], 10);
    const au = ensureAuth(req, res);
    if (!au) return;
    const todo = todosById.get(id);
    if (!todo || todo.userId !== au.user.id) {
      if (method === 'DELETE') {
        // DELETE should return 404 with JSON? Spec says for DELETE success returns no body, errors still JSON.
        return sendError(res, 404, 'Todo not found');
      } else {
        return sendError(res, 404, 'Todo not found');
      }
    }

    if (method === 'GET') {
      return sendJson(res, 200, toPublicTodo(todo));
    }

    if (method === 'PUT') {
      readJsonBody(req).then(body => {
        if (body && Object.prototype.hasOwnProperty.call(body, 'title')) {
          if (typeof body.title !== 'string' || body.title.trim().length === 0) {
            return sendError(res, 400, 'Title is required');
          }
          todo.title = body.title;
        }
        if (body && Object.prototype.hasOwnProperty.call(body, 'description')) {
          if (typeof body.description === 'string') {
            todo.description = body.description;
          } else {
            // if provided but not string, coerce to string
            todo.description = String(body.description);
          }
        }
        if (body && Object.prototype.hasOwnProperty.call(body, 'completed')) {
          todo.completed = Boolean(body.completed);
        }
        todo.updated_at = nowIsoSeconds();
        return sendJson(res, 200, toPublicTodo(todo));
      }).catch(err => {
        if (err.message === 'Invalid JSON') return sendError(res, 400, 'Invalid JSON');
        if (err.message === 'Payload too large') return sendError(res, 413, 'Payload too large');
        return sendError(res, 400, 'Invalid request');
      });
      return;
    }

    if (method === 'DELETE') {
      todosById.delete(id);
      res.writeHead(204);
      res.end();
      return;
    }
  }

  // Fallback 404
  sendError(res, 404, 'Not found');
}

function startServer(port) {
  const server = http.createServer((req, res) => {
    // Ensure we always send JSON content-type on all non-DELETE responses
    // We'll rely on sendJson/sendError for proper headers.
    route(req, res);
  });

  server.listen(port, '0.0.0.0', () => {
    console.log(`Server listening on 0.0.0.0:${port}`);
  });
}

if (require.main === module) {
  // parse --port PORT
  let port = 3000;
  const args = process.argv.slice(2);
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--port') {
      const p = parseInt(args[i+1], 10);
      if (!Number.isNaN(p)) port = p;
    }
  }
  startServer(port);
}

module.exports = { startServer };
