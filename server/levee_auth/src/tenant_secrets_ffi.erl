-module(tenant_secrets_ffi).
-export([generate_tenant_id/1, get_env/1]).

generate_tenant_id(ExistingKeys) ->
    generate_tenant_id(ExistingKeys, 5).

generate_tenant_id(_ExistingKeys, 0) ->
    Base = generate_name(),
    Suffix = base16_lower(crypto:strong_rand_bytes(3)),
    <<Base/binary, "-", Suffix/binary>>;

generate_tenant_id(ExistingKeys, Retries) ->
    Id = generate_name(),
    case lists:member(Id, ExistingKeys) of
        true -> generate_tenant_id(ExistingKeys, Retries - 1);
        false -> Id
    end.

get_env(Name) ->
    case os:getenv(binary_to_list(Name)) of
        false -> {error, nil};
        Value -> {ok, list_to_binary(Value)}
    end.

base16_lower(Bin) ->
    list_to_binary(lists:flatten([io_lib:format("~2.16.0b", [B]) || <<B>> <= Bin])).

generate_name() ->
    Adjective = choose([
        <<"brave">>, <<"calm">>, <<"clever">>, <<"gentle">>, <<"happy">>,
        <<"kind">>, <<"lively">>, <<"quiet">>, <<"swift">>, <<"wise">>
    ]),
    Color = choose([
        <<"amber">>, <<"blue">>, <<"crimson">>, <<"golden">>, <<"green">>,
        <<"indigo">>, <<"purple">>, <<"silver">>, <<"violet">>, <<"white">>
    ]),
    Animal = choose([
        <<"badger">>, <<"dolphin">>, <<"falcon">>, <<"fox">>, <<"heron">>,
        <<"otter">>, <<"panda">>, <<"raven">>, <<"tiger">>, <<"whale">>
    ]),
    <<Adjective/binary, "-", Color/binary, "-", Animal/binary>>.

choose(Words) ->
    Count = length(Words),
    <<N:32/unsigned-integer, _/binary>> = crypto:strong_rand_bytes(8),
    lists:nth((N rem Count) + 1, Words).
