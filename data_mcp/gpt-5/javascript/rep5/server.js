const http = require('http');
const crypto = require('crypto');
const { URL } = require('url');

// In-memory storage
const db = {
  users: [], // {id, username, passwordHash, salt}
  todos: [], // {id, userId, title, description, completed, created_at, updated_at}
  sessions: new Map(), // token -> userId
  nextUserId: 1,
  nextTodoId: 1,
};

function sendJSON(res, statusCode, obj) {
  const body = JSON.stringify(obj);
  res.statusCode = statusCode;
  res.setHeader('Content-Type', 'application/json');
  res.setHeader('Content-Length', Buffer.byteLength(body));
  res.end(body);
}

function sendNoContent(res, statusCode = 204) {
  res.statusCode = statusCode;
  // No body and no Content-Type for 204 per spec
  res.end();
}

function parseCookies(header) {
  const out = {};
  if (!header) return out;
  const parts = header.split(';');
  for (const part of parts) {
    const [k, v] = part.split('=');
    if (!k || v === undefined) continue;
    const key = k.trim();
    const val = v.trim();
    out[key] = decodeURIComponent(val);
  }
  return out;
}

function readBody(req, limit = 1 * 1024 * 1024) {
  return new Promise((resolve, reject) => {
    let data = '';
    let size = 0;
    req.on('data', (chunk) => {
      size += chunk.length;
      if (size > limit) {
        reject(new Error('Payload too large'));
        req.destroy();
        return;
      }
      data += chunk;
    });
    req.on('end', () => resolve(data));
    req.on('error', reject);
  });
}

function jsonBody(req) {
  return readBody(req).then((data) => {
    if (!data) return {};
    try {
      return JSON.parse(data);
    } catch (e) {
      const err = new Error('Invalid JSON');
      err.code = 'INVALID_JSON';
      throw err;
    }
  });
}

function nowIsoSeconds() {
  // ISO 8601 UTC timestamp with second precision: YYYY-MM-DDTHH:MM:SSZ
  const s = new Date().toISOString();
  return s.slice(0, 19) + 'Z';
}

function validateUsername(u) {
  if (typeof u !== 'string') return false;
  if (u.length < 3 || u.length > 50) return false;
  if (!/^[a-zA-Z0-9_]+$/.test(u)) return false;
  return true;
}

function validatePassword(p) {
  if (typeof p !== 'string') return false;
  if (p.length < 8) return false;
  return true;
}

function hashPassword(password, salt) {
  // Use scrypt with 64 bytes output
  const N = 16384; // default cost
  const r = 8;
  const p = 1;
  const keylen = 64;
  const buf = crypto.scryptSync(password, salt, keylen, { N, r, p });
  return buf.toString('hex');
}

function createUser(username, password) {
  const id = db.nextUserId++;
  const salt = crypto.randomBytes(16).toString('hex');
  const passwordHash = hashPassword(password, salt);
  const user = { id, username, passwordHash, salt };
  db.users.push(user);
  return { id: user.id, username: user.username };
}

function findUserByUsername(username) {
  return db.users.find((u) => u.username === username) || null;
}

function verifyPassword(user, password) {
  const h = hashPassword(password, user.salt);
  return crypto.timingSafeEqual(Buffer.from(h, 'hex'), Buffer.from(user.passwordHash, 'hex'));
}

function createSession(userId) {
  const token = crypto.randomBytes(16).toString('hex');
  db.sessions.set(token, userId);
  return token;
}

function getUserFromRequest(req) {
  const cookies = parseCookies(req.headers['cookie']);
  const token = cookies['session_id'];
  if (!token) return { user: null, token: null };
  const userId = db.sessions.get(token);
  if (!userId) return { user: null, token };
  const user = db.users.find((u) => u.id === userId) || null;
  return { user, token };
}

function requireAuth(req, res) {
  const { user, token } = getUserFromRequest(req);
  if (!user) {
    sendJSON(res, 401, { error: 'Authentication required' });
    return null;
  }
  return { user, token };
}

function toPublicUser(u) {
  return { id: u.id, username: u.username };
}

function route(req, res) {
  const url = new URL(req.url, 'http://localhost');
  const method = req.method || 'GET';
  const path = url.pathname;

  // Routing
  if (method === 'POST' && path === '/register') return handleRegister(req, res);
  if (method === 'POST' && path === '/login') return handleLogin(req, res);
  if (method === 'POST' && path === '/logout') return handleLogout(req, res);
  if (method === 'GET' && path === '/me') return handleMe(req, res);
  if (method === 'PUT' && path === '/password') return handlePassword(req, res);
  if (method === 'GET' && path === '/todos') return handleTodosList(req, res);
  if (method === 'POST' && path === '/todos') return handleTodosCreate(req, res);
  const todoIdMatch = path.match(/^\/todos\/(\d+)$/);
  if (todoIdMatch) {
    const id = parseInt(todoIdMatch[1], 10);
    if (method === 'GET') return handleTodosGet(req, res, id);
    if (method === 'PUT') return handleTodosUpdate(req, res, id);
    if (method === 'DELETE') return handleTodosDelete(req, res, id);
  }

  // Not found
  sendJSON(res, 404, { error: 'Not found' });
}

async function handleRegister(req, res) {
  try {
    const body = await jsonBody(req);
    const { username, password } = body || {};
    if (!validateUsername(username)) {
      return sendJSON(res, 400, { error: 'Invalid username' });
    }
    if (!validatePassword(password)) {
      return sendJSON(res, 400, { error: 'Password too short' });
    }
    if (findUserByUsername(username)) {
      return sendJSON(res, 409, { error: 'Username already exists' });
    }
    const pub = createUser(username, password);
    return sendJSON(res, 201, pub);
  } catch (e) {
    if (e && e.code === 'INVALID_JSON') {
      return sendJSON(res, 400, { error: 'Invalid JSON' });
    }
    return sendJSON(res, 500, { error: 'Internal server error' });
  }
}

async function handleLogin(req, res) {
  try {
    const body = await jsonBody(req);
    const { username, password } = body || {};
    const user = findUserByUsername(username);
    if (!user || !verifyPassword(user, password || '')) {
      return sendJSON(res, 401, { error: 'Invalid credentials' });
    }
    const token = createSession(user.id);
    res.setHeader('Set-Cookie', `session_id=${token}; Path=/; HttpOnly`);
    return sendJSON(res, 200, toPublicUser(user));
  } catch (e) {
    if (e && e.code === 'INVALID_JSON') {
      return sendJSON(res, 400, { error: 'Invalid JSON' });
    }
    return sendJSON(res, 500, { error: 'Internal server error' });
  }
}

async function handleLogout(req, res) {
  const auth = requireAuth(req, res);
  if (!auth) return; // response already sent
  const { token } = auth;
  if (token) db.sessions.delete(token);
  return sendJSON(res, 200, {});
}

async function handleMe(req, res) {
  const auth = requireAuth(req, res);
  if (!auth) return;
  return sendJSON(res, 200, toPublicUser(auth.user));
}

async function handlePassword(req, res) {
  const auth = requireAuth(req, res);
  if (!auth) return;
  try {
    const body = await jsonBody(req);
    const { old_password, new_password } = body || {};
    if (!verifyPassword(auth.user, old_password || '')) {
      return sendJSON(res, 401, { error: 'Invalid credentials' });
    }
    if (!validatePassword(new_password)) {
      return sendJSON(res, 400, { error: 'Password too short' });
    }
    // update
    const salt = crypto.randomBytes(16).toString('hex');
    const passwordHash = hashPassword(new_password, salt);
    auth.user.salt = salt;
    auth.user.passwordHash = passwordHash;
    return sendJSON(res, 200, {});
  } catch (e) {
    if (e && e.code === 'INVALID_JSON') {
      return sendJSON(res, 400, { error: 'Invalid JSON' });
    }
    return sendJSON(res, 500, { error: 'Internal server error' });
  }
}

async function handleTodosList(req, res) {
  const auth = requireAuth(req, res);
  if (!auth) return;
  const list = db.todos
    .filter((t) => t.userId === auth.user.id)
    .sort((a, b) => a.id - b.id)
    .map(todoPublicView);
  return sendJSON(res, 200, list);
}

function todoPublicView(t) {
  return {
    id: t.id,
    title: t.title,
    description: t.description,
    completed: t.completed,
    created_at: t.created_at,
    updated_at: t.updated_at,
  };
}

async function handleTodosCreate(req, res) {
  const auth = requireAuth(req, res);
  if (!auth) return;
  try {
    const body = await jsonBody(req);
    const title = body && typeof body.title === 'string' ? body.title : undefined;
    if (!title || title.trim() === '') {
      return sendJSON(res, 400, { error: 'Title is required' });
    }
    const description = body && typeof body.description === 'string' ? body.description : '';
    const id = db.nextTodoId++;
    const ts = nowIsoSeconds();
    const todo = {
      id,
      userId: auth.user.id,
      title: title,
      description: description,
      completed: false,
      created_at: ts,
      updated_at: ts,
    };
    db.todos.push(todo);
    return sendJSON(res, 201, todoPublicView(todo));
  } catch (e) {
    if (e && e.code === 'INVALID_JSON') {
      return sendJSON(res, 400, { error: 'Invalid JSON' });
    }
    return sendJSON(res, 500, { error: 'Internal server error' });
  }
}

async function handleTodosGet(req, res, id) {
  const auth = requireAuth(req, res);
  if (!auth) return;
  const todo = db.todos.find((t) => t.id === id);
  if (!todo || todo.userId !== auth.user.id) {
    return sendJSON(res, 404, { error: 'Todo not found' });
  }
  return sendJSON(res, 200, todoPublicView(todo));
}

async function handleTodosUpdate(req, res, id) {
  const auth = requireAuth(req, res);
  if (!auth) return;
  const todo = db.todos.find((t) => t.id === id);
  if (!todo || todo.userId !== auth.user.id) {
    return sendJSON(res, 404, { error: 'Todo not found' });
  }
  try {
    const body = await jsonBody(req);
    if (Object.prototype.hasOwnProperty.call(body || {}, 'title')) {
      const title = body.title;
      if (typeof title !== 'string' || title.trim() === '') {
        return sendJSON(res, 400, { error: 'Title is required' });
      }
      todo.title = title;
    }
    if (Object.prototype.hasOwnProperty.call(body || {}, 'description')) {
      const desc = body.description;
      if (typeof desc === 'string') {
        todo.description = desc;
      }
    }
    if (Object.prototype.hasOwnProperty.call(body || {}, 'completed')) {
      const comp = body.completed;
      if (typeof comp === 'boolean') {
        todo.completed = comp;
      }
    }
    todo.updated_at = nowIsoSeconds();
    return sendJSON(res, 200, todoPublicView(todo));
  } catch (e) {
    if (e && e.code === 'INVALID_JSON') {
      return sendJSON(res, 400, { error: 'Invalid JSON' });
    }
    return sendJSON(res, 500, { error: 'Internal server error' });
  }
}

async function handleTodosDelete(req, res, id) {
  const auth = requireAuth(req, res);
  if (!auth) return;
  const idx = db.todos.findIndex((t) => t.id === id);
  if (idx === -1 || db.todos[idx].userId !== auth.user.id) {
    return sendJSON(res, 404, { error: 'Todo not found' });
  }
  db.todos.splice(idx, 1);
  return sendNoContent(res, 204);
}

function startServer(port) {
  const server = http.createServer((req, res) => {
    // Ensure we always handle unexpected errors gracefully
    try {
      route(req, res);
    } catch (e) {
      try {
        sendJSON(res, 500, { error: 'Internal server error' });
      } catch (_) {
        res.statusCode = 500;
        res.end();
      }
    }
  });

  server.listen(port, '0.0.0.0', () => {
    // eslint-disable-next-line no-console
    console.log(`Server listening on 0.0.0.0:${port}`);
  });

  return server;
}

if (require.main === module) {
  // CLI parsing
  let port = 3000;
  const args = process.argv.slice(2);
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--port' && i + 1 < args.length) {
      const p = parseInt(args[i + 1], 10);
      if (!Number.isNaN(p) && p > 0 && p < 65536) {
        port = p;
        i++;
      }
    }
  }
  startServer(port);
}

module.exports = { startServer };
