/// Storage error types
pub type StorageError {
  NotFound
  AlreadyExists
  StorageError(message: String)
}
