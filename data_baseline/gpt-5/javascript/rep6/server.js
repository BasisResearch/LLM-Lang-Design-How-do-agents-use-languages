#!/usr/bin/env node

const http = require('http');
const url = require('url');
const crypto = require('crypto');

// In-memory storage
let nextUserId = 1;
let nextTodoId = 1;
const usersById = new Map(); // id -> {id, username, password}
const usersByUsername = new Map(); // username -> {id, username, password}
const sessions = new Map(); // token -> userId
const todosById = new Map(); // id -> {id, title, description, completed, created_at, updated_at, ownerId}

function nowIsoSeconds() {
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

function sendJson(res, statusCode, obj) {
  res.statusCode = statusCode;
  res.setHeader('Content-Type', 'application/json');
  res.end(JSON.stringify(obj));
}

function sendNoContent(res) {
  res.statusCode = 204;
  // no Content-Type header, no body
  res.end();
}

function readJsonBody(req, res) {
  return new Promise((resolve) => {
    const chunks = [];
    let total = 0;
    const MAX = 1 * 1024 * 1024; // 1MB
    req.on('data', (chunk) => {
      total += chunk.length;
      if (total > MAX) {
        // Too large; consume and then error
        req.pause();
        sendJson(res, 413, { error: 'Payload too large' });
        resolve({ error: true });
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => {
      if (chunks.length === 0) {
        resolve({});
        return;
      }
      const raw = Buffer.concat(chunks).toString('utf8');
      try {
        const obj = JSON.parse(raw);
        resolve(obj);
      } catch (e) {
        sendJson(res, 400, { error: 'Invalid JSON' });
        resolve({ error: true });
      }
    });
    req.on('error', () => {
      sendJson(res, 400, { error: 'Invalid request' });
      resolve({ error: true });
    });
  });
}

function authUser(req, res) {
  const cookies = parseCookies(req.headers['cookie']);
  const token = cookies['session_id'];
  if (!token) {
    sendJson(res, 401, { error: 'Authentication required' });
    return null;
  }
  const userId = sessions.get(token);
  if (!userId) {
    sendJson(res, 401, { error: 'Authentication required' });
    return null;
  }
  const user = usersById.get(userId);
  if (!user) {
    // Should not happen; invalidate session
    sessions.delete(token);
    sendJson(res, 401, { error: 'Authentication required' });
    return null;
  }
  // Attach session token for potential logout
  req.sessionToken = token;
  return user;
}

function sanitizeUser(user) {
  return { id: user.id, username: user.username };
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

function handleRegister(req, res) {
  readJsonBody(req, res).then((body) => {
    if (body && body.error) return; // already responded
    const username = body && typeof body.username === 'string' ? body.username : '';
    const password = body && typeof body.password === 'string' ? body.password : '';

    // Validate username
    if (!username || username.length < 3 || username.length > 50 || !/^[a-zA-Z0-9_]+$/.test(username)) {
      return sendJson(res, 400, { error: 'Invalid username' });
    }
    if (!password || password.length < 8) {
      return sendJson(res, 400, { error: 'Password too short' });
    }
    if (usersByUsername.has(username)) {
      return sendJson(res, 409, { error: 'Username already exists' });
    }

    const id = nextUserId++;
    const user = { id, username, password };
    usersById.set(id, user);
    usersByUsername.set(username, user);

    return sendJson(res, 201, sanitizeUser(user));
  });
}

function handleLogin(req, res) {
  readJsonBody(req, res).then((body) => {
    if (body && body.error) return;
    const username = body && typeof body.username === 'string' ? body.username : '';
    const password = body && typeof body.password === 'string' ? body.password : '';

    const user = usersByUsername.get(username);
    if (!user || user.password !== password) {
      return sendJson(res, 401, { error: 'Invalid credentials' });
    }
    const token = crypto.randomBytes(32).toString('hex');
    sessions.set(token, user.id);
    // Set-Cookie header
    const cookie = `session_id=${encodeURIComponent(token)}; Path=/; HttpOnly`;
    res.setHeader('Set-Cookie', cookie);
    return sendJson(res, 200, sanitizeUser(user));
  });
}

function handleLogout(req, res) {
  const user = authUser(req, res);
  if (!user) return;
  const token = req.sessionToken;
  if (token) {
    sessions.delete(token);
  }
  return sendJson(res, 200, {});
}

function handleMe(req, res) {
  const user = authUser(req, res);
  if (!user) return;
  return sendJson(res, 200, sanitizeUser(user));
}

function handlePassword(req, res) {
  const user = authUser(req, res);
  if (!user) return;
  readJsonBody(req, res).then((body) => {
    if (body && body.error) return;
    const oldp = body && typeof body.old_password === 'string' ? body.old_password : '';
    const newp = body && typeof body.new_password === 'string' ? body.new_password : '';
    if (user.password !== oldp) {
      return sendJson(res, 401, { error: 'Invalid credentials' });
    }
    if (!newp || newp.length < 8) {
      return sendJson(res, 400, { error: 'Password too short' });
    }
    user.password = newp;
    return sendJson(res, 200, {});
  });
}

function listTodos(req, res) {
  const user = authUser(req, res);
  if (!user) return;
  const todos = [];
  for (const todo of todosById.values()) {
    if (todo.ownerId === user.id) {
      todos.push(sanitizeTodo(todo));
    }
  }
  todos.sort((a, b) => a.id - b.id);
  return sendJson(res, 200, todos);
}

function createTodo(req, res) {
  const user = authUser(req, res);
  if (!user) return;
  readJsonBody(req, res).then((body) => {
    if (body && body.error) return;
    const title = body && typeof body.title === 'string' ? body.title : '';
    if (!title || title.trim() === '') {
      return sendJson(res, 400, { error: 'Title is required' });
    }
    const description = body && typeof body.description === 'string' ? body.description : '';
    const ts = nowIsoSeconds();
    const todo = {
      id: nextTodoId++,
      title: title,
      description: description || '',
      completed: false,
      created_at: ts,
      updated_at: ts,
      ownerId: user.id,
    };
    todosById.set(todo.id, todo);
    return sendJson(res, 201, sanitizeTodo(todo));
  });
}

function getTodoOwned(user, id) {
  const todo = todosById.get(id);
  if (!todo) return null;
  if (todo.ownerId !== user.id) return null; // hide existence
  return todo;
}

function getTodo(req, res, idStr) {
  const user = authUser(req, res);
  if (!user) return;
  const id = parseInt(idStr, 10);
  if (!Number.isInteger(id) || id <= 0) {
    return sendJson(res, 404, { error: 'Todo not found' });
  }
  const todo = getTodoOwned(user, id);
  if (!todo) {
    return sendJson(res, 404, { error: 'Todo not found' });
  }
  return sendJson(res, 200, sanitizeTodo(todo));
}

function updateTodo(req, res, idStr) {
  const user = authUser(req, res);
  if (!user) return;
  const id = parseInt(idStr, 10);
  if (!Number.isInteger(id) || id <= 0) {
    return sendJson(res, 404, { error: 'Todo not found' });
  }
  const todo = getTodoOwned(user, id);
  if (!todo) {
    return sendJson(res, 404, { error: 'Todo not found' });
  }
  readJsonBody(req, res).then((body) => {
    if (body && body.error) return;
    if (Object.prototype.hasOwnProperty.call(body, 'title')) {
      const title = typeof body.title === 'string' ? body.title : '';
      if (!title || title.trim() === '') {
        return sendJson(res, 400, { error: 'Title is required' });
      }
      todo.title = title;
    }
    if (Object.prototype.hasOwnProperty.call(body, 'description')) {
      const description = typeof body.description === 'string' ? body.description : '';
      todo.description = description;
    }
    if (Object.prototype.hasOwnProperty.call(body, 'completed')) {
      // Only accept boolean; if not boolean, coerce? Spec doesn't mandate; we enforce boolean quietly by casting
      const completed = body.completed === true;
      todo.completed = completed;
    }
    todo.updated_at = nowIsoSeconds();
    return sendJson(res, 200, sanitizeTodo(todo));
  });
}

function deleteTodo(req, res, idStr) {
  const user = authUser(req, res);
  if (!user) return;
  const id = parseInt(idStr, 10);
  if (!Number.isInteger(id) || id <= 0) {
    return sendJson(res, 404, { error: 'Todo not found' });
  }
  const todo = getTodoOwned(user, id);
  if (!todo) {
    return sendJson(res, 404, { error: 'Todo not found' });
  }
  todosById.delete(id);
  return sendNoContent(res);
}

function notFound(res) {
  sendJson(res, 404, { error: 'Not found' });
}

function router(req, res) {
  const parsed = url.parse(req.url, true);
  const path = parsed.pathname || '/';
  const method = req.method || 'GET';

  // Ensure we always set JSON content type for all except DELETE/204 handled in sendNoContent
  // CORS not requested; not adding.

  if (method === 'POST' && path === '/register') return handleRegister(req, res);
  if (method === 'POST' && path === '/login') return handleLogin(req, res);
  if (method === 'POST' && path === '/logout') return handleLogout(req, res);
  if (method === 'GET' && path === '/me') return handleMe(req, res);
  if (method === 'PUT' && path === '/password') return handlePassword(req, res);
  if (method === 'GET' && path === '/todos') return listTodos(req, res);
  if (method === 'POST' && path === '/todos') return createTodo(req, res);

  // Match /todos/:id
  const todoIdMatch = path.match(/^\/todos\/(\d+)$/);
  if (todoIdMatch) {
    const idStr = todoIdMatch[1];
    if (method === 'GET') return getTodo(req, res, idStr);
    if (method === 'PUT') return updateTodo(req, res, idStr);
    if (method === 'DELETE') return deleteTodo(req, res, idStr);
  }

  return notFound(res);
}

function parseArgs(argv) {
  const args = { port: 3000 };
  for (let i = 2; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === '--port' && i + 1 < argv.length) {
      const p = parseInt(argv[i + 1], 10);
      if (!isNaN(p) && p > 0 && p < 65536) {
        args.port = p;
      }
      i++;
    }
  }
  return args;
}

function createServer() {
  return http.createServer((req, res) => {
    // Only accept application/json content for requests with a body? Not strictly needed, but we'll accept any.
    router(req, res);
  });
}

if (require.main === module) {
  const { port } = parseArgs(process.argv);
  const server = createServer();
  server.listen(port, '0.0.0.0', () => {
    console.log(`Server listening on 0.0.0.0:${port}`);
  });
}

module.exports = { createServer };
