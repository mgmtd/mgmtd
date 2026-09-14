%%%-------------------------------------------------------------------
%%% @doc sys.config file backend for the configuration database.
%%%
%%% Prefix maps to the application-name slot of a sys.config file:
%%%
%%%     [{default, [{server, [...]}]},
%%%      {example, [{server, [...]}]}]
%%%
%%% Default-prefix rows are wrapped as `{default, Tree}` so they are not
%%% dumped as fake OTP apps. Named prefixes already match `{Prefix, Tree}`
%%% as the children of that root container.
%%%
%%% Lists are stored as lists of proplists (key leaves included) rather
%%% than path-tuple keys, which is the form operators already write in
%%% application env. The in-memory store is still `#cfg{}` records.
%%%
%%% A schema node may name `{codec, Mod}` in `opts`. At that node the
%%% default proplist value is rewritten by `Mod:export/1` / `Mod:import/1`
%%% (see `mgmtd_codec`). Codecs do not nest.
%%%
%%% Sections that do not match a schema node are not imported and are
%%% not visible to mgmtd operations. A rewrite of the file puts those
%%% terms back unchanged, in their original order, and only replaces
%%% schema-matched keys.
%%%
%%% On-disk output is a single Erlang term followed by a period, with
%%% unlimited print depth, so it is always readable by `file:consult/1`.
%%% The live file is replaced only after a temp file has been consulted
%%% back successfully.
%%% @end
%%%-------------------------------------------------------------------
-module(mgmtd_cfg_db_sys_config).

-include("mgmtd_schema.hrl").

-define(TABLE, mgmtd_cfg).
-define(FILE_NAME, "sys.config").
-define(META_FILE, sys_config_file).
-define(ORIGINAL, sys_config_original).

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

-export([format_consult/1]).

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
            remember_original([]),
            persist(Tab, File);
        true ->
            case file:consult(File) of
                {ok, []} ->
                    remember_original([]),
                    ok;
                {ok, [Term]} ->
                    case import_term(Tab, Term) of
                        ok ->
                            remember_original(Term),
                            ok;
                        {error, _} = Err ->
                            Err
                    end;
                {ok, Other} ->
                    {error, {invalid_sys_config, Other}};
                {error, Reason} ->
                    {error, {consult, File, Reason}}
            end
    end.

-spec remove_db(file:filename(), proplists:proplist()) -> ok.
remove_db(Dir, _Opts) ->
    delete_table(),
    try ets:delete(mgmtd_meta, ?META_FILE) catch error:badarg -> true end,
    try ets:delete(mgmtd_meta, ?ORIGINAL) catch error:badarg -> true end,
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
%% Consult-safe pretty printer. Unlimited depth so nested config cannot
%% be truncated to `...`, which `file:consult/1` cannot read.
%%--------------------------------------------------------------------
-spec format_consult(term()) -> iodata().
format_consult(Term) ->
    [<<"%% -*- erlang -*-\n">>,
     <<"%% coding: utf-8\n">>,
     io_lib:print(Term, 1, 80, -1),
     <<".\n">>].

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

remember_original(Term) when is_list(Term) ->
    ets:insert(mgmtd_meta, {?ORIGINAL, Term}),
    ok;
remember_original(_) ->
    ets:insert(mgmtd_meta, {?ORIGINAL, []}),
    ok.

original_term() ->
    case ets:lookup(mgmtd_meta, ?ORIGINAL) of
        [{_, Term}] when is_list(Term) ->
            Term;
        _ ->
            []
    end.

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
            ets:setopts(?TABLE, [{heir, Pid, sys_config}]);
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
    try cfg_to_term(ets:tab2list(Tab)) of
        Exported ->
            Term = merge_sys_config(original_term(), Exported),
            case consultable(Term) of
                false ->
                    {error, {not_consultable, Term}};
                true ->
                    case write_consult_file(File, Term) of
                        ok ->
                            remember_original(Term),
                            ok;
                        {error, _} = Err ->
                            Err
                    end
            end
    catch
        throw:{export_error, Reason} ->
            {error, {export_error, Reason}}
    end.

write_consult_file(File, Term) ->
    IoData = format_consult(Term),
    Tmp = File ++ ".tmp",
    case file:write_file(Tmp, IoData) of
        ok ->
            case file:consult(Tmp) of
                {ok, [Read]} when Read =:= Term ->
                    case file:rename(Tmp, File) of
                        ok ->
                            ok;
                        {error, Reason} ->
                            _ = file:delete(Tmp),
                            {error, {rename, Reason}}
                    end;
                {ok, Other} ->
                    _ = file:delete(Tmp),
                    {error, {consult_mismatch, Other}};
                {error, Reason} ->
                    _ = file:delete(Tmp),
                    {error, {consult, Tmp, Reason}}
            end;
        {error, Reason} ->
            {error, {write, Reason}}
    end.

%% Terms `file:consult/1` can reconstruct. Pids, refs, ports and funs
%% pretty-print with syntax consult cannot parse.
consultable(T) when is_atom(T); is_number(T); is_binary(T) ->
    true;
consultable(T) when is_bitstring(T) ->
    true;
consultable([]) ->
    true;
consultable([H | T]) ->
    consultable(H) andalso consultable(T);
consultable(T) when is_tuple(T) ->
    consultable(tuple_to_list(T));
consultable(T) when is_map(T) ->
    maps:fold(fun(K, V, true) -> consultable(K) andalso consultable(V);
                 (_, _, false) -> false
              end, true, T);
consultable(_) ->
    false.

%%--------------------------------------------------------------------
%% #cfg{} list -> sys.config term
%%--------------------------------------------------------------------
cfg_to_term(Cfgs) ->
    wrap_prefixes(mgmtd_cfg_db:cfg_list_to_tree(Cfgs)).

wrap_prefixes(Tree) ->
    Named = [{atom_to_list(P), P} || P <- named_prefixes()],
    {Prefixed, Default} = lists:partition(
                            fun(#cfg{name = Name}) ->
                                    lists:keymember(Name, 1, Named)
                            end, Tree),
    DefaultApp =
        case export_nodes(Default) of
            [] -> [];
            Kids -> [{?DEFAULT_NS, Kids}]
        end,
    NamedApps =
        lists:keysort(
          1,
          [{P, Kids}
           || #cfg{name = Name, value = Val} <- Prefixed,
              {_, P} <- [lists:keyfind(Name, 1, Named)],
              Kids <- [export_nodes(Val)],
              Kids =/= []]),
    DefaultApp ++ NamedApps.

named_prefixes() ->
    [P || P <- mgmtd_schema:registered_schemas(), P =/= ?DEFAULT_NS].

%% Overlay schema-owned keys from `Exported` onto the last on-disk term.
%% Unknown apps, unknown keys, and unmatched list items stay as they were.
merge_sys_config(Original, Exported) when is_list(Original), is_list(Exported) ->
    {Parts, Used} =
        lists:mapfoldl(
          fun(Entry, Acc) -> merge_top_entry(Entry, Exported, Acc) end,
          #{},
          Original),
    NewApps = [{App, Env} || {App, Env} <- Exported,
                             is_atom(App),
                             not maps:is_key(App, Used)],
    lists:append(Parts) ++ NewApps;
merge_sys_config(_Original, Exported) ->
    Exported.

merge_top_entry({App, OrigEnv}, Exported, Used)
  when is_atom(App), is_list(OrigEnv) ->
    case is_known_prefix(App) of
        false ->
            {[{App, OrigEnv}], Used};
        true ->
            ExpEnv =
                case lists:keyfind(App, 1, Exported) of
                    {App, Env} when is_list(Env) -> Env;
                    _ -> []
                end,
            MergedEnv = merge_env(prefix_path(App), OrigEnv, ExpEnv),
            case MergedEnv of
                [] when OrigEnv =:= [] ->
                    {[{App, []}], maps:put(App, true, Used)};
                [] ->
                    {[], maps:put(App, true, Used)};
                _ ->
                    {[{App, MergedEnv}], maps:put(App, true, Used)}
            end
    end;
merge_top_entry(Other, _Exported, Used) ->
    {[Other], Used}.

merge_env(Path, Orig, Exp) when is_list(Orig), is_list(Exp) ->
    {Parts, Used} =
        lists:mapfoldl(
          fun(Entry, Acc) -> merge_env_entry(Path, Entry, Exp, Acc) end,
          #{},
          Orig),
    New = [{K, V} || {K, V} <- Exp, not maps:is_key(from_key(K), Used)],
    lists:append(Parts) ++ New;
merge_env(_Path, _Orig, Exp) ->
    Exp.

merge_env_entry(Path, {Key, OrigVal}, Exp, Used) ->
    Name = from_key(Key),
    case is_list(Name) of
        false ->
            {[{Key, OrigVal}], Used};
        true ->
            FullPath = Path ++ [Name],
            case mgmtd_schema:lookup(FullPath) of
                false ->
                    {[{Key, OrigVal}], Used};
                Schema ->
                    NewUsed = maps:put(Name, true, Used),
                    case exp_value(Name, Exp) of
                        {ok, ExpVal} ->
                            {[{Key, merge_node(FullPath, Schema, OrigVal, ExpVal)}],
                             NewUsed};
                        error ->
                            {keep_leftovers(Key, FullPath, Schema, OrigVal), NewUsed}
                    end
            end
    end;
merge_env_entry(_Path, Other, _Exp, Used) ->
    {[Other], Used}.

merge_node(Path, Schema, OrigVal, ExpVal) ->
    case mgmtd_schema:codec(Schema) of
        undefined ->
            case Schema of
                #{node_type := container} ->
                    merge_env(Path, as_proplist(OrigVal), as_proplist(ExpVal));
                #{node_type := list, key_names := KeyNames} ->
                    merge_list(Path, KeyNames, OrigVal, ExpVal);
                _ ->
                    ExpVal
            end;
        _Mod ->
            ExpVal
    end.

keep_leftovers(Key, Path, Schema, OrigVal) ->
    case mgmtd_schema:codec(Schema) of
        undefined ->
            keep_leftovers1(Key, Path, Schema, OrigVal);
        _Mod ->
            []
    end.

keep_leftovers1(Key, Path, #{node_type := container}, OrigVal) ->
    keep_if_nonempty(Key, merge_env(Path, as_proplist(OrigVal), []));
keep_leftovers1(Key, Path, #{node_type := list, key_names := KeyNames}, OrigVal) ->
    keep_if_nonempty(Key, merge_list(Path, KeyNames, OrigVal, []));
keep_leftovers1(_Key, _Path, _Schema, _OrigVal) ->
    [].

keep_if_nonempty(_Key, []) ->
    [];
keep_if_nonempty(Key, Merged) ->
    [{Key, Merged}].

merge_list(ListPath, KeyNames, OrigItems, ExpItems)
  when is_list(OrigItems), is_list(ExpItems) ->
    ExpByKey = exp_items_by_key(KeyNames, ExpItems),
    {Parts, Used} =
        lists:mapfoldl(
          fun(Item, Acc) ->
                  merge_list_item(ListPath, KeyNames, Item, ExpByKey, Acc)
          end,
          #{},
          OrigItems),
    NewItems =
        [Item || Item <- ExpItems,
                 case item_key(KeyNames, Item) of
                     {ok, K} -> not maps:is_key(K, Used);
                     error -> true
                 end],
    lists:append(Parts) ++ NewItems;
merge_list(_ListPath, _KeyNames, _OrigItems, ExpItems) ->
    ExpItems.

merge_list_item(ListPath, KeyNames, Item, ExpByKey, Used) ->
    case item_key(KeyNames, Item) of
        {ok, Key} ->
            case maps:find(Key, ExpByKey) of
                {ok, ExpProps} ->
                    OrigProps = item_props(Item),
                    Merged = merge_env(ListPath ++ [Key], OrigProps, ExpProps),
                    {[Merged], maps:put(Key, true, Used)};
                error ->
                    {[], maps:put(Key, true, Used)}
            end;
        error ->
            {[Item], Used}
    end.

exp_items_by_key(KeyNames, Items) ->
    maps:from_list(
      [{K, item_props(I)}
       || I <- Items, {ok, K} <- [item_key(KeyNames, I)]]).

exp_value(_Name, []) ->
    error;
exp_value(Name, [{K, V} | Rest]) ->
    case from_key(K) of
        Name ->
            {ok, V};
        _ ->
            exp_value(Name, Rest)
    end;
exp_value(Name, [_ | Rest]) ->
    exp_value(Name, Rest).

as_proplist(L) when is_list(L) ->
    L;
as_proplist(_) ->
    [].

export_nodes(Nodes) when is_list(Nodes) ->
    lists:keysort(1, [export_node(N) || N <- Nodes]);
export_nodes(_) ->
    [].

export_node(#cfg{node_type = container, name = Name, path = Path, value = Children}) ->
    {to_key(Name), maybe_codec_export(Path, export_nodes(Children))};
export_node(#cfg{node_type = list, name = Name, path = Path, value = Items}) when is_list(Items) ->
    Sorted = case mgmtd_schema:ordered_by(Path) of
                 user -> Items;
                 system -> lists:keysort(#cfg.name, Items)
             end,
    Default = [export_list_item(I) || I <- Sorted],
    {to_key(Name), maybe_codec_export(Path, Default)};
export_node(#cfg{node_type = list, name = Name, path = Path, value = _}) ->
    {to_key(Name), maybe_codec_export(Path, [])};
export_node(#cfg{node_type = leaf, name = Name, path = Path, value = Value}) ->
    {to_key(Name), maybe_codec_export(Path, Value)};
export_node(#cfg{node_type = leaf_list, name = Name, path = Path, value = Value}) ->
    {to_key(Name), maybe_codec_export(Path, Value)}.

export_list_item(#cfg{node_type = list_key, value = Children}) ->
    export_nodes(Children).

maybe_codec_export(Path, DefaultVal) ->
    case mgmtd_schema:codec(Path) of
        undefined ->
            DefaultVal;
        Mod ->
            Mod:export(DefaultVal)
    end.

maybe_codec_import(Schema, Val) ->
    case mgmtd_schema:codec(Schema) of
        undefined ->
            Val;
        Mod ->
            Mod:import(Val)
    end.

to_key(Name) when is_atom(Name) ->
    Name;
to_key(Name) when is_list(Name) ->
    list_to_atom(Name);
to_key(Name) when is_binary(Name) ->
    binary_to_atom(Name, utf8).

from_key(Name) when is_atom(Name) ->
    atom_to_list(Name);
from_key(Name) when is_list(Name) ->
    Name;
from_key(Name) when is_binary(Name) ->
    unicode:characters_to_list(Name);
from_key(Name) ->
    Name.

%%--------------------------------------------------------------------
%% sys.config term -> #cfg{} rows
%%--------------------------------------------------------------------
import_term(_Tab, []) ->
    ok;
import_term(Tab, Term) when is_list(Term) ->
    try
        lists:foreach(fun(App) -> import_app(Tab, App) end, Term),
        ok
    catch
        throw:{import_error, Reason} ->
            delete_table(),
            {error, Reason}
    end;
import_term(_Tab, Other) ->
    {error, {invalid_sys_config, Other}}.

import_app(Tab, {Prefix, Env}) when is_atom(Prefix), is_list(Env) ->
    case is_known_prefix(Prefix) of
        true ->
            import_nodes(Tab, prefix_path(Prefix), Env);
        false ->
            ok
    end;
import_app(_Tab, {Prefix, _Other}) when is_atom(Prefix) ->
    case is_known_prefix(Prefix) of
        true ->
            throw({import_error, {invalid_app, Prefix}});
        false ->
            ok
    end;
import_app(_Tab, _Other) ->
    ok.

is_known_prefix(?DEFAULT_NS) ->
    true;
is_known_prefix(P) ->
    lists:member(P, mgmtd_schema:registered_schemas()).

prefix_path(?DEFAULT_NS) ->
    [];
prefix_path(Prefix) ->
    [atom_to_list(Prefix)].

import_nodes(Tab, Path, Env) when is_list(Env) ->
    lists:foreach(fun(Entry) -> import_node(Tab, Path, Entry) end, Env);
import_nodes(_Tab, Path, Other) ->
    throw({import_error, {invalid_tree, Path, Other}}).

import_node(Tab, Path, {Key, Val}) ->
    Name = from_key(Key),
    case is_list(Name) of
        false ->
            ok;
        true ->
            FullPath = Path ++ [Name],
            case mgmtd_schema:lookup(FullPath) of
                #{node_type := container} = Schema ->
                    import_nodes(Tab, FullPath, maybe_codec_import(Schema, Val));
                #{node_type := list, key_names := KeyNames} = Schema ->
                    import_list(Tab, FullPath, KeyNames, maybe_codec_import(Schema, Val));
                #{node_type := Leaf} = Schema when ?is_leaf(Leaf) ->
                    set_leaf(Tab, Path, Name, maybe_codec_import(Schema, Val));
                false ->
                    ok
            end
    end;
import_node(_Tab, _Path, _Other) ->
    ok.

import_list(Tab, ListPath, KeyNames, Items) when is_list(Items) ->
    lists:foreach(
      fun(Item) -> import_list_item(Tab, ListPath, KeyNames, Item) end,
      Items);
import_list(_Tab, ListPath, _KeyNames, Other) ->
    throw({import_error, {invalid_list, ListPath, Other}}).

import_list_item(Tab, ListPath, KeyNames, Item) ->
    case item_key(KeyNames, Item) of
        {ok, Key} ->
            import_list_item_at(Tab, ListPath ++ [Key], item_props(Item));
        error ->
            ok
    end.

import_list_item_at(_Tab, _ItemPath, []) ->
    ok;
import_list_item_at(Tab, ItemPath, Props) when is_list(Props) ->
    import_nodes(Tab, ItemPath, Props);
import_list_item_at(_Tab, _ItemPath, _Other) ->
    ok.

item_key(_KeyNames, {Key, Props}) when is_tuple(Key), is_list(Props) ->
    {ok, Key};
item_key(KeyNames, Props) when is_list(Props) ->
    try
        {ok, key_from_item(KeyNames, Props)}
    catch
        throw:{import_error, _} ->
            error
    end;
item_key(_KeyNames, _Other) ->
    error.

item_props({Key, Props}) when is_tuple(Key), is_list(Props) ->
    Props;
item_props(Props) when is_list(Props) ->
    Props;
item_props(_Other) ->
    [].

key_from_item(KeyNames, Props) ->
    list_to_tuple([key_token(prop_value(Props, Name)) || Name <- KeyNames]).

prop_value(Props, Name) ->
    case keyfind_value(Props, existing_atom(Name)) of
        {ok, V} ->
            V;
        false ->
            case keyfind_value(Props, Name) of
                {ok, V} ->
                    V;
                false ->
                    throw({import_error, {missing_list_key, Name}})
            end
    end.

existing_atom(Name) ->
    try list_to_existing_atom(Name) catch error:badarg -> undefined end.

keyfind_value(_Props, undefined) ->
    false;
keyfind_value(Props, Key) ->
    case lists:keyfind(Key, 1, Props) of
        {_, V} ->
            {ok, V};
        false ->
            false
    end.

key_token(V) when is_list(V) ->
    V;
key_token(V) when is_binary(V) ->
    unicode:characters_to_list(V);
key_token(V) when is_integer(V) ->
    integer_to_list(V);
key_token(V) when is_atom(V) ->
    atom_to_list(V);
key_token(V) when is_tuple(V) ->
    case inet:ntoa(V) of
        S when is_list(S) ->
            S;
        {error, _} ->
            throw({import_error, {invalid_list_key, V}})
    end;
key_token(V) ->
    throw({import_error, {invalid_list_key, V}}).

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
