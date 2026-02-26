%% @doc Minimal FFI helpers for levee_storage.
-module(storage_ffi_helpers).

-export([identity/1, make_summary_meta/2]).

%% @doc Identity function for type coercion.
identity(X) -> X.

%% @doc Build a map with summary metadata fields.
make_summary_meta(Handle, SequenceNumber) ->
    #{latest_summary_handle => Handle,
      latest_summary_sequence_number => SequenceNumber}.
