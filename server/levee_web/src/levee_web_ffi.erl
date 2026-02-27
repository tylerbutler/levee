-module(levee_web_ffi).
-export([random_hex_bytes/1, dynamic_to_json/1]).

%% Generate N random bytes and return as lowercase hex string.
-spec random_hex_bytes(non_neg_integer()) -> binary().
random_hex_bytes(N) ->
    Bytes = crypto:strong_rand_bytes(N),
    Hex = binary:encode_hex(Bytes),
    string:lowercase(Hex).

%% Convert an arbitrary Erlang term to a gleam/json:Json value.
%% Encodes via Jason (available in the BEAM environment), then wraps
%% as a pre-encoded JSON fragment that gleam/json can include verbatim.
%%
%% Falls back to null for terms that cannot be encoded.
-spec dynamic_to_json(term()) -> term().
dynamic_to_json(nil) ->
    gleam@json:null();
dynamic_to_json(Value) ->
    try
        Encoded = 'Elixir.Jason':encode!(Value),
        gleam@json:preprocessed_array([{json, Encoded}])
    catch
        _:_ -> gleam@json:null()
    end.
