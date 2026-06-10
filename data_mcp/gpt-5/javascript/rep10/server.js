const http = require('http');
const crypto = require('crypto');
const { URL } = require('url');

// In-memory storage
const db = {
  users: new Map(), // id -> {id, username, passwordHash}
  usernames: new Map(), // username -> id
  todos: new Map(), // id -> {id, user_id, title, description, completed, created_at, updated_at}
  sessions: new Map(), // token -> user_id
  nextUserId: 1,
  nextTodoId: 1,
};

function uuidToken() {
  return crypto.randomBytes(16).toString('hex');
}

function hashPassword(pw) {
  return crypto.createHash('sha256').update(pw).digest('hex');
}

function nowIsoSeconds() {
  return new Date().toISOString().replace(/\.\d{3}Z$/, 'Z');
}

function parseCookies(header) {
  const cookies = {};
  if (!header) return cookies;
  const parts = header.split(';');
  for (const part of parts) {
    const [name, ...rest] = part.split('=');
    if (!name) continue;
    const key = name.trim();
    const value = rest.join('=').trim();
    if (key) cookies[key] = decodeURIComponent(value || '');
  }
  return cookies;
}

function readJsonBody(req) {
  return new Promise((resolve, reject) => {
    let data = '';
    req.on('data', chunk => {
      data += chunk;
      // Hard limit to avoid memory exhaustion; 1MB
      if (data.length > 1_000_000) {
        reject({ status: 413, error: { error: 'Payload too large' } });
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
        if (obj === null || typeof obj !== 'object' || Array.isArray(obj)) {
          reject({ status: 400, error: { error: 'Invalid JSON' } });
          return;
        }
        resolve(obj);
      } catch (e) {
        reject({ status: 400, error: { error: 'Invalid JSON' } });
      }
    });
    req.on('error', (err) => {
      reject({ status: 400, error: { error: 'Invalid request' } });
    });
  });
}

function sendJSON(res, statusCode, obj) {
  const body = JSON.stringify(obj);
  res.statusCode = statusCode;
  res.setHeader('Content-Type', 'application/json');
  res.setHeader('Content-Length', Buffer.byteLength(body));
  res.end(body);
}

function sendNoContent(res) {
  res.statusCode = 204;
  // No body as per spec for DELETE
  res.end();
}

function authenticate(req, res) {
  const cookies = parseCookies(req.headers['cookie']);
  const token = cookies['session_id'];
  if (!token) return null;
  const userId = db.sessions.get(token);
  if (!userId) return null;
  const user = db.users.get(userId);
  if (!user) return null;
  return { user, token };
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
      const url = new URL(req.url, 'http://localhost');
      const path = url.pathname;
      const method = req.method || 'GET';

      // Utility to require auth
      const requireAuth = () => {
        const auth = authenticate(req, res);
        if (!auth) {
          sendJSON(res, 401, { error: 'Authentication required' });
          return null;
        }
        return auth;
      };

      // Routing
      if (method === 'POST' && path === '/register') {
        let body;
        try { body = await readJsonBody(req); } catch (e) { return sendJSON(res, e.status || 400, e.error || { error: 'Invalid JSON' }); }
        const { username, password } = body;
        if (!validateUsername(username)) {
          return sendJSON(res, 400, { error: 'Invalid username' });
        }
        if (typeof password !== 'string' || password.length < 8) {
          return sendJSON(res, 400, { error: 'Password too short' });
        }
        if (db.usernames.has(username)) {
          return sendJSON(res, 409, { error: 'Username already exists' });
        }
        const id = db.nextUserId++;
        const user = { id, username, passwordHash: hashPassword(password) };
        db.users.set(id, user);
        db.usernames.set(username, id);
        return sendJSON(res, 201, { id, username });
      }

      if (method === 'POST' && path === '/login') {
        let body;
        try { body = await readJsonBody(req); } catch (e) { return sendJSON(res, e.status || 400, e.error || { error: 'Invalid JSON' }); }
        const { username, password } = body;
        const uid = db.usernames.get(username);
        if (!uid) {
          return sendJSON(res, 401, { error: 'Invalid credentials' });
        }
        const user = db.users.get(uid);
        if (!user || user.passwordHash !== hashPassword(password || '')) {
          return sendJSON(res, 401, { error: 'Invalid credentials' });
        }
        // Create session
        const token = uuidToken();
        db.sessions.set(token, user.id);
        res.setHeader('Set-Cookie', `session_id=${token}; Path=/; HttpOnly`);
        return sendJSON(res, 200, { id: user.id, username: user.username });
      }

      if (method === 'POST' && path === '/logout') {
        const auth = requireAuth();
        if (!auth) return; // response already sent
        // Invalidate session server-side
        if (auth.token) {
          db.sessions.delete(auth.token);
        }
        return sendJSON(res, 200, {});
      }

      if (method === 'GET' && path === '/me') {
        const auth = requireAuth();
        if (!auth) return;
        return sendJSON(res, 200, { id: auth.user.id, username: auth.user.username });
      }

      if (method === 'PUT' && path === '/password') {
        const auth = requireAuth();
        if (!auth) return;
        let body;
        try { body = await readJsonBody(req); } catch (e) { return sendJSON(res, e.status || 400, e.error || { error: 'Invalid JSON' }); }
        const { old_password, new_password } = body;
        if (auth.user.passwordHash !== hashPassword(old_password || '')) {
          return sendJSON(res, 401, { error: 'Invalid credentials' });
        }
        if (typeof new_password !== 'string' || new_password.length < 8) {
          return sendJSON(res, 400, { error: 'Password too short' });
        }
        auth.user.passwordHash = hashPassword(new_password);
        db.users.set(auth.user.id, auth.user);
        return sendJSON(res, 200, {});
      }

      if (method === 'GET' && path === '/todos') {
        const auth = requireAuth();
        if (!auth) return;
        const todos = [];
        for (const todo of db.todos.values()) {
          if (todo.user_id === auth.user.id) {
            const { user_id, ...rest } = todo;
            todos.push({ ...rest });
          }
        }
        todos.sort((a, b) => a.id - b.id);
        return sendJSON(res, 200, todos);
      }

      if (method === 'POST' && path === '/todos') {
        const auth = requireAuth();
        if (!auth) return;
        let body;
        try { body = await readJsonBody(req); } catch (e) { return sendJSON(res, e.status || 400, e.error || { error: 'Invalid JSON' }); }
        let { title, description } = body;
        if (typeof title !== 'string' || title.trim() === '') {
          return sendJSON(res, 400, { error: 'Title is required' });
        }
        if (typeof description !== 'string') description = '';
        const timestamp = nowIsoSeconds();
        const id = db.nextTodoId++;
        const todo = {
          id,
          user_id: auth.user.id,
          title: title,
          description: description,
          completed: false,
          created_at: timestamp,
          updated_at: timestamp,
        };
        db.todos.set(id, todo);
        const { user_id, ...publicTodo } = todo;
        return sendJSON(res, 201, publicTodo);
      }

      if (method === 'GET' && path.startsWith('/todos/')) {
        const auth = requireAuth();
        if (!auth) return;
        const idStr = path.split('/')[2];
        const id = parseInt(idStr, 10);
        if (!Number.isInteger(id)) {
          return sendJSON(res, 404, { error: 'Todo not found' });
        }
        const todo = db.todos.get(id);
        if (!todo || todo.user_id !== auth.user.id) {
          return sendJSON(res, 404, { error: 'Todo not found' });
        }
        const { user_id, ...publicTodo } = todo;
        return sendJSON(res, 200, publicTodo);
      }

      if (method === 'PUT' && path.startsWith('/todos/')) {
        const auth = requireAuth();
        if (!auth) return;
        const idStr = path.split('/')[2];
        const id = parseInt(idStr, 10);
        if (!Number.isInteger(id)) {
          return sendJSON(res, 404, { error: 'Todo not found' });
        }
        const todo = db.todos.get(id);
        if (!todo || todo.user_id !== auth.user.id) {
          return sendJSON(res, 404, { error: 'Todo not found' });
        }
        let body;
        try { body = await readJsonBody(req); } catch (e) { return sendJSON(res, e.status || 400, e.error || { error: 'Invalid JSON' }); }
        if (Object.prototype.hasOwnProperty.call(body, 'title')) {
          if (typeof body.title !== 'string' || body.title.trim() === '') {
            return sendJSON(res, 400, { error: 'Title is required' });
          }
          todo.title = body.title;
        }
        if (Object.prototype.hasOwnProperty.call(body, 'description')) {
          if (typeof body.description !== 'string') {
            // Coerce to string if not string? Spec says must be string. We'll enforce string.
            body.description = String(body.description);
          }
          todo.description = body.description;
        }
        if (Object.prototype.hasOwnProperty.call(body, 'completed')) {
          if (typeof body.completed !== 'boolean') {
            // Attempt to coerce: only accept boolean strictly as spec
            return sendJSON(res, 400, { error: 'Invalid JSON' });
          }
          todo.completed = body.completed;
        }
        todo.updated_at = nowIsoSeconds();
        db.todos.set(id, todo);
        const { user_id, ...publicTodo } = todo;
        return sendJSON(res, 200, publicTodo);
      }

      if (method === 'DELETE' && path.startsWith('/todos/')) {
        const auth = authenticate(req, res);
        if (!auth) {
          // For DELETE, still must return 401 JSON? Spec says all responses MUST have JSON except DELETE returns no body on success. For errors, still JSON.
          return sendJSON(res, 401, { error: 'Authentication required' });
        }
        const idStr = path.split('/')[2];
        const id = parseInt(idStr, 10);
        const todo = Number.isInteger(id) ? db.todos.get(id) : null;
        if (!todo || todo.user_id !== auth.user.id) {
          return sendJSON(res, 404, { error: 'Todo not found' });
        }
        db.todos.delete(id);
        return sendNoContent(res);
      }

      // Unknown route
      sendJSON(res, 404, { error: 'Not found' });
    } catch (err) {
      try {
        sendJSON(res, 500, { error: 'Internal server error' });
      } catch (_) {
        // ignore
      }
      // Also log server-side for debugging
      console.error('Unhandled error:', err);
    }
  });
  return server;
}

function parseArgs(argv) {
  const args = { port: process.env.PORT ? parseInt(process.env.PORT, 10) : undefined };
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--port' && i + 1 < argv.length) {
      args.port = parseInt(argv[i + 1], 10);
      i++;
    }
  }
  if (!args.port || !Number.isInteger(args.port)) {
    args.port = 3000;
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
