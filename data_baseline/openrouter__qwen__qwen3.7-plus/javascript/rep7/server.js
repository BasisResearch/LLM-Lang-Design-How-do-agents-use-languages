const http = require('http');
const crypto = require('crypto');

let users = [];
let todos = [];
let sessions = new Map();

let userIdCounter = 0;
let todoIdCounter = 0;

const generateTimestamp = () => {
  return new Date().toISOString().replace(/\.\d{3}Z$/, 'Z');
};

function parseCookies(cookieHeader) {
  if (!cookieHeader) return {};
  const cookies = {};
  cookieHeader.split(';').forEach(cookie => {
    const parts = cookie.split('=');
    const key = parts[0].trim();
    const val = decodeURIComponent(parts[1] ? parts[1].trim() : '');
    cookies[key] = val;
  });
  return cookies;
}

function sendJSON(res, statusCode, data) {
  res.statusCode = statusCode;
  res.setHeader('Content-Type', 'application/json');
  res.end(JSON.stringify(data));
}

function getUserId(req) {
  const cookies = parseCookies(req.headers.cookie);
  const sessionId = cookies['session_id'];
  if (sessionId && sessions.has(sessionId)) {
    return sessions.get(sessionId);
  }
  return null;
}

function getBody(req) {
  return new Promise((resolve) => {
    let body = '';
    req.on('data', chunk => body += chunk.toString());
    req.on('end', () => {
      if (!body) resolve(null);
      else {
        try {
          resolve(JSON.parse(body));
        } catch (e) {
          resolve(null);
        }
      }
    });
    req.on('error', () => resolve(null));
  });
}

const server = http.createServer(async (req, res) => {
  const parsedUrl = new URL(req.url, `http://${req.headers.host}`);
  const path = parsedUrl.pathname;
  const method = req.method;

  let body = null;
  if (method !== 'GET' && method !== 'DELETE') {
    body = await getBody(req);
  }

  if (method === 'POST' && path === '/register') {
    if (!body) return sendJSON(res, 400, { error: "Invalid request" });
    const { username, password } = body;
    if (!username || typeof username !== 'string' || username.length < 3 || username.length > 50 || !/^[a-zA-Z0-9_]+$/.test(username)) {
      return sendJSON(res, 400, { error: "Invalid username" });
    }
    if (!password || typeof password !== 'string' || password.length < 8) {
      return sendJSON(res, 400, { error: "Password too short" });
    }
    if (users.find(u => u.username === username)) {
      return sendJSON(res, 409, { error: "Username already exists" });
    }
    userIdCounter++;
    const newUser = { id: userIdCounter, username, password };
    users.push(newUser);
    return sendJSON(res, 201, { id: newUser.id, username: newUser.username });
  }

  if (method === 'POST' && path === '/login') {
    if (!body) return sendJSON(res, 400, { error: "Invalid request" });
    const { username, password } = body;
    const user = users.find(u => u.username === username && u.password === password);
    if (!user) {
      return sendJSON(res, 401, { error: "Invalid credentials" });
    }
    const sessionId = crypto.randomUUID();
    sessions.set(sessionId, user.id);
    res.setHeader('Set-Cookie', `session_id=${sessionId}; Path=/; HttpOnly`);
    return sendJSON(res, 200, { id: user.id, username: user.username });
  }

  if (method === 'POST' && path === '/logout') {
    const userId = getUserId(req);
    if (userId === null) return sendJSON(res, 401, { error: "Authentication required" });
    const cookies = parseCookies(req.headers.cookie);
    sessions.delete(cookies['session_id']);
    res.setHeader('Set-Cookie', 'session_id=; Path=/; HttpOnly, Max-Age=0');
    return sendJSON(res, 200, {});
  }

  if (method === 'GET' && path === '/me') {
    const userId = getUserId(req);
    if (userId === null) return sendJSON(res, 401, { error: "Authentication required" });
    const user = users.find(u => u.id === userId);
    return sendJSON(res, 200, { id: user.id, username: user.username });
  }

  if (method === 'PUT' && path === '/password') {
    if (!body) return sendJSON(res, 400, { error: "Invalid request" });
    const userId = getUserId(req);
    if (userId === null) return sendJSON(res, 401, { error: "Authentication required" });
    const user = users.find(u => u.id === userId);
    if (!user || body.old_password !== user.password) {
      return sendJSON(res, 401, { error: "Invalid credentials" });
    }
    if (!body.new_password || typeof body.new_password !== 'string' || body.new_password.length < 8) {
      return sendJSON(res, 400, { error: "Password too short" });
    }
    user.password = body.new_password;
    return sendJSON(res, 200, {});
  }

  if (method === 'GET' && path === '/todos') {
    const userId = getUserId(req);
    if (userId === null) return sendJSON(res, 401, { error: "Authentication required" });
    const userTodos = todos.filter(t => t.user_id === userId).sort((a, b) => a.id - b.id);
    return sendJSON(res, 200, userTodos);
  }

  if (method === 'POST' && path === '/todos') {
    if (!body) return sendJSON(res, 400, { error: "Invalid request" });
    const userId = getUserId(req);
    if (userId === null) return sendJSON(res, 401, { error: "Authentication required" });
    if (!body.title || typeof body.title !== 'string' || body.title === '') {
      return sendJSON(res, 400, { error: "Title is required" });
    }
    todoIdCounter++;
    const now = generateTimestamp();
    const newTodo = {
      id: todoIdCounter,
      user_id: userId,
      title: body.title,
      description: body.description !== undefined ? body.description : '',
      completed: false,
      created_at: now,
      updated_at: now
    };
    todos.push(newTodo);
    return sendJSON(res, 201, newTodo);
  }

  if (method === 'GET' && path.startsWith('/todos/')) {
    const userId = getUserId(req);
    if (userId === null) return sendJSON(res, 401, { error: "Authentication required" });
    const parts = path.split('/');
    const idStr = parts[2];
    if (!/^\d+$/.test(idStr)) return sendJSON(res, 404, { error: "Todo not found" });
    const todoId = parseInt(idStr, 10);
    const todo = todos.find(t => t.id === todoId && t.user_id === userId);
    if (!todo) return sendJSON(res, 404, { error: "Todo not found" });
    return sendJSON(res, 200, todo);
  }

  if (method === 'PUT' && path.startsWith('/todos/')) {
    const userId = getUserId(req);
    if (userId === null) return sendJSON(res, 401, { error: "Authentication required" });
    const parts = path.split('/');
    const idStr = parts[2];
    if (!/^\d+$/.test(idStr)) return sendJSON(res, 404, { error: "Todo not found" });
    const todoId = parseInt(idStr, 10);
    const todoIndex = todos.findIndex(t => t.id === todoId && t.user_id === userId);
    if (todoIndex === -1) return sendJSON(res, 404, { error: "Todo not found" });
    
    const todo = todos[todoIndex];
    if (body) {
      if (body.title !== undefined) {
        if (typeof body.title !== 'string' || body.title === '') {
          return sendJSON(res, 400, { error: "Title is required" });
        }
        todo.title = body.title;
      }
      if (body.description !== undefined) {
        todo.description = body.description;
      }
      if (body.completed !== undefined) {
        todo.completed = body.completed;
      }
    }
    todo.updated_at = generateTimestamp();
    return sendJSON(res, 200, todo);
  }

  if (method === 'DELETE' && path.startsWith('/todos/')) {
    const userId = getUserId(req);
    if (userId === null) return sendJSON(res, 401, { error: "Authentication required" });
    const parts = path.split('/');
    const idStr = parts[2];
    if (!/^\d+$/.test(idStr)) return sendJSON(res, 404, { error: "Todo not found" });
    const todoId = parseInt(idStr, 10);
    const todoIndex = todos.findIndex(t => t.id === todoId && t.user_id === userId);
    if (todoIndex === -1) return sendJSON(res, 404, { error: "Todo not found" });
    todos.splice(todoIndex, 1);
    res.statusCode = 204;
    res.end();
    return;
  }

  return sendJSON(res, 404, { error: "Not found" });
});

const portIndex = process.argv.indexOf('--port');
const port = portIndex !== -1 ? process.argv[portIndex + 1] : 3000;
server.listen(port, '0.0.0.0', () => {
  console.log(`Server listening on 0.0.0.0:${port}`);
});
