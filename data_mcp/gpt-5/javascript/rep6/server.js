const http = require('http');
const crypto = require('crypto');
const { URL } = require('url');

// In-memory storage
const usersById = new Map(); // id -> {id, username, passwordHash, salt}
const usersByUsername = new Map(); // username -> id
let nextUserId = 1;

const sessions = new Map(); // token -> userId

const todosById = new Map(); // id -> {id, user_id, title, description, completed, created_at, updated_at}
let nextTodoId = 1;

function isoNowSeconds() {
  const d = new Date();
  // toISOString gives YYYY-MM-DDTHH:mm:ss.sssZ; strip milliseconds
  return d.toISOString().replace(/\..+Z$/, 'Z');
}

function sendJSON(res, statusCode, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(statusCode, {
    'Content-Type': 'application/json',
    'Content-Length': Buffer.byteLength(body)
  });
  res.end(body);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let data = '';
    req.on('data', chunk => {
      data += chunk;
      if (data.length > 1e6) { // 1MB limit for safety
        reject(new Error('Payload too large'));
        req.connection.destroy();
      }
    });
    req.on('end', () => {
      if (!data) return resolve(null);
      try {
        resolve(JSON.parse(data));
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
    const [name, ...rest] = part.trim().split('=');
    if (!name) continue;
    const value = rest.join('=');
    cookies[name] = decodeURIComponent(value || '');
  }
  return cookies;
}

function generateToken() {
  return crypto.randomBytes(32).toString('hex');
}

function hashPassword(password, salt) {
  // Use PBKDF2 with SHA256
  return crypto.pbkdf2Sync(password, salt, 100000, 32, 'sha256').toString('hex');
}

function createUser(username, password) {
  const id = nextUserId++;
  const salt = crypto.randomBytes(16).toString('hex');
  const passwordHash = hashPassword(password, salt);
  const user = { id, username, passwordHash, salt };
  usersById.set(id, user);
  usersByUsername.set(username, id);
  return { id, username };
}

function verifyUserPassword(user, password) {
  const testHash = hashPassword(password, user.salt);
  return crypto.timingSafeEqual(Buffer.from(testHash, 'hex'), Buffer.from(user.passwordHash, 'hex'));
}

function getAuthUser(req, res) {
  const cookies = parseCookies(req);
  const token = cookies['session_id'];
  if (!token) {
    sendJSON(res, 401, { error: 'Authentication required' });
    return null;
  }
  const userId = sessions.get(token);
  if (!userId) {
    sendJSON(res, 401, { error: 'Authentication required' });
    return null;
  }
  const user = usersById.get(userId);
  if (!user) {
    // Stale session
    sessions.delete(token);
    sendJSON(res, 401, { error: 'Authentication required' });
    return null;
  }
  return { user, token };
}

function route(req, res) {
  const url = new URL(req.url, 'http://localhost');
  const method = req.method || 'GET';
  const path = url.pathname;

  // Helper to extract ID for /todos/:id
  const matchTodoId = () => {
    const parts = path.split('/').filter(Boolean);
    if (parts.length === 2 && parts[0] === 'todos') {
      const id = parseInt(parts[1], 10);
      if (!Number.isInteger(id) || id <= 0) return null;
      return id;
    }
    return null;
  };

  // POST /register
  if (method === 'POST' && path === '/register') {
    readBody(req).then(body => {
      if (!body || typeof body !== 'object') {
        return sendJSON(res, 400, { error: 'Invalid JSON' });
      }
      const { username, password } = body;
      const usernameRegex = /^[a-zA-Z0-9_]{3,50}$/;
      if (!username || typeof username !== 'string' || !usernameRegex.test(username)) {
        return sendJSON(res, 400, { error: 'Invalid username' });
      }
      if (!password || typeof password !== 'string' || password.length < 8) {
        return sendJSON(res, 400, { error: 'Password too short' });
      }
      if (usersByUsername.has(username)) {
        return sendJSON(res, 409, { error: 'Username already exists' });
      }
      const userPublic = createUser(username, password);
      return sendJSON(res, 201, userPublic);
    }).catch(err => {
      if (err && err.message === 'Invalid JSON') return sendJSON(res, 400, { error: 'Invalid JSON' });
      return sendJSON(res, 400, { error: 'Bad Request' });
    });
    return;
  }

  // POST /login
  if (method === 'POST' && path === '/login') {
    readBody(req).then(body => {
      if (!body || typeof body !== 'object') {
        return sendJSON(res, 401, { error: 'Invalid credentials' });
      }
      const { username, password } = body;
      if (!username || !password) {
        return sendJSON(res, 401, { error: 'Invalid credentials' });
      }
      const userId = usersByUsername.get(username);
      if (!userId) {
        return sendJSON(res, 401, { error: 'Invalid credentials' });
      }
      const user = usersById.get(userId);
      if (!verifyUserPassword(user, password)) {
        return sendJSON(res, 401, { error: 'Invalid credentials' });
      }
      const token = generateToken();
      sessions.set(token, user.id);
      const bodyOut = JSON.stringify({ id: user.id, username: user.username });
      res.writeHead(200, {
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(bodyOut),
        'Set-Cookie': `session_id=${token}; Path=/; HttpOnly`
      });
      res.end(bodyOut);
    }).catch(err => {
      return sendJSON(res, 400, { error: 'Bad Request' });
    });
    return;
  }

  // POST /logout (Auth)
  if (method === 'POST' && path === '/logout') {
    const auth = getAuthUser(req, res);
    if (!auth) return; // response already sent
    // Invalidate session
    sessions.delete(auth.token);
    return sendJSON(res, 200, {});
  }

  // GET /me (Auth)
  if (method === 'GET' && path === '/me') {
    const auth = getAuthUser(req, res);
    if (!auth) return;
    const user = auth.user;
    return sendJSON(res, 200, { id: user.id, username: user.username });
  }

  // PUT /password (Auth)
  if (method === 'PUT' && path === '/password') {
    const auth = getAuthUser(req, res);
    if (!auth) return;
    const user = auth.user;
    readBody(req).then(body => {
      if (!body || typeof body !== 'object') {
        return sendJSON(res, 400, { error: 'Bad Request' });
      }
      const { old_password, new_password } = body;
      if (!old_password || !verifyUserPassword(user, old_password)) {
        return sendJSON(res, 401, { error: 'Invalid credentials' });
      }
      if (!new_password || typeof new_password !== 'string' || new_password.length < 8) {
        return sendJSON(res, 400, { error: 'Password too short' });
      }
      const newSalt = crypto.randomBytes(16).toString('hex');
      const newHash = hashPassword(new_password, newSalt);
      user.salt = newSalt;
      user.passwordHash = newHash;
      usersById.set(user.id, user);
      return sendJSON(res, 200, {});
    }).catch(err => sendJSON(res, 400, { error: 'Bad Request' }));
    return;
  }

  // GET /todos (Auth)
  if (method === 'GET' && path === '/todos') {
    const auth = getAuthUser(req, res);
    if (!auth) return;
    const userId = auth.user.id;
    const list = [];
    for (const todo of todosById.values()) {
      if (todo.user_id === userId) list.push({ ...todo });
    }
    list.sort((a, b) => a.id - b.id);
    return sendJSON(res, 200, list);
  }

  // POST /todos (Auth)
  if (method === 'POST' && path === '/todos') {
    const auth = getAuthUser(req, res);
    if (!auth) return;
    readBody(req).then(body => {
      if (!body || typeof body !== 'object') {
        return sendJSON(res, 400, { error: 'Bad Request' });
      }
      let { title, description } = body;
      if (typeof title !== 'string' || title.trim() === '') {
        return sendJSON(res, 400, { error: 'Title is required' });
      }
      if (typeof description !== 'string') description = '';
      const now = isoNowSeconds();
      const todo = {
        id: nextTodoId++,
        user_id: auth.user.id,
        title: title,
        description: description,
        completed: false,
        created_at: now,
        updated_at: now
      };
      todosById.set(todo.id, todo);
      const { user_id, ...publicTodo } = todo;
      return sendJSON(res, 201, publicTodo);
    }).catch(err => sendJSON(res, 400, { error: 'Bad Request' }));
    return;
  }

  // GET /todos/:id (Auth)
  if (method === 'GET' && path.startsWith('/todos/')) {
    const auth = getAuthUser(req, res);
    if (!auth) return;
    const id = matchTodoId();
    if (!id) return sendJSON(res, 404, { error: 'Todo not found' });
    const todo = todosById.get(id);
    if (!todo || todo.user_id !== auth.user.id) {
      return sendJSON(res, 404, { error: 'Todo not found' });
    }
    const { user_id, ...publicTodo } = todo;
    return sendJSON(res, 200, publicTodo);
  }

  // PUT /todos/:id (Auth)
  if (method === 'PUT' && path.startsWith('/todos/')) {
    const auth = getAuthUser(req, res);
    if (!auth) return;
    const id = matchTodoId();
    if (!id) return sendJSON(res, 404, { error: 'Todo not found' });
    const todo = todosById.get(id);
    if (!todo || todo.user_id !== auth.user.id) {
      return sendJSON(res, 404, { error: 'Todo not found' });
    }
    readBody(req).then(body => {
      if (!body || typeof body !== 'object') {
        return sendJSON(res, 400, { error: 'Bad Request' });
      }
      if (Object.prototype.hasOwnProperty.call(body, 'title')) {
        if (typeof body.title !== 'string' || body.title.trim() === '') {
          return sendJSON(res, 400, { error: 'Title is required' });
        }
        todo.title = body.title;
      }
      if (Object.prototype.hasOwnProperty.call(body, 'description')) {
        if (typeof body.description === 'string') todo.description = body.description; else todo.description = '';
      }
      if (Object.prototype.hasOwnProperty.call(body, 'completed')) {
        // Only accept boolean
        if (typeof body.completed === 'boolean') todo.completed = body.completed;
        else return sendJSON(res, 400, { error: 'Bad Request' });
      }
      todo.updated_at = isoNowSeconds();
      todosById.set(todo.id, todo);
      const { user_id, ...publicTodo } = todo;
      return sendJSON(res, 200, publicTodo);
    }).catch(err => sendJSON(res, 400, { error: 'Bad Request' }));
    return;
  }

  // DELETE /todos/:id (Auth)
  if (method === 'DELETE' && path.startsWith('/todos/')) {
    const auth = getAuthUser(req, res);
    if (!auth) return;
    const id = matchTodoId();
    if (!id) {
      // 404 with JSON? Spec says DELETE returns no body on success; for errors we still use JSON
      return sendJSON(res, 404, { error: 'Todo not found' });
    }
    const todo = todosById.get(id);
    if (!todo || todo.user_id !== auth.user.id) {
      return sendJSON(res, 404, { error: 'Todo not found' });
    }
    todosById.delete(id);
    res.writeHead(204);
    return res.end();
  }

  // Unknown route
  return sendJSON(res, 404, { error: 'Not found' });
}

function createServer() {
  const server = http.createServer((req, res) => {
    // Ensure we only send JSON for all responses except successful DELETEs, which we handle specially above.
    // Route handling may send response; if not, catch errors here.
    try {
      route(req, res);
    } catch (e) {
      try {
        sendJSON(res, 500, { error: 'Internal Server Error' });
      } catch (_) {
        // ignore
      }
    }
  });
  return server;
}

function parseArgs(argv) {
  const args = { port: 3000 };
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--port' && i + 1 < argv.length) {
      args.port = parseInt(argv[i + 1], 10);
      i++;
    }
  }
  if (!Number.isInteger(args.port) || args.port <= 0 || args.port > 65535) {
    console.error('Invalid port');
    process.exit(1);
  }
  return args;
}

if (require.main === module) {
  const { port } = parseArgs(process.argv);
  const server = createServer();
  server.listen(port, '0.0.0.0', () => {
    // eslint-disable-next-line no-console
    console.log(`Server listening on 0.0.0.0:${port}`);
  });
}

module.exports = { createServer };