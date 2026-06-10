// Minimal TypeScript server without external deps
// Using Node's http module and manual routing to meet the specification

// Ambient declarations to avoid needing @types/node
declare var require: any;
declare var Buffer: any;
declare var process: any;

const http = require('http');
const url = require('url');
const crypto = require('crypto');

type IncomingMessage = any;
type ServerResponse = any;

type User = {
  id: number;
  username: string;
  password: string;
};

type Todo = {
  id: number;
  userId: number;
  title: string;
  description: string;
  completed: boolean;
  created_at: string;
  updated_at: string;
};

const users: User[] = [];
let nextUserId = 1;
const usernameToUserId = new Map<string, number>();

const todos: Todo[] = [];
let nextTodoId = 1;

const sessions = new Map<string, number>();

function nowIsoSeconds(): string {
  return new Date().toISOString().replace(/\.\d{3}Z$/, 'Z');
}

function parseCookies(header: string | undefined): Record<string, string> {
  const cookies: Record<string, string> = {};
  if (!header) return cookies;
  const parts = header.split(';');
  for (const part of parts) {
    const [k, ...vparts] = part.trim().split('=');
    if (!k) continue;
    const v = vparts.join('=');
    cookies[k] = decodeURIComponent(v || '');
  }
  return cookies;
}

function sendJson(res: ServerResponse, status: number, obj: any) {
  const body = JSON.stringify(obj);
  res.statusCode = status;
  res.setHeader('Content-Type', 'application/json');
  res.setHeader('Content-Length', Buffer.byteLength(body));
  res.end(body);
}

function sendNoContent(res: ServerResponse, status: number) {
  res.statusCode = status;
  // No content type for 204 per spec
  res.end();
}

function readJsonBody(req: IncomingMessage): Promise<any> {
  return new Promise((resolve, reject) => {
    const chunks: any[] = [];
    let size = 0;
    req.on('data', (chunk: any) => {
      size += chunk.length;
      if (size > 1_000_000) {
        reject(new Error('Payload too large'));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => {
      if (size === 0) {
        resolve({});
        return;
      }
      try {
        const text = Buffer.concat(chunks).toString('utf8');
        const obj = JSON.parse(text);
        resolve(obj);
      } catch (e) {
        reject(new Error('Invalid JSON'));
      }
    });
    req.on('error', (err: any) => reject(err));
  });
}

function generateToken(): string {
  return crypto.randomBytes(16).toString('hex');
}

function validateUsername(username: any): username is string {
  return typeof username === 'string' && username.length >= 3 && username.length <= 50 && /^[a-zA-Z0-9_]+$/.test(username);
}

function publicUser(u: User) {
  return { id: u.id, username: u.username };
}

function authUser(req: IncomingMessage, res: ServerResponse): { userId: number } | null {
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
  (req as any).sessionToken = token;
  return { userId };
}

function stripUserId(t: Todo) {
  const { userId, ...rest } = t as any;
  return rest;
}

function route(req: IncomingMessage, res: ServerResponse) {
  const parsed = url.parse(req.url || '', true);
  const method = (req.method || 'GET').toUpperCase();
  const pathname = parsed.pathname || '/';

  // Helper to match /todos/:id
  const todosIdMatch = pathname.match(/^\/todos\/(\d+)$/);

  // POST /register
  if (method === 'POST' && pathname === '/register') {
    return readJsonBody(req).then(body => {
      const { username, password } = body || {};
      if (!validateUsername(username)) return sendJson(res, 400, { error: 'Invalid username' });
      if (typeof password !== 'string' || password.length < 8) return sendJson(res, 400, { error: 'Password too short' });
      if (usernameToUserId.has(username)) return sendJson(res, 409, { error: 'Username already exists' });
      const user: User = { id: nextUserId++, username, password };
      users.push(user);
      usernameToUserId.set(username, user.id);
      return sendJson(res, 201, publicUser(user));
    }).catch(() => {
      return sendJson(res, 400, { error: 'Invalid JSON' });
    });
  }

  // POST /login
  if (method === 'POST' && pathname === '/login') {
    return readJsonBody(req).then(body => {
      const { username, password } = body || {};
      if (typeof username !== 'string' || typeof password !== 'string') return sendJson(res, 401, { error: 'Invalid credentials' });
      const uid = usernameToUserId.get(username);
      if (!uid) return sendJson(res, 401, { error: 'Invalid credentials' });
      const user = users.find(u => u.id === uid);
      if (!user || user.password !== password) return sendJson(res, 401, { error: 'Invalid credentials' });
      const token = generateToken();
      sessions.set(token, user.id);
      res.setHeader('Set-Cookie', `session_id=${token}; Path=/; HttpOnly`);
      return sendJson(res, 200, publicUser(user));
    }).catch(() => sendJson(res, 400, { error: 'Invalid JSON' }));
  }

  // POST /logout
  if (method === 'POST' && pathname === '/logout') {
    const auth = authUser(req, res);
    if (!auth) return;
    const token = (req as any).sessionToken as string | undefined;
    if (token) sessions.delete(token);
    return sendJson(res, 200, {});
  }

  // GET /me
  if (method === 'GET' && pathname === '/me') {
    const auth = authUser(req, res);
    if (!auth) return;
    const user = users.find(u => u.id === auth.userId)!;
    return sendJson(res, 200, publicUser(user));
  }

  // PUT /password
  if (method === 'PUT' && pathname === '/password') {
    const auth = authUser(req, res);
    if (!auth) return;
    return readJsonBody(req).then(body => {
      const { old_password, new_password } = body || {};
      const user = users.find(u => u.id === auth.userId)!;
      if (typeof old_password !== 'string' || user.password !== old_password) return sendJson(res, 401, { error: 'Invalid credentials' });
      if (typeof new_password !== 'string' || new_password.length < 8) return sendJson(res, 400, { error: 'Password too short' });
      user.password = new_password;
      return sendJson(res, 200, {});
    }).catch(() => sendJson(res, 400, { error: 'Invalid JSON' }));
  }

  // GET /todos
  if (method === 'GET' && pathname === '/todos') {
    const auth = authUser(req, res);
    if (!auth) return;
    const list = todos.filter(t => t.userId === auth.userId).sort((a, b) => a.id - b.id);
    return sendJson(res, 200, list.map(stripUserId));
  }

  // POST /todos
  if (method === 'POST' && pathname === '/todos') {
    const auth = authUser(req, res);
    if (!auth) return;
    return readJsonBody(req).then(body => {
      const { title, description } = body || {};
      if (typeof title !== 'string' || title.trim() === '') return sendJson(res, 400, { error: 'Title is required' });
      const now = nowIsoSeconds();
      const todo: Todo = {
        id: nextTodoId++,
        userId: auth.userId,
        title: title,
        description: typeof description === 'string' ? description : '',
        completed: false,
        created_at: now,
        updated_at: now,
      };
      todos.push(todo);
      return sendJson(res, 201, stripUserId(todo));
    }).catch(() => sendJson(res, 400, { error: 'Invalid JSON' }));
  }

  // GET /todos/:id
  if (method === 'GET' && todosIdMatch) {
    const auth = authUser(req, res);
    if (!auth) return;
    const id = Number(todosIdMatch[1]);
    const t = todos.find(tt => tt.id === id && tt.userId === auth.userId);
    if (!t) return sendJson(res, 404, { error: 'Todo not found' });
    return sendJson(res, 200, stripUserId(t));
  }

  // PUT /todos/:id
  if (method === 'PUT' && todosIdMatch) {
    const auth = authUser(req, res);
    if (!auth) return;
    const id = Number(todosIdMatch[1]);
    const t = todos.find(tt => tt.id === id && tt.userId === auth.userId);
    if (!t) return sendJson(res, 404, { error: 'Todo not found' });
    return readJsonBody(req).then(body => {
      if (Object.prototype.hasOwnProperty.call(body, 'title')) {
        if (typeof body.title !== 'string' || body.title.trim() === '') return sendJson(res, 400, { error: 'Title is required' });
        t.title = body.title;
      }
      if (Object.prototype.hasOwnProperty.call(body, 'description')) {
        t.description = typeof body.description === 'string' ? body.description : '';
      }
      if (Object.prototype.hasOwnProperty.call(body, 'completed')) {
        t.completed = typeof body.completed === 'boolean' ? body.completed : Boolean(body.completed);
      }
      t.updated_at = nowIsoSeconds();
      return sendJson(res, 200, stripUserId(t));
    }).catch(() => sendJson(res, 400, { error: 'Invalid JSON' }));
  }

  // DELETE /todos/:id
  if (method === 'DELETE' && todosIdMatch) {
    const auth = authUser(req, res);
    if (!auth) return;
    const id = Number(todosIdMatch[1]);
    const idx = todos.findIndex(tt => tt.id === id && tt.userId === auth.userId);
    if (idx === -1) return sendJson(res, 404, { error: 'Todo not found' });
    todos.splice(idx, 1);
    return sendNoContent(res, 204);
  }

  // Not found
  return sendJson(res, 404, { error: 'Not found' });
}

function parsePortArg(argv: string[]): number | null {
  const idx = argv.indexOf('--port');
  if (idx !== -1 && idx + 1 < argv.length) {
    const p = Number(argv[idx + 1]);
    if (Number.isInteger(p) && p > 0 && p < 65536) return p;
  }
  return null;
}

const port = parsePortArg(process.argv as any) || 3000;

const server = http.createServer((req: IncomingMessage, res: ServerResponse) => {
  // Default JSON content-type; overridden for 204
  // We'll set per response in sendJson
  try {
    route(req, res);
  } catch (e) {
    try {
      sendJson(res, 500, { error: 'Internal server error' });
    } catch {}
  }
});

server.listen(port, '0.0.0.0', () => {
  console.log(`Server listening on 0.0.0.0:${port}`);
});
