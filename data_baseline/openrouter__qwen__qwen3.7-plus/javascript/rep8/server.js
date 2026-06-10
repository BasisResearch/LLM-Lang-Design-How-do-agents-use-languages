const http = require('http');
const crypto = require('crypto');
const { URL } = require('url');

const users = [];
const sessions = {};
let nextUserId = 1;
let nextTodoId = 1;
const todos = {};

function hashPassword(password) {
  return crypto.createHash('sha256').update(String(password)).digest('hex');
}

function generateToken() {
  return crypto.randomBytes(32).toString('hex');
}

function getCurrentTime() {
  return new Date().toISOString().slice(0, 19) + 'Z';
}

function parseBody(req) {
  return new Promise((resolve) => {
    let body = '';
    req.on('data', chunk => { body += chunk.toString(); });
    req.on('end', () => {
      if (!body) return resolve({});
      try {
        resolve(JSON.parse(body));
      } catch (e) {
        resolve(null);
      }
    });
  });
}

function sendJson(res, statusCode, data) {
  res.writeHead(statusCode, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(data));
}

function getAuthUser(req) {
  const cookies = {};
  if (req.headers.cookie) {
    req.headers.cookie.split(';').forEach(c => {
      const [name, ...val] = c.trim().split('=');
      cookies[name] = val.join('=');
    });
  }
  const sessionId = cookies['session_id'];
  if (sessionId && sessions[sessionId] !== undefined) {
    return users.find(u => u.id === sessions[sessionId]);
  }
  return null;
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://0.0.0.0');
  const path = url.pathname;
  const method = req.method;

  const parsedBody = await parseBody(req);

  if (method === 'POST' && path === '/register') {
    if (parsedBody === null) return sendJson(res, 400, { error: 'Invalid JSON' });
    const { username, password } = parsedBody || {};
    if (typeof username !== 'string' || !/^[a-zA-Z0-9_]{3,50}$/.test(username)) return sendJson(res, 400, { error: 'Invalid username' });
    if (typeof password !== 'string' || password.length < 8) return sendJson(res, 400, { error: 'Password too short' });
    if (users.find(u => u.username === username)) return sendJson(res, 409, { error: 'Username already exists' });
    const newUser = { id: nextUserId++, username, passwordHash: hashPassword(password) };
    users.push(newUser);
    return sendJson(res, 201, { id: newUser.id, username: newUser.username });
  }

  if (method === 'POST' && path === '/login') {
    if (parsedBody === null) return sendJson(res, 400, { error: 'Invalid JSON' });
    const { username, password } = parsedBody || {};
    const user = users.find(u => u.username === username);
    if (!user || user.passwordHash !== hashPassword(password)) return sendJson(res, 401, { error: 'Invalid credentials' });
    const token = generateToken();
    sessions[token] = user.id;
    res.setHeader('Set-Cookie', 'session_id=' + token + '; Path=/; HttpOnly');
    return sendJson(res, 200, { id: user.id, username: user.username });
  }

  if (method === 'POST' && path === '/logout') {
    const user = getAuthUser(req);
    if (!user) return sendJson(res, 401, { error: 'Authentication required' });
    let sessionId = null;
    if (req.headers.cookie) {
      req.headers.cookie.split(';').forEach(c => {
        const [name, ...val] = c.trim().split('=');
        if (name === 'session_id') sessionId = val.join('=');
      });
    }
    if (sessionId) delete sessions[sessionId];
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
    if (parsedBody === null) return sendJson(res, 400, { error: 'Invalid JSON' });
    const { old_password, new_password } = parsedBody || {};
    if (user.passwordHash !== hashPassword(old_password)) return sendJson(res, 401, { error: 'Invalid credentials' });
    if (typeof new_password !== 'string' || new_password.length < 8) return sendJson(res, 400, { error: 'Password too short' });
    user.passwordHash = hashPassword(new_password);
    return sendJson(res, 200, {});
  }

  if (method === 'GET' && path === '/todos') {
    const user = getAuthUser(req);
    if (!user) return sendJson(res, 401, { error: 'Authentication required' });
    const userTodos = Object.values(todos).filter(t => t.user_id === user.id).sort((a, b) => a.id - b.id);
    return sendJson(res, 200, userTodos);
  }

  if (method === 'POST' && path === '/todos') {
    const user = getAuthUser(req);
    if (!user) return sendJson(res, 401, { error: 'Authentication required' });
    if (parsedBody === null) return sendJson(res, 400, { error: 'Invalid JSON' });
    const { title, description } = parsedBody || {};
    if (typeof title !== 'string' || title === '') return sendJson(res, 400, { error: 'Title is required' });
    const now = getCurrentTime();
    const newTodo = { 
      id: nextTodoId++, 
      title, 
      description: typeof description === 'string' ? description : '', 
      completed: false, 
      created_at: now, 
      updated_at: now, 
      user_id: user.id 
    };
    todos[newTodo.id] = newTodo;
    return sendJson(res, 201, newTodo);
  }

  const todoMatch = path.match(/^\/todos\/(\d+)$/);
  if (todoMatch) {
    const todoId = parseInt(todoMatch[1], 10);
    
    if (method === 'GET') {
      const user = getAuthUser(req);
      if (!user) return sendJson(res, 401, { error: 'Authentication required' });
      const todo = todos[todoId];
      if (!todo || todo.user_id !== user.id) return sendJson(res, 404, { error: 'Todo not found' });
      return sendJson(res, 200, todo);
    }

    if (method === 'PUT') {
      const user = getAuthUser(req);
      if (!user) return sendJson(res, 401, { error: 'Authentication required' });
      const todo = todos[todoId];
      if (!todo || todo.user_id !== user.id) return sendJson(res, 404, { error: 'Todo not found' });
      if (parsedBody === null) return sendJson(res, 400, { error: 'Invalid JSON' });
      
      if (parsedBody.title !== undefined) {
        if (typeof parsedBody.title !== 'string' || parsedBody.title === '') return sendJson(res, 400, { error: 'Title is required' });
        todo.title = parsedBody.title;
      }
      if (parsedBody.description !== undefined) todo.description = parsedBody.description;
      if (parsedBody.completed !== undefined) todo.completed = Boolean(parsedBody.completed);
      
      todo.updated_at = getCurrentTime();
      return sendJson(res, 200, todo);
    }

    if (method === 'DELETE') {
      const user = getAuthUser(req);
      if (!user) return sendJson(res, 401, { error: 'Authentication required' });
      const todo = todos[todoId];
      if (!todo || todo.user_id !== user.id) return sendJson(res, 404, { error: 'Todo not found' });
      delete todos[todoId];
      res.writeHead(204);
      return res.end();
    }
  }

  sendJson(res, 404, { error: 'Not found' });
});

const portArgIndex = process.argv.indexOf('--port');
const port = portArgIndex !== -1 ? parseInt(process.argv[portArgIndex + 1], 10) : 3000;

server.listen(port, '0.0.0.0', () => {
  console.log('Server listening on 0.0.0.0:' + port);
});
