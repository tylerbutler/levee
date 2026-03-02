import levee_session
import startest
import startest/expect

pub fn main() -> Nil {
  startest.run(startest.default_config())
}

pub fn start_session_test() -> Nil {
  levee_session.start("test-tenant", "test-doc")
  |> expect.to_be_ok
  Nil
}

pub fn registry_and_get_or_create_test() -> Nil {
  let registry = levee_session.init_registry()
  levee_session.get_or_create(registry, "tenant-1", "doc-1")
  |> expect.to_be_ok
  Nil
}
