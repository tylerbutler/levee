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

%% Registry functions — uses Gleam session registry via persistent_term.

registry_get_or_create_session(TenantId, DocumentId) ->
    Registry = persistent_term:get(levee_session_registry),
    case levee_session:get_or_create(Registry, TenantId, DocumentId) of
        {ok, Subject} -> {ok, Subject};
        {error, Reason} -> {error, Reason}
    end.

%% Session functions — use gleam process:call/send with Subject.
%% Gleam custom type constructors compile to lowercase Erlang atoms:
%% ClientJoin(a,b,c) -> {client_join, A, B, C}

session_client_join(SessionSubject, ConnectMsg, HandlerPid) ->
    %% Returns ClientJoinResult: {join_ok, ClientId, Response} or {join_error, Reason}
    %% Channel expects {ok, ClientId, Response} format for decode_ok_tuple3
    case gleam@erlang@process:call(SessionSubject, 5000, fun(ReplyTo) ->
        {client_join, ConnectMsg, HandlerPid, ReplyTo}
    end) of
        {join_ok, ClientId, Response} -> {ok, ClientId, Response};
        {join_error, Reason} -> {error, Reason}
    end.

session_submit_ops(SessionSubject, ClientId, Batches) ->
    %% Returns SubmitOpsResult: ops_ok or {ops_error, Nacks}
    %% Channel expects :ok or {:error, Nacks}
    case gleam@erlang@process:call(SessionSubject, 5000, fun(ReplyTo) ->
        {submit_ops, ClientId, Batches, ReplyTo}
    end) of
        ops_ok -> ok;
        {ops_error, Nacks} -> {error, Nacks}
    end.

session_submit_signals(SessionSubject, ClientId, Signals) ->
    gleam@erlang@process:send(SessionSubject, {submit_signals, ClientId, Signals}),
    nil.

session_update_client_rsn(SessionSubject, ClientId, Rsn) ->
    gleam@erlang@process:send(SessionSubject, {update_client_rsn, ClientId, Rsn}),
    nil.

session_get_ops_since(SessionSubject, Sn) ->
    Ops = gleam@erlang@process:call(SessionSubject, 5000, fun(ReplyTo) ->
        {get_ops_since, Sn, ReplyTo}
    end),
    {ok, Ops}.

session_client_leave(SessionSubject, ClientId) ->
    gleam@erlang@process:send(SessionSubject, {client_leave, ClientId}),
    nil.

%% Notify the WebSocket handler of the session PID so it can monitor it.
%% Extract PID from Subject for the handler to monitor.
notify_handler_session(HandlerPid, SessionSubject) ->
    case SessionSubject of
        {subject, Pid, _} ->
            HandlerPid ! {session_started, Pid};
        _ ->
            ok
    end,
    nil.
