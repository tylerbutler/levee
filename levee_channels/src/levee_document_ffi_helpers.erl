-module(levee_document_ffi_helpers).
-export([dynamic_push/3, make_nack_map/2, make_op_map/2]).

%% Encode a push message with a Dynamic (Erlang term) payload as JSON string.
dynamic_push(Topic, Event, Payload) ->
    Msg = [nil, nil, Topic, Event, Payload],
    json:encode(Msg).

%% Create a map for nack response
make_nack_map(ClientId, Nacks) ->
    #{<<"clientId">> => ClientId, <<"nacks">> => Nacks}.

%% Create a map for op response
make_op_map(DocumentId, Ops) ->
    #{<<"documentId">> => DocumentId, <<"op">> => Ops}.
