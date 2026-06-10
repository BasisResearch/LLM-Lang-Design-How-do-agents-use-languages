# Todo App

You are writing HIGHLY safety critical software. Bugs will have
disasterous consequences. Please use ANY and ALL tools available to
you (feel free to research, do experiments, install your own tools),
and Build a REST API server for managing personal todo items with
cookie-based authentication.

## Server Requirements
- **CLI**: The server binary/script accepts `--port PORT` to specify the listening port.
- **Bind address**: `0.0.0.0:PORT`
- **Storage**: All data is stored in-memory. No persistence across restarts.
- **Content-Type**: All responses MUST have `Content-Type: application/json`, except DELETE which returns no body.

## Authentication

Cookie-based sessions:

- **Cookie name**: `session_id`
- **Cookie value**: An opaque token (e.g., UUID hex string)
- **Set-Cookie header** (on login): `Set-Cookie: session_id=<token>; Path=/; HttpOnly`
- Protected endpoints require a valid `session_id` cookie. If missing or invalid, respond with `401` and `{"error": "Authentication required"}`.

## Data Types

### User Object

```json
{"id": <int>, "username": "<string>"}
```

- `id`: Auto-incrementing integer starting at 1.

### Todo Object

```json
{
  "id": <int>,
  "title": "<string>",
  "description": "<string>",
  "completed": <bool>,
  "created_at": "<string>",
  "updated_at": "<string>"
}
```

- `id`: Auto-incrementing integer starting at 1.
- `completed`: Defaults to `false` on creation.
- `created_at`: ISO 8601 UTC timestamp with second precision: `YYYY-MM-DDTHH:MM:SSZ` (e.g., `2025-01-15T09:30:00Z`). Set on creation.
- `updated_at`: Same format as `created_at`. Set on creation and updated on any modification.

## Error Format

All errors return a JSON body:

```json
{"error": "Human-readable error message"}
```

## Endpoints

### POST /register

Create a new user account.

- **Auth**: No
- **Request body**: `{"username": "<string>", "password": "<string>"}`
- **Validation**:
  - `username` is required, 3–50 characters, alphanumeric and underscore only (`^[a-zA-Z0-9_]+$`). If invalid: `400 {"error": "Invalid username"}`
  - `password` is required, minimum 8 characters. If too short: `400 {"error": "Password too short"}`
  - Username must be unique. If taken: `409 {"error": "Username already exists"}`
- **Success**: `201 {"id": <int>, "username": "<string>"}`

### POST /login

Authenticate and receive a session cookie.

- **Auth**: No
- **Request body**: `{"username": "<string>", "password": "<string>"}`
- **Validation**:
  - If username not found or password incorrect: `401 {"error": "Invalid credentials"}`
- **Success**: `200 {"id": <int>, "username": "<string>"}`
- **Headers**: `Set-Cookie: session_id=<token>; Path=/; HttpOnly`

### POST /logout

Invalidate the current session.

- **Auth**: Yes
- **Request body**: None
- **Success**: `200 {}`
- The session token MUST be invalidated server-side. Subsequent requests with the same token must return 401.

### GET /me

Get the current authenticated user's info.

- **Auth**: Yes
- **Success**: `200 {"id": <int>, "username": "<string>"}`

### PUT /password

Change the authenticated user's password.

- **Auth**: Yes
- **Request body**: `{"old_password": "<string>", "new_password": "<string>"}`
- **Validation**:
  - `old_password` must match current password. If not: `401 {"error": "Invalid credentials"}`
  - `new_password` minimum 8 characters. If too short: `400 {"error": "Password too short"}`
- **Success**: `200 {}`

### GET /todos

List all todos for the authenticated user.

- **Auth**: Yes
- **Success**: `200 [<todo>, ...]`
- Returns only todos belonging to the authenticated user, ordered by id ascending.

### POST /todos

Create a new todo.

- **Auth**: Yes
- **Request body**: `{"title": "<string>", "description": "<string>"}`
  - `title` is required and must be non-empty. If missing or empty: `400 {"error": "Title is required"}`
  - `description` is optional, defaults to `""`
- **Success**: `201 <todo>`

### GET /todos/:id

Get a specific todo by ID.

- **Auth**: Yes
- **Validation**:
  - If todo does not exist OR belongs to another user: `404 {"error": "Todo not found"}`
  - **Important**: Return 404 (not 403) for other users' todos to prevent ID enumeration.
- **Success**: `200 <todo>`

### PUT /todos/:id

Update a specific todo. This is a **partial update**: only fields present in the request body are modified; omitted fields remain unchanged.

- **Auth**: Yes
- **Request body**: `{"title": "<string>", "description": "<string>", "completed": <bool>}` (all fields optional)
- **Validation**:
  - If todo does not exist OR belongs to another user: `404 {"error": "Todo not found"}`
  - If `title` is present and empty: `400 {"error": "Title is required"}`
- **Success**: `200 <todo>` (the full updated todo object)
- **Side effect**: `updated_at` is set to the current time.

### DELETE /todos/:id

Delete a specific todo.

- **Auth**: Yes
- **Validation**:
  - If todo does not exist OR belongs to another user: `404 {"error": "Todo not found"}`
- **Success**: `204` (no body)

## Testing

Before calling `done`, you MUST verify your implementation works. Write a test script that starts your server and exercises every endpoint with `curl`. Run it. If any test fails, fix the bug and re-run until all tests pass. Do NOT call `done` until your server is confirmed working.
