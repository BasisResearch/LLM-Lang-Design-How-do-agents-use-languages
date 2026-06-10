const http = require('http');
const url = require('url');
const crypto = require('crypto');

let nextUserId = 1;
let nextTodoId = 1;
const users = new Map();
const sessions = new Map();
const todos = new Map();

function generateToken() {
  return crypto.randomBytes(16).toString('hex');
}

function getTimestamp() {
  return new Date().toISOString().replace(/\.\d{3}Z$/, 'Z');
}

function sendJson(res, statusCode, data) {
  res.writeHead(statusCode, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(data));
}

function parseBody(req) {
  return new Promise((resolve) => {
    let body = '';
    req.on('data', chunk => { body += chunk.toString(); });
    req.on('end', () => {
      try {
        resolve(body ? JSON.parse(body) : {});
      } catch (e) {
        resolve({});
      }
    });
    req.on('error', () => resolve({}));
  });
}

function getCookies(req) {
  const cookieHeader = req.headers.cookie;
  if (!cookieHeader) return {};
  const cookies = {};
  cookieHeader.split(';').forEach(cookie => {
    const [name, ...rest] = cookie.trim().split('=');
    cookies[name] = rest.join('=');
  });
  return cookies;
}

function getAuthUser(req) {
  const cookies = getCookies(req);
  const token = cookies.session_id;
  if (!token || !sessions.has(token)) {
    return null;
  }
  const userId = sessions.get(token);
  for (const user of users.values()) {
    if (user.id === userId) return user;
  }
  return null;
}

function sanitizeTodo(todo) {
  return {
    id: todo.id,
    title: todo.title,
    description: todo.description,
    completed: todo.completed,
    created_at: todo.created_at,
    updated_at: todo.updated_at
  };
}

const server = http.createServer(async (req, res) => {
  const parsedUrl = url.parse(req.url);
  const path = parsedUrl.pathname;
  const method = req.method;

  if (method === 'POST' && path === '/register') {
    const body = await parseBody(req);
    const { username, password } = body;
    if (typeof username !== 'string' || !/^[a-zA-Z0-9_]{3,50}$/.test(username)) {
      return sendJson(res, 400, { error: 'Invalid username' });
    }
    if (typeof password !== 'string' || password.length < 8) {
      return sendJson(res, 400, { error: 'Password too short' });
    }
    if (users.has(username)) {
      return sendJson(res, 409, { error: 'Username already exists' });
    }
    const user = { id: nextUserId++, username, password };
    users.set(username, user);
    return sendJson(res, 201, { id: user.id, username: user.username });
  }

  if (method === 'POST' && path === '/login') {
    const body = await parseBody(req);
    const { username, password } = body;
    const user = users.get(username);
    if (!user || user.password !== password) {
      return sendJson(res, 401, { error: 'Invalid credentials' });
    }
    const token = generateToken();
    sessions.set(token, user.id);
    res.setHeader('Set-Cookie', `session_id=${token}; Path=/; HttpOnly`);
    return sendJson(res, 200, { id: user.id, username: user.username });
  }

  if (method === 'POST' && path === '/logout') {
    const user = getAuthUser(req);
    if (!user) return sendJson(res, 401, { error: 'Authentication required' });
    const cookies = getCookies(req);
    sessions.delete(cookies.session_id);
    return sendJson(res, 200, {});
  }

  if (method === 'GET' && path === '/me') {
    const user = getAuthUser(req);
    if (!user) return sendJson(res, 401, { error: 'Authentication required' });
    return sendJson(res, 200, { id: user.id, username: user.username });
  }

  if (method === 'PUT' && path === '/password') {
    const user = getAuthUser(req);
    if (!user) return sendJson(res, 401, { error: 'Authentication required' });
    const body = await parseBody(req);
    const { old_password, new_password } = body;
    if (user.password !== old_password) {
      return sendJson(res, 401, { error: 'Invalid credentials' });
    }
    if (typeof new_password !== 'string' || new_password.length < 8) {
      return sendJson(res, 400, { error: 'Password too short' });
    }
    user.password = new_password;
    return sendJson(res, 200, {});
  }

  if (method === 'GET' && path === '/todos') {
    const user = getAuthUser(req);
    if (!user) return sendJson(res, 401, { error: 'Authentication required' });
    const userTodos = [];
    for (const todo of todos.values()) {
      if (todo.userId === user.id) {
        userTodos.push(sanitizeTodo(todo));
      }
    }
    userTodos.sort((a, b) => a.id - b.id);
    return sendJson(res, 200, userTodos);
  }

  if (method === 'POST' && path === '/todos') {
    const user = getAuthUser(req);
    if (!user) return sendJson(res, 401, { error: 'Authentication required' });
    const body = await parseBody(req);
    if (typeof body.title !== 'string' || body.title.length === 0) {
      return sendJson(res, 400, { error: 'Title is required' });
    }
    const description = typeof body.description === 'string' ? body.description : '';
    const now = getTimestamp();
    const todo = {
      id: nextTodoId++,
      userId: user.id,
      title: body.title,
      description: description,
      completed: false,
      created_at: now,
      updated_at: now
    };
    todos.set(todo.id, todo);
    return sendJson(res, 201, sanitizeTodo(todo));
  }

  const todoIdMatch = path.match(/^\/todos\/(\d+)$/);
  if (todoIdMatch) {
    const todoId = parseInt(todoIdMatch[1], 10);
    const user = getAuthUser(req);
    if (!user) return sendJson(res, 401, { error: 'Authentication required' });

    const todo = todos.get(todoId);
    if (!todo || todo.userId !== user.id) {
      return sendJson(res, 404, { error: 'Todo not found' });
    }

    if (method === 'GET') {
      return sendJson(res, 200, sanitizeTodo(todo));
    }

    if (method === 'PUT') {
      const body = await parseBody(req);
      if ('title' in body && (typeof body.title !== 'string' || body.title.length === 0)) {
        return sendJson(res, 400, { error: 'Title is required' });
      }
      if ('title' in body) todo.title = body.title;
      if ('description' in body) todo.description = body.description;
      if ('completed' in body) todo.completed = typeof body.completed === 'boolean' ? body.completed : Boolean(body.completed);
      todo.updated_at = getTimestamp();
      return sendJson(res, 200, sanitizeTodo(todo));
    }

    if (method === 'DELETE') {
      todos.delete(todoId);
      res.writeHead(204).end();
      return;
    }
  }

  return sendJson(res, 404, { error: 'Not found' });
});

const portArg = process.argv.indexOf('--port');
const port = portArg !== -1 ? parseInt(process.argv[portArg + 1], 10) : 3000;

server.listen(port, '0.0.0.0', () => {
  console.log(`Server listening on 0.0.0.0:${port}`);
});
