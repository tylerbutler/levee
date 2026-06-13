-module(levee_server_ffi).

-export([
    get_tables/0,
    put_tables/1,
    get_tenant_secrets_actor/0,
    put_tenant_secrets_actor/1,
    put_tenant_secret/2,
    get_tenant_secrets/1,
    clear_tenant_secret/1,
    list_tenants/0,
    list_tenants_with_names/0,
    create_tenant/1,
    get_tenant/1,
    regenerate_tenant_secret/2,
    delete_tenant/1,
    tenant_exists/1,
    dynamic_to_json/1,
    dynamic_to_base64/1,
    now_seconds/0,
    now_iso8601/0,
    set_env/2,
    get_github_allowed_users/0,
    set_github_allowed_users/1,
    unset_github_allowed_users/0,
    ensure_dir/1,
    static_dir/1,
    read_file/1,
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

get_tenant_secrets_actor() ->
    try {ok, persistent_term:get(levee_server_tenant_secrets)}
    catch error:badarg -> {error, nil}
    end.

put_tenant_secrets_actor(Actor) ->
    persistent_term:put(levee_server_tenant_secrets, Actor),
    nil.

put_tenant_secret(Tenant, Secret) ->
    persistent_term:put({levee_server_tenant_secret, Tenant}, Secret),
    nil.

get_tenant_secrets(Tenant) ->
    case get_test_tenant_secrets(Tenant) of
        {ok, Secrets} -> {ok, Secrets};
        {error, nil} -> get_actor_tenant_secrets(Tenant)
    end.

get_test_tenant_secrets(Tenant) ->
    try
        #{secret1 := Secret1, secret2 := Secret2} = persistent_term:get({levee_server_tenant, Tenant}),
        {ok, {Secret1, Secret2}}
    catch error:{badmatch, _} ->
        get_legacy_test_tenant_secrets(Tenant);
    error:badarg ->
        get_legacy_test_tenant_secrets(Tenant)
    end.

get_legacy_test_tenant_secrets(Tenant) ->
    try
        Secret = persistent_term:get({levee_server_tenant_secret, Tenant}),
        {ok, {Secret, Secret}}
    catch error:badarg -> {error, nil}
    end.

get_actor_tenant_secrets(Tenant) ->
    try persistent_term:get(levee_server_tenant_secrets) of
        Actor ->
            case 'levee_documents@tenant_secrets':get_secrets(Actor, Tenant) of
                {ok, {Secret1, Secret2}} -> {ok, {Secret1, Secret2}};
                _ -> {error, nil}
            end
    catch
        _:_ -> {error, nil}
    end.

clear_tenant_secret(Tenant) ->
    persistent_term:erase({levee_server_tenant_secret, Tenant}),
    nil.

list_tenants() ->
    TestTenants = [Tenant || {{levee_server_tenant, Tenant}, _Data} <- persistent_term:get()]
        ++ [Tenant || {{levee_server_tenant_secret, Tenant}, _Secret} <- persistent_term:get()],
    ActorTenants =
        try persistent_term:get(levee_server_tenant_secrets) of
            Actor ->
                case 'levee_documents@tenant_secrets':list_tenants(Actor) of
                    Tenants when is_list(Tenants) -> Tenants;
                    _ -> []
                end
        catch
            _:_ -> []
        end,
    lists:usort(TestTenants ++ ActorTenants).

list_tenants_with_names() ->
    TestTenants = test_tenants_with_names(),
    ActorTenants =
        try persistent_term:get(levee_server_tenant_secrets) of
            Actor ->
                case 'levee_documents@tenant_secrets':list_tenants_with_names(Actor) of
                    Tenants when is_list(Tenants) -> [tenant_info_to_tuple(T) || T <- Tenants];
                    _ -> []
                end
        catch
            _:_ -> []
        end,
    dedupe_tenant_infos(TestTenants ++ ActorTenants).

test_tenants_with_names() ->
    New = [begin
        Name = maps:get(name, Data, Tenant),
        {Tenant, Name}
    end || {{levee_server_tenant, Tenant}, Data} <- persistent_term:get()],
    Legacy = [{Tenant, Tenant} || {{levee_server_tenant_secret, Tenant}, _Secret} <- persistent_term:get()],
    New ++ Legacy.

tenant_info_to_tuple({tenant_info, Id, Name}) -> {Id, Name};
tenant_info_to_tuple(#{id := Id, name := Name}) -> {Id, Name};
tenant_info_to_tuple(#{<<"id">> := Id, <<"name">> := Name}) -> {Id, Name};
tenant_info_to_tuple(Other) when is_map(Other) ->
    Id = maps:get(id, Other, maps:get(<<"id">>, Other, <<>>)),
    Name = maps:get(name, Other, maps:get(<<"name">>, Other, Id)),
    {Id, Name};
tenant_info_to_tuple({Id, Name}) -> {Id, Name};
tenant_info_to_tuple(Id) when is_binary(Id) -> {Id, Id}.

dedupe_tenant_infos(Infos) ->
    maps:values(lists:foldl(fun({Id, Name}, Acc) -> maps:put(Id, {Id, Name}, Acc) end, #{}, Infos)).

create_tenant(Name) ->
    try persistent_term:get(levee_server_tenant_secrets) of
        Actor ->
            case 'levee_documents@tenant_secrets':create_tenant(Actor, Name) of
                {ok, Tenant} -> {ok, tenant_with_secrets_to_tuple(Tenant)};
                _ -> create_test_tenant(Name)
            end
    catch
        _:_ -> create_test_tenant(Name)
    end.

create_test_tenant(Name) ->
    Id = <<"tenant-", (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    Secret1 = random_secret(),
    Secret2 = random_secret(),
    persistent_term:put({levee_server_tenant, Id}, #{name => Name, secret1 => Secret1, secret2 => Secret2}),
    {ok, {Id, Name, Secret1, Secret2}}.

tenant_with_secrets_to_tuple({tenant_with_secrets, Id, Name, Secret1, Secret2}) ->
    {Id, Name, Secret1, Secret2};
tenant_with_secrets_to_tuple(#{id := Id, name := Name, secret1 := Secret1, secret2 := Secret2}) ->
    {Id, Name, Secret1, Secret2};
tenant_with_secrets_to_tuple(#{<<"id">> := Id, <<"name">> := Name, <<"secret1">> := Secret1, <<"secret2">> := Secret2}) ->
    {Id, Name, Secret1, Secret2};
tenant_with_secrets_to_tuple(Tenant) when is_map(Tenant) ->
    Id = maps:get(id, Tenant, maps:get(<<"id">>, Tenant, <<>>)),
    Name = maps:get(name, Tenant, maps:get(<<"name">>, Tenant, Id)),
    Secret1 = maps:get(secret1, Tenant, maps:get(<<"secret1">>, Tenant, <<>>)),
    Secret2 = maps:get(secret2, Tenant, maps:get(<<"secret2">>, Tenant, <<>>)),
    {Id, Name, Secret1, Secret2}.

get_tenant(Id) ->
    case get_test_tenant(Id) of
        {ok, Tenant} -> {ok, Tenant};
        {error, nil} ->
            try persistent_term:get(levee_server_tenant_secrets) of
                Actor ->
                    case 'levee_documents@tenant_secrets':get_tenant(Actor, Id) of
                        {ok, TenantInfo} -> {ok, tenant_info_to_tuple(TenantInfo)};
                        _ -> {error, nil}
                    end
            catch
                _:_ -> {error, nil}
            end
    end.

get_test_tenant(Id) ->
    try
        Data = persistent_term:get({levee_server_tenant, Id}),
        {ok, {Id, maps:get(name, Data, Id)}}
    catch error:badarg ->
        try persistent_term:get({levee_server_tenant_secret, Id}), {ok, {Id, Id}}
        catch error:badarg -> {error, nil}
        end
    end.

regenerate_tenant_secret(Id, Slot) ->
    case regenerate_test_tenant_secret(Id, Slot) of
        {ok, Secret} -> {ok, Secret};
        {error, nil} ->
            try persistent_term:get(levee_server_tenant_secrets) of
                Actor ->
                    GleamSlot = case Slot of 1 -> slot1; 2 -> slot2; _ -> invalid end,
                    case GleamSlot of
                        invalid -> {error, nil};
                        _ ->
                            case 'levee_documents@tenant_secrets':regenerate_secret(Actor, Id, GleamSlot) of
                                {ok, Secret} -> {ok, Secret};
                                _ -> {error, nil}
                            end
                    end
            catch
                _:_ -> {error, nil}
            end
    end.

regenerate_test_tenant_secret(Id, Slot) ->
    try
        Data = persistent_term:get({levee_server_tenant, Id}),
        Secret = random_secret(),
        Key = case Slot of 1 -> secret1; 2 -> secret2 end,
        persistent_term:put({levee_server_tenant, Id}, maps:put(Key, Secret, Data)),
        {ok, Secret}
    catch
        _:_ -> {error, nil}
    end.

delete_tenant(Id) ->
    Existed = tenant_exists(Id),
    persistent_term:erase({levee_server_tenant, Id}),
    persistent_term:erase({levee_server_tenant_secret, Id}),
    try persistent_term:get(levee_server_tenant_secrets) of
        Actor -> 'levee_documents@tenant_secrets':unregister_tenant(Actor, Id)
    catch
        _:_ -> nil
    end,
    Existed.

tenant_exists(Id) ->
    case get_test_tenant(Id) of
        {ok, _} -> true;
        {error, nil} ->
            try persistent_term:get(levee_server_tenant_secrets) of
                Actor ->
                    case 'levee_documents@tenant_secrets':tenant_exists(Actor, Id) of
                        true -> true;
                        _ -> false
                    end
            catch
                _:_ -> false
            end
    end.

random_secret() ->
    string:lowercase(binary:encode_hex(crypto:strong_rand_bytes(32))).

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

static_dir(Name) ->
    Candidates = [
        filename:join([<<"..">>, <<"priv">>, <<"static">>, Name]),
        filename:join([<<"priv">>, <<"static">>, Name]),
        case code:priv_dir(levee) of
            {error, _} -> <<"">>;
            Dir -> filename:join([Dir, <<"static">>, Name])
        end,
        case code:priv_dir(levee_server) of
            {error, _} -> <<"">>;
            Dir2 -> filename:join([Dir2, <<"static">>, Name])
        end
    ],
    case [Path || Path <- Candidates, Path =/= <<"">>, filelib:is_dir(Path)] of
        [First | _] -> First;
        [] -> filename:join([<<"..">>, <<"priv">>, <<"static">>, Name])
    end.

read_file(Path) ->
    case file:read_file(Path) of
        {ok, Data} -> {ok, unicode:characters_to_binary(Data)};
        _ -> {error, nil}
    end.

session_alive(Tenant, Document) ->
    try persistent_term:get(levee_server_document_supervisor) of
        Supervisor ->
            case 'levee_documents@supervisor':get_session(Supervisor, Tenant, Document) of
                {ok, _Actor} -> true;
                _ -> false
            end
    catch
        _:_ -> false
    end.

get_auth_store() ->
    try {ok, persistent_term:get(levee_server_auth_store)}
    catch error:badarg -> {error, nil}
    end.

put_auth_store(Store) ->
    persistent_term:put(levee_server_auth_store, Store),
    nil.

get_oauth_store() ->
    try {ok, persistent_term:get(levee_server_oauth_store)}
    catch error:badarg -> {error, nil}
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

