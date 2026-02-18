-module(password_ffi).
-export([pbkdf2_sha256/4, safe_base64_decode/1]).

%% PBKDF2-SHA256 key derivation using Erlang's crypto module
pbkdf2_sha256(Password, Salt, Iterations, KeyLength) ->
    crypto:pbkdf2_hmac(sha256, Password, Salt, Iterations, KeyLength).

%% Safe base64 decode that returns {ok, Decoded} or {error, nil} instead of throwing
safe_base64_decode(Data) ->
    try
        {ok, base64:decode(Data)}
    catch
        _:_ -> {error, nil}
    end.
