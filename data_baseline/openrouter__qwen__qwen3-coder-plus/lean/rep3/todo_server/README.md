# Todo Server in Lean 4

This is a complete implementation of a REST API server for managing personal todo items with cookie-based authentication according to the specified requirements.

## Server Structure

- All business logic is implemented in `TodoServer.lean`
- Uses in-memory storage for users, todos, and sessions
- Implemented with cookie-based sessions for authentication
- Follows the specified API contract precisely

## Project Setup

To build and run this project, you need Lean 4 and Lake package manager.

### Dependencies

This project depends on:
- Lean 4 (tested with version 4.30.0)
- Lake package manager  
- `lean4-http` library for HTTP server functionality

### Installation

1. Clone the repository: `git clone <repo-url>`
2. Install http dependency: `lake update`
3. Build the project: `lake build` 
4. Run the server: `./run.sh --port <PORT>`

### Issues

Git authentication may cause issues in some environments when fetching external dependencies. If you encounter this, you may need to manually clone the `lean4-http` repo and reference it, or use git credentials helper.

## Implemented Endpoints

All endpoints per the specification are implemented:
- `POST /register` - Create a new user account
- `POST /login` - Authenticate and receive session cookie
- `POST /logout` - Invalidate the current session
- `GET /me` - Get the current authenticated user's info
- `PUT /password` - Change the authenticated user's password
- `GET /todos` - List all todos for the authenticated user
- `POST /todos` - Create a new todo
- `GET /todos/:id` - Get a specific todo by ID
- `PUT /todos/:id` - Update a specific todo (partial update)
- `DELETE /tos/:id` - Delete a specific todo

## Security Features

- Password validation (minimum 8 characters)
- Session-based authentication using cookies
- Access control to prevent unauthorized operations
- Input validation for usernames (alphanumeric+underscore, 3-50 chars)
- Proper user separation of data