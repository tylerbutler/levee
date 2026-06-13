import gleeunit
import gleeunit/should

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn test_runner_smoke_test() {
  True
  |> should.be_true
}
