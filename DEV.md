# Development Guide

## Quick Start

```bash
mix deps.get           # Install dependencies
mix compile            # Compile project
mix phx.server         # Start dev server at localhost:4000
```

## Default Dev Tenant

In development and test environments, a default tenant is automatically registered at startup:

| Property | Value |
|----------|-------|
| Tenant ID | `dev-tenant` |
| Secret | `levee-dev-secret-change-in-production` |

This allows immediate testing without manual tenant setup.

### Generate a JWT for the dev tenant

```elixir
# In iex -S mix
Levee.Auth.JWT.generate_test_token("dev-tenant", "my-doc", "user-1")
```

### Register additional tenants

```elixir
Levee.Auth.TenantSecrets.register_tenant("my-tenant", "my-secret-key")
```

Or via environment variables (loaded at startup):
```bash
LEVEE_TENANT_ID=my-tenant LEVEE_TENANT_KEY=my-secret-key mix phx.server
```

## Running Tests

```bash
mix test               # Run all tests
mix test --only wip    # Run tests tagged @tag :wip
```

## Gleam Protocol

The `levee_protocol/` directory contains Gleam code that compiles to BEAM. After modifying Gleam files:

```bash
cd levee_protocol
gleam build
cd ..
mix compile --force    # Reload BEAM modules
```
