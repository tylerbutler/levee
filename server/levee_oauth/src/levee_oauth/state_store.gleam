import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/otp/actor
import gleam/time/timestamp

/// Messages accepted by the state store actor.
pub type Message {
  /// Store a token with a TTL in seconds (fire-and-forget).
  Store(token: String, ttl_seconds: Int)
  /// Validate and consume a token, replying with Result(Nil, Nil).
  Validate(token: String, reply_to: Subject(Result(Nil, Nil)))
  /// Periodic cleanup of expired tokens.
  Cleanup
  /// Shut down the actor.
  Shutdown
}

/// Internal actor state: a dict mapping state tokens to expiry timestamps
/// (unix seconds), plus the actor's own subject for scheduling cleanup.
type State {
  State(tokens: Dict(String, Int), self_subject: Subject(Message))
}

/// Start the state store actor.
/// Returns a Subject for sending messages to the actor.
pub fn start() -> Result(Subject(Message), actor.StartError) {
  actor.new_with_initialiser(5000, fn(subject) {
    // Schedule the first periodic cleanup
    schedule_cleanup(subject)
    actor.initialised(State(tokens: dict.new(), self_subject: subject))
    |> actor.returning(subject)
    |> Ok
  })
  |> actor.on_message(handle_message)
  |> actor.start
  |> extract_subject
}

/// Extract the Subject from the Started record.
fn extract_subject(
  result: Result(actor.Started(Subject(Message)), actor.StartError),
) -> Result(Subject(Message), actor.StartError) {
  case result {
    Ok(started) -> Ok(started.data)
    Error(e) -> Error(e)
  }
}

/// Store a state token with a TTL (fire-and-forget).
pub fn store(actor: Subject(Message), token: String, ttl_seconds: Int) -> Nil {
  process.send(actor, Store(token:, ttl_seconds:))
}

/// Validate and consume a state token. Returns Ok(Nil) if the token existed
/// and was not expired, Error(Nil) otherwise. The token is consumed on
/// successful validation (one-time use).
pub fn validate_and_consume(
  actor: Subject(Message),
  token: String,
) -> Result(Nil, Nil) {
  process.call(actor, 5000, fn(reply_to) { Validate(token:, reply_to:) })
}

/// Get the current unix timestamp in seconds.
fn now_seconds() -> Int {
  let #(seconds, _nanoseconds) =
    timestamp.system_time()
    |> timestamp.to_unix_seconds_and_nanoseconds()
  seconds
}

/// Schedule a cleanup message to be sent after 60 seconds.
fn schedule_cleanup(subject: Subject(Message)) -> Nil {
  process.send_after(subject, 60_000, Cleanup)
  Nil
}

/// Handle incoming messages.
fn handle_message(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Store(token:, ttl_seconds:) -> {
      let expires_at = now_seconds() + ttl_seconds
      let new_tokens = dict.insert(state.tokens, token, expires_at)
      actor.continue(State(..state, tokens: new_tokens))
    }

    Validate(token:, reply_to:) -> {
      let now = now_seconds()
      case dict.get(state.tokens, token) {
        Ok(expires_at) -> {
          // Always remove the token (consume it)
          let new_tokens = dict.delete(state.tokens, token)
          case expires_at > now {
            True -> {
              process.send(reply_to, Ok(Nil))
              actor.continue(State(..state, tokens: new_tokens))
            }
            False -> {
              process.send(reply_to, Error(Nil))
              actor.continue(State(..state, tokens: new_tokens))
            }
          }
        }
        Error(Nil) -> {
          process.send(reply_to, Error(Nil))
          actor.continue(state)
        }
      }
    }

    Cleanup -> {
      let now = now_seconds()
      let new_tokens =
        dict.filter(state.tokens, fn(_token, expires_at) { expires_at > now })
      // Schedule next cleanup
      schedule_cleanup(state.self_subject)
      actor.continue(State(..state, tokens: new_tokens))
    }

    Shutdown -> {
      actor.stop()
    }
  }
}
