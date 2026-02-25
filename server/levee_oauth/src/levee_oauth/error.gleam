import vestibule/error as vestibule_error

/// OAuth errors for levee_oauth.
pub type OAuthError {
  /// Wraps a vestibule AuthError.
  VestibuleError(vestibule_error.AuthError(Nil))
  /// Required environment variable is missing.
  ConfigMissing(variable: String)
  /// Provider name not recognized.
  UnknownProvider(name: String)
  /// State store process is not available.
  StateStoreUnavailable
}
