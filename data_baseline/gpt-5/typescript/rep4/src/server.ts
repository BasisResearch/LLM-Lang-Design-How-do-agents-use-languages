import http, { IncomingMessage, ServerResponse } from 'http';
import { parse as parseUrl } from 'url';
import crypto from 'crypto';

// Types
interface User { id: number; username: string; passwordHash: string }
interface PublicUser { id: number; username: string }
interface Todo { id: number; userId: number; title: string; description: string; completed: boolean; created_at: string; updated_at: string }

// In-memory stores
const users: User[] = [];
const sessions = new Map<string, number>(); // session_id -> userId
const todos: Todo[] = [];

let nextUserId = 1;
let nextTodoId = 1;

// Helpers
function nowIsoSeconds(): string {
  const d = new Date();
  const iso = new Date(Math.floor(d.getTime() / 1000) * 1000).toISOString();
  return iso.replace(/\.\d{3}Z$/, 'Z');
}

function hashPassword(pw: string): string {
  return crypto.createHash('sha256').update(pw).digest('hex');
}

function validateUsername(u: any): u is string {
  if (typeof u !== 'string') return false;
  if (u.length < 3 || u.length > 50) return false;
  if (!/^[a-zA-Z0-9_]+$/.test(u)) return false;
  return true;
}

function parseCookies(header: string | undefined): Record<string, string> {
  const cookies: Record<string, string> = {};
  if (!header) return cookies;
  header.split(';').forEach(part => {
    const [k, v] = part.trim().split('=');
    if (k) cookies[k] = decodeURIComponent(v || '');
  });
  return cookies;
}

function sendJson(res: ServerResponse, status: number, obj: any) {
  res.statusCode = status;
  res.setHeader('Content-Type', 'application/json');
  res.end(JSON.stringify(obj));
}

function sendNoContent(res: ServerResponse, status: number) {
  res.statusCode = status;
  res.end();
}

function parseBody(req: IncomingMessage): Promise<any> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    req.on('data', (c: Buffer) => {
      chunks.push(c);
      if (Buffer.concat(chunks).length > 1e6) {
        req.socket.destroy();
        reject(new Error('Payload too large'));
      }
    });
    req.on('end', () => {
      const raw = Buffer.concat(chunks).toString('utf8');
      if (!raw) return resolve({});
      try {
        resolve(JSON.parse(raw));
      } catch (e) {
        resolve({});
      }
    });
    req.on('error', reject);
  });
}

function getAuthUserId(req: IncomingMessage): number | null {
  const cookies = parseCookies(req.headers['cookie']);
  const token = cookies['session_id'];
  if (!token) return null;
  const userId = sessions.get(token) || null;
  return userId;
}

function publicUser(u: User): PublicUser { return { id: u.id, username: u.username }; }

function findUserTodo(userId: number, idStr: string): Todo | undefined {
  const id = Number(idStr);
  if (!Number.isInteger(id) || id <= 0) return undefined;
  return todos.find(td => td.id === id && td.userId === userId);
}

function route(req: IncomingMessage, res: ServerResponse) {
  const method = req.method || 'GET';
  const urlObj = parseUrl(req.url || '/', true);
  const path = urlObj.pathname || '/';

  // Routing
  if (method === 'POST' && path === '/register') {
    return parseBody(req).then(body => {
      const { username, password } = body || {};
      if (!validateUsername(username)) {
        return sendJson(res, 400, { error: 'Invalid username' });
      }
      if (typeof password !== 'string' || password.length < 8) {
        return sendJson(res, 400, { error: 'Password too short' });
      }
      const existing = users.find(u => u.username.toLowerCase() === String(username).toLowerCase());
      if (existing) {
        return sendJson(res, 409, { error: 'Username already exists' });
      }
      const user: User = { id: nextUserId++, username, passwordHash: hashPassword(password) };
      users.push(user);
      return sendJson(res, 201, publicUser(user));
    });
  }

  if (method === 'POST' && path === '/login') {
    return parseBody(req).then(body => {
      const { username, password } = body || {};
      const user = users.find(u => u.username === username);
      if (!user || hashPassword(password || '') !== user.passwordHash) {
        return sendJson(res, 401, { error: 'Invalid credentials' });
      }
      const token = crypto.randomBytes(16).toString('hex');
      sessions.set(token, user.id);
      res.setHeader('Set-Cookie', `session_id=${token}; Path=/; HttpOnly`);
      return sendJson(res, 200, publicUser(user));
    });
  }

  if (method === 'POST' && path === '/logout') {
    const userId = getAuthUserId(req);
    if (!userId) return sendJson(res, 401, { error: 'Authentication required' });
    const cookies = parseCookies(req.headers['cookie']);
    const token = cookies['session_id'];
    if (token) sessions.delete(token);
    return sendJson(res, 200, {});
  }

  if (method === 'GET' && path === '/me') {
    const userId = getAuthUserId(req);
    if (!userId) return sendJson(res, 401, { error: 'Authentication required' });
    const user = users.find(u => u.id === userId);
    if (!user) return sendJson(res, 401, { error: 'Authentication required' });
    return sendJson(res, 200, publicUser(user));
  }

  if (method === 'PUT' && path === '/password') {
    const userId = getAuthUserId(req);
    if (!userId) return sendJson(res, 401, { error: 'Authentication required' });
    const user = users.find(u => u.id === userId);
    return parseBody(req).then(body => {
      const { old_password, new_password } = body || {};
      if (!user || hashPassword(old_password || '') !== user.passwordHash) {
        return sendJson(res, 401, { error: 'Invalid credentials' });
      }
      if (typeof new_password !== 'string' || new_password.length < 8) {
        return sendJson(res, 400, { error: 'Password too short' });
      }
      user.passwordHash = hashPassword(new_password);
      return sendJson(res, 200, {});
    });
  }

  if (method === 'GET' && path === '/todos') {
    const userId = getAuthUserId(req);
    if (!userId) return sendJson(res, 401, { error: 'Authentication required' });
    const list = todos.filter(t => t.userId === userId).sort((a, b) => a.id - b.id)
      .map(({ userId: _u, ...rest }) => rest);
    return sendJson(res, 200, list);
  }

  if (method === 'POST' && path === '/todos') {
    const userId = getAuthUserId(req);
    if (!userId) return sendJson(res, 401, { error: 'Authentication required' });
    return parseBody(req).then(body => {
      const { title, description } = body || {};
      if (typeof title !== 'string' || title.trim() === '') {
        return sendJson(res, 400, { error: 'Title is required' });
      }
      const now = nowIsoSeconds();
      const todo: Todo = {
        id: nextTodoId++,
        userId,
        title: title,
        description: typeof description === 'string' ? description : '',
        completed: false,
        created_at: now,
        updated_at: now,
      };
      todos.push(todo);
      const { userId: _u, ...pub } = todo;
      return sendJson(res, 201, pub);
    });
  }

  // Match /todos/:id
  const todoIdMatch = path.match(/^\/todos\/(\d+)$/);
  if (todoIdMatch) {
    const idStr = todoIdMatch[1];
    if (method === 'GET') {
      const userId = getAuthUserId(req);
      if (!userId) return sendJson(res, 401, { error: 'Authentication required' });
      const t = findUserTodo(userId, idStr);
      if (!t) return sendJson(res, 404, { error: 'Todo not found' });
      const { userId: _u, ...pub } = t;
      return sendJson(res, 200, pub);
    }
    if (method === 'PUT') {
      const userId = getAuthUserId(req);
      if (!userId) return sendJson(res, 401, { error: 'Authentication required' });
      const t = findUserTodo(userId, idStr);
      if (!t) return sendJson(res, 404, { error: 'Todo not found' });
      return parseBody(req).then(body => {
        const { title, description, completed } = body || {};
        if (title !== undefined) {
          if (typeof title !== 'string' || title.trim() === '') {
            return sendJson(res, 400, { error: 'Title is required' });
          }
          t.title = title;
        }
        if (description !== undefined) {
          if (typeof description !== 'string') {
            return sendJson(res, 400, { error: 'Invalid description' });
          }
          t.description = description;
        }
        if (completed !== undefined) {
          if (typeof completed !== 'boolean') {
            return sendJson(res, 400, { error: 'Invalid completed' });
          }
          t.completed = completed;
        }
        t.updated_at = nowIsoSeconds();
        const { userId: _u, ...pub } = t;
        return sendJson(res, 200, pub);
      });
    }
    if (method === 'DELETE') {
      const userId = getAuthUserId(req);
      if (!userId) return sendJson(res, 401, { error: 'Authentication required' });
      const id = Number(idStr);
      if (!Number.isInteger(id) || id <= 0) {
        return sendNoContent(res, 404);
      }
      const idx = todos.findIndex(td => td.id === id && td.userId === userId);
      if (idx === -1) return sendNoContent(res, 404);
      todos.splice(idx, 1);
      return sendNoContent(res, 204);
    }
  }

  // Not found
  sendJson(res, 404, { error: 'Not found' });
}

function parsePortArg(): number {
  const idx = process.argv.indexOf('--port');
  if (idx !== -1 && idx + 1 < process.argv.length) {
    const p = Number(process.argv[idx + 1]);
    if (Number.isInteger(p) && p > 0 && p < 65536) return p;
  }
  return 3000;
}

const port = parsePortArg();
const server = http.createServer((req, res) => {
  // Ensure JSON content-type for all non-DELETE handlers that send a body is set in sendJson
  route(req, res);
});

server.listen(port, '0.0.0.0', () => {
  console.log(`Server listening on 0.0.0.0:${port}`);
});
