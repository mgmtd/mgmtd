%%%-------------------------------------------------------------------
%%% @doc JSON file backend for the configuration database.
%%%
%%% The on-disk format is a nested JSON tree of the committed config:
%%%
%%%     {
%%%       "interface": {"speed": "1GbE"},
%%%       "server": {
%%%         "servers": [{"name": "web1", "port": 81}]
%%%       },
%%%       "example": {
%%%         "server": {
%%%           "servers": [{"name": "ex1", "port": 82}]
%%%         }
%%%       }
%%%     }
%%%
%%% Containers are objects, lists are arrays of objects (key leaves
%%% included), leaf-lists are arrays of scalars. Named prefixes are
%%% ordinary root objects; the silent `default` prefix is omitted, so
%%% its children sit at the top level. Leaf values use JSON types
%%% (strings, numbers, booleans) with RFC 7951-ish scalars: IP
%%% addresses as strings, `empty` as `[null]`, bits as a
%%% space-separated string, binary as base64.
%%%
%%% This is not the sys.config backend. There is no OTP-app wrapping,
%%% no `{codec, Mod}` rewrite, and unmatched JSON members are ignored
%%% on import and not written back.
%%%
%%% The in-memory store is still `#cfg{}` records in ETS. Persist runs
%%% inside a commit; commits are serialized by `mgmtd_cfg_server`.
%%% Each persist exports the full table. The live file is replaced
%%% only after a temp file has been decoded back successfully.
%%% @end
%%%-------------------------------------------------------------------
-module(mgmtd_cfg_db_json).

-include("mgmtd_schema.hrl").

-define(TABLE, mgmtd_cfg).
-define(FILE_NAME, "config.json").
-define(META_FILE, json_config_file).

-export([init/2, remove_db/2]).

-export([copy_to_ets/0]).

%% Transaction based operations
-export([transaction/1,
         read/1,
         match/1,
         write/1,
         delete/1,
         match_delete/1,
         first/0,
         next/1]).

%% Dirty operations
-export([select/2,
         lookup/1,
         match_object/1]).

%%--------------------------------------------------------------------
%% API callbacks
%%--------------------------------------------------------------------

-spec init(file:filename(), proplists:proplist()) -> ok | {error, term()}.
init(Dir, _Opts) ->
    File = config_file(Dir),
    ok = filelib:ensure_dir(File),
    Tab = recreate_table(),
    maybe_heir(Tab),
    ets:insert(mgmtd_meta, {?META_FILE, File}),
    case filelib:is_regular(File) of
        false ->
            persist(Tab, File);
        true ->
            case file:read_file(File) of
                {ok, Bin} ->
                    import_bin(Tab, Bin);
                {error, Reason} ->
                    {error, {read, File, Reason}}
            end
    end.

-spec remove_db(file:filename(), proplists:proplist()) -> ok.
remove_db(Dir, _Opts) ->
    delete_table(),
    try ets:delete(mgmtd_meta, ?META_FILE) catch error:badarg -> true end,
    _ = file:del_dir_r(Dir),
    ok.

transaction(Fun) when is_function(Fun, 0) ->
    Tab = ?TABLE,
    Snapshot = ets:tab2list(Tab),
    try Fun() of
        ok ->
            case persist(Tab, config_file()) of
                ok ->
                    ok;
                {error, _} = Err ->
                    restore(Tab, Snapshot),
                    Err
            end;
        _Other ->
            restore(Tab, Snapshot),
            {error, "FAIL"}
    catch
        throw:{error, Reason} ->
            restore(Tab, Snapshot),
            {error, Reason};
        Class:Reason:Stack ->
            restore(Tab, Snapshot),
            erlang:raise(Class, Reason, Stack)
    end.

read(Key) ->
    ets:lookup(?TABLE, Key).

match(Pattern) ->
    ets:match_object(?TABLE, Pattern).

write(#cfg{} = Cfg) ->
    ets:insert(?TABLE, Cfg),
    ok.

delete(Key) ->
    ets:delete(?TABLE, Key),
    ok.

match_delete(Pattern) ->
    ets:match_delete(?TABLE, Pattern),
    ok.

first() ->
    ets:first(?TABLE).

next(Key) ->
    ets:next(?TABLE, Key).

lookup(Path) ->
    ets:lookup(?TABLE, Path).

select(Path, Pattern) ->
    ets:select(?TABLE,
               [{#cfg{path = mgmtd_schema:ets_pat(Path ++ [Pattern]),
                      _ = mgmtd_schema:ets_pat('_')},
                 [], ['$1']}]).

match_object(Pattern) ->
    ets:match_object(?TABLE, Pattern).

-spec copy_to_ets() -> ets:table().
copy_to_ets() ->
    Ets = ets:new(cfg_txn, [public, ordered_set, {keypos, #cfg.path}]),
    ets:insert(Ets, ets:tab2list(?TABLE)),
    Ets.

%%--------------------------------------------------------------------
%% Internal
%%--------------------------------------------------------------------
config_file() ->
    case ets:lookup(mgmtd_meta, ?META_FILE) of
        [{_, File}] ->
            File;
        [] ->
            config_file("config_db")
    end.

config_file(Dir) ->
    filename:join(Dir, ?FILE_NAME).

recreate_table() ->
    delete_table(),
    ets:new(?TABLE, [named_table, public, ordered_set, {keypos, #cfg.path}]).

delete_table() ->
    case ets:info(?TABLE) of
        undefined ->
            ok;
        _ ->
            ets:delete(?TABLE),
            ok
    end.

maybe_heir(_Tab) ->
    case whereis(mgmtd_cfg_server) of
        Pid when is_pid(Pid) ->
            ets:setopts(?TABLE, [{heir, Pid, json}]);
        undefined ->
            ok
    end.

restore(Tab, Snapshot) ->
    ets:delete_all_objects(Tab),
    case Snapshot of
        [] ->
            ok;
        _ ->
            ets:insert(Tab, Snapshot),
            ok
    end.

persist(Tab, File) ->
    try cfg_to_json(ets:tab2list(Tab)) of
        Map ->
            write_json_file(File, Map)
    catch
        throw:{export_error, Reason} ->
            {error, {export_error, Reason}}
    end.

write_json_file(File, Map) ->
    Bin = mgmtd_json:encode_pretty(Map),
    Tmp = File ++ ".tmp",
    case file:write_file(Tmp, Bin) of
        ok ->
            case file:read_file(Tmp) of
                {ok, ReadBin} ->
                    case decode_map(ReadBin) of
                        {ok, Read} when Read =:= Map ->
                            case file:rename(Tmp, File) of
                                ok ->
                                    ok;
                                {error, Reason} ->
                                    _ = file:delete(Tmp),
                                    {error, {rename, Reason}}
                            end;
                        {ok, Other} ->
                            _ = file:delete(Tmp),
                            {error, {json_mismatch, Other}};
                        {error, Reason} ->
                            _ = file:delete(Tmp),
                            {error, {json_decode, Tmp, Reason}}
                    end;
                {error, Reason} ->
                    _ = file:delete(Tmp),
                    {error, {read, Tmp, Reason}}
            end;
        {error, Reason} ->
            {error, {write, Reason}}
    end.

decode_map(Bin) ->
    try mgmtd_json:decode(Bin) of
        Map when is_map(Map) ->
            {ok, Map};
        Other ->
            {error, {invalid_json_config, Other}}
    catch
        error:Reason ->
            {error, Reason};
        _:Reason ->
            {error, Reason}
    end.

import_bin(_Tab, <<>>) ->
    ok;
import_bin(Tab, Bin) ->
    case decode_map(Bin) of
        {ok, Map} ->
            import_map(Tab, Map);
        {error, Reason} ->
            {error, {json_decode, Reason}}
    end.

%%--------------------------------------------------------------------
%% #cfg{} list -> JSON map
%%--------------------------------------------------------------------
cfg_to_json(Cfgs) ->
    export_nodes(mgmtd_cfg_db:cfg_list_to_tree(Cfgs)).

export_nodes(Nodes) when is_list(Nodes) ->
    maps:from_list([export_node(N) || N <- Nodes]);
export_nodes(_) ->
    #{}.

export_node(#cfg{node_type = container, name = Name, value = Children}) ->
    {json_key(Name), export_nodes(Children)};
export_node(#cfg{node_type = list, name = Name, path = Path, value = Items})
  when is_list(Items) ->
    Sorted = case mgmtd_schema:ordered_by(Path) of
                 user -> Items;
                 system -> lists:keysort(#cfg.name, Items)
             end,
    {json_key(Name), [export_list_item(I) || I <- Sorted]};
export_node(#cfg{node_type = list, name = Name, value = _}) ->
    {json_key(Name), []};
export_node(#cfg{node_type = leaf, name = Name, path = Path, value = Value}) ->
    {json_key(Name), encode_leaf(schema_type(Path), Value)};
export_node(#cfg{node_type = leaf_list, name = Name, path = Path, value = Value})
  when is_list(Value) ->
    Type = schema_type(Path),
    {json_key(Name), [encode_leaf(Type, V) || V <- Value]};
export_node(#cfg{node_type = leaf_list, name = Name, value = _}) ->
    {json_key(Name), []}.

export_list_item(#cfg{node_type = list_key, value = Children}) ->
    export_nodes(Children).

schema_type(Path) ->
    case mgmtd_schema:lookup(Path) of
        #{type := Type} ->
            Type;
        _ ->
            undefined
    end.

encode_leaf(empty, empty) ->
    [null];
encode_leaf(boolean, B) when is_boolean(B) ->
    B;
encode_leaf({bits, _}, Names) when is_list(Names) ->
    encode_bits(Names);
encode_leaf(_Type, N) when is_integer(N) ->
    N;
encode_leaf(_Type, F) when is_float(F) ->
    F;
encode_leaf(_Type, B) when is_boolean(B) ->
    B;
encode_leaf(_Type, T) when is_tuple(T), tuple_size(T) =:= 4;
                           is_tuple(T), tuple_size(T) =:= 8 ->
    list_to_binary(ip_string(T));
encode_leaf(_Type, S) when is_list(S) ->
    to_bin(S);
encode_leaf(_Type, B) when is_binary(B) ->
    B;
encode_leaf(_Type, A) when is_atom(A) ->
    atom_to_binary(A, utf8).

encode_bits([]) ->
    <<>>;
encode_bits(Names) ->
    case hd(Names) of
        H when is_integer(H) ->
            to_bin(Names);
        _ ->
            iolist_to_binary(lists:join(<<" ">>, [to_bin(N) || N <- Names]))
    end.

to_bin(B) when is_binary(B) ->
    B;
to_bin(A) when is_atom(A) ->
    atom_to_binary(A, utf8);
to_bin(S) when is_list(S) ->
    unicode:characters_to_binary(S);
to_bin(N) when is_integer(N) ->
    integer_to_binary(N).

ip_string(T) ->
    case inet:ntoa(T) of
        {error, einval} ->
            lists:flatten(io_lib:format("~p", [T]));
        Str ->
            Str
    end.

json_key(Name) when is_binary(Name) ->
    Name;
json_key(Name) when is_atom(Name) ->
    atom_to_binary(Name, utf8);
json_key(Name) when is_list(Name) ->
    unicode:characters_to_binary(Name).

%%--------------------------------------------------------------------
%% JSON map -> #cfg{} rows
%%--------------------------------------------------------------------
import_map(_Tab, Map) when map_size(Map) =:= 0 ->
    ok;
import_map(Tab, Map) when is_map(Map) ->
    try
        import_nodes(Tab, [], Map),
        ok
    catch
        throw:{import_error, Reason} ->
            delete_table(),
            {error, Reason}
    end.

import_nodes(Tab, Path, Map) when is_map(Map) ->
    maps:foreach(
      fun(Key, Val) -> import_node(Tab, Path, Key, Val) end,
      Map);
import_nodes(_Tab, Path, Other) ->
    throw({import_error, {invalid_tree, Path, Other}}).

import_node(Tab, Path, Key, Val) ->
    case from_key(Key) of
        error ->
            ok;
        Name ->
            FullPath = Path ++ [Name],
            case mgmtd_schema:lookup(FullPath) of
                #{node_type := container} ->
                    import_nodes(Tab, FullPath, as_map(Val, FullPath));
                #{node_type := list, key_names := KeyNames} ->
                    import_list(Tab, FullPath, KeyNames, as_list(Val, FullPath));
                #{node_type := leaf, type := empty} = Schema ->
                    set_leaf(Tab, Path, Name, json_token(Schema, Val));
                #{node_type := Leaf} = Schema when ?is_leaf(Leaf), Val =/= null ->
                    set_leaf(Tab, Path, Name, json_token(Schema, Val));
                _ ->
                    ok
            end
    end.

as_map(Map, _Path) when is_map(Map) ->
    Map;
as_map(Other, Path) ->
    throw({import_error, {invalid_tree, Path, Other}}).

as_list(List, _Path) when is_list(List) ->
    List;
as_list(Map, _Path) when is_map(Map) ->
    [Map];
as_list(Other, Path) ->
    throw({import_error, {invalid_list, Path, Other}}).

import_list(Tab, ListPath, KeyNames, Items) ->
    lists:foreach(
      fun(Item) -> import_list_item(Tab, ListPath, KeyNames, Item) end,
      Items).

import_list_item(Tab, ListPath, KeyNames, Item) when is_map(Item) ->
    case item_key(KeyNames, Item) of
        {ok, Key} ->
            import_nodes(Tab, ListPath ++ [Key], Item);
        error ->
            ok
    end;
import_list_item(_Tab, _ListPath, _KeyNames, _Other) ->
    ok.

item_key(KeyNames, Item) ->
    try
        {ok, list_to_tuple([key_token(json_member(Item, Name)) || Name <- KeyNames])}
    catch
        throw:{import_error, _} ->
            error
    end.

json_member(Map, Name) ->
    case maps:find(json_key(Name), Map) of
        {ok, V} ->
            V;
        error ->
            throw({import_error, {missing_list_key, Name}})
    end.

key_token(V) when is_list(V), V =/= [], is_integer(hd(V)) ->
    V;
key_token(V) when is_binary(V) ->
    unicode:characters_to_list(V);
key_token(V) when is_integer(V) ->
    integer_to_list(V);
key_token(V) when is_atom(V), V =/= null, V =/= true, V =/= false ->
    atom_to_list(V);
key_token(true) ->
    "true";
key_token(false) ->
    "false";
key_token(V) when is_tuple(V) ->
    case inet:ntoa(V) of
        S when is_list(S) ->
            S;
        {error, _} ->
            throw({import_error, {invalid_list_key, V}})
    end;
key_token(V) ->
    throw({import_error, {invalid_list_key, V}}).

json_token(#{type := empty}, [null]) ->
    empty;
json_token(#{type := empty}, null) ->
    empty;
json_token(#{type := empty}, <<>>) ->
    empty;
json_token(#{type := empty}, "") ->
    empty;
json_token(#{node_type := leaf_list} = Schema, List) when is_list(List) ->
    [json_token(Schema#{node_type => leaf}, V) || V <- List];
json_token(#{node_type := leaf_list}, Other) ->
    throw({import_error, {invalid_leaf_list, Other}});
json_token(_Schema, B) when is_binary(B) ->
    unicode:characters_to_list(B);
json_token(_Schema, N) when is_integer(N) ->
    N;
json_token(_Schema, B) when is_boolean(B) ->
    B;
json_token(_Schema, F) when is_float(F) ->
    lists:flatten(io_lib:format("~p", [F]));
json_token(_Schema, Other) ->
    throw({import_error, {invalid_leaf, Other}}).

from_key(Name) when is_binary(Name) ->
    case unicode:characters_to_list(Name) of
        L when is_list(L) -> L;
        _ -> error
    end;
from_key(Name) when is_atom(Name) ->
    atom_to_list(Name);
from_key(Name) when is_list(Name) ->
    Name;
from_key(_) ->
    error.

set_leaf(Tab, ParentPath, Name, Value) ->
    CliPath = ParentPath ++ [Name, Value],
    case mgmtd_schema:lookup_path(CliPath) of
        {ok, SchemaPath} ->
            case mgmtd_schema:cast_value(SchemaPath, Value) of
                {ok, Internal} ->
                    case mgmtd_schema:cast_list_key_values(SchemaPath) of
                        {ok, Path1} ->
                            mgmtd_cfg_db:insert_path_items({ets, Tab}, Path1, Internal);
                        {error, Reason} ->
                            throw({import_error, Reason})
                    end;
                {error, Reason} ->
                    throw({import_error, Reason})
            end;
        {error, Reason} ->
            throw({import_error, Reason})
    end.
