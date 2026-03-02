-module(levee_web_ffi).
-export([store_tenant_secrets_ref/1, store_session_registry_ref/1,
         random_hex_bytes/1, dynamic_to_json/1]).

%% Store the tenant_secrets actor Subject in persistent_term for global access.
store_tenant_secrets_ref(Subject) ->
    persistent_term:put(levee_tenant_secrets, Subject),
    nil.

%% Store the session registry (bravo USet) in persistent_term for global access.
store_session_registry_ref(Registry) ->
    persistent_term:put(levee_session_registry, Registry),
    nil.

%% Generate N random bytes as lowercase hex string.
random_hex_bytes(N) ->
    Bytes = crypto:strong_rand_bytes(N),
    Hex = binary:encode_hex(Bytes),
    string:lowercase(Hex).

%% Convert an arbitrary Erlang term to a gleam/json:Json value.
%% Falls back to null for terms that cannot be encoded.
dynamic_to_json(nil) ->
    gleam@json:null();
dynamic_to_json(Value) when is_binary(Value) ->
    gleam@json:string(Value);
dynamic_to_json(Value) when is_integer(Value) ->
    gleam@json:int(Value);
dynamic_to_json(Value) when is_float(Value) ->
    gleam@json:float(Value);
dynamic_to_json(true) ->
    gleam@json:bool(true);
dynamic_to_json(false) ->
    gleam@json:bool(false);
dynamic_to_json(Value) when is_list(Value) ->
    gleam@json:preprocessed_array([dynamic_to_json(V) || V <- Value]);
dynamic_to_json(Value) when is_map(Value) ->
    Pairs = [{K, dynamic_to_json(V)} || {K, V} <- maps:to_list(Value), is_binary(K)],
    gleam@json:object(Pairs);
dynamic_to_json(_) ->
    gleam@json:null().
