%% @doc Minimal FFI helpers for levee_storage.
-module(storage_ffi_helpers).

-export([identity/1, make_summary_meta/2, json_from_map/1,
         dynamic_to_json_string/1, json_string_to_dynamic/1,
         pg_timestamp_to_datetime/1]).

%% @doc Identity function for type coercion.
identity(X) -> X.

%% @doc Build a map with summary metadata fields.
make_summary_meta(Handle, SequenceNumber) ->
    #{latest_summary_handle => Handle,
      latest_summary_sequence_number => SequenceNumber}.

%% @doc Convert an Erlang/Elixir map to a JSON binary for gleam_json iolist embedding.
json_from_map(Map) when is_map(Map) ->
    'Elixir.Jason':'encode!'(Map).

%% @doc Encode a Dynamic value (Elixir map/list/etc) to a JSON binary string.
dynamic_to_json_string(nil) -> nil;
dynamic_to_json_string(none) -> nil;
dynamic_to_json_string({some, Val}) ->
    'Elixir.Jason':'encode!'(Val);
dynamic_to_json_string(Val) ->
    'Elixir.Jason':'encode!'(Val).

%% @doc Decode a JSON binary string back to a Dynamic value (Elixir map/list).
json_string_to_dynamic(nil) -> nil;
json_string_to_dynamic(none) -> nil;
json_string_to_dynamic({some, Bin}) when is_binary(Bin) ->
    'Elixir.Jason':'decode!'(Bin);
json_string_to_dynamic(Bin) when is_binary(Bin) ->
    'Elixir.Jason':'decode!'(Bin).

%% @doc Convert a PG timestamp tuple to an Elixir DateTime.
pg_timestamp_to_datetime({{Year, Month, Day}, {Hour, Min, Sec}}) ->
    %% Sec may be integer or float; truncate microseconds
    SecTrunc = trunc(Sec),
    Micro = round((Sec - SecTrunc) * 1000000),
    case 'Elixir.DateTime':'new!'(
           'Elixir.Date':'new!'(Year, Month, Day),
           'Elixir.Time':'new!'(Hour, Min, SecTrunc, {Micro, 6})) of
        DT -> DT
    end;
pg_timestamp_to_datetime(Other) ->
    %% Already a DateTime or something else, pass through
    Other.
