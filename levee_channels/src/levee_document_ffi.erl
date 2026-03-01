-module(levee_document_ffi).
-export([
    jwt_verify/2,
    jwt_expired/1,
    jwt_has_read_scope/1,
    jwt_has_write_scope/1,
    registry_get_or_create_session/2,
    session_client_join/3,
    session_submit_ops/3,
    session_submit_signals/3,
    session_update_client_rsn/3,
    session_get_ops_since/2,
    session_client_leave/2,
    notify_handler_session/2
]).

%% JWT functions — uses Gleam levee_auth modules via persistent_term for tenant secret lookup.

jwt_verify(Token, TenantId) ->
    TsActor = persistent_term:get(levee_tenant_secrets),
    case tenant_secrets:get_secret(TsActor, TenantId) of
        {ok, Secret} ->
            'levee_auth@token':verify(Token, Secret);
        {error, _} ->
            {error, tenant_not_found}
    end.

jwt_expired(Claims) ->
    'levee_auth@token':is_expired(Claims).

jwt_has_read_scope(Claims) ->
    'levee_auth@token':has_scope(Claims, doc_read).

jwt_has_write_scope(Claims) ->
    'levee_auth@token':has_scope(Claims, doc_write).

%% Registry functions — inlined from deleted Levee.Documents.Registry

registry_get_or_create_session(TenantId, DocumentId) ->
    Key = {TenantId, DocumentId},
    case 'Elixir.Registry':lookup('Elixir.Levee.SessionRegistry', Key) of
        [{Pid, _}] ->
            {ok, Pid};
        [] ->
            ChildSpec = {'Elixir.Levee.Documents.Session', {TenantId, DocumentId}},
            case 'Elixir.DynamicSupervisor':start_child('Elixir.Levee.Documents.Supervisor', ChildSpec) of
                {ok, Pid} -> {ok, Pid};
                {error, {already_started, Pid}} -> {ok, Pid};
                {error, Reason} -> {error, Reason}
            end
    end.

%% Session functions
session_client_join(SessionPid, ConnectMsg, HandlerPid) ->
    'Elixir.Levee.Documents.Session':client_join(SessionPid, ConnectMsg, HandlerPid).

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

%% Notify the WebSocket handler of the session PID so it can monitor it
notify_handler_session(HandlerPid, SessionPid) ->
    HandlerPid ! {session_started, SessionPid},
    nil.
