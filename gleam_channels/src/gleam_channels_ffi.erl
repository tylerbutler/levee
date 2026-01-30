-module(gleam_channels_ffi).
-export([identity/1]).

%% Identity function for type erasure
identity(X) -> X.
