const http = require('http');
const { URL } = require('url');
const crypto = require('crypto');

// In-memory storage
const users = []; // {id, username, password}
const usersByUsername = new Map(); // username -> user
let nextUserId = 1;

const sessions = new Map(); // token -> userId

const todos = []; // {id, userId, title, description, completed, created_at, updated_at}
let nextTodoId = 1;

function isoNowSeconds(date = new Date()) {
  const d = new Date(Math.floor(date.getTime() / 1000) * 1000);
  return d.toISOString().replace(/\.\d{3}Z$/, 'Z');
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
    cookies[key] = val;
  }
  return cookies;
}

function sendJson(res, statusCode, data, extraHeaders = {}) {
  const body = JSON.stringify(data);
  res.writeHead(statusCode, {
    'Content-Type': 'application/json',
    'Content-Length': Buffer.byteLength(body),
    ...extraHeaders,
  });
  res.end(body);
}

function sendError(res, status, message) {
  sendJson(res, status, { error: message });
}

function notFound(res) {
  sendError(res, 404, 'Not found');
}

function getRequestBody(req, limit = 1 * 1024 * 1024) {
  return new Promise((resolve, reject) => {
    let total = 0;
    const chunks = [];
    req.on('data', (chunk) => {
      total += chunk.length;
      if (total > limit) {
        reject(new Error('Body too large'));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => {
      const buf = Buffer.concat(chunks);
      resolve(buf);
    });
    req.on('error', (err) => reject(err));
  });
}

async function getJson(req, res) {
  try {
    const buf = await getRequestBody(req);
    if (!buf || buf.length === 0) return {};
    const str = buf.toString('utf8').trim();
    if (str === '') return {};
    try {
      return JSON.parse(str);
    } catch (e) {
      sendError(res, 400, 'Invalid JSON');
      return null;
    }
  } catch (e) {
    sendError(res, 400, 'Invalid JSON');
    return null;
  }
}

function authenticate(req, res) {
  const cookies = parseCookies(req);
  const token = cookies['session_id'];
  if (!token) {
    sendError(res, 401, 'Authentication required');
    return null;
  }
  const userId = sessions.get(token);
  if (!userId) {
    sendError(res, 401, 'Authentication required');
    return null;
  }
  const user = users.find((u) => u.id === userId);
  if (!user) {
    // Remove stale session mapping if user does not exist
    sessions.delete(token);
    sendError(res, 401, 'Authentication required');
    return null;
  }
  return { user, token };
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

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
    const method = req.method || 'GET';
    const path = url.pathname || '/';

    // Routing
    if (method === 'POST' && path === '/register') {
      const body = await getJson(req, res);
      if (body == null) return; // error already sent
      const { username, password } = body;
      const usernameRegex = /^[a-zA-Z0-9_]+$/;
      if (!username || typeof username !== 'string' || username.length < 3 || username.length > 50 || !usernameRegex.test(username)) {
        return sendError(res, 400, 'Invalid username');
      }
      if (!password || typeof password !== 'string' || password.length < 8) {
        return sendError(res, 400, 'Password too short');
      }
      if (usersByUsername.has(username)) {
        return sendError(res, 409, 'Username already exists');
      }
      const user = { id: nextUserId++, username, password };
      users.push(user);
      usersByUsername.set(username, user);
      return sendJson(res, 201, { id: user.id, username: user.username });
    }

    if (method === 'POST' && path === '/login') {
      const body = await getJson(req, res);
      if (body == null) return;
      const { username, password } = body || {};
      const user = typeof username === 'string' ? usersByUsername.get(username) : undefined;
      if (!user || user.password !== password) {
        return sendError(res, 401, 'Invalid credentials');
      }
      const token = crypto.randomBytes(16).toString('hex');
      sessions.set(token, user.id);
      const headers = { 'Set-Cookie': `session_id=${token}; Path=/; HttpOnly` };
      return sendJson(res, 200, { id: user.id, username: user.username }, headers);
    }

    if (method === 'POST' && path === '/logout') {
      const auth = authenticate(req, res);
      if (!auth) return;
      // Invalidate only current session token
      sessions.delete(auth.token);
      return sendJson(res, 200, {});
    }

    if (method === 'GET' && path === '/me') {
      const auth = authenticate(req, res);
      if (!auth) return;
      return sendJson(res, 200, { id: auth.user.id, username: auth.user.username });
    }

    if (method === 'PUT' && path === '/password') {
      const auth = authenticate(req, res);
      if (!auth) return;
      const body = await getJson(req, res);
      if (body == null) return;
      const { old_password, new_password } = body;
      if (typeof old_password !== 'string' || auth.user.password !== old_password) {
        return sendError(res, 401, 'Invalid credentials');
      }
      if (!new_password || typeof new_password !== 'string' || new_password.length < 8) {
        return sendError(res, 400, 'Password too short');
      }
      auth.user.password = new_password;
      return sendJson(res, 200, {});
    }

    if (method === 'GET' && path === '/todos') {
      const auth = authenticate(req, res);
      if (!auth) return;
      const list = todos
        .filter((t) => t.userId === auth.user.id)
        .sort((a, b) => a.id - b.id)
        .map(todoPublicView);
      return sendJson(res, 200, list);
    }

    if (method === 'POST' && path === '/todos') {
      const auth = authenticate(req, res);
      if (!auth) return;
      const body = await getJson(req, res);
      if (body == null) return;
      let { title, description } = body;
      if (typeof title !== 'string' || title.trim() === '') {
        return sendError(res, 400, 'Title is required');
      }
      if (typeof description !== 'string') description = '';
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
      return sendJson(res, 201, todoPublicView(todo));
    }

    if ((method === 'GET' || method === 'PUT' || method === 'DELETE') && path.startsWith('/todos/')) {
      const auth = authenticate(req, res);
      if (!auth) return;
      const idStr = path.slice('/todos/'.length);
      const id = parseInt(idStr, 10);
      if (!Number.isInteger(id)) {
        return sendError(res, 404, 'Todo not found');
      }
      const todo = todos.find((t) => t.id === id);
      if (!todo || todo.userId !== auth.user.id) {
        return sendError(res, 404, 'Todo not found');
      }

      if (method === 'GET') {
        return sendJson(res, 200, todoPublicView(todo));
      }

      if (method === 'PUT') {
        const body = await getJson(req, res);
        if (body == null) return;
        if (Object.prototype.hasOwnProperty.call(body, 'title')) {
          if (typeof body.title !== 'string' || body.title.trim() === '') {
            return sendError(res, 400, 'Title is required');
          }
          todo.title = body.title;
        }
        if (Object.prototype.hasOwnProperty.call(body, 'description')) {
          if (typeof body.description === 'string') {
            todo.description = body.description;
          } else {
            // if provided but not string, coerce to string
            todo.description = String(body.description);
          }
        }
        if (Object.prototype.hasOwnProperty.call(body, 'completed')) {
          if (typeof body.completed !== 'boolean') {
            // Enforce boolean type
            return sendError(res, 400, 'Invalid JSON');
          }
          todo.completed = body.completed;
        }
        todo.updated_at = isoNowSeconds();
        return sendJson(res, 200, todoPublicView(todo));
      }

      if (method === 'DELETE') {
        const idx = todos.findIndex((t) => t.id === id);
        if (idx !== -1) {
          todos.splice(idx, 1);
        }
        // 204 No Content, no body
        res.writeHead(204);
        return res.end();
      }
    }

    return notFound(res);
  } catch (err) {
    try {
      sendError(res, 500, 'Internal server error');
    } catch (_) {
      // ignore
    }
  }
});

function parseArgs(argv) {
  const args = { port: 3000 };
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--port') {
      const p = parseInt(argv[i + 1], 10);
      if (!Number.isFinite(p)) {
        throw new Error('Invalid port');
      }
      args.port = p;
      i += 1;
    }
  }
  return args;
}

function start() {
  const { port } = parseArgs(process.argv);
  server.listen(port, '0.0.0.0', () => {
    // eslint-disable-next-line no-console
    console.log(`Server listening on 0.0.0.0:${port}`);
  });
}

if (require.main === module) {
  start();
}

module.exports = { start, server, _state: { users, usersByUsername, sessions, todos } };
