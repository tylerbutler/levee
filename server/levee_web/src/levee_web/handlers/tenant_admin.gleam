//// Tenant admin handler — CRUD for tenant management.
////
//// Used by both the admin key API (/api/admin/tenants) and the
//// session-authenticated admin UI API (/api/tenants).

import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import levee_web/context.{type Context}
import levee_web/json_helpers
import tenant_secrets.{type Message}
import wisp.{type Request, type Response}

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

/// GET /api/admin/tenants or /api/tenants — list all tenants.
pub fn index(_req: Request, ctx: Context) -> Response {
  use actor <- require_tenant_secrets(ctx)

  let tenants = tenant_secrets.list_tenants_with_names(actor)

  let tenant_list =
    tenants
    |> list.map(fn(t) {
      json.object([
        #("id", json.string(t.id)),
        #("name", json.string(t.name)),
      ])
    })
    |> json.preprocessed_array

  json_helpers.json_response(200, json.object([#("tenants", tenant_list)]))
}

/// POST /api/admin/tenants or /api/tenants — create a new tenant.
pub fn create(req: Request, ctx: Context) -> Response {
  use actor <- require_tenant_secrets(ctx)
  use body <- wisp.require_json(req)

  case decode.run(body, decode.at(["name"], decode.string)) {
    Error(_) ->
      json_helpers.json_response(
        422,
        json.object([
          #(
            "error",
            json.object([
              #("code", json.string("missing_fields")),
              #("message", json.string("Required: name")),
            ]),
          ),
        ]),
      )

    Ok(name) ->
      case tenant_secrets.create_tenant(actor, name) {
        Ok(tenant) ->
          json_helpers.json_response(
            201,
            json.object([
              #(
                "tenant",
                json.object([
                  #("id", json.string(tenant.id)),
                  #("name", json.string(tenant.name)),
                  #("secret1", json.string(tenant.secret1)),
                  #("secret2", json.string(tenant.secret2)),
                ]),
              ),
            ]),
          )

        Error(_) ->
          json_helpers.error_response(
            500,
            "server_error",
            "Failed to create tenant",
          )
      }
  }
}

/// GET /api/admin/tenants/:id or /api/tenants/:id — show tenant with secrets.
pub fn show(_req: Request, ctx: Context, tenant_id: String) -> Response {
  use actor <- require_tenant_secrets(ctx)

  case tenant_secrets.get_tenant(actor, tenant_id) {
    Error(tenant_secrets.TenantNotFound) ->
      json_helpers.json_response(
        404,
        json.object([
          #(
            "error",
            json.object([
              #("code", json.string("not_found")),
              #("message", json.string("Tenant not found")),
            ]),
          ),
        ]),
      )

    Error(_) ->
      json_helpers.error_response(500, "server_error", "Failed to get tenant")

    Ok(tenant_info) ->
      case tenant_secrets.get_secrets(actor, tenant_id) {
        Error(_) ->
          json_helpers.error_response(
            500,
            "server_error",
            "Failed to get secrets",
          )

        Ok(#(secret1, secret2)) ->
          json_helpers.json_response(
            200,
            json.object([
              #(
                "tenant",
                json.object([
                  #("id", json.string(tenant_info.id)),
                  #("name", json.string(tenant_info.name)),
                  #("secret1", json.string(secret1)),
                  #("secret2", json.string(secret2)),
                ]),
              ),
            ]),
          )
      }
  }
}

/// DELETE /api/admin/tenants/:id or /api/tenants/:id — delete a tenant.
pub fn delete(_req: Request, ctx: Context, tenant_id: String) -> Response {
  use actor <- require_tenant_secrets(ctx)

  case tenant_secrets.tenant_exists(actor, tenant_id) {
    False ->
      json_helpers.json_response(
        404,
        json.object([
          #(
            "error",
            json.object([
              #("code", json.string("not_found")),
              #("message", json.string("Tenant not found")),
            ]),
          ),
        ]),
      )

    True -> {
      tenant_secrets.unregister_tenant(actor, tenant_id)
      json_helpers.json_response(
        200,
        json.object([#("message", json.string("Tenant unregistered"))]),
      )
    }
  }
}

/// POST /api/admin/tenants/:id/secrets/:slot or /api/tenants/:id/secrets/:slot
/// — regenerate a tenant secret.
pub fn regenerate_secret(
  _req: Request,
  ctx: Context,
  tenant_id: String,
  slot_str: String,
) -> Response {
  use actor <- require_tenant_secrets(ctx)

  case parse_slot(slot_str) {
    Error(_) ->
      json_helpers.json_response(
        400,
        json.object([
          #(
            "error",
            json.object([
              #("code", json.string("invalid_slot")),
              #("message", json.string("Slot must be 1 or 2")),
            ]),
          ),
        ]),
      )

    Ok(slot) ->
      case tenant_secrets.regenerate_secret(actor, tenant_id, slot) {
        Ok(new_secret) ->
          json_helpers.json_response(
            200,
            json.object([#("secret", json.string(new_secret))]),
          )

        Error(tenant_secrets.TenantNotFound) ->
          json_helpers.json_response(
            404,
            json.object([
              #(
                "error",
                json.object([
                  #("code", json.string("not_found")),
                  #("message", json.string("Tenant not found")),
                ]),
              ),
            ]),
          )

        Error(_) ->
          json_helpers.error_response(
            500,
            "server_error",
            "Failed to regenerate secret",
          )
      }
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Parse slot string ("1" or "2") to SecretSlot type.
fn parse_slot(slot_str: String) -> Result(tenant_secrets.SecretSlot, Nil) {
  case int.parse(slot_str) {
    Ok(1) -> Ok(tenant_secrets.Slot1)
    Ok(2) -> Ok(tenant_secrets.Slot2)
    _ -> Error(Nil)
  }
}

/// Extract the tenant_secrets actor from context, returning 500 if not configured.
fn require_tenant_secrets(
  ctx: Context,
  next: fn(Subject(Message)) -> Response,
) -> Response {
  case ctx.tenant_secrets {
    None ->
      json_helpers.error_response(
        500,
        "server_error",
        "Tenant management not configured",
      )
    Some(actor) -> next(actor)
  }
}
