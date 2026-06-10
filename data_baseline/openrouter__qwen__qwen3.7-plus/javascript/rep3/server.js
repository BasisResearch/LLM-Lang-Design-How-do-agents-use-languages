const http = require('http');
const crypto = require('crypto');

let nextUserId = 1;
let nextTodoId = 1;

const users = [];
const sessions = new Map();
const todos = [];

function getTimestamp() {
  return new Date().toISOString().split('.')[0] + 'Z';
}

function hashPassword(password) {
  return crypto.createHash('sha256').update(password).digest('hex');
}

function generateToken() {
  return crypto.randomBytes(16).toString('hex');
}

function sendJson(res, statusCode, data) {
  res.writeHead(statusCode, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(data));
}

function sendNoContent(res, statusCode) {
  res.writeHead(statusCode);
  res.end();
}

function parseBody(req) {
  return new Promise((resolve, reject) => {
    let body = '';
    req.on('data', chunk => {
      body += chunk.toString();
    });
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

function getSessionToken(req) {
  const cookieHeader = req.headers.cookie;
  if (!cookieHeader) return null;
  const cookies = cookieHeader.split(';').map(c => c.trim());
  const sessionCookie = cookies.find(c => c.startsWith('session_id='));
  if (!sessionCookie) return null;
  return sessionCookie.substring('session_id='.length);
}

function getSessionUserId(req) {
  const token = getSessionToken(req);
  if (!token) return null;
  return sessions.get(token) || null;
}

function authMiddleware(req, res) {
  const userId = getSessionUserId(req);
  if (!userId) {
    sendJson(res, 401, { error: 'Authentication required' });
    return null;
  }
  return userId;
}

const server = http.createServer(async (req, res) => {
  const parsedUrl = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
  const pathname = parsedUrl.pathname;
  const method = req.method;

  try {
    if (method === 'POST' && pathname === '/register') {
      const body = await parseBody(req);
      const { username, password } = body;
      
      if (typeof username !== 'string' || typeof password !== 'string') {
        return sendJson(res, 400, { error: 'Invalid request body' });
      }
      
      if (username.length < 3 || username.length > 50 || !/^[a-zA-Z0-9_]+$/.test(username)) {
        return sendJson(res, 400, { error: 'Invalid username' });
      }
      if (password.length < 8) {
        return sendJson(res, 400, { error: 'Password too short' });
      }
      
      const existingUser = users.find(u => u.username === username);
      if (existingUser) {
        return sendJson(res, 409, { error: 'Username already exists' });
      }
      
      const newUser = {
        id: nextUserId++,
        username,
        password: hashPassword(password)
      };
      users.push(newUser);
      
      return sendJson(res, 201, { id: newUser.id, username: newUser.username });
    }

    if (method === 'POST' && pathname === '/login') {
      const body = await parseBody(req);
      const { username, password } = body;
      
      if (typeof username !== 'string' || typeof password !== 'string') {
        return sendJson(res, 400, { error: 'Invalid request body' });
      }
      
      const user = users.find(u => u.username === username && u.password === hashPassword(password));
      if (!user) {
        return sendJson(res, 401, { error: 'Invalid credentials' });
      }
      
      const token = generateToken();
      sessions.set(token, user.id);
      
      res.writeHead(200, {
        'Content-Type': 'application/json',
        'Set-Cookie': `session_id=${token}; Path=/; HttpOnly`
      });
      res.end(JSON.stringify({ id: user.id, username: user.username }));
      return;
    }

    if (method === 'POST' && pathname === '/logout') {
      const userId = authMiddleware(req, res);
      if (!userId) return;
      
      const token = getSessionToken(req);
      sessions.delete(token);
      return sendJson(res, 200, {});
    }

    if (method === 'GET' && pathname === '/me') {
      const userId = authMiddleware(req, res);
      if (!userId) return;
      
      const user = users.find(u => u.id === userId);
      if (!user) {
        return sendJson(res, 401, { error: 'Authentication required' });
      }
      return sendJson(res, 200, { id: user.id, username: user.username });
    }

    if (method === 'PUT' && pathname === '/password') {
      const userId = authMiddleware(req, res);
      if (!userId) return;
      
      const body = await parseBody(req);
      const { old_password, new_password } = body;
      
      if (typeof old_password !== 'string' || typeof new_password !== 'string') {
        return sendJson(res, 400, { error: 'Invalid request body' });
      }
      
      const user = users.find(u => u.id === userId);
      if (!user || user.password !== hashPassword(old_password)) {
        return sendJson(res, 401, { error: 'Invalid credentials' });
      }
      if (new_password.length < 8) {
        return sendJson(res, 400, { error: 'Password too short' });
      }
      
      user.password = hashPassword(new_password);
      return sendJson(res, 200, {});
    }

    if (method === 'GET' && pathname === '/todos') {
      const userId = authMiddleware(req, res);
      if (!userId) return;
      
      const userTodos = todos.filter(t => t.userId === userId).sort((a, b) => a.id - b.id);
      return sendJson(res, 200, userTodos);
    }

    if (method === 'POST' && pathname === '/todos') {
      const userId = authMiddleware(req, res);
      if (!userId) return;
      
      const body = await parseBody(req);
      
      if (typeof body.title !== 'string' || body.title.trim() === '') {
        return sendJson(res, 400, { error: 'Title is required' });
      }
      
      const now = getTimestamp();
      const newTodo = {
        id: nextTodoId++,
        userId,
        title: body.title,
        description: (typeof body.description === 'string') ? body.description : '',
        completed: false,
        created_at: now,
        updated_at: now
      };
      
      todos.push(newTodo);
      return sendJson(res, 201, newTodo);
    }

    const todoMatch = pathname.match(/^\/todos\/(\d+)$/);
    if (todoMatch) {
      const todoId = parseInt(todoMatch[1], 10);
      
      if (method === 'GET') {
        const userId = authMiddleware(req, res);
        if (!userId) return;
        
        const todo = todos.find(t => t.id === todoId && t.userId === userId);
        if (!todo) {
          return sendJson(res, 404, { error: 'Todo not found' });
        }
        return sendJson(res, 200, todo);
      }

      if (method === 'PUT') {
        const userId = authMiddleware(req, res);
        if (!userId) return;
        
        const todo = todos.find(t => t.id === todoId && t.userId === userId);
        if (!todo) {
          return sendJson(res, 404, { error: 'Todo not found' });
        }
        
        const body = await parseBody(req);
        
        if (body.title !== undefined) {
          if (typeof body.title !== 'string' || body.title.trim() === '') {
            return sendJson(res, 400, { error: 'Title is required' });
          }
          todo.title = body.title;
        }
        if (body.description !== undefined) {
          if (typeof body.description !== 'string') {
            return sendJson(res, 400, { error: 'Invalid request body' });
          }
          todo.description = body.description;
        }
        if (body.completed !== undefined) {
          if (typeof body.completed !== 'boolean') {
            return sendJson(res, 400, { error: 'Invalid request body' });
          }
          todo.completed = body.completed;
        }
        
        todo.updated_at = getTimestamp();
        return sendJson(res, 200, todo);
      }

      if (method === 'DELETE') {
        const userId = authMiddleware(req, res);
        if (!userId) return;
        
        const todoIndex = todos.findIndex(t => t.id === todoId && t.userId === userId);
        if (todoIndex === -1) {
          return sendJson(res, 404, { error: 'Todo not found' });
        }
        
        todos.splice(todoIndex, 1);
        return sendNoContent(res, 204);
      }
    }

    return sendJson(res, 404, { error: 'Not found' });

  } catch (e) {
    if (e.message === 'Invalid JSON') {
      return sendJson(res, 400, { error: 'Invalid JSON' });
    }
    console.error(e);
    return sendJson(res, 500, { error: 'Internal server error' });
  }
});

const portArg = process.argv.indexOf('--port');
const port = portArg !== -1 ? parseInt(process.argv[portArg + 1], 10) : 3000;

server.listen(port, '0.0.0.0', () => {
  console.log(`Server listening on 0.0.0.0:${port}`);
});
