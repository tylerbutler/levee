import startest/expect

import levee_oauth/config
import levee_oauth/error

pub fn build_github_config_missing_client_id_test() {
  let result = config.build_github_config("", "secret", "http://localhost/callback")
  result
  |> expect.to_be_error()
  |> expect.to_equal(error.ConfigMissing(variable: "GITHUB_CLIENT_ID"))
}

pub fn build_github_config_success_test() {
  let result = config.build_github_config(
    "my-client-id",
    "my-secret",
    "http://localhost:4000/auth/github/callback",
  )
  result
  |> expect.to_be_ok()

  Nil
}

pub fn build_github_config_missing_secret_test() {
  let result = config.build_github_config("id", "", "http://localhost/callback")
  result
  |> expect.to_be_error()
  |> expect.to_equal(error.ConfigMissing(variable: "GITHUB_CLIENT_SECRET"))
}

pub fn build_github_config_missing_redirect_test() {
  let result = config.build_github_config("id", "secret", "")
  result
  |> expect.to_be_error()
  |> expect.to_equal(error.ConfigMissing(variable: "GITHUB_REDIRECT_URI"))
}
