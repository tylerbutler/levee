//// Tenant detail page component with edit secret and type-to-confirm delete.

import gleam/option.{type Option, None, Some}
import gleam/string
import lustre/attribute.{class, disabled, for, id, placeholder, type_, value}
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html.{a, button, div, form, h1, h2, input, label, p, span, text}
import lustre/event

// ─────────────────────────────────────────────────────────────────────────────
// Model
// ─────────────────────────────────────────────────────────────────────────────

pub type PageState {
  Loading
  Loaded
  NotFound
  Error(String)
}

pub type SecretState {
  SecretIdle
  SecretSubmitting
  SecretSuccess
  SecretError(String)
}

pub type DeleteState {
  DeleteHidden
  DeleteConfirming(confirmation_input: String)
  DeleteSubmitting
  DeleteError(String)
}

pub type Model {
  Model(
    tenant_id: String,
    state: PageState,
    new_secret: String,
    secret_state: SecretState,
    delete_state: DeleteState,
    pending_update: Option(String),
    pending_delete: Bool,
  )
}

pub fn init(tenant_id: String) -> Model {
  Model(
    tenant_id: tenant_id,
    state: Loading,
    new_secret: "",
    secret_state: SecretIdle,
    delete_state: DeleteHidden,
    pending_update: None,
    pending_delete: False,
  )
}

pub fn set_loaded(model: Model) -> Model {
  Model(..model, state: Loaded)
}

pub fn set_not_found(model: Model) -> Model {
  Model(..model, state: NotFound)
}

pub fn set_error(model: Model, error: String) -> Model {
  Model(..model, state: Error(error))
}

pub fn start_update_loading(model: Model) -> Model {
  Model(..model, secret_state: SecretSubmitting, pending_update: None)
}

pub fn set_update_success(model: Model) -> Model {
  Model(..model, secret_state: SecretSuccess, new_secret: "")
}

pub fn set_update_error(model: Model, error: String) -> Model {
  Model(..model, secret_state: SecretError(error))
}

pub fn get_pending_update(model: Model) -> Option(String) {
  model.pending_update
}

pub fn start_delete_loading(model: Model) -> Model {
  Model(..model, delete_state: DeleteSubmitting, pending_delete: False)
}

pub fn get_pending_delete(model: Model) -> Bool {
  model.pending_delete
}

// ─────────────────────────────────────────────────────────────────────────────
// Messages
// ─────────────────────────────────────────────────────────────────────────────

pub type Msg {
  // Secret editing
  UpdateNewSecret(String)
  SubmitSecret
  // Delete flow
  ShowDeleteConfirm
  HideDeleteConfirm
  UpdateDeleteConfirmation(String)
  ConfirmDelete
}

// ─────────────────────────────────────────────────────────────────────────────
// Update
// ─────────────────────────────────────────────────────────────────────────────

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    UpdateNewSecret(secret) -> #(
      Model(..model, new_secret: secret),
      effect.none(),
    )

    SubmitSecret -> {
      case string.is_empty(string.trim(model.new_secret)) {
        True -> #(
          Model(..model, secret_state: SecretError("Secret cannot be empty")),
          effect.none(),
        )
        False -> {
          #(
            Model(..model, pending_update: Some(model.new_secret)),
            effect.none(),
          )
        }
      }
    }

    ShowDeleteConfirm -> #(
      Model(..model, delete_state: DeleteConfirming("")),
      effect.none(),
    )

    HideDeleteConfirm -> #(
      Model(..model, delete_state: DeleteHidden),
      effect.none(),
    )

    UpdateDeleteConfirmation(input) -> #(
      Model(..model, delete_state: DeleteConfirming(input)),
      effect.none(),
    )

    ConfirmDelete -> {
      case model.delete_state {
        DeleteConfirming(input) if input == model.tenant_id -> {
          #(Model(..model, pending_delete: True), effect.none())
        }
        _ -> #(model, effect.none())
      }
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// View
// ─────────────────────────────────────────────────────────────────────────────

pub fn view(model: Model) -> Element(Msg) {
  div([class("page tenant-detail-page")], [
    div([class("page-header")], [
      a([class("back-link"), attribute.href("/admin/tenants")], [
        text("Back to Tenants"),
      ]),
      h1([class("page-title")], [text("Tenant: " <> model.tenant_id)]),
    ]),
    view_content(model),
  ])
}

fn view_content(model: Model) -> Element(Msg) {
  case model.state {
    Loading ->
      div([class("loading-state")], [p([], [text("Loading tenant...")])])

    NotFound ->
      div([class("empty-state card")], [
        p([], [text("Tenant not found.")]),
        a([attribute.href("/admin/tenants")], [text("Back to Tenants")]),
      ])

    Error(message) ->
      div([class("error-state")], [
        div([class("alert alert-error")], [
          span([class("alert-icon")], [text("!")]),
          span([class("alert-message")], [text(message)]),
        ]),
      ])

    Loaded ->
      div([class("tenant-detail-content")], [
        view_info(model),
        view_update_secret(model),
        view_delete_section(model),
      ])
  }
}

fn view_info(model: Model) -> Element(Msg) {
  div([class("card")], [
    h2([], [text("Tenant Information")]),
    div([class("detail-row")], [
      span([class("detail-label")], [text("ID")]),
      span([class("detail-value")], [text(model.tenant_id)]),
    ]),
  ])
}

fn view_update_secret(model: Model) -> Element(Msg) {
  let is_submitting = case model.secret_state {
    SecretSubmitting -> True
    _ -> False
  }

  div([class("card")], [
    h2([], [text("Update Secret")]),
    view_secret_status(model.secret_state),
    form([class("tenant-form"), event.on_submit(fn(_) { SubmitSecret })], [
      div([class("form-group")], [
        label([for("new_secret")], [text("New Secret")]),
        input([
          type_("password"),
          id("new_secret"),
          placeholder("Enter new signing secret"),
          value(model.new_secret),
          event.on_input(UpdateNewSecret),
          attribute.required(True),
        ]),
      ]),
      button(
        [type_("submit"), class("btn btn-primary"), disabled(is_submitting)],
        [
          case is_submitting {
            True -> text("Updating...")
            False -> text("Update Secret")
          },
        ],
      ),
    ]),
  ])
}

fn view_secret_status(state: SecretState) -> Element(Msg) {
  case state {
    SecretSuccess ->
      div([class("alert alert-success")], [
        span([class("alert-message")], [text("Secret updated successfully.")]),
      ])
    SecretError(message) ->
      div([class("alert alert-error")], [
        span([class("alert-icon")], [text("!")]),
        span([class("alert-message")], [text(message)]),
      ])
    _ -> element.none()
  }
}

fn view_delete_section(model: Model) -> Element(Msg) {
  div([class("card danger-card")], [
    h2([], [text("Danger Zone")]),
    case model.delete_state {
      DeleteHidden ->
        button(
          [class("btn btn-danger"), event.on_click(ShowDeleteConfirm)],
          [text("Delete Tenant")],
        )

      DeleteConfirming(confirmation) -> {
        let matches = confirmation == model.tenant_id
        div([class("delete-confirm")], [
          p([class("delete-warning")], [
            text(
              "This action cannot be undone. Type the tenant ID to confirm:",
            ),
          ]),
          p([class("delete-tenant-id")], [text(model.tenant_id)]),
          div([class("form-group")], [
            input([
              type_("text"),
              placeholder("Type tenant ID to confirm"),
              value(confirmation),
              event.on_input(UpdateDeleteConfirmation),
              class("delete-confirm-input"),
            ]),
          ]),
          div([class("delete-actions")], [
            button(
              [
                class("btn btn-danger"),
                disabled(!matches),
                event.on_click(ConfirmDelete),
              ],
              [text("Delete Tenant")],
            ),
            button(
              [class("btn btn-secondary"), event.on_click(HideDeleteConfirm)],
              [text("Cancel")],
            ),
          ]),
        ])
      }

      DeleteSubmitting ->
        p([class("loading")], [text("Deleting tenant...")])

      DeleteError(message) ->
        div([], [
          div([class("alert alert-error")], [
            span([class("alert-icon")], [text("!")]),
            span([class("alert-message")], [text(message)]),
          ]),
          button(
            [class("btn btn-secondary"), event.on_click(HideDeleteConfirm)],
            [text("Cancel")],
          ),
        ])
    },
  ])
}
