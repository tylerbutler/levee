import gleam/erlang/process
import startest/expect

import levee_oauth/state_store

pub fn store_and_validate_test() {
  let assert Ok(actor) = state_store.start()
  let token = "test-state-token"
  let verifier = "test-code-verifier"

  state_store.store(actor, token, verifier, 180)

  // Should succeed, consume the token, and return the code verifier
  state_store.validate_and_consume(actor, token)
  |> expect.to_equal(Ok(verifier))

  // Second attempt should fail — token was consumed
  state_store.validate_and_consume(actor, token)
  |> expect.to_be_error()

  process.send(actor, state_store.Shutdown)
}

pub fn validate_unknown_token_test() {
  let assert Ok(actor) = state_store.start()

  state_store.validate_and_consume(actor, "nonexistent")
  |> expect.to_be_error()

  process.send(actor, state_store.Shutdown)
}

pub fn expired_token_test() {
  let assert Ok(actor) = state_store.start()
  let token = "expired-token"

  // Store with 0-second TTL (immediately expired)
  state_store.store(actor, token, "verifier", 0)

  // Small delay to ensure expiry
  process.sleep(10)

  state_store.validate_and_consume(actor, token)
  |> expect.to_be_error()

  process.send(actor, state_store.Shutdown)
}
