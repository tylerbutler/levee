# Admin UI Tenant Management Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build tenant management pages (list, create, detail/edit, delete) in the Lustre admin SPA, wire them into the main app, and add integration tests.

**Architecture:** Each page is a Gleam module following the existing nested component pattern (Model/Msg/init/update/view). The main app delegates to page modules and handles API effects. The `api.gleam` client already has all tenant CRUD functions — we only write UI code.

**Tech Stack:** Gleam (Lustre framework, modem routing, gleam_fetch), Elixir (Phoenix, ExUnit), HTML/CSS

---

### Task 1: Add `TenantNew` Route to Router

**Files:**
- Modify: `server/levee_admin/src/levee_admin/router.gleam`
- Modify: `server/levee_admin/test/levee_admin_test.gleam`

**Step 1: Add failing tests for the new route**

Add to `server/levee_admin/test/levee_admin_test.gleam` before the helper function:

```gleam
pub fn parse_tenant_new_route_test() {
  let uri = uri_from_path("/admin/tenants/new")
  router.parse(uri)
  |> should.equal(router.TenantNew)
}

pub fn to_path_tenant_new_test() {
  router.to_path(router.TenantNew)
  |> should.equal("/admin/tenants/new")
}
```

**Step 2: Run tests to verify they fail**

Run: `cd server/levee_admin && gleam test`
Expected: Compile error — `TenantNew` variant doesn't exist on `Route` type.

**Step 3: Add `TenantNew` variant and routing logic**

In `server/levee_admin/src/levee_admin/router.gleam`:

1. Add `TenantNew` variant to the `Route` type (after `Tenants`):

```gleam
pub type Route {
  Login
  Register
  Dashboard
  Tenants
  TenantNew
  TenantDetail(id: String)
  NotFound
}
```

2. In `parse`, add the `TenantNew` case **before** the `TenantDetail` catch-all:

```gleam
    ["admin", "tenants", "new"] -> TenantNew
    ["admin", "tenants", id] -> TenantDetail(id)
```

3. In `to_path`, add:

```gleam
    TenantNew -> "/admin/tenants/new"
```

**Step 4: Run tests to verify they pass**

Run: `cd server/levee_admin && gleam test`
Expected: All 12 tests pass (10 existing + 2 new).

**Step 5: Commit**

```bash
git add server/levee_admin/src/levee_admin/router.gleam server/levee_admin/test/levee_admin_test.gleam
git commit -m "feat(admin): add TenantNew route to admin router"
```

---

### Task 2: Create Tenant List Page (`tenants.gleam`) — Issue #14

**Files:**
- Create: `server/levee_admin/src/levee_admin/pages/tenants.gleam`

**Step 1: Create the tenant list page module**

Create `server/levee_admin/src/levee_admin/pages/tenants.gleam`:

```gleam
//// Tenant list page component.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import lustre/attribute.{class, href}
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html.{a, div, h1, li, p, span, text, ul}
import lustre/event

// ─────────────────────────────────────────────────────────────────────────────
// Model
// ─────────────────────────────────────────────────────────────────────────────

pub type Tenant {
  Tenant(id: String)
}

pub type PageState {
  Loading
  Loaded
  Error(String)
}

pub type Model {
  Model(tenants: List(Tenant), state: PageState)
}

pub fn init() -> Model {
  Model(tenants: [], state: Loading)
}

// ─────────────────────────────────────────────────────────────────────────────
// Messages
// ─────────────────────────────────────────────────────────────────────────────

pub type Msg {
  LoadTenants
  TenantsLoaded(List(Tenant))
  LoadError(String)
  Retry
}

// ─────────────────────────────────────────────────────────────────────────────
// Update
// ─────────────────────────────────────────────────────────────────────────────

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    LoadTenants -> {
      #(Model(..model, state: Loading), effect.none())
    }

    TenantsLoaded(tenants) -> {
      #(Model(tenants: tenants, state: Loaded), effect.none())
    }

    LoadError(error) -> {
      #(Model(..model, state: Error(error)), effect.none())
    }

    Retry -> {
      #(Model(..model, state: Loading), effect.none())
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// View
// ─────────────────────────────────────────────────────────────────────────────

pub fn view(model: Model) -> Element(Msg) {
  div([class("page tenants-page")], [
    div([class("page-header")], [
      h1([class("page-title")], [text("Tenants")]),
      a([class("btn btn-primary"), href("/admin/tenants/new")], [
        text("Create Tenant"),
      ]),
    ]),
    view_content(model),
  ])
}

fn view_content(model: Model) -> Element(Msg) {
  case model.state {
    Loading -> div([class("loading-state")], [p([], [text("Loading tenants...")])])

    Error(message) ->
      div([class("error-state")], [
        div([class("alert alert-error")], [
          span([class("alert-icon")], [text("!")]),
          span([class("alert-message")], [text(message)]),
        ]),
        html.button(
          [class("btn btn-primary"), event.on_click(Retry)],
          [text("Retry")],
        ),
      ])

    Loaded ->
      case model.tenants {
        [] ->
          div([class("empty-state card")], [
            p([], [text("No tenants registered yet.")]),
            a([class("btn btn-primary"), href("/admin/tenants/new")], [
              text("Create Your First Tenant"),
            ]),
          ])

        tenants ->
          div([class("tenant-table card")], [
            div([class("tenant-table-header")], [
              span([], [
                text(
                  int.to_string(list.length(tenants)) <> " tenant"
                  <> case list.length(tenants) {
                    1 -> ""
                    _ -> "s"
                  },
                ),
              ]),
            ]),
            ul(
              [class("tenant-list")],
              list.map(tenants, fn(tenant) {
                li([class("tenant-row")], [
                  a([href("/admin/tenants/" <> tenant.id)], [
                    span([class("tenant-id")], [text(tenant.id)]),
                  ]),
                ])
              }),
            ),
          ])
      }
  }
}
```

**Step 2: Verify it compiles**

Run: `cd server/levee_admin && gleam check`
Expected: No errors.

**Step 3: Commit**

```bash
git add server/levee_admin/src/levee_admin/pages/tenants.gleam
git commit -m "feat(admin): add tenant list page component (#14)"
```

---

### Task 3: Create Tenant Form Page (`tenant_new.gleam`) — Issue #15

**Files:**
- Create: `server/levee_admin/src/levee_admin/pages/tenant_new.gleam`

**Step 1: Create the create tenant page module**

Create `server/levee_admin/src/levee_admin/pages/tenant_new.gleam`:

```gleam
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
      // Validate: both fields non-empty
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
```

**Step 2: Verify it compiles**

Run: `cd server/levee_admin && gleam check`
Expected: No errors.

**Step 3: Commit**

```bash
git add server/levee_admin/src/levee_admin/pages/tenant_new.gleam
git commit -m "feat(admin): add create tenant form component (#15)"
```

---

### Task 4: Create Tenant Detail Page (`tenant_detail.gleam`) — Issues #16, #17

**Files:**
- Create: `server/levee_admin/src/levee_admin/pages/tenant_detail.gleam`

**Step 1: Create the tenant detail page module**

Create `server/levee_admin/src/levee_admin/pages/tenant_detail.gleam`:

```gleam
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

      DeleteConfirming(input) -> {
        let matches = input == model.tenant_id
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
              value(input),
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
```

**Step 2: Verify it compiles**

Run: `cd server/levee_admin && gleam check`
Expected: No errors.

**Step 3: Commit**

```bash
git add server/levee_admin/src/levee_admin/pages/tenant_detail.gleam
git commit -m "feat(admin): add tenant detail page with edit and delete (#16, #17)"
```

---

### Task 5: Wire Pages Into Main App (`levee_admin.gleam`)

**Files:**
- Modify: `server/levee_admin/src/levee_admin.gleam`

This is the largest change — connects all new pages into the main Lustre app.

**Step 1: Add imports**

Add after the existing page imports (line 24):

```gleam
import levee_admin/pages/tenant_detail
import levee_admin/pages/tenant_new
import levee_admin/pages/tenants
```

**Step 2: Update Model type**

Replace the `Model` type (lines 32-41) to add new page models:

```gleam
pub type Model {
  Model(
    route: Route,
    user: Option(User),
    session_token: Option(String),
    login: login.Model,
    register: register.Model,
    dashboard: dashboard.Model,
    tenants: tenants.Model,
    tenant_new: tenant_new.Model,
    tenant_detail: tenant_detail.Model,
  )
}
```

**Step 3: Update init function**

Update the model construction in `init` (lines 54-62) to initialize new pages:

```gleam
  let model =
    Model(
      route: router.Login,
      user: None,
      session_token: session_token,
      login: login.init(),
      register: register.init(),
      dashboard: dashboard.init(),
      tenants: tenants.init(),
      tenant_new: tenant_new.init(),
      tenant_detail: tenant_detail.init(""),
    )
```

**Step 4: Update Msg type**

Replace the `Msg` type (lines 71-81) to add new message variants:

```gleam
pub type Msg {
  OnRouteChange(Route)
  LoginMsg(login.Msg)
  RegisterMsg(register.Msg)
  DashboardMsg(dashboard.Msg)
  TenantsMsg(tenants.Msg)
  TenantNewMsg(tenant_new.Msg)
  TenantDetailMsg(tenant_detail.Msg)
  // Auth API responses
  LoginResponse(Result(api.AuthResponse, api.ApiError))
  RegisterResponse(Result(api.AuthResponse, api.ApiError))
  MeResponse(Result(api.User, api.ApiError))
  // Tenant API responses
  TenantsResponse(Result(api.TenantList, api.ApiError))
  CreateTenantResponse(Result(api.TenantResponse, api.ApiError))
  GetTenantResponse(Result(api.Tenant, api.ApiError))
  UpdateTenantResponse(Result(api.TenantResponse, api.ApiError))
  DeleteTenantResponse(Result(api.DeleteResponse, api.ApiError))
  Logout
}
```

**Step 5: Update OnRouteChange handler**

Replace the `OnRouteChange` case (lines 93-101) to handle new routes and trigger data loading:

```gleam
    OnRouteChange(route) -> {
      // Redirect to login if not authenticated and trying to access protected route
      let route = case model.session_token, route {
        None, router.Dashboard -> router.Login
        None, router.Tenants -> router.Login
        None, router.TenantNew -> router.Login
        None, router.TenantDetail(_) -> router.Login
        _, r -> r
      }

      // Trigger data loading for pages that need it
      let effect = case route, model.session_token {
        router.Tenants, Some(token) ->
          api.list_tenants(token, TenantsResponse)
        router.TenantDetail(id), Some(token) ->
          api.get_tenant(token, id, GetTenantResponse)
        _, _ -> effect.none()
      }

      // Reset page state when navigating to new pages
      let model = case route {
        router.Tenants -> Model(..model, route: route, tenants: tenants.init())
        router.TenantNew -> Model(..model, route: route, tenant_new: tenant_new.init())
        router.TenantDetail(id) -> Model(..model, route: route, tenant_detail: tenant_detail.init(id))
        _ -> Model(..model, route: route)
      }

      #(model, effect)
    }
```

**Step 6: Add update handlers for new pages**

Add after the `DashboardMsg` handler (line 153) and before the `LoginResponse` handler:

```gleam
    TenantsMsg(tenants_msg) -> {
      let #(tenants_model, tenants_effect) =
        tenants.update(model.tenants, tenants_msg)
      let effect = effect.map(tenants_effect, TenantsMsg)

      // Check for retry — re-fetch tenants
      case tenants_msg {
        tenants.Retry ->
          case model.session_token {
            Some(token) -> #(
              Model(..model, tenants: tenants_model),
              api.list_tenants(token, TenantsResponse),
            )
            None -> #(Model(..model, tenants: tenants_model), effect)
          }
        _ -> #(Model(..model, tenants: tenants_model), effect)
      }
    }

    TenantNewMsg(tenant_new_msg) -> {
      let #(tenant_new_model, tenant_new_effect) =
        tenant_new.update(model.tenant_new, tenant_new_msg)
      let effect = effect.map(tenant_new_effect, TenantNewMsg)

      // Check for pending submission
      case tenant_new.get_pending_submit(tenant_new_model), model.session_token {
        Some(data), Some(token) -> {
          let tenant_new_model = tenant_new.start_loading(tenant_new_model)
          let api_effect =
            api.create_tenant(token, data.tenant_id, data.secret, CreateTenantResponse)
          #(Model(..model, tenant_new: tenant_new_model), api_effect)
        }
        _, _ -> #(Model(..model, tenant_new: tenant_new_model), effect)
      }
    }

    TenantDetailMsg(detail_msg) -> {
      let #(detail_model, detail_effect) =
        tenant_detail.update(model.tenant_detail, detail_msg)
      let effect = effect.map(detail_effect, TenantDetailMsg)

      // Check for pending secret update
      case tenant_detail.get_pending_update(detail_model), model.session_token {
        Some(secret), Some(token) -> {
          let detail_model = tenant_detail.start_update_loading(detail_model)
          let api_effect =
            api.update_tenant(
              token,
              detail_model.tenant_id,
              secret,
              UpdateTenantResponse,
            )
          #(Model(..model, tenant_detail: detail_model), api_effect)
        }
        _, _ -> {
          // Check for pending delete
          case tenant_detail.get_pending_delete(detail_model), model.session_token {
            True, Some(token) -> {
              let detail_model = tenant_detail.start_delete_loading(detail_model)
              let api_effect =
                api.delete_tenant(
                  token,
                  detail_model.tenant_id,
                  DeleteTenantResponse,
                )
              #(Model(..model, tenant_detail: detail_model), api_effect)
            }
            _, _ -> #(Model(..model, tenant_detail: detail_model), effect)
          }
        }
      }
    }
```

**Step 7: Add API response handlers**

Add after the `MeResponse(Error(_))` handler (line 217) and before the `Logout` handler:

```gleam
    TenantsResponse(Ok(tenant_list)) -> {
      let tenant_models =
        list.map(tenant_list.tenants, fn(t) { tenants.Tenant(id: t.id) })
      let tenants_model = model.tenants
      let tenants_model =
        tenants.update(tenants_model, tenants.TenantsLoaded(tenant_models)).0
      #(Model(..model, tenants: tenants_model), effect.none())
    }

    TenantsResponse(Error(_error)) -> {
      let tenants_model =
        tenants.update(model.tenants, tenants.LoadError("Failed to load tenants")).0
      #(Model(..model, tenants: tenants_model), effect.none())
    }

    CreateTenantResponse(Ok(response)) -> {
      // Navigate to the new tenant's detail page
      let model = Model(..model, tenant_new: tenant_new.init())
      #(model, modem.push("/admin/tenants/" <> response.tenant.id, None, None))
    }

    CreateTenantResponse(Error(api.ServerError(409, _))) -> {
      let tenant_new_model =
        tenant_new.set_error(model.tenant_new, "A tenant with this ID already exists")
      #(Model(..model, tenant_new: tenant_new_model), effect.none())
    }

    CreateTenantResponse(Error(_error)) -> {
      let tenant_new_model =
        tenant_new.set_error(model.tenant_new, "Failed to create tenant")
      #(Model(..model, tenant_new: tenant_new_model), effect.none())
    }

    GetTenantResponse(Ok(_tenant)) -> {
      let detail_model = tenant_detail.set_loaded(model.tenant_detail)
      #(Model(..model, tenant_detail: detail_model), effect.none())
    }

    GetTenantResponse(Error(api.ServerError(404, _))) -> {
      let detail_model = tenant_detail.set_not_found(model.tenant_detail)
      #(Model(..model, tenant_detail: detail_model), effect.none())
    }

    GetTenantResponse(Error(_error)) -> {
      let detail_model =
        tenant_detail.set_error(model.tenant_detail, "Failed to load tenant")
      #(Model(..model, tenant_detail: detail_model), effect.none())
    }

    UpdateTenantResponse(Ok(_response)) -> {
      let detail_model = tenant_detail.set_update_success(model.tenant_detail)
      #(Model(..model, tenant_detail: detail_model), effect.none())
    }

    UpdateTenantResponse(Error(_error)) -> {
      let detail_model =
        tenant_detail.set_update_error(model.tenant_detail, "Failed to update secret")
      #(Model(..model, tenant_detail: detail_model), effect.none())
    }

    DeleteTenantResponse(Ok(_response)) -> {
      // Navigate back to tenant list
      #(model, modem.push("/admin/tenants", None, None))
    }

    DeleteTenantResponse(Error(_error)) -> {
      let detail_model = Model(
        ..model.tenant_detail,
        delete_state: tenant_detail.DeleteError("Failed to delete tenant"),
      )
      #(Model(..model, tenant_detail: detail_model), effect.none())
    }
```

**Step 8: Add import for list**

Add `import gleam/list` to the imports at the top (needed for `list.map` in TenantsResponse handler).

**Step 9: Update view_content**

Replace the `Tenants` and `TenantDetail` cases in `view_content` (lines 247-251):

```gleam
    router.Tenants ->
      view_authenticated_layout(
        model,
        element.map(tenants.view(model.tenants), TenantsMsg),
      )

    router.TenantNew ->
      view_authenticated_layout(
        model,
        element.map(tenant_new.view(model.tenant_new), TenantNewMsg),
      )

    router.TenantDetail(_id) ->
      view_authenticated_layout(
        model,
        element.map(tenant_detail.view(model.tenant_detail), TenantDetailMsg),
      )
```

**Step 10: Remove placeholder view functions**

Delete `view_tenants_placeholder` (lines 284-289) and `view_tenant_detail_placeholder` (lines 291-296) — they're no longer needed.

**Step 11: Verify it compiles**

Run: `cd server/levee_admin && gleam check`
Expected: No errors. Fix any compilation issues.

**Step 12: Run existing tests**

Run: `cd server/levee_admin && gleam test`
Expected: All 12 tests pass.

**Step 13: Commit**

```bash
git add server/levee_admin/src/levee_admin.gleam
git commit -m "feat(admin): wire tenant pages into main app

Connect tenant list, create, and detail pages to the main Lustre app.
Handle API effects for CRUD operations with proper error states."
```

---

### Task 6: Update Dashboard to Load Tenants

**Files:**
- Modify: `server/levee_admin/src/levee_admin/pages/dashboard.gleam`
- Modify: `server/levee_admin/src/levee_admin.gleam` (small addition to OnRouteChange)

**Step 1: Simplify dashboard Tenant type**

The dashboard's `Tenant` type has fields (name, slug, member_count) that don't exist in the API. Replace it to match the actual API response.

Replace the entire `dashboard.gleam` with:

```gleam
//// Dashboard page component.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import lustre/attribute.{class, href}
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html.{a, div, h1, h2, li, p, span, text, ul}

// ─────────────────────────────────────────────────────────────────────────────
// Model
// ─────────────────────────────────────────────────────────────────────────────

pub type Tenant {
  Tenant(id: String)
}

pub type Model {
  Model(tenants: List(Tenant), loading: Bool, error: Option(String))
}

pub fn init() -> Model {
  Model(tenants: [], loading: False, error: None)
}

// ─────────────────────────────────────────────────────────────────────────────
// Messages
// ─────────────────────────────────────────────────────────────────────────────

pub type Msg {
  TenantsLoaded(List(Tenant))
  LoadError(String)
}

// ─────────────────────────────────────────────────────────────────────────────
// Update
// ─────────────────────────────────────────────────────────────────────────────

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    TenantsLoaded(tenants) -> {
      #(Model(tenants: tenants, loading: False, error: None), effect.none())
    }

    LoadError(error) -> {
      #(Model(..model, error: Some(error), loading: False), effect.none())
    }
  }
}

/// Set loading state (called by parent before API call)
pub fn start_loading(model: Model) -> Model {
  Model(..model, loading: True, error: None)
}

// ─────────────────────────────────────────────────────────────────────────────
// View
// ─────────────────────────────────────────────────────────────────────────────

pub fn view(model: Model) -> Element(Msg) {
  div([class("page dashboard")], [
    h1([class("page-title")], [text("Dashboard")]),
    div([class("dashboard-content")], [
      view_welcome(),
      view_tenants_section(model),
      view_quick_actions(),
    ]),
  ])
}

fn view_welcome() -> Element(Msg) {
  div([class("card welcome-card")], [
    h2([], [text("Welcome to Levee Admin")]),
    p([], [
      text(
        "Manage your tenants, users, and document access from this dashboard.",
      ),
    ]),
  ])
}

fn view_tenants_section(model: Model) -> Element(Msg) {
  div([class("card tenants-card")], [
    h2([], [text("Your Tenants")]),
    case model.loading {
      True -> p([class("loading")], [text("Loading...")])
      False ->
        case model.error {
          Some(error) ->
            div([class("alert alert-error")], [
              span([class("alert-icon")], [text("!")]),
              span([class("alert-message")], [text(error)]),
            ])
          None ->
            case model.tenants {
              [] ->
                div([class("empty-state")], [
                  p([], [text("You don't have any tenants yet.")]),
                  a([class("btn btn-primary"), href("/admin/tenants/new")], [
                    text("Create Your First Tenant"),
                  ]),
                ])
              tenants -> view_tenant_preview(tenants)
            }
        }
    },
  ])
}

fn view_tenant_preview(tenants: List(Tenant)) -> Element(Msg) {
  let count = list.length(tenants)
  let preview = list.take(tenants, 5)

  div([], [
    p([class("tenant-count")], [
      text(
        int.to_string(count) <> " tenant" <> case count {
          1 -> ""
          _ -> "s"
        } <> " registered",
      ),
    ]),
    ul([class("tenant-list")], list.map(preview, fn(tenant) {
      li([class("tenant-item")], [
        a([href("/admin/tenants/" <> tenant.id)], [text(tenant.id)]),
      ])
    })),
    case count > 5 {
      True ->
        a([class("view-all-link"), href("/admin/tenants")], [
          text("View all " <> int.to_string(count) <> " tenants"),
        ])
      False ->
        a([class("view-all-link"), href("/admin/tenants")], [
          text("View all tenants"),
        ])
    },
  ])
}

fn view_quick_actions() -> Element(Msg) {
  div([class("card quick-actions-card")], [
    h2([], [text("Quick Actions")]),
    ul([class("action-list")], [
      li([], [
        a([href("/admin/tenants/new")], [text("Create New Tenant")]),
      ]),
      li([], [
        a([href("/admin/tenants")], [text("View All Tenants")]),
      ]),
    ]),
  ])
}
```

**Step 2: Update OnRouteChange in `levee_admin.gleam` for Dashboard**

In the `OnRouteChange` handler, update the data-loading section to also load tenants on Dashboard:

```gleam
      // Trigger data loading for pages that need it
      let effect = case route, model.session_token {
        router.Dashboard, Some(token) ->
          api.list_tenants(token, DashboardTenantsResponse)
        router.Tenants, Some(token) ->
          api.list_tenants(token, TenantsResponse)
        router.TenantDetail(id), Some(token) ->
          api.get_tenant(token, id, GetTenantResponse)
        _, _ -> effect.none()
      }
```

**Step 3: Add DashboardTenantsResponse to Msg and handler**

Add `DashboardTenantsResponse(Result(api.TenantList, api.ApiError))` to the `Msg` type.

Add handler in update:

```gleam
    DashboardTenantsResponse(Ok(tenant_list)) -> {
      let tenant_models =
        list.map(tenant_list.tenants, fn(t) { dashboard.Tenant(id: t.id) })
      let dashboard_model =
        dashboard.update(model.dashboard, dashboard.TenantsLoaded(tenant_models)).0
      #(Model(..model, dashboard: dashboard_model), effect.none())
    }

    DashboardTenantsResponse(Error(_error)) -> {
      let dashboard_model =
        dashboard.update(model.dashboard, dashboard.LoadError("Failed to load tenants")).0
      #(Model(..model, dashboard: dashboard_model), effect.none())
    }
```

Also update the Dashboard case in OnRouteChange to set loading:

```gleam
        router.Dashboard -> Model(..model, route: route, dashboard: dashboard.start_loading(dashboard.init()))
```

**Step 4: Also trigger dashboard load after login/register success**

In the `LoginResponse(Ok(response))` and `RegisterResponse(Ok(response))` handlers, add the dashboard load effect. Replace the effect in LoginResponse(Ok):

```gleam
      let nav_effect = modem.push("/admin/dashboard", None, None)
      let load_effect = api.list_tenants(response.token, DashboardTenantsResponse)
      #(model, effect.batch([nav_effect, load_effect]))
```

Same for RegisterResponse(Ok) and MeResponse(Ok).

**Step 5: Verify it compiles and tests pass**

Run: `cd server/levee_admin && gleam check && gleam test`
Expected: No errors, all tests pass.

**Step 6: Commit**

```bash
git add server/levee_admin/src/levee_admin/pages/dashboard.gleam server/levee_admin/src/levee_admin.gleam
git commit -m "feat(admin): dashboard loads and displays tenant data

Dashboard now fetches tenants on page load, shows count and
preview of first 5 tenants with 'View all' link."
```

---

### Task 7: Add CSS for New Components

**Files:**
- Modify: `server/levee_admin/index.html`

**Step 1: Add CSS rules**

Add the following CSS before the closing `</style>` tag in `server/levee_admin/index.html`:

```css
    /* Page header with title and action button */
    .page-header {
      display: flex;
      align-items: center;
      justify-content: space-between;
      margin-bottom: 1.5rem;
      flex-wrap: wrap;
      gap: 0.5rem;
    }
    .page-title { margin-bottom: 0; }

    /* Back link */
    .back-link {
      color: var(--color-gray-500);
      text-decoration: none;
      font-size: 0.875rem;
      margin-bottom: 0.25rem;
    }
    .back-link:hover { color: var(--color-primary); }

    /* Cards */
    .card {
      background: white;
      border-radius: 0.5rem;
      padding: 1.5rem;
      box-shadow: 0 1px 3px rgba(0, 0, 0, 0.1);
      margin-bottom: 1rem;
    }
    .card h2 { font-size: 1rem; font-weight: 600; color: var(--color-gray-700); margin-bottom: 0.75rem; }
    .form-card { max-width: 500px; }

    /* Tenant table/list */
    .tenant-table-header {
      display: flex;
      justify-content: space-between;
      margin-bottom: 0.75rem;
      color: var(--color-gray-500);
      font-size: 0.875rem;
    }
    .tenant-list { list-style: none; }
    .tenant-row {
      border-top: 1px solid var(--color-gray-200);
      padding: 0.75rem 0;
    }
    .tenant-row a {
      color: var(--color-primary);
      text-decoration: none;
      font-weight: 500;
    }
    .tenant-row a:hover { text-decoration: underline; }
    .tenant-id { font-family: monospace; }

    /* Tenant form */
    .tenant-form { display: flex; flex-direction: column; gap: 1rem; }
    .form-help { color: var(--color-gray-500); font-size: 0.75rem; margin-top: 0.25rem; }

    /* Detail page */
    .tenant-detail-content { display: flex; flex-direction: column; gap: 1rem; max-width: 600px; }
    .detail-row { display: flex; gap: 1rem; padding: 0.5rem 0; }
    .detail-label { font-weight: 500; color: var(--color-gray-500); min-width: 80px; }
    .detail-value { font-family: monospace; }

    /* States */
    .loading-state, .empty-state, .error-state { padding: 2rem; text-align: center; }
    .error-state .btn { margin-top: 1rem; }

    /* Tenant count and preview on dashboard */
    .tenant-count { font-weight: 500; margin-bottom: 0.5rem; }
    .tenant-item { padding: 0.25rem 0; }
    .tenant-item a { color: var(--color-primary); text-decoration: none; font-family: monospace; }
    .tenant-item a:hover { text-decoration: underline; }
    .view-all-link { display: inline-block; margin-top: 0.75rem; color: var(--color-primary); text-decoration: none; font-size: 0.875rem; }
    .view-all-link:hover { text-decoration: underline; }

    /* Danger zone */
    .danger-card { border: 1px solid var(--color-error); }
    .danger-card h2 { color: var(--color-error); }
    .btn-danger { background-color: var(--color-error); color: white; }
    .btn-danger:hover:not(:disabled) { background-color: #b91c1c; }
    .btn-danger:disabled { opacity: 0.6; cursor: not-allowed; }
    .btn-secondary { background-color: var(--color-gray-100); color: var(--color-gray-700); border: 1px solid var(--color-gray-300); }
    .btn-secondary:hover { background-color: var(--color-gray-200); }
    .delete-confirm { margin-top: 1rem; }
    .delete-warning { color: var(--color-error); font-weight: 500; margin-bottom: 0.5rem; }
    .delete-tenant-id { font-family: monospace; font-weight: 600; background: var(--color-gray-100); padding: 0.25rem 0.5rem; border-radius: 0.25rem; display: inline-block; margin-bottom: 0.75rem; }
    .delete-confirm-input { border-color: var(--color-error) !important; }
    .delete-actions { display: flex; gap: 0.5rem; margin-top: 0.75rem; }

    /* Success alert */
    .alert-success { background-color: #f0fdf4; color: var(--color-success); display: flex; align-items: center; gap: 0.5rem; padding: 0.75rem 1rem; border-radius: 0.375rem; margin-bottom: 1rem; font-size: 0.875rem; }
```

**Step 2: Copy updated index.html to priv**

Run: `cp server/levee_admin/index.html server/priv/static/admin/index.html`

**Step 3: Commit**

```bash
git add server/levee_admin/index.html server/priv/static/admin/index.html
git commit -m "style(admin): add CSS for tenant management pages

Styles for tenant list, create form, detail page, danger zone,
type-to-confirm delete, loading/empty/error states."
```

---

### Task 8: Build and Verify Gleam Admin Compiles

**Step 1: Build the Gleam admin package**

Run: `cd server/levee_admin && gleam build`
Expected: Build succeeds with no errors.

**Step 2: Run all Gleam admin tests**

Run: `cd server/levee_admin && gleam test`
Expected: All tests pass.

**Step 3: Copy built assets to priv**

Run: `cp -r server/levee_admin/build/dev/javascript/levee_admin/ server/priv/static/admin/levee_admin/`

**Step 4: Commit built assets**

```bash
git add server/priv/static/admin/
git commit -m "build(admin): compile Gleam admin UI with tenant pages"
```

---

### Task 9: Elixir Integration Tests — Tenant Admin API via Session Auth

**Files:**
- Create: `server/test/levee_web/controllers/tenant_admin_controller_test.exs`

**Step 1: Create the test file**

Create `server/test/levee_web/controllers/tenant_admin_controller_test.exs`:

```elixir
defmodule LeveeWeb.TenantAdminControllerTest do
  use LeveeWeb.ConnCase

  alias Levee.Auth.GleamBridge
  alias Levee.Auth.SessionStore
  alias Levee.Auth.TenantSecrets

  setup do
    SessionStore.clear()

    # Create an admin user (first user gets auto-promoted)
    {:ok, admin} =
      GleamBridge.create_user("admin@example.com", "password123", "Admin")

    admin = %{admin | is_admin: true}
    SessionStore.store_user(admin)
    admin_session = GleamBridge.create_session(admin.id, nil)
    SessionStore.store_session(admin_session)

    # Create a non-admin user
    {:ok, user} =
      GleamBridge.create_user("user@example.com", "password123", "Regular User")

    SessionStore.store_user(user)
    user_session = GleamBridge.create_session(user.id, nil)
    SessionStore.store_session(user_session)

    # Clean up any test tenants
    on_exit(fn ->
      for id <- TenantSecrets.list_tenants() do
        TenantSecrets.unregister_tenant(id)
      end
    end)

    {:ok,
     admin: admin,
     admin_token: admin_session.id,
     user_token: user_session.id}
  end

  defp auth_conn(conn, token) do
    put_req_header(conn, "authorization", "Bearer #{token}")
  end

  # ── List tenants ──────────────────────────────────────────────────────────

  describe "GET /api/tenants" do
    test "returns empty list when no tenants", %{conn: conn, admin_token: token} do
      conn =
        conn
        |> auth_conn(token)
        |> get("/api/tenants")

      assert %{"tenants" => []} = json_response(conn, 200)
    end

    test "returns tenant list", %{conn: conn, admin_token: token} do
      TenantSecrets.register_tenant("tenant-a", "secret-a")
      TenantSecrets.register_tenant("tenant-b", "secret-b")

      conn =
        conn
        |> auth_conn(token)
        |> get("/api/tenants")

      assert %{"tenants" => tenants} = json_response(conn, 200)
      ids = Enum.map(tenants, & &1["id"])
      assert "tenant-a" in ids
      assert "tenant-b" in ids
    end

    test "returns 401 without auth", %{conn: conn} do
      conn = get(conn, "/api/tenants")
      assert json_response(conn, 401)
    end

    test "returns 403 for non-admin user", %{conn: conn, user_token: token} do
      conn =
        conn
        |> auth_conn(token)
        |> get("/api/tenants")

      assert %{"error" => %{"code" => "forbidden"}} = json_response(conn, 403)
    end
  end

  # ── Create tenant ─────────────────────────────────────────────────────────

  describe "POST /api/tenants" do
    test "creates tenant with valid data", %{conn: conn, admin_token: token} do
      conn =
        conn
        |> auth_conn(token)
        |> put_req_header("content-type", "application/json")
        |> post("/api/tenants", %{id: "new-tenant", secret: "new-secret"})

      assert %{"tenant" => %{"id" => "new-tenant"}, "message" => _} =
               json_response(conn, 201)

      assert TenantSecrets.tenant_exists?("new-tenant")
    end

    test "returns 409 for duplicate tenant", %{conn: conn, admin_token: token} do
      TenantSecrets.register_tenant("existing", "secret")

      conn =
        conn
        |> auth_conn(token)
        |> put_req_header("content-type", "application/json")
        |> post("/api/tenants", %{id: "existing", secret: "new-secret"})

      assert %{"error" => %{"code" => "tenant_exists"}} = json_response(conn, 409)
    end

    test "returns 422 for missing fields", %{conn: conn, admin_token: token} do
      conn =
        conn
        |> auth_conn(token)
        |> put_req_header("content-type", "application/json")
        |> post("/api/tenants", %{id: "only-id"})

      assert %{"error" => %{"code" => "missing_fields"}} = json_response(conn, 422)
    end

    test "returns 401 without auth", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/api/tenants", %{id: "t", secret: "s"})

      assert json_response(conn, 401)
    end

    test "returns 403 for non-admin", %{conn: conn, user_token: token} do
      conn =
        conn
        |> auth_conn(token)
        |> put_req_header("content-type", "application/json")
        |> post("/api/tenants", %{id: "t", secret: "s"})

      assert %{"error" => %{"code" => "forbidden"}} = json_response(conn, 403)
    end
  end

  # ── Get tenant ────────────────────────────────────────────────────────────

  describe "GET /api/tenants/:id" do
    test "returns tenant when exists", %{conn: conn, admin_token: token} do
      TenantSecrets.register_tenant("show-tenant", "secret")

      conn =
        conn
        |> auth_conn(token)
        |> get("/api/tenants/show-tenant")

      assert %{"tenant" => %{"id" => "show-tenant"}} = json_response(conn, 200)
    end

    test "returns 404 for non-existent tenant", %{conn: conn, admin_token: token} do
      conn =
        conn
        |> auth_conn(token)
        |> get("/api/tenants/nonexistent")

      assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
    end
  end

  # ── Update tenant ─────────────────────────────────────────────────────────

  describe "PUT /api/tenants/:id" do
    test "updates tenant secret", %{conn: conn, admin_token: token} do
      TenantSecrets.register_tenant("update-tenant", "old-secret")

      conn =
        conn
        |> auth_conn(token)
        |> put_req_header("content-type", "application/json")
        |> put("/api/tenants/update-tenant", %{secret: "new-secret"})

      assert %{"tenant" => %{"id" => "update-tenant"}, "message" => _} =
               json_response(conn, 200)
    end

    test "returns 404 for non-existent tenant", %{conn: conn, admin_token: token} do
      conn =
        conn
        |> auth_conn(token)
        |> put_req_header("content-type", "application/json")
        |> put("/api/tenants/nonexistent", %{secret: "s"})

      assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
    end

    test "returns 422 for missing secret", %{conn: conn, admin_token: token} do
      TenantSecrets.register_tenant("update-tenant-2", "secret")

      conn =
        conn
        |> auth_conn(token)
        |> put_req_header("content-type", "application/json")
        |> put("/api/tenants/update-tenant-2", %{})

      assert %{"error" => %{"code" => "missing_fields"}} = json_response(conn, 422)
    end
  end

  # ── Delete tenant ─────────────────────────────────────────────────────────

  describe "DELETE /api/tenants/:id" do
    test "deletes existing tenant", %{conn: conn, admin_token: token} do
      TenantSecrets.register_tenant("delete-me", "secret")

      conn =
        conn
        |> auth_conn(token)
        |> delete("/api/tenants/delete-me")

      assert %{"message" => _} = json_response(conn, 200)
      refute TenantSecrets.tenant_exists?("delete-me")
    end

    test "returns 404 for non-existent tenant", %{conn: conn, admin_token: token} do
      conn =
        conn
        |> auth_conn(token)
        |> delete("/api/tenants/nonexistent")

      assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
    end

    test "returns 401 without auth", %{conn: conn} do
      conn = delete(conn, "/api/tenants/any")
      assert json_response(conn, 401)
    end

    test "returns 403 for non-admin", %{conn: conn, user_token: token} do
      TenantSecrets.register_tenant("delete-forbidden", "secret")

      conn =
        conn
        |> auth_conn(token)
        |> delete("/api/tenants/delete-forbidden")

      assert %{"error" => %{"code" => "forbidden"}} = json_response(conn, 403)
    end
  end
end
```

**Step 2: Run the integration tests**

Run: `cd server && mix test test/levee_web/controllers/tenant_admin_controller_test.exs`
Expected: All tests pass. If any fail, investigate and fix the issue.

**Step 3: Run the full test suite**

Run: `cd server && mix test`
Expected: All tests pass.

**Step 4: Commit**

```bash
git add server/test/levee_web/controllers/tenant_admin_controller_test.exs
git commit -m "test(admin): add integration tests for session-auth tenant API

Tests CRUD operations via /api/tenants/ with admin session auth,
including 401 for missing auth and 403 for non-admin users."
```

---

### Task 10: Final Verification

**Step 1: Run all Gleam admin tests**

Run: `cd server/levee_admin && gleam test`
Expected: All tests pass.

**Step 2: Run all Elixir tests**

Run: `cd server && mix test`
Expected: All tests pass.

**Step 3: Start the dev server and manually verify**

Run: `cd server && mix phx.server`

1. Navigate to `http://localhost:4000/admin`
2. Register a new user (first user becomes admin)
3. Verify dashboard loads and shows "0 tenants"
4. Click "Create New Tenant" → verify form works
5. Create a tenant → verify redirect to detail page
6. Click "Back to Tenants" → verify list shows the new tenant
7. Click tenant → verify detail page with edit/delete sections
8. Update secret → verify success message
9. Delete tenant (type-to-confirm) → verify redirect to list

**Step 4: Final commit if any fixes needed**

Only commit if manual testing revealed issues that required fixes.
