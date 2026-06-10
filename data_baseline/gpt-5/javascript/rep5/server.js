#!/usr/bin/env node

// Todo App REST API Server (in-memory)
// Requirements per specification

const http = require('http');
const { parse: parseUrl } = require('url');
const crypto = require('crypto');

// In-memory storage
const db = {
  users: [], // {id, username, password}
  nextUserId: 1,
  todos: [], // {id, user_id, title, description, completed, created_at, updated_at}
  nextTodoId: 1,
  sessions: new Map(), // token -> user_id
};

function isoNowSeconds() {
  return new Date().toISOString().replace(/\.\d{3}Z$/, 'Z');
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
  // No body for DELETE per spec
  res.end();
}

function notFound(res) {
  sendJSON(res, 404, { error: 'Not found' });
}

function unauthorized(res) {
  sendJSON(res, 401, { error: 'Authentication required' });
}

function parseCookies(cookieHeader) {
  const cookies = {};
  if (!cookieHeader) return cookies;
  const parts = cookieHeader.split(';');
  for (const part of parts) {
    const [k, v] = part.split('=');
    if (k && v !== undefined) {
      cookies[k.trim()] = v.trim();
    }
  }
  return cookies;
}

function getSessionUser(req) {
  const cookies = parseCookies(req.headers['cookie']);
  const token = cookies['session_id'];
  if (!token) return null;
  const userId = db.sessions.get(token);
  if (!userId) return null;
  const user = db.users.find(u => u.id === userId);
  if (!user) return null;
  return { user, token };
}

function readJSON(req) {
  return new Promise((resolve, reject) => {
    let data = '';
    req.on('data', chunk => {
      data += chunk;
      // Basic protection against huge payloads
      if (data.length > 1e6) {
        req.destroy();
        reject(new Error('Payload too large'));
      }
    });
    req.on('end', () => {
      if (data.length === 0) {
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

function generateToken() {
  if (crypto.randomUUID) {
    return crypto.randomUUID().replace(/-/g, '');
  }
  return crypto.randomBytes(16).toString('hex');
}

function validateUsername(username) {
  if (typeof username !== 'string') return false;
  if (username.length < 3 || username.length > 50) return false;
  if (!/^[a-zA-Z0-9_]+$/.test(username)) return false;
  return true;
}

function routeHandler(req, res) {
  const { pathname } = parseUrl(req.url, true);
  const method = req.method || 'GET';

  // Helper to ensure JSON content-type on all non-DELETE responses
  // sendJSON already does it

  // Routing
  if (method === 'POST' && pathname === '/register') {
    return readJSON(req)
      .then(body => {
        const { username, password } = body || {};
        if (!validateUsername(username)) {
          return sendJSON(res, 400, { error: 'Invalid username' });
        }
        if (typeof password !== 'string' || password.length < 8) {
          return sendJSON(res, 400, { error: 'Password too short' });
        }
        const existing = db.users.find(u => u.username === username);
        if (existing) {
          return sendJSON(res, 409, { error: 'Username already exists' });
        }
        const user = { id: db.nextUserId++, username, password };
        db.users.push(user);
        return sendJSON(res, 201, { id: user.id, username: user.username });
      })
      .catch(err => {
        if (err && err.message === 'Invalid JSON') {
          return sendJSON(res, 400, { error: 'Invalid JSON' });
        }
        return sendJSON(res, 500, { error: 'Internal server error' });
      });
  }

  if (method === 'POST' && pathname === '/login') {
    return readJSON(req)
      .then(body => {
        const { username, password } = body || {};
        const user = db.users.find(u => u.username === username);
        if (!user || user.password !== password) {
          return sendJSON(res, 401, { error: 'Invalid credentials' });
        }
        const token = generateToken();
        db.sessions.set(token, user.id);
        res.setHeader('Set-Cookie', `session_id=${token}; Path=/; HttpOnly`);
        return sendJSON(res, 200, { id: user.id, username: user.username });
      })
      .catch(err => {
        if (err && err.message === 'Invalid JSON') {
          return sendJSON(res, 400, { error: 'Invalid JSON' });
        }
        return sendJSON(res, 500, { error: 'Internal server error' });
      });
  }

  if (method === 'POST' && pathname === '/logout') {
    const sess = getSessionUser(req);
    if (!sess) return unauthorized(res);
    // Invalidate token server-side
    db.sessions.delete(sess.token);
    // Optional: clear cookie client-side (not required by spec)
    // res.setHeader('Set-Cookie', 'session_id=; Path=/; HttpOnly; Max-Age=0');
    return sendJSON(res, 200, {});
  }

  if (method === 'GET' && pathname === '/me') {
    const sess = getSessionUser(req);
    if (!sess) return unauthorized(res);
    const { user } = sess;
    return sendJSON(res, 200, { id: user.id, username: user.username });
  }

  if (method === 'PUT' && pathname === '/password') {
    const sess = getSessionUser(req);
    if (!sess) return unauthorized(res);
    const { user } = sess;
    return readJSON(req)
      .then(body => {
        const { old_password, new_password } = body || {};
        if (user.password !== old_password) {
          return sendJSON(res, 401, { error: 'Invalid credentials' });
        }
        if (typeof new_password !== 'string' || new_password.length < 8) {
          return sendJSON(res, 400, { error: 'Password too short' });
        }
        user.password = new_password;
        return sendJSON(res, 200, {});
      })
      .catch(err => {
        if (err && err.message === 'Invalid JSON') {
          return sendJSON(res, 400, { error: 'Invalid JSON' });
        }
        return sendJSON(res, 500, { error: 'Internal server error' });
      });
  }

  if (method === 'GET' && pathname === '/todos') {
    const sess = getSessionUser(req);
    if (!sess) return unauthorized(res);
    const list = db.todos
      .filter(t => t.user_id === sess.user.id)
      .sort((a, b) => a.id - b.id)
      .map(stripTodoUser);
    return sendJSON(res, 200, list);
  }

  if (method === 'POST' && pathname === '/todos') {
    const sess = getSessionUser(req);
    if (!sess) return unauthorized(res);
    return readJSON(req)
      .then(body => {
        const title = body && typeof body.title === 'string' ? body.title.trim() : '';
        if (!title) {
          return sendJSON(res, 400, { error: 'Title is required' });
        }
        const description = body && typeof body.description === 'string' ? body.description : '';
        const now = isoNowSeconds();
        const todo = {
          id: db.nextTodoId++,
          user_id: sess.user.id,
          title,
          description,
          completed: false,
          created_at: now,
          updated_at: now,
        };
        db.todos.push(todo);
        return sendJSON(res, 201, stripTodoUser(todo));
      })
      .catch(err => {
        if (err && err.message === 'Invalid JSON') {
          return sendJSON(res, 400, { error: 'Invalid JSON' });
        }
        return sendJSON(res, 500, { error: 'Internal server error' });
      });
  }

  // Routes with ID: /todos/:id
  const todoIdMatch = pathname && pathname.startsWith('/todos/') ? pathname.match(/^\/todos\/(\d+)$/) : null;
  if (todoIdMatch) {
    const id = parseInt(todoIdMatch[1], 10);
    const sess = getSessionUser(req);
    if (!sess) return unauthorized(res);
    const todo = db.todos.find(t => t.id === id);
    const notFoundTodo = () => sendJSON(res, 404, { error: 'Todo not found' });
    if (!todo || todo.user_id !== sess.user.id) {
      return notFoundTodo();
    }

    if (method === 'GET') {
      return sendJSON(res, 200, stripTodoUser(todo));
    }

    if (method === 'PUT') {
      return readJSON(req)
        .then(body => {
          if (body && Object.prototype.hasOwnProperty.call(body, 'title')) {
            if (typeof body.title !== 'string' || body.title.trim() === '') {
              return sendJSON(res, 400, { error: 'Title is required' });
            }
            todo.title = body.title.trim();
          }
          if (body && Object.prototype.hasOwnProperty.call(body, 'description')) {
            if (typeof body.description === 'string') {
              todo.description = body.description;
            }
          }
          if (body && Object.prototype.hasOwnProperty.call(body, 'completed')) {
            if (typeof body.completed === 'boolean') {
              todo.completed = body.completed;
            }
          }
          todo.updated_at = isoNowSeconds();
          return sendJSON(res, 200, stripTodoUser(todo));
        })
        .catch(err => {
          if (err && err.message === 'Invalid JSON') {
            return sendJSON(res, 400, { error: 'Invalid JSON' });
          }
          return sendJSON(res, 500, { error: 'Internal server error' });
        });
    }

    if (method === 'DELETE') {
      const idx = db.todos.findIndex(t => t.id === id && t.user_id === sess.user.id);
      if (idx === -1) return sendJSON(res, 404, { error: 'Todo not found' });
      db.todos.splice(idx, 1);
      return sendNoContent(res);
    }
  }

  return notFound(res);
}

function stripTodoUser(todo) {
  const { user_id, ...rest } = todo;
  return rest;
}

function startServer(port) {
  const server = http.createServer((req, res) => {
    // Ensure JSON content-type by default where applicable
    // We'll let routeHandler set appropriate headers
    routeHandler(req, res);
  });

  server.listen(port, '0.0.0.0', () => {
    // eslint-disable-next-line no-console
    console.log(`Server listening on 0.0.0.0:${port}`);
  });

  // Graceful shutdown handling (for tests)
  process.on('SIGTERM', () => server.close(() => process.exit(0)));
  process.on('SIGINT', () => server.close(() => process.exit(0)));

  return server;
}

function parsePortArg(argv) {
  const idx = argv.indexOf('--port');
  if (idx !== -1 && argv[idx + 1]) {
    const p = parseInt(argv[idx + 1], 10);
    if (!Number.isNaN(p) && p > 0 && p < 65536) return p;
  }
  // default
  return 3000;
}

const port = parsePortArg(process.argv.slice(2));
startServer(port);
