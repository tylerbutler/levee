import gleam_channels
import gleam_channels/topic
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

// Topic pattern tests

pub fn parse_exact_pattern_test() {
  topic.parse_pattern("room:lobby")
  |> should.equal(topic.Exact("room:lobby"))
}

pub fn parse_wildcard_pattern_test() {
  topic.parse_pattern("room:*")
  |> should.equal(topic.Wildcard("room:"))
}

pub fn wildcard_matches_test() {
  let pattern = topic.Wildcard("room:")

  topic.matches(pattern, "room:lobby")
  |> should.be_true

  topic.matches(pattern, "room:123")
  |> should.be_true

  topic.matches(pattern, "user:123")
  |> should.be_false
}

pub fn exact_matches_test() {
  let pattern = topic.Exact("room:lobby")

  topic.matches(pattern, "room:lobby")
  |> should.be_true

  topic.matches(pattern, "room:other")
  |> should.be_false
}

pub fn extract_id_test() {
  let pattern = topic.Wildcard("room:")

  topic.extract_id(pattern, "room:lobby")
  |> should.equal(Ok("lobby"))

  topic.extract_id(pattern, "room:abc:123")
  |> should.equal(Ok("abc:123"))

  topic.extract_id(topic.Exact("room:lobby"), "room:lobby")
  |> should.equal(Error(Nil))
}

pub fn segments_test() {
  topic.segments("room:lobby")
  |> should.equal(["room", "lobby"])

  topic.segments("doc:tenant:123:ops")
  |> should.equal(["doc", "tenant", "123", "ops"])
}

pub fn from_segments_test() {
  topic.from_segments(["room", "lobby"])
  |> should.equal("room:lobby")
}

pub fn validate_topic_test() {
  topic.validate("room:lobby")
  |> should.equal(Ok("room:lobby"))

  topic.validate("")
  |> should.equal(Error(topic.EmptyTopic))

  topic.validate(":invalid")
  |> should.be_error

  topic.validate("invalid:")
  |> should.be_error
}

// Config tests

pub fn default_config_test() {
  let config = gleam_channels.default_config()

  config.heartbeat_interval_ms
  |> should.equal(30_000)

  config.heartbeat_timeout_ms
  |> should.equal(60_000)
}
