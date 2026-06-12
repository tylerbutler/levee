import gleeunit
import gleeunit/should
import levee_server

pub fn main() -> Nil {
  gleeunit.main()
}

// Verify the module compiles and pure constants are correct.
// This keeps the test suite fast without spawning any real processes.

pub fn default_port_is_4000_test() {
  levee_server.default_port
  |> should.equal(4000)
}

pub fn default_upstream_port_is_4001_test() {
  levee_server.default_upstream_port
  |> should.equal(4001)
}
