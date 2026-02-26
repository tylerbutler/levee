# Admin UI Tenant Management Design

**Date:** 2026-02-23
**Issues:** #14, #15, #16, #17 (Issue #18 already resolved)
**Status:** Approved

## Summary

Build the tenant management UI pages in the Lustre admin SPA. The backend API and session-auth routes already exist. This work adds the frontend pages that call them.

## Architecture

Each page follows the existing nested component pattern (Model/Msg/init/update/view), same as login.gleam and register.gleam.

### New Files

```
server/levee_admin/src/pages/
├── tenants.gleam        # Tenant list (Issue #14)
├── tenant_new.gleam     # Create tenant form (Issue #15)
└── tenant_detail.gleam  # Detail + edit + delete (Issues #16, #17)
```

### Modified Files

- `router.gleam` — Add `TenantNew` route for `/admin/tenants/new`
- `levee_admin.gleam` — Add Msg variants, Model fields, update/view delegation for new pages
- `dashboard.gleam` — Load tenants from API, show count and preview
- `index.html` — CSS for new components (tables, forms, confirmation dialogs)

### Unchanged

- `api.gleam` — Already has all 5 tenant functions pointing at `/api/tenants/`

## Page Designs

### Tenant List (`tenants.gleam`)

**Model:** `tenants: List(Tenant)`, `state: Loading | Loaded | Error(String)`

- Fetch tenants on page load
- Table/list showing tenant IDs, each row links to detail page
- "Create Tenant" button links to `/admin/tenants/new`
- Loading, empty, and error states handled

### Create Tenant (`tenant_new.gleam`)

**Model:** `id: String`, `secret: String`, `state: Idle | Submitting | Error(String)`

- Form with Tenant ID (text) and Secret (password) fields
- Client-side validation: both non-empty
- On success: navigate to `/admin/tenants/:id`
- On error: inline error message
- Help text clarifying tenant ID is user-chosen

### Tenant Detail (`tenant_detail.gleam`)

**Model:** `tenant_id`, `state: Loading | Loaded | NotFound | Error(String)`, `new_secret`, `secret_state`, `delete_state`

**View section:** Displays tenant ID, back link to tenant list.

**Edit secret section:** Form field + "Update Secret" button with success/error states.

**Delete section (type-to-confirm):**
- "Delete Tenant" button reveals confirmation panel
- User must type tenant ID to enable delete button
- On confirm: delete and redirect to tenant list

### Dashboard Update

- Load tenants via `api.list_tenants` on page load
- Show tenant count in "Your Tenants" card
- Preview first few tenant IDs
- "View All" link to `/admin/tenants`

## Testing Strategy

### Gleam Unit Tests

- **Router:** Parse/generate paths for `TenantNew` and all existing routes
- **Page modules:** `init()` defaults, `update` state transitions (form input, loading, error states)

### Elixir Integration Tests

- Tenant CRUD via `/api/tenants/` with valid admin session (200/201 responses)
- 401 for invalid/missing session tokens
- 403 for non-admin user sessions
- 404 for non-existent tenants

## Build Sequence

| Step | Issue | Deliverable |
|------|-------|-------------|
| 1 | #14 | Tenant list page + route wiring |
| 2 | #15 | Create tenant form + TenantNew route |
| 3 | #16/#17 | Tenant detail with edit + type-to-confirm delete |
| 4 | — | Dashboard tenant loading |
| 5 | — | CSS for new components |
| 6 | — | Elixir integration tests |

Each step is an independent commit point.

## Decisions

- **#18 resolved:** Session-auth tenant routes and AdminSessionAuth plug already exist
- **Nested component pattern:** Same as existing login/register pages
- **Detail + delete combined:** Delete is an action within the detail page, not separate
- **Type-to-confirm delete:** User must type tenant ID to confirm (GitHub-style)
- **Bottom-up build order:** List → Create → Detail → Dashboard
