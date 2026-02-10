import gleam/option
import gleam/uri.{type Uri}
import gleeunit
import gleeunit/should

import levee_admin/router

pub fn main() {
  gleeunit.main()
}

// Router tests

pub fn parse_login_route_test() {
  let uri = uri_from_path("/login")
  router.parse(uri)
  |> should.equal(router.Login)
}

pub fn parse_register_route_test() {
  let uri = uri_from_path("/register")
  router.parse(uri)
  |> should.equal(router.Register)
}

pub fn parse_dashboard_route_test() {
  let uri = uri_from_path("/dashboard")
  router.parse(uri)
  |> should.equal(router.Dashboard)
}

pub fn parse_tenants_route_test() {
  let uri = uri_from_path("/tenants")
  router.parse(uri)
  |> should.equal(router.Tenants)
}

pub fn parse_tenant_detail_route_test() {
  let uri = uri_from_path("/tenants/abc123")
  router.parse(uri)
  |> should.equal(router.TenantDetail("abc123"))
}

pub fn parse_unknown_route_test() {
  let uri = uri_from_path("/unknown/path")
  router.parse(uri)
  |> should.equal(router.NotFound)
}

pub fn parse_root_route_test() {
  let uri = uri_from_path("/")
  router.parse(uri)
  |> should.equal(router.Login)
}

pub fn to_path_login_test() {
  router.to_path(router.Login)
  |> should.equal("/login")
}

pub fn to_path_dashboard_test() {
  router.to_path(router.Dashboard)
  |> should.equal("/dashboard")
}

pub fn to_path_tenant_detail_test() {
  router.to_path(router.TenantDetail("tenant-123"))
  |> should.equal("/tenants/tenant-123")
}

// Helper to create a URI from a path
fn uri_from_path(path: String) -> Uri {
  uri.Uri(
    scheme: option.None,
    userinfo: option.None,
    host: option.None,
    port: option.None,
    path: path,
    query: option.None,
    fragment: option.None,
  )
}
