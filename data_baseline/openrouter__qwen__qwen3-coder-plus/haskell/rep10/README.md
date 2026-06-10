# Todo App Server

A REST API server for managing personal todo items with cookie-based authentication.

## Endpoints

### Authentication
- POST `/register` - Create a new user account
- POST `/login` - Authenticate and receive session cookie
- POST `/logout` - Invalidate current session
- GET `/me` - Get current authenticated user's info
- PUT `/password` - Change authenticated user's password

### Todo Management
- GET `/todos` - List all todos for authenticated user
- POST `/todos` - Create a new todo
- GET `/todos/:id` - Get a specific todo by ID
- PUT `/todos/:id` - Update a specific todo
- DELETE `/todos/:id` - Delete a specific todo

## Data Types

### User Object
{"id": int, "username": string}

### Todo Object
{"id": int, "title": string, "description": string, "completed": bool, "created_at": string, "updated_at": string}