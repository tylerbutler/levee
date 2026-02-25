import startest
import startest/expect

import levee_oauth

pub fn main() {
  startest.run(startest.default_config())
}

pub fn placeholder_test() {
  levee_oauth.placeholder()
  |> expect.to_equal(Nil)
}
