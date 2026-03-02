//// CORS middleware.
////
//// Handles preflight OPTIONS requests and sets CORS headers.

import cors_builder
import gleam/http
import wisp.{type Request, type Response}

/// Apply CORS headers. Handles OPTIONS preflight automatically.
pub fn apply(req: Request, next: fn() -> Response) -> Response {
  let cors =
    cors_builder.new()
    |> cors_builder.allow_all_origins
    |> cors_builder.allow_method(http.Get)
    |> cors_builder.allow_method(http.Post)
    |> cors_builder.allow_method(http.Put)
    |> cors_builder.allow_method(http.Patch)
    |> cors_builder.allow_method(http.Delete)
    |> cors_builder.allow_method(http.Options)
    |> cors_builder.allow_header("authorization")
    |> cors_builder.allow_header("content-type")
    |> cors_builder.allow_header("accept")
    |> cors_builder.max_age(86_400)

  cors_builder.wisp_middleware(req, cors, fn(_req) { next() })
}
