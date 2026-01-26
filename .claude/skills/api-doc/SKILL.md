---
name: api-doc
description: Generate OpenAPI documentation from Phoenix router
---

# API Documentation Generator

Analyze the Levee API and generate comprehensive documentation.

## Source Files to Analyze

1. **Router**: `lib/levee_web/router.ex` - All endpoints and pipelines
2. **Controllers**: `lib/levee_web/controllers/*.ex` - Request/response handling
3. **Auth Plug**: `lib/levee_web/plugs/auth.ex` - Authentication requirements
4. **Channels**: `lib/levee_web/channels/*.ex` - WebSocket endpoints

## Documentation Structure

Generate documentation covering:

### REST Endpoints
For each endpoint, document:
- HTTP method and path
- Pipeline (authentication level required)
- Required JWT scopes (e.g., `doc:read`, `doc:write`, `summary:write`)
- Path parameters
- Request body schema (from controller action)
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
