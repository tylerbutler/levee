//// Connection pool management for the PostgreSQL storage backend.
////
//// Provides helpers to start a pog connection pool from a DATABASE_URL
//// and execute raw SQL (for migrations).

import gleam/erlang/process
import gleam/otp/actor
import pog

/// Start a connection pool from a DATABASE_URL string.
pub fn start_from_url(url: String) -> pog.Connection {
  let pool_name = process.new_name("levee_storage_pg")
  let assert Ok(config) = pog.url_config(pool_name, url)
  let config = config |> pog.pool_size(10)
  let assert Ok(actor.Started(_, conn)) = pog.start(config)
  conn
}

/// Execute a raw SQL statement (used for migrations).
pub fn execute_raw(conn: pog.Connection, sql: String) -> Nil {
  let _ = pog.query(sql) |> pog.execute(conn)
  Nil
}
