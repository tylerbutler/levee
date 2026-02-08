-module(password_ffi).
-export([pbkdf2_sha256/4]).

%% PBKDF2-SHA256 key derivation using Erlang's crypto module
pbkdf2_sha256(Password, Salt, Iterations, KeyLength) ->
    crypto:pbkdf2_hmac(sha256, Password, Salt, Iterations, KeyLength).
