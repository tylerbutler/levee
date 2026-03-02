---
name: api-doc
description: Generate OpenAPI documentation from Wisp router
---

# API Documentation Generator

Analyze the Levee API and generate comprehensive documentation.

## Source Files to Analyze

1. **Router**: `server/levee_web/src/levee_web/router.gleam` - All endpoints and routing
2. **Handlers**: `server/levee_web/src/levee_web/handlers/*.gleam` - Request/response handling
3. **Auth Middleware**: `server/levee_web/src/levee_web/middleware/jwt_auth.gleam` - Authentication requirements
4. **Channels**: `levee_channels/src/levee_channels/document_channel.gleam` - WebSocket endpoints

## Documentation Structure

Generate documentation covering:

### REST Endpoints
For each endpoint, document:
- HTTP method and path
- Authentication requirements (JWT middleware)
- Required JWT scopes (e.g., `doc:read`, `doc:write`, `summary:write`)
- Path parameters
- Request body schema (from handler)
- Response schema and status codes
- Example request/response

### WebSocket Channels
For each channel, document:
- Topic pattern (e.g., `document:tenant_id:document_id`)
- Join requirements and authentication
- Incoming events (e.g., `connect_document`, `submitOp`, `submitSignal`)
- Outgoing events and their payloads
- Error conditions

### Authentication
Document the JWT token structure:
- Required claims (`documentId`, `scopes`, `tenantId`, `user`, `iat`, `exp`, `ver`)
- Scope definitions and what each grants access to
- Token validation process

## Output Format

Output as Markdown suitable for a README or docs site. Use tables for endpoint listings and code blocks for examples.
