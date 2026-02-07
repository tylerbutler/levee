//// URL routing for the Levee Admin app.

import gleam/uri.{type Uri}

/// Application routes
pub type Route {
  Login
  Register
  Dashboard
  Tenants
  TenantDetail(id: String)
  NotFound
}

/// Parse a URI into a Route
pub fn parse(uri: Uri) -> Route {
  case uri.path_segments(uri.path) {
    [] -> Login
    [""] -> Login
    ["login"] -> Login
    ["register"] -> Register
    ["dashboard"] -> Dashboard
    ["tenants"] -> Tenants
    ["tenants", id] -> TenantDetail(id)
    _ -> NotFound
  }
}

/// Convert a Route to a path string
pub fn to_path(route: Route) -> String {
  case route {
    Login -> "/login"
    Register -> "/register"
    Dashboard -> "/dashboard"
    Tenants -> "/tenants"
    TenantDetail(id) -> "/tenants/" <> id
    NotFound -> "/404"
  }
}
