const http = require('http');
const crypto = require('crypto');

const users = [];
const todos = [];
const sessions = new Map();

let nextUserId = 1;
let nextTodoId = 1;

function parseBody(req) {
  return new Promise((resolve, reject) => {
    let body = '';
    req.on('data', chunk => { body += chunk.toString(); });
    req.on('end', () => {
      try {
        resolve(body ? JSON.parse(body) : {});
      } catch (e) {
        reject(new Error('Invalid JSON'));
      }
    });
    req.on('error', reject);
  });
}

function getCookie(req, name) {
  const cookieHeader = req.headers.cookie;
  if (!cookieHeader) return null;
  const cookies = cookieHeader.split(';');
  for (const c of cookies) {
    const eqIndex = c.indexOf('=');
    if (eqIndex !== -1) {
      const key = c.substring(0, eqIndex).trim();
      const value = c.substring(eqIndex + 1).trim();
      if (key === name) return value;
    }
  }
  return null;
}

function getCurrentUser(req) {
  const token = getCookie(req, 'session_id');
  if (!token || !sessions.has(token)) return null;
  const userId = sessions.get(token);
  return users.find(u => u.id === userId) || null;
}

function sendJson(res, statusCode, data) {
  res.writeHead(statusCode, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(data));
}

function sendEmpty(res, statusCode) {
  res.writeHead(statusCode, { 'Content-Type': 'application/json' });
  res.end();
}

function requireAuth(req, res) {
  const user = getCurrentUser(req);
  if (!user) {
    sendJson(res, 401, { error: 'Authentication required' });
    return null;
  }
  return user;
}

function getTimestamp() {
  return new Date().toISOString().replace(/\.\d{3}Z$/, 'Z');
}

async function handleRequest(req, res) {
  const url = new URL(req.url, `http://${req.headers.host}`);
  const path = url.pathname;
  const method = req.method;

  try {
    if (method === 'POST' && path === '/register') {
      const body = await parseBody(req);
      const { username, password } = body;

      if (typeof username !== 'string' || !/^[a-zA-Z0-9_]{3,50}$/.test(username)) {
        return sendJson(res, 400, { error: 'Invalid username' });
      }
      if (typeof password !== 'string' || password.length < 8) {
        return sendJson(res, 400, { error: 'Password too short' });
      }
      if (users.some(u => u.username === username)) {
        return sendJson(res, 409, { error: 'Username already exists' });
      }

      const newUser = { id: nextUserId++, username, password };
      users.push(newUser);
      return sendJson(res, 201, { id: newUser.id, username: newUser.username });
    }

    if (method === 'POST' && path === '/login') {
      const body = await parseBody(req);
      const { username, password } = body;

      const user = users.find(u => u.username === username && u.password === password);
      if (!user) {
        return sendJson(res, 401, { error: 'Invalid credentials' });
      }

      const token = crypto.randomBytes(32).toString('hex');
      sessions.set(token, user.id);
      
      res.writeHead(200, {
        'Content-Type': 'application/json',
        'Set-Cookie': `session_id=${token}; Path=/; HttpOnly`
      });
      return res.end(JSON.stringify({ id: user.id, username: user.username }));
    }

    if (method === 'POST' && path === '/logout') {
      const user = requireAuth(req, res);
      if (!user) return;
      const token = getCookie(req, 'session_id');
      sessions.delete(token);
      return sendJson(res, 200, {});
    }

    if (method === 'GET' && path === '/me') {
      const user = requireAuth(req, res);
      if (!user) return;
      return sendJson(res, 200, { id: user.id, username: user.username });
    }

    if (method === 'PUT' && path === '/password') {
      const user = requireAuth(req, res);
      if (!user) return;
      const body = await parseBody(req);
      const { old_password, new_password } = body;

      const actualUser = users.find(u => u.id === user.id);
      if (!actualUser || actualUser.password !== old_password) {
        return sendJson(res, 401, { error: 'Invalid credentials' });
      }
      if (typeof new_password !== 'string' || new_password.length < 8) {
        return sendJson(res, 400, { error: 'Password too short' });
      }

      actualUser.password = new_password;
      return sendJson(res, 200, {});
    }

    if (method === 'GET' && path === '/todos') {
      const user = requireAuth(req, res);
      if (!user) return;
      const userTodos = todos.filter(t => t.userId === user.id).sort((a, b) => a.id - b.id);
      return sendJson(res, 200, userTodos);
    }

    if (method === 'POST' && path === '/todos') {
      const user = requireAuth(req, res);
      if (!user) return;
      const body = await parseBody(req);
      const { title, description } = body;

      if (typeof title !== 'string' || title.length === 0) {
        return sendJson(res, 400, { error: 'Title is required' });
      }

      const now = getTimestamp();
      const newTodo = {
        id: nextTodoId++,
        userId: user.id,
        title: title,
        description: typeof description === 'string' ? description : '',
        completed: false,
        created_at: now,
        updated_at: now
      };
      todos.push(newTodo);
      
      const { userId, ...responseTodo } = newTodo;
      return sendJson(res, 201, responseTodo);
    }

    const todoMatch = path.match(/^\/todos\/(\d+)$/);
    if (todoMatch) {
      const todoId = parseInt(todoMatch[1], 10);
      
      if (method === 'GET') {
        const user = requireAuth(req, res);
        if (!user) return;
        const todo = todos.find(t => t.id === todoId && t.userId === user.id);
        if (!todo) {
          return sendJson(res, 404, { error: 'Todo not found' });
        }
        const { userId, ...responseTodo } = todo;
        return sendJson(res, 200, responseTodo);
      }

      if (method === 'PUT') {
        const user = requireAuth(req, res);
        if (!user) return;
        const todo = todos.find(t => t.id === todoId && t.userId === user.id);
        if (!todo) {
          return sendJson(res, 404, { error: 'Todo not found' });
        }
        
        const body = await parseBody(req);
        
        if (body.title !== undefined) {
          if (typeof body.title !== 'string' || body.title.length === 0) {
            return sendJson(res, 400, { error: 'Title is required' });
          }
          todo.title = body.title;
        }
        if (body.description !== undefined) {
          todo.description = body.description;
        }
        if (body.completed !== undefined) {
          todo.completed = Boolean(body.completed);
        }
        todo.updated_at = getTimestamp();

        const { userId, ...responseTodo } = todo;
        return sendJson(res, 200, responseTodo);
      }

      if (method === 'DELETE') {
        const user = requireAuth(req, res);
        if (!user) return;
        const todoIndex = todos.findIndex(t => t.id === todoId && t.userId === user.id);
        if (todoIndex === -1) {
          return sendJson(res, 404, { error: 'Todo not found' });
        }
        todos.splice(todoIndex, 1);
        return sendEmpty(res, 204);
      }
    }

    return sendJson(res, 404, { error: 'Not found' });

  } catch (e) {
    if (e.message === 'Invalid JSON') {
      return sendJson(res, 400, { error: 'Invalid JSON' });
    }
    return sendJson(res, 500, { error: 'Internal server error' });
  }
}

const server = http.createServer(handleRequest);

const args = process.argv.slice(2);
let port = 3000;
for (let i = 0; i < args.length; i++) {
  if (args[i] === '--port' && args[i+1]) {
    port = parseInt(args[i+1], 10);
    i++;
  }
}

server.listen(port, '0.0.0.0', () => {
  console.log(`Server listening on 0.0.0.0:${port}`);
});