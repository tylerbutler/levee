-module(levee_storage_ets_backend).

-export([
    init_tables/0,
    create_document/3, get_document/2, update_document_sequence/3,
    store_delta/3, get_deltas/4,
    create_blob/2, get_blob/2,
    create_tree/2, get_tree/3,
    create_commit/2, get_commit/2,
    create_ref/3, get_ref/2, list_refs/1, update_ref/3,
    store_summary/3, get_summary/3, get_latest_summary/2, list_summaries/4
]).

-define(DOCUMENTS, fluid_documents).
-define(DELTAS, fluid_deltas).
-define(BLOBS, fluid_blobs).
-define(TREES, fluid_trees).
-define(COMMITS, fluid_commits).
-define(REFS, fluid_refs).
-define(SUMMARIES, fluid_summaries).
-define(MAX_DELTAS, 2000).

%% Initialize all ETS tables
init_tables() ->
    ets:new(?DOCUMENTS, [set, public, named_table, {read_concurrency, true}]),
    ets:new(?DELTAS, [ordered_set, public, named_table, {read_concurrency, true}]),
    ets:new(?BLOBS, [set, public, named_table, {read_concurrency, true}]),
    ets:new(?TREES, [set, public, named_table, {read_concurrency, true}]),
    ets:new(?COMMITS, [set, public, named_table, {read_concurrency, true}]),
    ets:new(?REFS, [set, public, named_table, {read_concurrency, true}]),
    ets:new(?SUMMARIES, [ordered_set, public, named_table, {read_concurrency, true}]),
    nil.

%% Document operations

create_document(TenantId, DocumentId, Params) ->
    Now = utc_now(),
    SeqNum = case maps:find(sequence_number, Params) of
        {ok, V} -> V;
        error -> 0
    end,
    Doc = #{
        id => DocumentId,
        tenant_id => TenantId,
        sequence_number => SeqNum,
        created_at => Now,
        updated_at => Now
    },
    Key = {TenantId, DocumentId},
    case ets:insert_new(?DOCUMENTS, {Key, Doc}) of
        true -> {ok, Doc};
        false -> {error, already_exists}
    end.

get_document(TenantId, DocumentId) ->
    Key = {TenantId, DocumentId},
    case ets:lookup(?DOCUMENTS, Key) of
        [{_, Doc}] -> {ok, Doc};
        [] -> {error, not_found}
    end.

update_document_sequence(TenantId, DocumentId, SeqNum) ->
    Key = {TenantId, DocumentId},
    case ets:lookup(?DOCUMENTS, Key) of
        [{_, Doc}] ->
            Updated = Doc#{
                sequence_number => SeqNum,
                updated_at => utc_now()
            },
            ets:insert(?DOCUMENTS, {Key, Updated}),
            {ok, Updated};
        [] ->
            {error, not_found}
    end.

%% Delta operations

store_delta(TenantId, DocumentId, Delta) ->
    SN = maps:get(sequence_number, Delta),
    Key = {TenantId, DocumentId, SN},
    ets:insert(?DELTAS, {Key, Delta}),
    {ok, Delta}.

get_deltas(TenantId, DocumentId, Opts, MaxLimit) ->
    FromSN = case maps:find(from, Opts) of
        {ok, F} -> F;
        error -> -1
    end,
    ToSN = maps:find(to, Opts),
    ReqLimit = case maps:find(limit, Opts) of
        {ok, L} -> L;
        error -> MaxLimit
    end,
    Limit = min(ReqLimit, MaxLimit),

    Guards = case ToSN of
        {ok, To} -> [{'>', '$1', FromSN}, {'<', '$1', To}];
        error -> [{'>', '$1', FromSN}]
    end,

    MatchSpec = [{{
        {TenantId, DocumentId, '$1'}, '$2'
    }, Guards, ['$2']}],

    Deltas0 = ets:select(?DELTAS, MatchSpec),
    Sorted = lists:sort(fun(A, B) ->
        maps:get(sequence_number, A) =< maps:get(sequence_number, B)
    end, Deltas0),
    Limited = lists:sublist(Sorted, Limit),
    {ok, Limited}.

%% Blob operations

create_blob(TenantId, Content) when is_binary(Content) ->
    Sha = compute_sha256(Content),
    Blob = #{
        sha => Sha,
        content => Content,
        size => byte_size(Content)
    },
    Key = {TenantId, Sha},
    ets:insert(?BLOBS, {Key, Blob}),
    {ok, Blob}.

get_blob(TenantId, Sha) ->
    Key = {TenantId, Sha},
    case ets:lookup(?BLOBS, Key) of
        [{_, Blob}] -> {ok, Blob};
        [] -> {error, not_found}
    end.

%% Tree operations

create_tree(TenantId, Entries) ->
    TreeContent = 'Elixir.Jason':'encode!'(Entries),
    Sha = compute_sha256(TreeContent),
    Tree = #{
        sha => Sha,
        tree => Entries
    },
    Key = {TenantId, Sha},
    ets:insert(?TREES, {Key, Tree}),
    {ok, Tree}.

get_tree(TenantId, Sha, Recursive) ->
    Key = {TenantId, Sha},
    case ets:lookup(?TREES, Key) of
        [{_, Tree}] ->
            case Recursive of
                true -> {ok, expand_tree_recursive(TenantId, Tree)};
                false -> {ok, Tree}
            end;
        [] ->
            {error, not_found}
    end.

expand_tree_recursive(TenantId, Tree) ->
    Entries = maps:get(tree, Tree),
    ExpandedEntries = lists:flatmap(fun(Entry) ->
        case maps:get(type, Entry) of
            <<"tree">> ->
                EntrySha = maps:get(sha, Entry),
                EntryPath = maps:get(path, Entry),
                case get_tree(TenantId, EntrySha, true) of
                    {ok, SubTree} ->
                        SubEntries = maps:get(tree, SubTree),
                        lists:map(fun(SubEntry) ->
                            SubPath = maps:get(path, SubEntry),
                            SubEntry#{path => <<EntryPath/binary, "/", SubPath/binary>>}
                        end, SubEntries);
                    {error, _} ->
                        [Entry]
                end;
            _ ->
                [Entry]
        end
    end, Entries),
    Tree#{tree => ExpandedEntries}.

%% Commit operations

create_commit(TenantId, Params) ->
    CommitData = #{
        <<"tree">> => maps:get(<<"tree">>, Params),
        <<"parents">> => maps:get(<<"parents">>, Params, []),
        <<"message">> => maps:get(<<"message">>, Params, nil),
        <<"author">> => maps:get(<<"author">>, Params)
    },
    CommitContent = 'Elixir.Jason':'encode!'(CommitData),
    Sha = compute_sha256(CommitContent),
    Now = list_to_binary(calendar:system_time_to_rfc3339(
        erlang:system_time(second), [{unit, second}, {offset, "Z"}]
    )),
    Committer = case maps:find(<<"committer">>, Params) of
        {ok, C} -> C;
        error -> #{
            <<"name">> => <<"Levee">>,
            <<"email">> => <<"server@fluid.local">>,
            <<"date">> => Now
        }
    end,
    Commit = #{
        sha => Sha,
        tree => maps:get(<<"tree">>, Params),
        parents => maps:get(<<"parents">>, Params, []),
        message => maps:get(<<"message">>, Params, nil),
        author => maps:get(<<"author">>, Params),
        committer => Committer
    },
    Key = {TenantId, Sha},
    ets:insert(?COMMITS, {Key, Commit}),
    {ok, Commit}.

get_commit(TenantId, Sha) ->
    Key = {TenantId, Sha},
    case ets:lookup(?COMMITS, Key) of
        [{_, Commit}] -> {ok, Commit};
        [] -> {error, not_found}
    end.

%% Reference operations

create_ref(TenantId, RefPath, Sha) ->
    Ref = #{
        ref => RefPath,
        sha => Sha
    },
    Key = {TenantId, RefPath},
    case ets:insert_new(?REFS, {Key, Ref}) of
        true -> {ok, Ref};
        false -> {error, already_exists}
    end.

get_ref(TenantId, RefPath) ->
    Key = {TenantId, RefPath},
    case ets:lookup(?REFS, Key) of
        [{_, Ref}] -> {ok, Ref};
        [] -> {error, not_found}
    end.

list_refs(TenantId) ->
    MatchSpec = [{{
        {TenantId, '_'}, '$1'
    }, [], ['$1']}],
    Refs = ets:select(?REFS, MatchSpec),
    {ok, Refs}.

update_ref(TenantId, RefPath, Sha) ->
    Key = {TenantId, RefPath},
    case ets:lookup(?REFS, Key) of
        [{_, _}] ->
            UpdatedRef = #{ref => RefPath, sha => Sha},
            ets:insert(?REFS, {Key, UpdatedRef}),
            {ok, UpdatedRef};
        [] ->
            {error, not_found}
    end.

%% Summary operations

store_summary(TenantId, DocumentId, Summary) ->
    SN = maps:get(sequence_number, Summary),
    Key = {TenantId, DocumentId, SN},
    SummaryWithMeta = Summary#{
        tenant_id => TenantId,
        document_id => DocumentId,
        created_at => maps:get(created_at, Summary, utc_now())
    },
    ets:insert(?SUMMARIES, {Key, SummaryWithMeta}),
    update_document_latest_summary(TenantId, DocumentId, SummaryWithMeta),
    {ok, SummaryWithMeta}.

get_summary(TenantId, DocumentId, Handle) ->
    MatchSpec = [{{
        {TenantId, DocumentId, '_'}, '$1'
    }, [{'==', {map_get, handle, '$1'}, Handle}], ['$1']}],
    case ets:select(?SUMMARIES, MatchSpec) of
        [Summary | _] -> {ok, Summary};
        [] -> {error, not_found}
    end.

get_latest_summary(TenantId, DocumentId) ->
    MatchSpec = [{{
        {TenantId, DocumentId, '$1'}, '$2'
    }, [], [{{'$1', '$2'}}]}],
    case ets:select(?SUMMARIES, MatchSpec) of
        [] ->
            {error, not_found};
        Results ->
            {_, Summary} = lists:max(Results),
            {ok, Summary}
    end.

list_summaries(TenantId, DocumentId, FromSN, Limit) ->
    MatchSpec = [{{
        {TenantId, DocumentId, '$1'}, '$2'
    }, [{'>=', '$1', FromSN}], ['$2']}],
    Summaries0 = ets:select(?SUMMARIES, MatchSpec),
    Sorted = lists:sort(fun(A, B) ->
        maps:get(sequence_number, A) =< maps:get(sequence_number, B)
    end, Summaries0),
    Limited = lists:sublist(Sorted, Limit),
    {ok, Limited}.

%% Internal helpers

update_document_latest_summary(TenantId, DocumentId, Summary) ->
    Key = {TenantId, DocumentId},
    case ets:lookup(?DOCUMENTS, Key) of
        [{_, Doc}] ->
            Updated = Doc#{
                latest_summary_handle => maps:get(handle, Summary),
                latest_summary_sequence_number => maps:get(sequence_number, Summary),
                updated_at => utc_now()
            },
            ets:insert(?DOCUMENTS, {Key, Updated});
        [] ->
            ok
    end.

compute_sha256(Content) ->
    Hash = crypto:hash(sha256, Content),
    list_to_binary([io_lib:format("~2.16.0b", [B]) || <<B>> <= Hash]).

utc_now() ->
    'Elixir.DateTime':utc_now().
