import http, { IncomingMessage, ServerResponse } from 'http';
import { parse as parseUrl } from 'url';
import { randomBytes, createHash } from 'crypto';

// Utility: format ISO 8601 UTC with second precision
function isoNow(): string {
  const d = new Date();
  const iso = d.toISOString();
  // toISOString is milliseconds precision; trim to seconds
  return iso.replace(/\.\d{3}Z$/, 'Z');
}

// Types
interface User { id: number; username: string; passwordHash: string; }
interface PublicUser { id: number; username: string; }
interface Todo { id: number; userId: number; title: string; description: string; completed: boolean; created_at: string; updated_at: string; }

// In-memory stores
const usersById = new Map<number, User>();
const usersByUsername = new Map<string, User>();
let nextUserId = 1;

const todosById = new Map<number, Todo>();
let nextTodoId = 1;

// Sessions: token -> userId
const sessions = new Map<string, number>();

// Password hashing: simple sha256 for demo (not for production)
function hashPassword(pw: string): string {
  return createHash('sha256').update(pw, 'utf8').digest('hex');
}

// Helpers
function sendJSON(res: ServerResponse, status: number, obj: any): void {
  const body = JSON.stringify(obj);
  res.statusCode = status;
  res.setHeader('Content-Type', 'application/json');
  res.setHeader('Content-Length', Buffer.byteLength(body));
  res.end(body);
}

function sendNoContent(res: ServerResponse): void {
  res.statusCode = 204;
  // No body per spec; still set content-type? Spec says except DELETE returns no body.
  res.end();
}

function parseCookies(req: IncomingMessage): Record<string, string> {
  const header = req.headers['cookie'];
  const out: Record<string, string> = {};
  if (!header) return out;
  const parts = header.split(';');
  for (const part of parts) {
    const [k, ...v] = part.trim().split('=');
    if (!k) continue;
    out[k] = decodeURIComponent(v.join('='));
  }
  return out;
}

function readJSON<T = any>(req: IncomingMessage): Promise<T | null> {
  return new Promise((resolve) => {
    const chunks: Buffer[] = [];
    req.on('data', (c) => chunks.push(Buffer.isBuffer(c) ? c : Buffer.from(c)));
    req.on('end', () => {
      if (chunks.length === 0) return resolve(null);
      const str = Buffer.concat(chunks).toString('utf8');
      try {
        const obj = JSON.parse(str);
        resolve(obj);
      } catch (e) {
        resolve(null);
      }
    });
  });
}

function getAuthUser(req: IncomingMessage): User | null {
  const cookies = parseCookies(req);
  const token = cookies['session_id'];
  if (!token) return null;
  const uid = sessions.get(token);
  if (!uid) return null;
  const user = usersById.get(uid) || null;
  return user;
}

function requireAuth(req: IncomingMessage, res: ServerResponse): User | null {
  const user = getAuthUser(req);
  if (!user) {
    sendJSON(res, 401, { error: 'Authentication required' });
    return null;
  }
  return user;
}

function setSessionCookie(res: ServerResponse, token: string) {
  // As per spec: Path=/; HttpOnly
  res.setHeader('Set-Cookie', `session_id=${token}; Path=/; HttpOnly`);
}

function notFound(res: ServerResponse) {
  sendJSON(res, 404, { error: 'Not found' });
}

function methodNotAllowed(res: ServerResponse) {
  sendJSON(res, 405, { error: 'Method not allowed' });
}

function validateUsername(username: unknown): username is string {
  if (typeof username !== 'string') return false;
  if (username.length < 3 || username.length > 50) return false;
  if (!/^[a-zA-Z0-9_]+$/.test(username)) return false;
  return true;
}

function validatePassword(pw: unknown): pw is string {
  return typeof pw === 'string' && pw.length >= 8;
}

function todoPublic(t: Todo) {
  return {
    id: t.id,
    title: t.title,
    description: t.description,
    completed: t.completed,
    created_at: t.created_at,
    updated_at: t.updated_at,
  };
}

function userPublic(u: User): PublicUser {
  return { id: u.id, username: u.username };
}

// Router
const server = http.createServer(async (req, res) => {
  try {
    const url = parseUrl(req.url || '', true);
    const pathname = url.pathname || '/';

    // Force application/json Content-Type on all responses except 204
    // We'll set per sendJSON; ensure default content-type if someone writes directly

    // CORS not specified; ignore.

    // Routing
    if (pathname === '/register') {
      if (req.method !== 'POST') return methodNotAllowed(res);
      const body = await readJSON(req);
      const username = (body && (body as any).username) ?? undefined;
      const password = (body && (body as any).password) ?? undefined;
      if (!validateUsername(username)) {
        return sendJSON(res, 400, { error: 'Invalid username' });
      }
      if (!validatePassword(password)) {
        return sendJSON(res, 400, { error: 'Password too short' });
      }
      if (usersByUsername.has(username)) {
        return sendJSON(res, 409, { error: 'Username already exists' });
      }
      const u: User = { id: nextUserId++, username, passwordHash: hashPassword(password) };
      usersById.set(u.id, u);
      usersByUsername.set(username, u);
      return sendJSON(res, 201, userPublic(u));
    }

    if (pathname === '/login') {
      if (req.method !== 'POST') return methodNotAllowed(res);
      const body = await readJSON(req);
      const username = (body && (body as any).username) ?? '';
      const password = (body && (body as any).password) ?? '';
      const u = usersByUsername.get(username);
      if (!u || u.passwordHash !== hashPassword(password)) {
        return sendJSON(res, 401, { error: 'Invalid credentials' });
      }
      // Generate session token
      const token = randomBytes(16).toString('hex');
      sessions.set(token, u.id);
      setSessionCookie(res, token);
      return sendJSON(res, 200, userPublic(u));
    }

    if (pathname === '/logout') {
      if (req.method !== 'POST') return methodNotAllowed(res);
      const cookies = parseCookies(req);
      const token = cookies['session_id'];
      const user = requireAuth(req, res);
      if (!user) return; // response already sent
      if (token) {
        sessions.delete(token);
      }
      return sendJSON(res, 200, {});
    }

    if (pathname === '/me') {
      if (req.method !== 'GET') return methodNotAllowed(res);
      const user = requireAuth(req, res);
      if (!user) return;
      return sendJSON(res, 200, userPublic(user));
    }

    if (pathname === '/password') {
      if (req.method !== 'PUT') return methodNotAllowed(res);
      const user = requireAuth(req, res);
      if (!user) return;
      const body = await readJSON(req);
      const oldPw = (body && (body as any).old_password) ?? '';
      const newPw = (body && (body as any).new_password) ?? '';
      if (user.passwordHash !== hashPassword(oldPw)) {
        return sendJSON(res, 401, { error: 'Invalid credentials' });
      }
      if (!validatePassword(newPw)) {
        return sendJSON(res, 400, { error: 'Password too short' });
      }
      user.passwordHash = hashPassword(newPw);
      usersById.set(user.id, user);
      usersByUsername.set(user.username, user);
      return sendJSON(res, 200, {});
    }

    if (pathname === '/todos' && req.method === 'GET') {
      const user = requireAuth(req, res);
      if (!user) return;
      const list = Array.from(todosById.values())
        .filter(t => t.userId === user.id)
        .sort((a, b) => a.id - b.id)
        .map(todoPublic);
      return sendJSON(res, 200, list);
    }

    if (pathname === '/todos' && req.method === 'POST') {
      const user = requireAuth(req, res);
      if (!user) return;
      const body = await readJSON(req);
      const title = (body && (body as any).title) ?? '';
      const description = (body && (body as any).description) ?? '';
      if (typeof title !== 'string' || title.trim() === '') {
        return sendJSON(res, 400, { error: 'Title is required' });
      }
      const now = isoNow();
      const t: Todo = {
        id: nextTodoId++,
        userId: user.id,
        title: String(title),
        description: typeof description === 'string' ? description : '',
        completed: false,
        created_at: now,
        updated_at: now,
      };
      todosById.set(t.id, t);
      return sendJSON(res, 201, todoPublic(t));
    }

    const todoIdMatch = pathname.match(/^\/todos\/(\d+)$/);
    if (todoIdMatch) {
      const id = parseInt(todoIdMatch[1], 10);
      const todo = todosById.get(id) || null;
      if (req.method === 'GET') {
        const user = requireAuth(req, res);
        if (!user) return;
        if (!todo || todo.userId !== user.id) {
          return sendJSON(res, 404, { error: 'Todo not found' });
        }
        return sendJSON(res, 200, todoPublic(todo));
      }
      if (req.method === 'PUT') {
        const user = requireAuth(req, res);
        if (!user) return;
        if (!todo || todo.userId !== user.id) {
          return sendJSON(res, 404, { error: 'Todo not found' });
        }
        const body = await readJSON(req);
        if (body && Object.prototype.hasOwnProperty.call(body, 'title')) {
          const title = (body as any).title;
          if (typeof title !== 'string' || title.trim() === '') {
            return sendJSON(res, 400, { error: 'Title is required' });
          }
          todo.title = title;
        }
        if (body && Object.prototype.hasOwnProperty.call(body, 'description')) {
          const desc = (body as any).description;
          todo.description = typeof desc === 'string' ? desc : '';
        }
        if (body && Object.prototype.hasOwnProperty.call(body, 'completed')) {
          const comp = (body as any).completed;
          todo.completed = Boolean(comp);
        }
        todo.updated_at = isoNow();
        todosById.set(todo.id, todo);
        return sendJSON(res, 200, todoPublic(todo));
      }
      if (req.method === 'DELETE') {
        const user = requireAuth(req, res);
        if (!user) return;
        if (!todo || todo.userId !== user.id) {
          return sendJSON(res, 404, { error: 'Todo not found' });
        }
        todosById.delete(todo.id);
        return sendNoContent(res);
      }
      return methodNotAllowed(res);
    }

    return notFound(res);
  } catch (err) {
    // Fallback error handler
    try {
      sendJSON(res, 500, { error: 'Internal server error' });
    } catch {}
  }
});

function parseArgs(argv: string[]): { port: number } {
  let port = 3000;
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--port' && i + 1 < argv.length) {
      const p = parseInt(argv[i + 1], 10);
      if (!Number.isNaN(p) && p > 0 && p < 65536) {
        port = p;
      }
    }
  }
  return { port };
}

const { port } = parseArgs(process.argv.slice(2));
server.listen(port, '0.0.0.0', () => {
  console.log(`Server running on http://0.0.0.0:${port}`);
});
