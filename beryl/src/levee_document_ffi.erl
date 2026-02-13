-module(levee_document_ffi).
-export([
    jwt_verify/2,
    jwt_expired/1,
    jwt_has_read_scope/1,
    jwt_has_write_scope/1,
    registry_get_or_create_session/2,
    session_client_join/2,
    session_submit_ops/3,
    session_submit_signals/3,
    session_update_client_rsn/3,
    session_get_ops_since/2,
    session_client_leave/2,
    process_monitor/1
]).

%% JWT functions
jwt_verify(Token, TenantId) ->
    'Elixir.Levee.Auth.JWT':verify(Token, TenantId).

jwt_expired(Claims) ->
    'Elixir.Levee.Auth.JWT':'expired?'(Claims).

jwt_has_read_scope(Claims) ->
    'Elixir.Levee.Auth.JWT':'has_read_scope?'(Claims).

jwt_has_write_scope(Claims) ->
    'Elixir.Levee.Auth.JWT':'has_write_scope?'(Claims).

%% Registry functions
registry_get_or_create_session(TenantId, DocumentId) ->
    'Elixir.Levee.Documents.Registry':get_or_create_session(TenantId, DocumentId).

%% Session functions - these use GenServer.call, so caller PID matters
session_client_join(SessionPid, ConnectMsg) ->
    'Elixir.Levee.Documents.Session':client_join(SessionPid, ConnectMsg).

session_submit_ops(SessionPid, ClientId, Batches) ->
    'Elixir.Levee.Documents.Session':submit_ops(SessionPid, ClientId, Batches).

session_submit_signals(SessionPid, ClientId, Signals) ->
    'Elixir.Levee.Documents.Session':submit_signals(SessionPid, ClientId, Signals).

session_update_client_rsn(SessionPid, ClientId, Rsn) ->
    'Elixir.Levee.Documents.Session':update_client_rsn(SessionPid, ClientId, Rsn).

session_get_ops_since(SessionPid, Sn) ->
    'Elixir.Levee.Documents.Session':get_ops_since(SessionPid, Sn).

session_client_leave(SessionPid, ClientId) ->
    'Elixir.Levee.Documents.Session':client_leave(SessionPid, ClientId).

%% Process monitoring
process_monitor(Pid) ->
    erlang:monitor(process, Pid).
