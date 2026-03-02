-module(session_ffi).
-export([raw_send/2, system_time_ms/0, system_time_s/0, json_encode_to_string/1,
         pid_alive/1, load_latest_summary/2, store_summary/3]).

%% Send a raw Erlang message to a PID (bypasses Subject typing).
raw_send(Pid, Msg) -> Pid ! Msg, nil.

%% Wall-clock system time in milliseconds.
system_time_ms() -> erlang:system_time(millisecond).

%% Wall-clock system time in seconds.
system_time_s() -> erlang:system_time(second).

%% Encode an Erlang term to a JSON iodata binary.
json_encode_to_string(Term) ->
    iolist_to_binary(json:encode(Term)).

%% Check if a PID is alive (for stale ETS entry cleanup).
pid_alive(Pid) -> is_process_alive(Pid).

%% Load the latest summary from Gleam ETS storage.
%% Returns {ok, SummaryContext} or {error, nil}.
%% Wrapped in try/catch so it gracefully returns {error, nil} when
%% the storage module isn't loaded or ETS tables aren't initialized.
load_latest_summary(TenantId, DocumentId) ->
    try
        case 'levee_storage@ets':get_latest_summary(TenantId, DocumentId) of
            {ok, Summary} ->
                Handle = element(2, Summary),
                Sn = element(5, Summary),
                {ok, {summary_context, Handle, Sn}};
            {error, _} ->
                {error, nil}
        end
    catch
        error:undef -> {error, nil};
        error:badarg -> {error, nil}
    end.

%% Store a summary in Gleam ETS storage.
store_summary(TenantId, DocumentId, Summary) ->
    'levee_storage@ets':store_summary(TenantId, DocumentId, Summary).
