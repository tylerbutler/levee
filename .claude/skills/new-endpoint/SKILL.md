---
name: new-endpoint
description: Create a new REST API endpoint with authentication
---

# Create New API Endpoint

Guide for adding a new REST endpoint to Levee.

## Prerequisites

1. Understand the endpoint requirements:
   - HTTP method (GET, POST, PATCH, DELETE)
   - URL path and parameters
   - Required authentication/authorization
   - Request/response schemas

## Step 1: Analyze Router Structure

Read `server/levee_web/src/levee_web/router.gleam` to understand:
- Existing route patterns
- How middleware (auth, CORS) is applied
- How the context is threaded through handlers

## Step 2: Add Route

Add the route to `server/levee_web/src/levee_web/router.gleam`:

```gleam
// In the router function, add a new pattern match
wisp.path_segments(req)
|> list.map(dynamic.from)
|> route_segments(req, ctx)

// Add your route pattern
fn route_segments(segments, req, ctx) {
  case segments {
    ["your-path", tenant_id, id] -> your_handler.handle(req, ctx, tenant_id, id)
    // ...existing routes
  }
}
```

## Step 3: Create Handler

Create a handler in `server/levee_web/src/levee_web/handlers/`:

```gleam
import gleam/http
import gleam/json
import levee_web/context.{type Context}
import levee_web/middleware/jwt_auth
import wisp.{type Request, type Response}

pub fn handle(req: Request, ctx: Context, tenant_id: String, id: String) -> Response {
  case req.method {
    http.Get -> show(req, ctx, tenant_id, id)
    http.Post -> create(req, ctx, tenant_id)
    _ -> wisp.method_not_allowed([http.Get, http.Post])
  }
}

fn show(req: Request, ctx: Context, tenant_id: String, id: String) -> Response {
  // Authenticate
  use claims <- jwt_auth.require_scope(req, ctx, "doc:read", tenant_id)

  // Your logic here
  case get_resource(ctx, tenant_id, id) {
    Ok(data) -> wisp.json_response(json.to_string_tree(encode(data)), 200)
    Error(_) -> wisp.not_found()
  }
}
```

## Step 4: Add Tests

Add tests in `server/levee_web/test/`:

```gleam
import startest.{describe, it}
import startest/expect

pub fn your_handler_tests() {
  describe("your_handler", [
    it("returns data with valid token", fn() {
      // Test setup and assertions
      expect.to_be_ok(result)
    }),
  ])
}
```

## Step 5: Verify

```bash
# Run Gleam tests
cd server/levee_web && gleam test

# Run all server tests
just test-server

# Manual test with curl
just server
# In another terminal:
curl -H "Authorization: Bearer $TOKEN" http://localhost:4000/your-path/tenant/id
```

## Common Patterns

### JSON Response
```gleam
wisp.json_response(json.to_string_tree(data), 200)
```

### Error Responses
```gleam
wisp.not_found()
wisp.bad_request()
wisp.internal_server_error()
wisp.json_response(json.to_string_tree(error_json), 400)
```

### Reading JSON Body
```gleam
use body <- wisp.require_json(req)
// body is a Dynamic value, decode it
```
