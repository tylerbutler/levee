import gleeunit
import gleeunit/should
import levee_protocol_deps

pub fn main() {
  gleeunit.main()
}

pub fn protocol_loaded_test() {
  levee_protocol_deps.protocol_loaded()
  |> should.be_true()
}
