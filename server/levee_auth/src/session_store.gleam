//// Persistent store for users, sessions, and memberships.
////
//// Uses shelf/set (ETS + DETS) for typed, persistent key-value storage.
//// Data is persisted to DETS files on disk and survives restarts.

import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import session.{type Session}
import shelf/set.{type PSet}
import tenant.{type Membership}
import user.{type User}

// ---------------------------------------------------------------------------
// Messages
// ---------------------------------------------------------------------------

/// Messages accepted by the session store actor.
pub type Message {
  StoreUser(user: User)
  GetUser(id: String, reply_to: Subject(Result(User, Nil)))
  FindUserByEmail(email: String, reply_to: Subject(Result(User, Nil)))
  FindUserByGithubId(github_id: String, reply_to: Subject(Result(User, Nil)))
  UserCount(reply_to: Subject(Int))
  StoreSession(session: Session)
  GetSession(
    id: String,
    tenant_id: Option(String),
    reply_to: Subject(Result(Session, Nil)),
  )
  DeleteSession(id: String)
  StoreMembership(membership: Membership)
  GetMembership(
    user_id: String,
    tenant_id: String,
    reply_to: Subject(Result(Membership, Nil)),
  )
  Clear
  Shutdown
}

// ---------------------------------------------------------------------------
// State — shelf-backed persistent tables
// ---------------------------------------------------------------------------

pub type Tables {
  Tables(
    users: PSet(String, User),
    sessions: PSet(String, Session),
    memberships: PSet(#(String, String), Membership),
  )
}

fn dets_path(data_dir: String, table_name: String) -> String {
  data_dir <> "/" <> table_name <> ".dets"
}

/// Open all persistent tables. Call once at startup.
pub fn init_tables(data_dir: String) -> Tables {
  let assert Ok(users) =
    set.open(name: "levee_auth_users", path: dets_path(data_dir, "auth_users"))
  let assert Ok(sessions) =
    set.open(
      name: "levee_auth_sessions",
      path: dets_path(data_dir, "auth_sessions"),
    )
  let assert Ok(memberships) =
    set.open(
      name: "levee_auth_memberships",
      path: dets_path(data_dir, "auth_memberships"),
    )
  Tables(users:, sessions:, memberships:)
}

/// Close all tables, persisting data to disk.
pub fn close_tables(tables: Tables) -> Nil {
  let _ = set.close(tables.users)
  let _ = set.close(tables.sessions)
  let _ = set.close(tables.memberships)
  Nil
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Start the session store actor with persistent shelf tables.
pub fn start(data_dir: String) -> Result(Subject(Message), actor.StartError) {
  let tables = init_tables(data_dir)

  actor.new_with_initialiser(5000, fn(subject) {
    actor.initialised(tables)
    |> actor.returning(subject)
    |> Ok
  })
  |> actor.on_message(handle_message)
  |> actor.start
  |> extract_subject
}

/// Store a user (fire-and-forget).
pub fn store_user(actor: Subject(Message), user: User) -> Nil {
  process.send(actor, StoreUser(user:))
}

/// Get a user by ID.
pub fn get_user(actor: Subject(Message), id: String) -> Result(User, Nil) {
  process.call(actor, 5000, fn(reply_to) { GetUser(id:, reply_to:) })
}

/// Find a user by email.
pub fn find_user_by_email(
  actor: Subject(Message),
  email: String,
) -> Result(User, Nil) {
  process.call(actor, 5000, fn(reply_to) { FindUserByEmail(email:, reply_to:) })
}

/// Find a user by GitHub ID.
pub fn find_user_by_github_id(
  actor: Subject(Message),
  github_id: String,
) -> Result(User, Nil) {
  process.call(actor, 5000, fn(reply_to) {
    FindUserByGithubId(github_id:, reply_to:)
  })
}

/// Get the number of stored users.
pub fn user_count(actor: Subject(Message)) -> Int {
  process.call(actor, 5000, fn(reply_to) { UserCount(reply_to:) })
}

/// Store a session (fire-and-forget).
pub fn store_session(actor: Subject(Message), session: Session) -> Nil {
  process.send(actor, StoreSession(session:))
}

/// Get a session by ID. Optionally validates the session belongs to the given tenant.
pub fn get_session(
  actor: Subject(Message),
  id: String,
  tenant_id: Option(String),
) -> Result(Session, Nil) {
  process.call(actor, 5000, fn(reply_to) {
    GetSession(id:, tenant_id:, reply_to:)
  })
}

/// Delete a session by ID (fire-and-forget).
pub fn delete_session(actor: Subject(Message), id: String) -> Nil {
  process.send(actor, DeleteSession(id:))
}

/// Store a membership (fire-and-forget).
pub fn store_membership(actor: Subject(Message), membership: Membership) -> Nil {
  process.send(actor, StoreMembership(membership:))
}

/// Get a user's membership in a specific tenant.
pub fn get_membership(
  actor: Subject(Message),
  user_id: String,
  tenant_id: String,
) -> Result(Membership, Nil) {
  process.call(actor, 5000, fn(reply_to) {
    GetMembership(user_id:, tenant_id:, reply_to:)
  })
}

/// Clear all users, sessions, and memberships (test helper, fire-and-forget).
pub fn clear(actor: Subject(Message)) -> Nil {
  process.send(actor, Clear)
}

// ---------------------------------------------------------------------------
// Message handler
// ---------------------------------------------------------------------------

fn handle_message(
  tables: Tables,
  message: Message,
) -> actor.Next(Tables, Message) {
  case message {
    StoreUser(user:) -> {
      let _ = set.insert(into: tables.users, key: user.id, value: user)
      actor.continue(tables)
    }

    GetUser(id:, reply_to:) -> {
      let result =
        set.lookup(from: tables.users, key: id) |> result.replace_error(Nil)
      process.send(reply_to, result)
      actor.continue(tables)
    }

    FindUserByEmail(email:, reply_to:) -> {
      let result = find_user_where(tables.users, fn(u) { u.email == email })
      process.send(reply_to, result)
      actor.continue(tables)
    }

    FindUserByGithubId(github_id:, reply_to:) -> {
      let result =
        find_user_where(tables.users, fn(u) { u.github_id == Some(github_id) })
      process.send(reply_to, result)
      actor.continue(tables)
    }

    UserCount(reply_to:) -> {
      let count =
        set.size(of: tables.users)
        |> result.unwrap(0)
      process.send(reply_to, count)
      actor.continue(tables)
    }

    StoreSession(session:) -> {
      let _ = set.insert(into: tables.sessions, key: session.id, value: session)
      actor.continue(tables)
    }

    GetSession(id:, tenant_id:, reply_to:) -> {
      let result = case
        set.lookup(from: tables.sessions, key: id)
        |> result.replace_error(Nil)
      {
        Error(Nil) -> Error(Nil)
        Ok(s) ->
          case tenant_id {
            None -> Ok(s)
            Some(tid) ->
              case s.tenant_id == tid {
                True -> Ok(s)
                False -> Error(Nil)
              }
          }
      }
      process.send(reply_to, result)
      actor.continue(tables)
    }

    DeleteSession(id:) -> {
      let _ = set.delete_key(from: tables.sessions, key: id)
      actor.continue(tables)
    }

    StoreMembership(membership:) -> {
      let key = #(membership.user_id, membership.tenant_id)
      let _ = set.insert(into: tables.memberships, key: key, value: membership)
      actor.continue(tables)
    }

    GetMembership(user_id:, tenant_id:, reply_to:) -> {
      let key = #(user_id, tenant_id)
      let result =
        set.lookup(from: tables.memberships, key: key)
        |> result.replace_error(Nil)
      process.send(reply_to, result)
      actor.continue(tables)
    }

    Clear -> {
      let _ = set.delete_all(from: tables.users)
      let _ = set.delete_all(from: tables.sessions)
      let _ = set.delete_all(from: tables.memberships)
      actor.continue(tables)
    }

    Shutdown -> {
      close_tables(tables)
      actor.stop()
    }
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Extract the Subject from the Started record.
fn extract_subject(
  result: Result(actor.Started(Subject(Message)), actor.StartError),
) -> Result(Subject(Message), actor.StartError) {
  case result {
    Ok(started) -> Ok(started.data)
    Error(e) -> Error(e)
  }
}

/// Find the first user matching a predicate.
fn find_user_where(
  users: PSet(String, User),
  predicate: fn(User) -> Bool,
) -> Result(User, Nil) {
  users
  |> set.to_list
  |> result.unwrap([])
  |> list.find_map(fn(entry) {
    let #(_key, u) = entry
    case predicate(u) {
      True -> Ok(u)
      False -> Error(Nil)
    }
  })
}
