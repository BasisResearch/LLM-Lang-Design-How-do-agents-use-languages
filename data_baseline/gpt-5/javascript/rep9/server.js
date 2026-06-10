const http = require('http');
const { URL } = require('url');
const crypto = require('crypto');

// In-memory data stores
const users = []; // {id, username, salt, passHash}
let userIdCounter = 1;

const todos = []; // {id, user_id, title, description, completed, created_at, updated_at}
let todoIdCounter = 1;

const sessions = new Map(); // token -> user_id

function isoNowSeconds() {
  // ISO 8601 UTC timestamp with seconds precision (no milliseconds)
  return new Date().toISOString().replace(/\.\d{3}Z$/, 'Z');
}

function parseCookies(cookieHeader) {
  const cookies = {};
  if (!cookieHeader) return cookies;
  const parts = cookieHeader.split(';');
  for (const part of parts) {
    const idx = part.indexOf('=');
    if (idx === -1) continue;
    const key = part.slice(0, idx).trim();
    const val = part.slice(idx + 1).trim();
    cookies[key] = decodeURIComponent(val);
  }
  return cookies;
}

function readJsonBody(req) {
  return new Promise((resolve, reject) => {
    let data = '';
    req.on('data', chunk => {
      data += chunk.toString('utf8');
      if (data.length > 1e6) { // 1MB limit
        req.socket.destroy();
        reject(new Error('Payload too large'));
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
  });
}

function sendJSON(res, statusCode, obj) {
  const body = JSON.stringify(obj);
  res.statusCode = statusCode;
  res.setHeader('Content-Type', 'application/json');
  res.setHeader('Content-Length', Buffer.byteLength(body));
  res.end(body);
}

function sendEmpty(res, statusCode) {
  res.statusCode = statusCode;
  // No body, do not set Content-Type per spec for DELETE success
  res.end();
}

function errorJSON(res, statusCode, message) {
  sendJSON(res, statusCode, { error: message });
}

function validateUsername(username) {
  if (typeof username !== 'string') return false;
  if (username.length < 3 || username.length > 50) return false;
  if (!/^[a-zA-Z0-9_]+$/.test(username)) return false;
  return true;
}

function hashPassword(password, salt) {
  return crypto.createHash('sha256').update(password + ':' + salt).digest('hex');
}

function createUser(username, password) {
  const id = userIdCounter++;
  const salt = crypto.randomBytes(16).toString('hex');
  const passHash = hashPassword(password, salt);
  const user = { id, username, salt, passHash };
  users.push(user);
  return { id: user.id, username: user.username };
}

function findUserByUsername(username) {
  return users.find(u => u.username === username);
}

function authenticateUser(username, password) {
  const user = findUserByUsername(username);
  if (!user) return null;
  const passHash = hashPassword(password, user.salt);
  if (passHash !== user.passHash) return null;
  return { id: user.id, username: user.username };
}

function requireAuth(req, res) {
  const cookies = parseCookies(req.headers['cookie']);
  const token = cookies['session_id'];
  if (!token) {
    errorJSON(res, 401, 'Authentication required');
    return null;
  }
  const userId = sessions.get(token);
  if (!userId) {
    errorJSON(res, 401, 'Authentication required');
    return null;
  }
  const user = users.find(u => u.id === userId);
  if (!user) {
    // Should not happen, but ensure session invalidation
    sessions.delete(token);
    errorJSON(res, 401, 'Authentication required');
    return null;
  }
  // attach user info for handlers
  return user;
}

function sanitizeTodo(todo) {
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
  const parsed = new URL(req.url, `http://localhost`);
  const pathname = parsed.pathname;
  const method = req.method.toUpperCase();

  // Ensure only JSON responses except DELETE 204 cases - enforce for all normal paths
  // We'll call sendEmpty for 204s only.

  // Routing
  if (method === 'POST' && pathname === '/register') {
    return readJsonBody(req).then(body => {
      const { username, password } = body || {};
      if (!validateUsername(username)) {
        return errorJSON(res, 400, 'Invalid username');
      }
      if (typeof password !== 'string' || password.length < 8) {
        return errorJSON(res, 400, 'Password too short');
      }
      if (findUserByUsername(username)) {
        return errorJSON(res, 409, 'Username already exists');
      }
      const userPublic = createUser(username, password);
      return sendJSON(res, 201, userPublic);
    }).catch(err => {
      if (err.message === 'Invalid JSON') return errorJSON(res, 400, 'Invalid JSON');
      return errorJSON(res, 400, 'Invalid request');
    });
  }

  if (method === 'POST' && pathname === '/login') {
    return readJsonBody(req).then(body => {
      const { username, password } = body || {};
      if (typeof username !== 'string' || typeof password !== 'string') {
        return errorJSON(res, 401, 'Invalid credentials');
      }
      const user = authenticateUser(username, password);
      if (!user) {
        return errorJSON(res, 401, 'Invalid credentials');
      }
      const token = crypto.randomUUID().replace(/-/g, '');
      sessions.set(token, user.id);
      // Set-Cookie: session_id=<token>; Path=/; HttpOnly
      res.setHeader('Set-Cookie', `session_id=${token}; Path=/; HttpOnly`);
      return sendJSON(res, 200, user);
    }).catch(err => {
      if (err.message === 'Invalid JSON') return errorJSON(res, 400, 'Invalid JSON');
      return errorJSON(res, 400, 'Invalid request');
    });
  }

  if (method === 'POST' && pathname === '/logout') {
    const user = requireAuth(req, res);
    if (!user) return; // response already sent
    // Invalidate current session token only
    const cookies = parseCookies(req.headers['cookie']);
    const token = cookies['session_id'];
    if (token) sessions.delete(token);
    return sendJSON(res, 200, {});
  }

  if (method === 'GET' && pathname === '/me') {
    const user = requireAuth(req, res);
    if (!user) return;
    return sendJSON(res, 200, { id: user.id, username: user.username });
  }

  if (method === 'PUT' && pathname === '/password') {
    const user = requireAuth(req, res);
    if (!user) return;
    return readJsonBody(req).then(body => {
      const { old_password, new_password } = body || {};
      if (typeof old_password !== 'string') {
        return errorJSON(res, 401, 'Invalid credentials');
      }
      const passHash = hashPassword(old_password, user.salt);
      if (passHash !== user.passHash) {
        return errorJSON(res, 401, 'Invalid credentials');
      }
      if (typeof new_password !== 'string' || new_password.length < 8) {
        return errorJSON(res, 400, 'Password too short');
      }
      const newSalt = crypto.randomBytes(16).toString('hex');
      const newHash = hashPassword(new_password, newSalt);
      user.salt = newSalt;
      user.passHash = newHash;
      return sendJSON(res, 200, {});
    }).catch(err => {
      if (err.message === 'Invalid JSON') return errorJSON(res, 400, 'Invalid JSON');
      return errorJSON(res, 400, 'Invalid request');
    });
  }

  // Todos collection routes
  if (pathname === '/todos' && method === 'GET') {
    const user = requireAuth(req, res);
    if (!user) return;
    const list = todos.filter(t => t.user_id === user.id).sort((a, b) => a.id - b.id).map(sanitizeTodo);
    return sendJSON(res, 200, list);
  }

  if (pathname === '/todos' && method === 'POST') {
    const user = requireAuth(req, res);
    if (!user) return;
    return readJsonBody(req).then(body => {
      const title = body && typeof body.title === 'string' ? body.title : undefined;
      const description = body && typeof body.description === 'string' ? body.description : '';
      if (!title || title.trim() === '') {
        return errorJSON(res, 400, 'Title is required');
      }
      const now = isoNowSeconds();
      const todo = {
        id: todoIdCounter++,
        user_id: user.id,
        title: title,
        description: description || '',
        completed: false,
        created_at: now,
        updated_at: now,
      };
      todos.push(todo);
      return sendJSON(res, 201, sanitizeTodo(todo));
    }).catch(err => {
      if (err.message === 'Invalid JSON') return errorJSON(res, 400, 'Invalid JSON');
      return errorJSON(res, 400, 'Invalid request');
    });
  }

  // Todos item routes with id
  if (pathname.startsWith('/todos/')) {
    const user = requireAuth(req, res);
    if (!user) return;
    const idStr = pathname.slice('/todos/'.length);
    const id = parseInt(idStr, 10);
    if (!Number.isInteger(id) || id <= 0) {
      return errorJSON(res, 404, 'Todo not found');
    }
    const todo = todos.find(t => t.id === id);
    if (!todo || todo.user_id !== user.id) {
      return errorJSON(res, 404, 'Todo not found');
    }

    if (method === 'GET') {
      return sendJSON(res, 200, sanitizeTodo(todo));
    }

    if (method === 'PUT') {
      return readJsonBody(req).then(body => {
        if (body && Object.prototype.hasOwnProperty.call(body, 'title')) {
          if (typeof body.title !== 'string' || body.title.trim() === '') {
            return errorJSON(res, 400, 'Title is required');
          }
          todo.title = body.title;
        }
        if (body && Object.prototype.hasOwnProperty.call(body, 'description')) {
          if (typeof body.description === 'string') {
            todo.description = body.description;
          }
        }
        if (body && Object.prototype.hasOwnProperty.call(body, 'completed')) {
          // Only update if boolean, otherwise coerce? Spec doesn't require validation, but be strict.
          if (typeof body.completed === 'boolean') {
            todo.completed = body.completed;
          }
        }
        todo.updated_at = isoNowSeconds();
        return sendJSON(res, 200, sanitizeTodo(todo));
      }).catch(err => {
        if (err.message === 'Invalid JSON') return errorJSON(res, 400, 'Invalid JSON');
        return errorJSON(res, 400, 'Invalid request');
      });
    }

    if (method === 'DELETE') {
      const idx = todos.findIndex(t => t.id === id && t.user_id === user.id);
      if (idx === -1) {
        return errorJSON(res, 404, 'Todo not found');
      }
      todos.splice(idx, 1);
      return sendEmpty(res, 204);
    }

    // Unsupported method for this path
    return errorJSON(res, 405, 'Method Not Allowed');
  }

  // Fallback for undefined routes
  return errorJSON(res, 404, 'Not Found');
}

function startServer(port) {
  const server = http.createServer((req, res) => {
    // Route and handle
    route(req, res);
  });

  server.listen(port, '0.0.0.0', () => {
    console.log(`Server listening on 0.0.0.0:${port}`);
  });

  return server;
}

if (require.main === module) {
  // CLI parsing for --port PORT
  const args = process.argv.slice(2);
  let port = 3000;
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
