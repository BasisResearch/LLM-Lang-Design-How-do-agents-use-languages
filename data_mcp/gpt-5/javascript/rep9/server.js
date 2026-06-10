const http = require('http');
const crypto = require('crypto');
const { URL } = require('url');

// In-memory storage
const state = {
  users: [], // {id, username, password}
  todos: [], // {id, userId, title, description, completed, created_at, updated_at}
  sessions: new Map(), // token -> userId
  nextUserId: 1,
  nextTodoId: 1,
};

function nowIsoSeconds() {
  return new Date().toISOString().replace(/\.\d{3}Z$/, 'Z');
}

function sendJson(res, statusCode, obj) {
  const body = JSON.stringify(obj);
  res.statusCode = statusCode;
  res.setHeader('Content-Type', 'application/json');
  res.setHeader('Content-Length', Buffer.byteLength(body));
  res.end(body);
}

function sendNoContent(res) {
  res.statusCode = 204;
  // No body, and per spec, DELETE returns no body; omit Content-Type.
  res.end();
}

function readJson(req) {
  return new Promise((resolve, reject) => {
    let data = '';
    req.on('data', chunk => {
      data += chunk;
      // limit to 1MB to avoid abuse
      if (data.length > 1e6) {
        req.destroy();
        reject(new Error('Payload too large'));
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
    req.on('error', (err) => reject(err));
  });
}

function parseCookies(req) {
  const header = req.headers['cookie'];
  const cookies = {};
  if (!header) return cookies;
  const parts = header.split(';');
  for (const part of parts) {
    const [k, v] = part.split('=');
    if (k && v !== undefined) {
      cookies[k.trim()] = decodeURIComponent(v.trim());
    }
  }
  return cookies;
}

function requireAuth(req, res) {
  const cookies = parseCookies(req);
  const token = cookies['session_id'];
  if (!token) {
    sendJson(res, 401, { error: 'Authentication required' });
    return null;
  }
  const userId = state.sessions.get(token);
  if (!userId) {
    sendJson(res, 401, { error: 'Authentication required' });
    return null;
  }
  const user = state.users.find(u => u.id === userId);
  if (!user) {
    // Should not happen, but treat as unauthenticated
    sendJson(res, 401, { error: 'Authentication required' });
    return null;
  }
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
    // Ensure we always set JSON content-type for all responses except DELETE 204.
    // We'll set headers right before sending.
    try {
      const url = new URL(req.url, 'http://localhost');
      const method = req.method || 'GET';
      const path = url.pathname;

      // CORS not required; keep minimal. Ensure only JSON content.

      // Routing
      if (method === 'POST' && path === '/register') {
        let body;
        try { body = await readJson(req); } catch (e) { return sendJson(res, 400, { error: 'Invalid JSON' }); }
        const { username, password } = body || {};
        if (!validateUsername(username)) {
          return sendJson(res, 400, { error: 'Invalid username' });
        }
        if (typeof password !== 'string' || password.length < 8) {
          return sendJson(res, 400, { error: 'Password too short' });
        }
        const existing = state.users.find(u => u.username.toLowerCase() === String(username).toLowerCase());
        if (existing) {
          return sendJson(res, 409, { error: 'Username already exists' });
        }
        const newUser = { id: state.nextUserId++, username: String(username), password: String(password) };
        state.users.push(newUser);
        return sendJson(res, 201, { id: newUser.id, username: newUser.username });
      }

      if (method === 'POST' && path === '/login') {
        let body;
        try { body = await readJson(req); } catch (e) { return sendJson(res, 400, { error: 'Invalid JSON' }); }
        const { username, password } = body || {};
        const user = state.users.find(u => u.username === username);
        if (!user || user.password !== password) {
          return sendJson(res, 401, { error: 'Invalid credentials' });
        }
        const token = crypto.randomBytes(16).toString('hex');
        state.sessions.set(token, user.id);
        res.setHeader('Set-Cookie', `session_id=${token}; Path=/; HttpOnly`);
        return sendJson(res, 200, { id: user.id, username: user.username });
      }

      if (method === 'POST' && path === '/logout') {
        const auth = requireAuth(req, res);
        if (!auth) return; // response already sent
        // Invalidate session
        state.sessions.delete(auth.token);
        return sendJson(res, 200, {});
      }

      if (method === 'GET' && path === '/me') {
        const auth = requireAuth(req, res);
        if (!auth) return;
        const { user } = auth;
        return sendJson(res, 200, { id: user.id, username: user.username });
      }

      if (method === 'PUT' && path === '/password') {
        const auth = requireAuth(req, res);
        if (!auth) return;
        let body;
        try { body = await readJson(req); } catch (e) { return sendJson(res, 400, { error: 'Invalid JSON' }); }
        const { old_password, new_password } = body || {};
        if (auth.user.password !== old_password) {
          return sendJson(res, 401, { error: 'Invalid credentials' });
        }
        if (typeof new_password !== 'string' || new_password.length < 8) {
          return sendJson(res, 400, { error: 'Password too short' });
        }
        auth.user.password = new_password;
        return sendJson(res, 200, {});
      }

      if (method === 'GET' && path === '/todos') {
        const auth = requireAuth(req, res);
        if (!auth) return;
        const list = state.todos.filter(t => t.userId === auth.user.id).sort((a, b) => a.id - b.id).map(stripTodoUserId);
        return sendJson(res, 200, list);
      }

      if (method === 'POST' && path === '/todos') {
        const auth = requireAuth(req, res);
        if (!auth) return;
        let body;
        try { body = await readJson(req); } catch (e) { return sendJson(res, 400, { error: 'Invalid JSON' }); }
        const title = body && body.title;
        const description = (body && typeof body.description === 'string') ? body.description : '';
        if (typeof title !== 'string' || title.trim() === '') {
          return sendJson(res, 400, { error: 'Title is required' });
        }
        const timestamp = nowIsoSeconds();
        const todo = {
          id: state.nextTodoId++,
          userId: auth.user.id,
          title: String(title),
          description: description,
          completed: false,
          created_at: timestamp,
          updated_at: timestamp,
        };
        state.todos.push(todo);
        return sendJson(res, 201, stripTodoUserId(todo));
      }

      const todoIdMatch = path.match(/^\/todos\/(\d+)$/);
      if (todoIdMatch) {
        const id = parseInt(todoIdMatch[1], 10);
        const auth = requireAuth(req, res);
        if (!auth) return;
        const todo = state.todos.find(t => t.id === id);
        if (!todo || todo.userId !== auth.user.id) {
          if (method === 'DELETE') {
            // DELETE requires 404 with JSON body? Spec says DELETE returns no body on success; for errors, JSON.
            return sendJson(res, 404, { error: 'Todo not found' });
          }
          return sendJson(res, 404, { error: 'Todo not found' });
        }
        if (method === 'GET') {
          return sendJson(res, 200, stripTodoUserId(todo));
        } else if (method === 'PUT') {
          let body;
          try { body = await readJson(req); } catch (e) { return sendJson(res, 400, { error: 'Invalid JSON' }); }
          if (body && Object.prototype.hasOwnProperty.call(body, 'title')) {
            const t = body.title;
            if (typeof t !== 'string' || t.trim() === '') {
              return sendJson(res, 400, { error: 'Title is required' });
            }
            todo.title = t;
          }
          if (body && Object.prototype.hasOwnProperty.call(body, 'description')) {
            const d = body.description;
            if (typeof d !== 'string') {
              // Coerce to string per simplicity
              todo.description = String(d);
            } else {
              todo.description = d;
            }
          }
          if (body && Object.prototype.hasOwnProperty.call(body, 'completed')) {
            const c = body.completed;
            todo.completed = Boolean(c);
          }
          todo.updated_at = nowIsoSeconds();
          return sendJson(res, 200, stripTodoUserId(todo));
        } else if (method === 'DELETE') {
          const idx = state.todos.findIndex(t => t.id === id);
          if (idx === -1) {
            return sendJson(res, 404, { error: 'Todo not found' });
          }
          state.todos.splice(idx, 1);
          return sendNoContent(res);
        }
      }

      // Fallback 404
      return sendJson(res, 404, { error: 'Not found' });
    } catch (err) {
      // Internal error: return 500 JSON
      try {
        sendJson(res, 500, { error: 'Internal server error' });
      } catch (_) { /* ignore */ }
      return;
    }
  });
  return server;
}

function stripTodoUserId(todo) {
  return {
    id: todo.id,
    title: todo.title,
    description: todo.description,
    completed: todo.completed,
    created_at: todo.created_at,
    updated_at: todo.updated_at,
  };
}

function parseArgs(argv) {
  const out = { port: 3000 };
  for (let i = 2; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === '--port') {
      const val = argv[i + 1];
      i++;
      if (!val || isNaN(parseInt(val, 10))) {
        throw new Error('Invalid --port');
      }
      out.port = parseInt(val, 10);
    }
  }
  return out;
}

if (require.main === module) {
  const { port } = parseArgs(process.argv);
  const server = createServer();
  server.listen(port, '0.0.0.0', () => {
    console.log(`Server listening on 0.0.0.0:${port}`);
  });
}

module.exports = { createServer };
