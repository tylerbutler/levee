-module(levee_server_ffi).

-export([
    get_tables/0,
    put_tables/1,
    put_tenant_secret/2,
    get_tenant_secrets/1,
    clear_tenant_secret/1,
    list_tenants/0,
    dynamic_to_json/1,
    dynamic_to_base64/1,
    now_seconds/0,
    now_iso8601/0,
    set_env/2,
    get_github_allowed_users/0,
    set_github_allowed_users/1,
    unset_github_allowed_users/0,
    ensure_dir/1,
    session_alive/2,
    get_auth_store/0,
    put_auth_store/1,
    get_oauth_store/0,
    put_oauth_store/1,
    get_document_supervisor/0,
    put_document_supervisor/1,
    clear_document_supervisor/0
]).

get_tables() ->
    try {ok, persistent_term:get(levee_storage_tables)}
    catch error:badarg -> {error, nil}
    end.

put_tables(Tables) ->
    persistent_term:put(levee_storage_tables, Tables),
    nil.

put_tenant_secret(Tenant, Secret) ->
    persistent_term:put({levee_server_tenant_secret, Tenant}, Secret),
    nil.

get_tenant_secrets(Tenant) ->
    case get_test_tenant_secrets(Tenant) of
        {ok, Secrets} -> {ok, Secrets};
        {error, nil} -> get_elixir_tenant_secrets(Tenant)
    end.

get_test_tenant_secrets(Tenant) ->
    try
        Secret = persistent_term:get({levee_server_tenant_secret, Tenant}),
        {ok, {Secret, Secret}}
    catch error:badarg -> {error, nil}
    end.

get_elixir_tenant_secrets(Tenant) ->
    try 'Elixir.Levee.Auth.TenantSecrets':get_secrets(Tenant) of
        {ok, #{secret1 := Secret1, secret2 := Secret2}} -> {ok, {Secret1, Secret2}};
        {error, _} -> {error, nil};
        _ -> {error, nil}
    catch
        _:_ -> {error, nil}
    end.

clear_tenant_secret(Tenant) ->
    persistent_term:erase({levee_server_tenant_secret, Tenant}),
    nil.

list_tenants() ->
    TestTenants =
        [Tenant || {{levee_server_tenant_secret, Tenant}, _Secret} <- persistent_term:get()],
    ElixirTenants =
        try 'Elixir.Levee.Auth.TenantSecrets':list_tenants() of
            Tenants when is_list(Tenants) -> Tenants;
            _ -> []
        catch
            _:_ -> []
        end,
    lists:usort(TestTenants ++ ElixirTenants).

dynamic_to_json(Value) ->
    iolist_to_binary(json:encode(Value)).

dynamic_to_base64(Value) when is_binary(Value) ->
    base64:encode(Value);
dynamic_to_base64(Value) ->
    base64:encode(iolist_to_binary(json:encode(Value))).

now_seconds() ->
    erlang:system_time(second).

now_iso8601() ->
    unicode:characters_to_binary(
        calendar:system_time_to_rfc3339(
            erlang:system_time(second),
            [{unit, second}, {offset, "Z"}])).

get_github_allowed_users() ->
    case application:get_env(levee, github_allowed_users) of
        {ok, Users} when is_list(Users) -> {some, Users};
        _ -> none
    end.

set_github_allowed_users(Users) ->
    application:set_env(levee, github_allowed_users, Users),
    nil.

unset_github_allowed_users() ->
    application:unset_env(levee, github_allowed_users),
    nil.

set_env(Name, Value) ->
    os:putenv(binary_to_list(Name), binary_to_list(Value)),
    nil.

ensure_dir(Path) ->
    ok = filelib:ensure_dir(filename:join(Path, <<"dummy">>)),
    nil.

session_alive(Tenant, Document) ->
    case gleam_session_alive(Tenant, Document) of
        true -> true;
        false -> phoenix_session_alive(Tenant, Document)
    end.

gleam_session_alive(Tenant, Document) ->
    try persistent_term:get(levee_server_document_supervisor) of
        Supervisor ->
            case 'levee_documents@supervisor':get_session(Supervisor, Tenant, Document) of
                {ok, _Actor} -> true;
                _ -> false
            end
    catch
        _:_ -> false
    end.

phoenix_session_alive(Tenant, Document) ->
    try 'Elixir.Levee.Documents.Registry':get_session(Tenant, Document) of
        {ok, _Pid} -> true;
        _ -> false
    catch
        _:_ -> false
    end.

get_auth_store() ->
    case get_test_auth_store() of
        {ok, Store} -> {ok, Store};
        {error, nil} -> get_elixir_auth_store()
    end.

get_test_auth_store() ->
    try {ok, persistent_term:get(levee_server_auth_store)}
    catch error:badarg -> {error, nil}
    end.

get_elixir_auth_store() ->
    try 'Elixir.Levee.Auth.SessionStoreSupervisor':get_actor() of
        Actor -> {ok, Actor}
    catch
        _:_ -> {error, nil}
    end.

put_auth_store(Store) ->
    persistent_term:put(levee_server_auth_store, Store),
    nil.

get_oauth_store() ->
    case get_test_oauth_store() of
        {ok, Store} -> {ok, Store};
        {error, nil} -> get_elixir_oauth_store()
    end.

get_test_oauth_store() ->
    try {ok, persistent_term:get(levee_server_oauth_store)}
    catch error:badarg -> {error, nil}
    end.

get_elixir_oauth_store() ->
    try 'Elixir.Levee.OAuth.StateStoreSupervisor':get_actor() of
        Actor -> {ok, Actor}
    catch
        _:_ -> {error, nil}
    end.

put_oauth_store(Store) ->
    persistent_term:put(levee_server_oauth_store, Store),
    nil.

get_document_supervisor() ->
    try {ok, persistent_term:get(levee_server_document_supervisor)}
    catch error:badarg -> {error, nil}
    end.

put_document_supervisor(Supervisor) ->
    persistent_term:put(levee_server_document_supervisor, Supervisor),
    nil.

clear_document_supervisor() ->
    persistent_term:erase(levee_server_document_supervisor),
    nil.
