%% @doc Minimal FFI helpers for levee_storage.
-module(storage_ffi_helpers).

-export([identity/1, make_summary_meta/2, json_from_map/1, utc_now/0,
         dynamic_to_json_string/1, json_string_to_dynamic/1,
         pg_timestamp_to_datetime/1, make_table_public/1]).

%% @doc Identity function for type coercion.
identity(X) -> X.

%% @doc Build a map with summary metadata fields.
make_summary_meta(Handle, SequenceNumber) ->
    #{latest_summary_handle => Handle,
      latest_summary_sequence_number => SequenceNumber}.

%% @doc Current UTC time as an RFC3339 binary.
utc_now() ->
    unicode:characters_to_binary(
      calendar:system_time_to_rfc3339(
        erlang:system_time(second),
        [{unit, second}, {offset, "Z"}])).

%% @doc Convert an Erlang map to JSON iodata for gleam_json embedding.
json_from_map(Map) when is_map(Map) ->
    json:encode(Map).

%% @doc Encode a Dynamic value to a JSON binary string.
dynamic_to_json_string(nil) -> nil;
dynamic_to_json_string(none) -> nil;
dynamic_to_json_string({some, Val}) ->
    iolist_to_binary(json:encode(Val));
dynamic_to_json_string(Val) ->
    iolist_to_binary(json:encode(Val)).

%% @doc Decode a JSON binary string back to a Dynamic value.
json_string_to_dynamic(nil) -> nil;
json_string_to_dynamic(none) -> nil;
json_string_to_dynamic({some, Bin}) when is_binary(Bin) ->
    json:decode(Bin);
json_string_to_dynamic(Bin) when is_binary(Bin) ->
    json:decode(Bin).

%% @doc Convert a PG timestamp tuple to an RFC3339 binary.
pg_timestamp_to_datetime({{Year, Month, Day}, {Hour, Min, Sec}}) ->
    SecTrunc = trunc(Sec),
    Micro = round((Sec - SecTrunc) * 1000000),
    Base = io_lib:format("~4..0B-~2..0B-~2..0BT~2..0B:~2..0B:~2..0B",
                         [Year, Month, Day, Hour, Min, SecTrunc]),
    Fraction =
        case Micro of
            0 -> "";
            _ -> io_lib:format(".~6..0B", [Micro])
        end,
    iolist_to_binary([Base, Fraction, "Z"]);
pg_timestamp_to_datetime(Other) ->
    Other.

%% @doc Replace a shelf PSet's protected ETS table with a public one.
%% Shelf creates protected tables (owner-only writes), but levee
%% stores the table handle in persistent_term and writes from any process.
%% Must be called from the table owner process (e.g., during GenServer init).
make_table_public(PSet) ->
    OldEts = element(2, PSet),
    Type = proplists:get_value(type, ets:info(OldEts)),
    NewEts = ets:new(shelf_ets, [Type, public, {keypos, 1}, {read_concurrency, true}]),
    ets:foldl(fun(Entry, _) -> ets:insert(NewEts, Entry) end, ok, OldEts),
    ets:delete(OldEts),
    setelement(2, PSet, NewEts).
