# Tenant Secret Rotation Design

## Summary

Replace user-provided tenant IDs and secrets with server-generated values. Each tenant gets a human-readable ID (e.g. `tremendous-brown-cat`), a user-provided display name, and two rotating secrets. Secrets can be regenerated individually via the admin UI.

## Data Model

**Current**: `%{tenant_id => secret}` — both user-provided.

**New**: `%{tenant_id => %{name: string, secret1: string, secret2: string}}`

- **tenant_id** — server-generated via `unique_names_generator` using `[:adjectives, :colors, :animals]` with `"-"` separator. Collision retry up to 5 times.
- **name** — user-provided display name (what was previously called "id")
- **secret1, secret2** — server-generated 32-byte random hex strings (`64 chars`), both populated at creation

## API Changes

### Create Tenant
- `POST /api/tenants` — body: `{"name": "My App"}`
- Response (201): `{"tenant": {"id": "...", "name": "...", "secret1": "...", "secret2": "..."}}`
- Secrets shown only in this response

### List Tenants
- `GET /api/tenants` — response: `{"tenants": [{"id": "...", "name": "..."}]}`
- No secrets returned

### Get Tenant
- `GET /api/tenants/:id` — response: `{"tenant": {"id": "...", "name": "..."}}`
- No secrets returned

### Regenerate Secret
- `POST /api/tenants/:id/secrets/:slot` where slot is `1` or `2`
- Response (200): `{"secret": "new-hex-value"}`
- Returns only the regenerated secret

### Delete Tenant
- `DELETE /api/tenants/:id` — unchanged

### Removed
- `PUT /api/tenants/:id` — replaced by per-slot regenerate endpoint

All admin-key routes (`/api/admin/tenants/...`) mirror the same changes.

## JWT Changes

### Signing
- Always uses `secret1` for new tokens
- No other changes to signing flow

### Verification (try-both)
1. Look up tenant, get both secrets
2. Try verify with `secret1`
3. If `:invalid_signature`, try `secret2`
4. If both fail, return `{:error, :invalid_signature}`
5. Other errors (malformed token, tenant not found) fail immediately

### Helpers
- `generate_secret/0` — `:crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)`
- `generate_tenant_id/1` — calls `unique_names_generator`, checks for collision, retries up to 5 times

## Admin UI Changes (Lustre SPA)

### Create Tenant Page
- Single field: Name (text input)
- Server generates ID and secrets
- On success, navigate to detail page

### Tenant Detail Page
- **Info section**: ID and Name (both read-only)
- **Secrets section**: two cards, one per slot
  - Secret value (masked by default, show/hide toggle)
  - "Regenerate" button with confirmation prompt
  - Success/error feedback per slot
- **Danger Zone**: unchanged (delete with type-to-confirm)

### Dashboard & Tenant List
- Show name alongside ID

### API Client
- `create_tenant(token, name, callback)` — simplified
- New `regenerate_secret(token, id, slot, callback)`
- Remove `update_tenant`
- Updated decoders for new response shapes

## Testing

### Controller Tests
- Create returns server-generated id, name, secret1, secret2
- Secrets are 64-char hex strings
- Regenerate replaces one slot, other slot unchanged
- Invalid slot (e.g. `3`) returns 400
- Nonexistent tenant returns 404
- List/Get return name, no secrets

### JWT Tests
- Token signed with secret1 verifies
- Token signed with secret2 verifies
- Random secret fails
- After regenerating secret1, old secret1 tokens fail, secret2 tokens still work

### TenantSecrets Tests
- New data shape stored correctly
- generate_secret/0 returns 64-char hex
- ID generation produces adjective-color-animal format
- Both secrets stored on registration

## Dependencies

- Add `unique_names_generator` to `mix.exs`
