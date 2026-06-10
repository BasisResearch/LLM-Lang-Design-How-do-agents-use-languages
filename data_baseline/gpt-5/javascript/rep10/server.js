const http = require('http');
const crypto = require('crypto');
const { URL } = require('url');

// In-memory storage
const state = {
  usersById: new Map(), // id -> {id, username, password}
  userIdByUsername: new Map(), // username -> id
  nextUserId: 1,

  todosById: new Map(), // id -> {id, userId, title, description, completed, created_at, updated_at}
  nextTodoId: 1,

  sessions: new Map(), // token -> userId
};

function formatTimestamp(date = new Date()) {
  // ISO 8601 UTC with second precision
  const d = new Date(date.getTime());
  const iso = d.toISOString(); // e.g., 2025-01-15T09:30:00.000Z
  return iso.replace(/\..+Z$/, 'Z');
}

function parseCookies(header) {
  const cookies = {};
  if (!header) return cookies;
  const parts = header.split(';');
  for (const part of parts) {
    const [name, ...rest] = part.trim().split('=');
    if (!name) continue;
    const value = rest.join('=');
    if (name) cookies[name] = decodeURIComponent(value || '');
  }
  return cookies;
}

function readJsonBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let length = 0;
    req.on('data', (chunk) => {
      chunks.push(chunk);
      length += chunk.length;
      if (length > 1e6) { // 1MB limit safety
        reject({ code: 413, error: { error: 'Payload too large' } });
        req.destroy();
      }
    });
    req.on('end', () => {
      const raw = Buffer.concat(chunks).toString('utf8');
      if (raw.length === 0) {
        resolve({});
        return;
      }
      try {
        const obj = JSON.parse(raw);
        resolve(obj);
      } catch (e) {
        reject({ code: 400, error: { error: 'Invalid JSON' } });
      }
    });
    req.on('error', (err) => {
      reject({ code: 400, error: { error: 'Invalid request' } });
    });
  });
}

function sendJson(res, statusCode, obj, extraHeaders = {}) {
  const body = JSON.stringify(obj);
  const headers = Object.assign({
    'Content-Type': 'application/json',
    'Content-Length': Buffer.byteLength(body),
  }, extraHeaders);
  res.writeHead(statusCode, headers);
  res.end(body);
}

function sendError(res, statusCode, message) {
  sendJson(res, statusCode, { error: message });
}

function authUser(req) {
  const cookies = parseCookies(req.headers['cookie']);
  const token = cookies['session_id'];
  if (!token) return null;
  const userId = state.sessions.get(token);
  if (!userId) return null;
  const user = state.usersById.get(userId);
  if (!user) return null;
  return { user, token };
}

function notFound(res) {
  sendError(res, 404, 'Not found');
}

function createServer() {
  const server = http.createServer(async (req, res) => {
    // Ensure we always catch unhandled errors and respond with JSON
    try {
      const u = new URL(req.url, 'http://localhost');
      const method = req.method || 'GET';
      const path = u.pathname || '/';

      // Helper: require authentication
      const requireAuth = () => {
        const auth = authUser(req);
        if (!auth) {
          sendError(res, 401, 'Authentication required');
          return null;
        }
        return auth;
      };

      // Routing
      if (method === 'POST' && path === '/register') {
        let body;
        try { body = await readJsonBody(req); } catch (err) { return sendJson(res, err.code || 400, err.error || { error: 'Invalid JSON' }); }
        const username = typeof body.username === 'string' ? body.username : '';
        const password = typeof body.password === 'string' ? body.password : '';

        const usernameRegex = /^[a-zA-Z0-9_]{3,50}$/;
        if (!username || !usernameRegex.test(username)) {
          return sendError(res, 400, 'Invalid username');
        }
        if (!password || password.length < 8) {
          return sendError(res, 400, 'Password too short');
        }
        if (state.userIdByUsername.has(username)) {
          return sendError(res, 409, 'Username already exists');
        }
        const id = state.nextUserId++;
        const user = { id, username, password };
        state.usersById.set(id, user);
        state.userIdByUsername.set(username, id);
        return sendJson(res, 201, { id, username });
      }

      if (method === 'POST' && path === '/login') {
        let body;
        try { body = await readJsonBody(req); } catch (err) { return sendJson(res, err.code || 400, err.error || { error: 'Invalid JSON' }); }
        const username = typeof body.username === 'string' ? body.username : '';
        const password = typeof body.password === 'string' ? body.password : '';
        const userId = state.userIdByUsername.get(username);
        if (!userId) {
          return sendError(res, 401, 'Invalid credentials');
        }
        const user = state.usersById.get(userId);
        if (!user || user.password !== password) {
          return sendError(res, 401, 'Invalid credentials');
        }
        // Create session token
        const token = crypto.randomBytes(32).toString('hex');
        state.sessions.set(token, user.id);
        const cookie = `session_id=${token}; Path=/; HttpOnly`;
        return sendJson(res, 200, { id: user.id, username: user.username }, { 'Set-Cookie': cookie });
      }

      if (method === 'POST' && path === '/logout') {
        const auth = requireAuth();
        if (!auth) return; // response already sent
        // Invalidate session
        state.sessions.delete(auth.token);
        return sendJson(res, 200, {});
      }

      if (method === 'GET' && path === '/me') {
        const auth = requireAuth();
        if (!auth) return;
        return sendJson(res, 200, { id: auth.user.id, username: auth.user.username });
      }

      if (method === 'PUT' && path === '/password') {
        const auth = requireAuth();
        if (!auth) return;
        let body;
        try { body = await readJsonBody(req); } catch (err) { return sendJson(res, err.code || 400, err.error || { error: 'Invalid JSON' }); }
        const oldp = typeof body.old_password === 'string' ? body.old_password : '';
        const newp = typeof body.new_password === 'string' ? body.new_password : '';
        if (auth.user.password !== oldp) {
          return sendError(res, 401, 'Invalid credentials');
        }
        if (!newp || newp.length < 8) {
          return sendError(res, 400, 'Password too short');
        }
        auth.user.password = newp;
        return sendJson(res, 200, {});
      }

      if (method === 'GET' && path === '/todos') {
        const auth = requireAuth();
        if (!auth) return;
        const list = [];
        for (const todo of state.todosById.values()) {
          if (todo.userId === auth.user.id) {
            const { userId, ...rest } = todo;
            list.push(rest);
          }
        }
        list.sort((a, b) => a.id - b.id);
        return sendJson(res, 200, list);
      }

      if (method === 'POST' && path === '/todos') {
        const auth = requireAuth();
        if (!auth) return;
        let body;
        try { body = await readJsonBody(req); } catch (err) { return sendJson(res, err.code || 400, err.error || { error: 'Invalid JSON' }); }
        const title = body && typeof body.title === 'string' ? body.title : '';
        if (!title || title.trim() === '') {
          return sendError(res, 400, 'Title is required');
        }
        const description = body && typeof body.description === 'string' ? body.description : '';
        const now = formatTimestamp(new Date());
        const id = state.nextTodoId++;
        const todo = {
          id,
          userId: auth.user.id,
          title,
          description,
          completed: false,
          created_at: now,
          updated_at: now,
        };
        state.todosById.set(id, todo);
        const { userId, ...publicTodo } = todo;
        return sendJson(res, 201, publicTodo);
      }

      // Handle /todos/:id for GET, PUT, DELETE
      if (path.startsWith('/todos/')) {
        const idStr = path.slice('/todos/'.length);
        const id = Number(idStr);
        if (!Number.isInteger(id) || id <= 0) {
          // For invalid IDs, still respond 404 for security
          if (method === 'DELETE') {
            // For DELETE, send 404 with JSON per error spec (it says errors return JSON; DELETE success returns no body)
            return sendError(res, 404, 'Todo not found');
          }
          return sendError(res, 404, 'Todo not found');
        }
        const auth = requireAuth();
        if (!auth) return;
        const todo = state.todosById.get(id);
        if (!todo || todo.userId !== auth.user.id) {
          return sendError(res, 404, 'Todo not found');
        }
        if (method === 'GET') {
          const { userId, ...publicTodo } = todo;
          return sendJson(res, 200, publicTodo);
        }
        if (method === 'PUT') {
          let body;
          try { body = await readJsonBody(req); } catch (err) { return sendJson(res, err.code || 400, err.error || { error: 'Invalid JSON' }); }
          if (Object.prototype.hasOwnProperty.call(body, 'title')) {
            const title = typeof body.title === 'string' ? body.title : '';
            if (!title || title.trim() === '') {
              return sendError(res, 400, 'Title is required');
            }
            todo.title = title;
          }
          if (Object.prototype.hasOwnProperty.call(body, 'description')) {
            if (typeof body.description === 'string') {
              todo.description = body.description;
            } else if (body.description === null) {
              // not specified, but keep as string; ignore null
            }
          }
          if (Object.prototype.hasOwnProperty.call(body, 'completed')) {
            if (typeof body.completed === 'boolean') {
              todo.completed = body.completed;
            } else {
              // If provided but not boolean, attempt to coerce specific strings
              if (body.completed === 'true') todo.completed = true;
              else if (body.completed === 'false') todo.completed = false;
            }
          }
          todo.updated_at = formatTimestamp(new Date());
          const { userId, ...publicTodo } = todo;
          return sendJson(res, 200, publicTodo);
        }
        if (method === 'DELETE') {
          state.todosById.delete(id);
          // 204 No Content, no body, and do not set Content-Type
          res.writeHead(204);
          return res.end();
        }
      }

      // Unknown route
      return notFound(res);
    } catch (err) {
      try {
        // Fallback error handler
        sendError(res, 500, 'Internal server error');
      } catch (_) {
        // ignore
      }
    }
  });
  return server;
}

if (require.main === module) {
  // CLI: --port PORT
  const args = process.argv.slice(2);
  let port = 3000;
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--port' && i + 1 < args.length) {
      const p = Number(args[i + 1]);
      if (Number.isInteger(p) && p > 0 && p < 65536) {
        port = p;
        i++;
        continue;
      }
    }
  }
  const server = createServer();
  server.listen(port, '0.0.0.0', () => {
    console.log(`Server listening on 0.0.0.0:${port}`);
  });
}

module.exports = { createServer };
