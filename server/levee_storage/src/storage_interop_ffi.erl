%% @doc Interop helpers for converting between Gleam storage types and
%% atom-keyed Erlang maps (consumed by Elixir/Phoenix).
-module(storage_interop_ffi).

-export([document_to_map/1, delta_to_map/1, blob_to_map/1,
         tree_to_map/1, tree_entry_to_map/1, commit_to_map/1,
         ref_to_map/1, summary_to_map/1,
         map_to_delta/1, map_to_tree_entry/1, map_to_summary/1]).

%% --- Option helpers ---

unwrap_option(none) -> nil;
unwrap_option({some, Val}) -> Val;
unwrap_option(Val) -> Val.

wrap_option(nil) -> none;
wrap_option(Val) -> {some, Val}.

%% Retrieve a key from a map, trying atom key first then binary key.
get_key(Map, AtomKey) ->
    case maps:find(AtomKey, Map) of
        {ok, Val} -> Val;
        error ->
            BinKey = atom_to_binary(AtomKey, utf8),
            maps:get(BinKey, Map, nil)
    end.

%% --- Gleam type → atom-keyed map ---

document_to_map({document, Id, TenantId, Sn, CreatedAt, UpdatedAt}) ->
    #{id => Id, tenant_id => TenantId, sequence_number => Sn,
      created_at => CreatedAt, updated_at => UpdatedAt}.

delta_to_map({delta, Sn, ClientId, Csn, Rsn, Msn, Type, Contents, Metadata, Ts}) ->
    #{sequence_number => Sn, client_id => unwrap_option(ClientId),
      client_sequence_number => Csn, reference_sequence_number => Rsn,
      minimum_sequence_number => Msn, type => Type,
      contents => Contents, metadata => Metadata, timestamp => Ts}.

blob_to_map({blob, Sha, Content, Size}) ->
    #{sha => Sha, content => Content, size => Size}.

tree_to_map({tree, Sha, Entries}) ->
    #{sha => Sha, tree => lists:map(fun tree_entry_to_map/1, Entries)}.

tree_entry_to_map({tree_entry, Path, Mode, Sha, EntryType}) ->
    #{path => Path, mode => Mode, sha => Sha, type => EntryType}.

commit_to_map({commit, Sha, Tree, Parents, Message, Author, Committer}) ->
    #{sha => Sha, tree => Tree, parents => Parents,
      message => unwrap_option(Message), author => Author,
      committer => Committer}.

ref_to_map({ref, RefPath, Sha}) ->
    #{ref => RefPath, sha => Sha}.

summary_to_map({summary, Handle, TenantId, DocId, Sn, TreeSha,
                CommitSha, ParentHandle, Message, CreatedAt}) ->
    #{handle => Handle, tenant_id => TenantId, document_id => DocId,
      sequence_number => Sn, tree_sha => TreeSha,
      commit_sha => unwrap_option(CommitSha),
      parent_handle => unwrap_option(ParentHandle),
      message => unwrap_option(Message), created_at => CreatedAt}.

%% --- Atom-keyed map → Gleam type ---

map_to_delta(Map) ->
    {delta,
     maps:get(sequence_number, Map),
     wrap_option(maps:get(client_id, Map)),
     maps:get(client_sequence_number, Map),
     maps:get(reference_sequence_number, Map),
     maps:get(minimum_sequence_number, Map),
     maps:get(type, Map),
     maps:get(contents, Map),
     maps:get(metadata, Map),
     maps:get(timestamp, Map)}.

map_to_tree_entry(Map) ->
    {tree_entry,
     get_key(Map, path),
     get_key(Map, mode),
     get_key(Map, sha),
     get_key(Map, type)}.

map_to_summary(Map) ->
    {summary,
     maps:get(handle, Map),
     maps:get(tenant_id, Map, <<>>),
     maps:get(document_id, Map, <<>>),
     maps:get(sequence_number, Map),
     maps:get(tree_sha, Map),
     wrap_option(maps:get(commit_sha, Map, nil)),
     wrap_option(maps:get(parent_handle, Map, nil)),
     wrap_option(maps:get(message, Map, nil)),
     maps:get(created_at, Map, nil)}.
