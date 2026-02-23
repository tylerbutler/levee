//// Create tenant form page component.

import gleam/option.{type Option, None, Some}
import gleam/string
import lustre/attribute.{class, disabled, for, id, placeholder, type_, value}
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html.{a, button, div, form, h1, input, label, p, span, text}
import lustre/event

// ─────────────────────────────────────────────────────────────────────────────
// Model
// ─────────────────────────────────────────────────────────────────────────────

pub type FormState {
  Idle
  Submitting
  Error(String)
}

pub type Model {
  Model(
    tenant_id: String,
    secret: String,
    state: FormState,
    pending_submit: Option(SubmitData),
  )
}

pub type SubmitData {
  SubmitData(tenant_id: String, secret: String)
}

pub fn init() -> Model {
  Model(tenant_id: "", secret: "", state: Idle, pending_submit: None)
}

pub fn start_loading(model: Model) -> Model {
  Model(..model, state: Submitting, pending_submit: None)
}

pub fn set_error(model: Model, error: String) -> Model {
  Model(..model, state: Error(error))
}

pub fn get_pending_submit(model: Model) -> Option(SubmitData) {
  model.pending_submit
}

// ─────────────────────────────────────────────────────────────────────────────
// Messages
// ─────────────────────────────────────────────────────────────────────────────

pub type Msg {
  UpdateTenantId(String)
  UpdateSecret(String)
  Submit
}

// ─────────────────────────────────────────────────────────────────────────────
// Update
// ─────────────────────────────────────────────────────────────────────────────

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    UpdateTenantId(tenant_id) -> #(
      Model(..model, tenant_id: tenant_id),
      effect.none(),
    )

    UpdateSecret(secret) -> #(Model(..model, secret: secret), effect.none())

    Submit -> {
      case string.is_empty(string.trim(model.tenant_id)), string.is_empty(string.trim(model.secret)) {
        True, _ -> #(
          Model(..model, state: Error("Tenant ID is required")),
          effect.none(),
        )
        _, True -> #(
          Model(..model, state: Error("Secret is required")),
          effect.none(),
        )
        False, False -> {
          let data = SubmitData(
            tenant_id: string.trim(model.tenant_id),
            secret: model.secret,
          )
          #(Model(..model, pending_submit: Some(data)), effect.none())
        }
      }
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// View
// ─────────────────────────────────────────────────────────────────────────────

pub fn view(model: Model) -> Element(Msg) {
  let is_submitting = case model.state {
    Submitting -> True
    _ -> False
  }

  div([class("page tenant-new-page")], [
    div([class("page-header")], [
      a([class("back-link"), attribute.href("/admin/tenants")], [
        text("Back to Tenants"),
      ]),
      h1([class("page-title")], [text("Create Tenant")]),
    ]),
    div([class("card form-card")], [
      view_error(model.state),
      form([class("tenant-form"), event.on_submit(fn(_) { Submit })], [
        div([class("form-group")], [
          label([for("tenant_id")], [text("Tenant ID")]),
          input([
            type_("text"),
            id("tenant_id"),
            placeholder("my-tenant"),
            value(model.tenant_id),
            event.on_input(UpdateTenantId),
            attribute.required(True),
          ]),
          p([class("form-help")], [
            text("Choose a unique identifier for this tenant. This cannot be changed later."),
          ]),
        ]),
        div([class("form-group")], [
          label([for("secret")], [text("Secret")]),
          input([
            type_("password"),
            id("secret"),
            placeholder("Tenant signing secret"),
            value(model.secret),
            event.on_input(UpdateSecret),
            attribute.required(True),
          ]),
          p([class("form-help")], [
            text("Used to sign JWT tokens for this tenant's clients."),
          ]),
        ]),
        button(
          [type_("submit"), class("btn btn-primary"), disabled(is_submitting)],
          [
            case is_submitting {
              True -> text("Creating...")
              False -> text("Create Tenant")
            },
          ],
        ),
      ]),
    ]),
  ])
}

fn view_error(state: FormState) -> Element(Msg) {
  case state {
    Error(message) ->
      div([class("alert alert-error")], [
        span([class("alert-icon")], [text("!")]),
        span([class("alert-message")], [text(message)]),
      ])
    _ -> element.none()
  }
}
