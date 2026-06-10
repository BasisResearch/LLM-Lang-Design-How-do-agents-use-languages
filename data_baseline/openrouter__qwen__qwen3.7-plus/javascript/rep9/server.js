const http = require('http');
const crypto = require('crypto');

const users = [];
const sessions = new Map();
let nextUserId = 1;

const todos = [];
let nextTodoId = 1;

function getTimestamp() {
  return new Date().toISOString().replace(/\.\d{3}Z$/, 'Z');
}

function parseBody(req) {
  return new Promise((resolve, reject) => {
    let body = '';
    req.on('data', chunk => body += chunk.toString());
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
  if (!req.headers.cookie) return null;
  const cookies = req.headers.cookie.split(';');
  for (const c of cookies) {
    const [key, ...val] = c.trim().split('=');
    if (key === name) {
      return val.join('=');
    }
  }
  return null;
}

function getUser(req) {
  const sessionId = getCookie(req, 'session_id');
  if (!sessionId) return null;
  const session = sessions.get(sessionId);
  if (!session) return null;
  return users.find(u => u.id === session.userId) || null;
}

const args = process.argv.slice(2);
let port = 3000;
for (let i = 0; i < args.length; i++) {
  if (args[i] === '--port' && args[i+1]) {
    port = parseInt(args[i+1], 10);
  }
}

const server = http.createServer(async (req, res) => {
  res.setHeader('Content-Type', 'application/json');
  
  let url;
  try {
    url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
  } catch (e) {
    res.statusCode = 400;
    return res.end(JSON.stringify({ error: "Invalid URL" }));
  }
  
  const method = req.method;
  const path = url.pathname;

  const send = (status, data) => {
    res.statusCode = status;
    if (data !== undefined) {
      res.end(JSON.stringify(data));
    } else {
      res.end();
    }
  };

  try {
    if (method === 'POST' && path === '/register') {
      const body = await parseBody(req);
      const { username, password } = body;
      
      if (!username || typeof username !== 'string' || !/^[a-zA-Z0-9_]{3,50}$/.test(username)) {
        return send(400, { error: "Invalid username" });
      }
      if (!password || typeof password !== 'string' || password.length < 8) {
        return send(400, { error: "Password too short" });
      }
      if (users.find(u => u.username === username)) {
        return send(409, { error: "Username already exists" });
      }
      
      const newUser = { id: nextUserId++, username, password };
      users.push(newUser);
      return send(201, { id: newUser.id, username: newUser.username });
    }

    if (method === 'POST' && path === '/login') {
      const body = await parseBody(req);
      const { username, password } = body;
      
      const user = users.find(u => u.username === username && u.password === password);
      if (!user) {
        return send(401, { error: "Invalid credentials" });
      }
      
      const sessionId = crypto.randomUUID();
      sessions.set(sessionId, { userId: user.id });
      
      res.setHeader('Set-Cookie', `session_id=${sessionId}; Path=/; HttpOnly`);
      return send(200, { id: user.id, username: user.username });
    }
    
    if (method === 'POST' && path === '/logout') {
      const user = getUser(req);
      if (!user) return send(401, { error: "Authentication required" });
      
      const sessionId = getCookie(req, 'session_id');
      sessions.delete(sessionId);
      
      return send(200, {});
    }

    if (method === 'GET' && path === '/me') {
      const user = getUser(req);
      if (!user) return send(401, { error: "Authentication required" });
      return send(200, { id: user.id, username: user.username });
    }

    if (method === 'PUT' && path === '/password') {
      const user = getUser(req);
      if (!user) return send(401, { error: "Authentication required" });
      
      const body = await parseBody(req);
      const { old_password, new_password } = body;
      
      if (old_password !== user.password) {
        return send(401, { error: "Invalid credentials" });
      }
      if (!new_password || typeof new_password !== 'string' || new_password.length < 8) {
        return send(400, { error: "Password too short" });
      }
      
      user.password = new_password;
      return send(200, {});
    }

    if (method === 'GET' && path === '/todos') {
      const user = getUser(req);
      if (!user) return send(401, { error: "Authentication required" });
      
      const userTodos = todos.filter(t => t.userId === user.id).sort((a, b) => a.id - b.id);
      return send(200, userTodos);
    }

    if (method === 'POST' && path === '/todos') {
      const user = getUser(req);
      if (!user) return send(401, { error: "Authentication required" });
      
      const body = await parseBody(req);
      const { title, description } = body;
      
      if (!title || typeof title !== 'string' || title.trim() === '') {
        return send(400, { error: "Title is required" });
      }
      
      const newTodo = {
        id: nextTodoId++,
        userId: user.id,
        title: title,
        description: typeof description === 'string' ? description : "",
        completed: false,
        created_at: getTimestamp(),
        updated_at: getTimestamp()
      };
      todos.push(newTodo);
      return send(201, newTodo);
    }

    const todosMatch = path.match(/^\/todos\/(\d+)$/);
    if (todosMatch) {
      const todoId = parseInt(todosMatch[1], 10);
      const user = getUser(req);
      if (!user) return send(401, { error: "Authentication required" });

      const todo = todos.find(t => t.id === todoId && t.userId === user.id);
      
      if (method === 'GET') {
        if (!todo) return send(404, { error: "Todo not found" });
        return send(200, todo);
      }

      if (method === 'PUT') {
        if (!todo) return send(404, { error: "Todo not found" });
        const body = await parseBody(req);
        if (body.title !== undefined) {
          if (typeof body.title !== 'string' || body.title.trim() === '') {
            return send(400, { error: "Title is required" });
          }
          todo.title = body.title;
        }
        if (body.description !== undefined) {
          todo.description = typeof body.description === 'string' ? body.description : "";
        }
        if (body.completed !== undefined) {
          if (typeof body.completed === 'boolean') {
            todo.completed = body.completed;
          }
        }
        todo.updated_at = getTimestamp();
        return send(200, todo);
      }

      if (method === 'DELETE') {
        if (!todo) return send(404, { error: "Todo not found" });
        res.removeHeader('Content-Type');
        const index = todos.findIndex(t => t.id === todoId);
        if (index !== -1) {
          todos.splice(index, 1);
        }
        res.statusCode = 204;
        res.end();
        return;
      }
    }

    return send(404, { error: "Not found" });

  } catch (err) {
    console.error(err);
    return send(500, { error: "Internal server error" });
  }
});

server.listen(port, '0.0.0.0', () => {
  console.log(`Server running on 0.0.0.0:${port}`);
});
