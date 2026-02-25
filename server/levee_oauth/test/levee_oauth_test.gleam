import startest

pub fn main() {
  startest.run(startest.default_config())
}

// Integration tests for begin_auth/complete_auth require
// real GitHub OAuth credentials and are tested via the
// Elixir e2e test suite. Unit tests for individual modules
// are in their respective test files.
