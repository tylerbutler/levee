//// In-memory store for users and sessions.
////
//// This is a temporary implementation for development/testing.
//// Will be replaced with database storage when available.

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import session.{type Session}
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
  Clear
  Shutdown
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

type State {
  State(users: Dict(String, User), sessions: Dict(String, Session))
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Start the session store actor.
pub fn start() -> Result(Subject(Message), actor.StartError) {
  actor.new_with_initialiser(5000, fn(subject) {
    actor.initialised(State(users: dict.new(), sessions: dict.new()))
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

/// Clear all users and sessions (test helper, fire-and-forget).
pub fn clear(actor: Subject(Message)) -> Nil {
  process.send(actor, Clear)
}

// ---------------------------------------------------------------------------
// Message handler
// ---------------------------------------------------------------------------

fn handle_message(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    StoreUser(user:) -> {
      let new_users = dict.insert(state.users, user.id, user)
      actor.continue(State(..state, users: new_users))
    }

    GetUser(id:, reply_to:) -> {
      process.send(reply_to, dict.get(state.users, id))
      actor.continue(state)
    }

    FindUserByEmail(email:, reply_to:) -> {
      let result = find_user_where(state.users, fn(u) { u.email == email })
      process.send(reply_to, result)
      actor.continue(state)
    }

    FindUserByGithubId(github_id:, reply_to:) -> {
      let result =
        find_user_where(state.users, fn(u) { u.github_id == Some(github_id) })
      process.send(reply_to, result)
      actor.continue(state)
    }

    UserCount(reply_to:) -> {
      process.send(reply_to, dict.size(state.users))
      actor.continue(state)
    }

    StoreSession(session:) -> {
      let new_sessions = dict.insert(state.sessions, session.id, session)
      actor.continue(State(..state, sessions: new_sessions))
    }

    GetSession(id:, tenant_id:, reply_to:) -> {
      let result = case dict.get(state.sessions, id) {
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
      actor.continue(state)
    }

    DeleteSession(id:) -> {
      let new_sessions = dict.delete(state.sessions, id)
      actor.continue(State(..state, sessions: new_sessions))
    }

    Clear -> {
      actor.continue(State(users: dict.new(), sessions: dict.new()))
    }

    Shutdown -> {
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
  users: Dict(String, User),
  predicate: fn(User) -> Bool,
) -> Result(User, Nil) {
  users
  |> dict.values
  |> list.find(predicate)
}
