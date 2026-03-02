//// Admin SPA handler — serves the Lustre admin UI.
////
//// Route: GET /admin/* — serve priv/static/admin/index.html
//// All admin sub-paths serve the same index.html for client-side routing.

import gleam/http/response
import gleam/option
import levee_web/context.{type Context}
import levee_web/json_helpers
import simplifile
import wisp.{type Request, type Response}

/// GET /admin or /admin/* — serve the admin SPA index.html.
pub fn index(_req: Request, ctx: Context) -> Response {
  let index_path = ctx.static_path <> "/admin/index.html"

  case simplifile.is_file(index_path) {
    Ok(True) ->
      wisp.response(200)
      |> wisp.set_body(wisp.File(
        path: index_path,
        offset: 0,
        limit: option.None,
      ))
      |> response.set_header("content-type", "text/html; charset=utf-8")

    _ ->
      json_helpers.error_response(
        404,
        "not_found",
        "Admin UI not built — run the admin build first",
      )
  }
}
