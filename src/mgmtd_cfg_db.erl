%%%-------------------------------------------------------------------
%%% @author Sean Hinde <sean@Seans-MacBook.local>
%%% @copyright (C) 2019, Sean Hinde
%%% @doc Configuration database backend
%%%
%%% @end
%%% Created : 20 Sep 2019 by Sean Hinde <sean@Seans-MacBook.local>
%%%-------------------------------------------------------------------
-module(mgmtd_cfg_db).

-include("mgmtd_schema.hrl").

-export([init/2, remove_db/2, transaction/1, copy_to_ets/0]).

-export([insert_path_items/3, check_conflict/3, delete_path_items/2]).

-export([cfg_list_to_tree/1, simplify_tree/1, schema_path_to_key/1]).

%% Dirty operations towards current config database
-export([lookup/1, lookup/2, list_keys/1, list_keys/2, list_keys/3]).

%%--------------------------------------------------------------------
%% Wrapper functions around the operations towards the chosen storage
%% engine
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% @doc Called once at startup to allow the chosen database backend to
%% create tables etc.
%% --------------------------------------------------------------------
-spec init(file:filename(), proplists:proplist()) -> ok.
init(DbLocation, Opts) ->
    Backend = proplists:get_value(backend, Opts, json),
    BackendMod = backend_mod(Backend),
    BackendMod:init(DbLocation, Opts),
    ets:insert(mgmtd_meta, {backend, BackendMod}),
    to_ok(ets:insert(mgmtd_meta, {db_location, DbLocation})).

remove_db(DbLocation, Opts) ->
    Backend = proplists:get_value(backend, Opts, json),
    BackendMod = backend_mod(Backend),
    ok = BackendMod:remove_db(DbLocation, Opts),
    try ets:delete(mgmtd_meta, db_location) catch error:badarg -> true end,
    try ets:delete(mgmtd_meta, backend) catch error:badarg -> true end,
    ok.

transaction(Fun) when is_function(Fun) ->
    BackendMod = backend(),
    BackendMod:transaction(Fun).

-spec read(permanent | {ets, ets:tid()}, item_path()) -> list().
read(permanent, Key) ->
    BackendMod = backend(),
    BackendMod:read(Key);
read({ets, Ets}, Path) ->
    ets:lookup(Ets, Path).

-spec write(permanent | {ets, ets:tid()}, #cfg{}) -> ok.
write(permanent, #cfg{} = Cfg) ->
    BackendMod = backend(),
    BackendMod:write(Cfg);
write({ets, Ets}, #cfg{} = Cfg) ->
    to_ok(ets:insert(Ets, Cfg)).

-spec delete(permanent | {ets, ets:tid()}, item_path()) -> ok.
delete(permanent, Path) ->
    BackendMod = backend(),
    BackendMod:delete(Path);
delete({ets, Ets}, Path) ->
    to_ok(ets:delete(Ets, Path)).

lookup(Path) ->
    lookup(permanent, Path).

-spec lookup(permanent | {ets, ets:tid()}, item_path()) -> list().
lookup(permanent, Path) ->
    BackendMod = backend(),
    BackendMod:lookup(Path);
lookup({ets, Ets}, Path) ->
    ets:lookup(Ets, Path).

match_delete(Pattern) ->
    match_delete(permanent, Pattern).

match_delete(permanent, Pattern) ->
    BackendMod = backend(),
    BackendMod:match_delete(Pattern);
match_delete({ets, Ets}, Pattern) ->
    to_ok(ets:match_delete(Ets, Pattern)).

match(Pattern) ->
    match(permanent, Pattern).

match(permanent, Pattern) ->
    BackendMod = backend(),
    BackendMod:match(Pattern);
match({ets, Ets}, Pattern) ->
    to_ok(ets:match(Ets, Pattern)).

list_keys(Path) ->
    list_keys(Path, '$1').

list_keys(Path, Pattern) ->
    list_keys(permanent, Path, Pattern).

list_keys(permanent, Path, Pattern) ->
    BackendMod = backend(),
    BackendMod:select(Path, Pattern);
list_keys({ets, Ets}, Path, Pattern) ->
    ets:select(Ets, [{#cfg{path = Path ++ [Pattern], _ = '_'}, [], ['$1']}]).

copy_to_ets() ->
    BackendMod = backend(),
    BackendMod:copy_to_ets().

backend() ->
    [{_, Mod}] = ets:lookup(mgmtd_meta, backend),
    Mod.

backend_mod(mnesia) -> mgmtd_cfg_db_mnesia;
backend_mod(json)   -> mgmtd_cfg_db_json;
backend_mod(config) -> mgmtd_cfg_db_config.

to_ok(true) -> ok;
to_ok(Else) -> Else.

%% Insert all the database items required for a single configuration
%% item.  One entry is required for each level in the path plus a few
%% more for list items.
%%
%% If the entry already exists, but is of a different type that's bad:
%% it means the schema used to create the database was different to
%% the schema used to parse the command. Bail if this happens.
%%
%% List items. Are awkward. We need to generate several database
%% entries for the list item, one for each of the list keys, and
%% potentially one for a value. We need these for easy lookup /
%% subscribe etc.
%%
%% e.g. {set, ["a",{"b","c"},"name"], "Val"} leads to these database entries:
%%
%% #cfg{node_type = list, path = ["a"], value = ["keyb_name", "keyc_name"]}
%% #cfg{node_type = list_key, path = ["a", {"b", "c"}], value = ["keyb_name", "keyc_name"]}
%% #cfg{node_type = leaf, path = ["a", {"b", "c"}, "keyb_name"], value = "b"}
%% #cfg{node_type = leaf, path = ["a", {"b", "c"}, "keyc_name"], value = "c"}
%% #cfg{node_type = leaf, path = ["a", {"b", "c"}, "name"],     value = "Val"}
%%
%% The path we get here is a list of schema items, normally not
%% including any values. A few options to geth the list key values to here:
%%
%% 1. Have cfg_lookup create multiple entries for all the parts of a list entry
%% 2. Include the values of list keys in the #cfg_schema{node_type=list} item
%% 3. Hm
%%
%% Insert a single entry in the database.
-spec insert_path_items(permanent | {ets, ets:tid()}, map_path(), term()) -> ok.
insert_path_items(Db, Is, Value) ->
    insert_path_items(Db, Is, Value, []).

-spec insert_path_items(permanent | {ets, ets:tid()}, map_path(), term(), list()) -> ok.
insert_path_items(Db, [I | Is], Value, Path) ->
    case I of
        #{role := schema, node_type := container, name := Name} ->
            FullPath = Path ++ [Name],
            Cfg = schema_to_cfg(I, FullPath, undefined),
            write(Db, Cfg),
            insert_path_items(Db, Is, Value, FullPath);

        %% List items
        #{role := schema, node_type := list, name := Name,
          key_names := Keys, key_values := KVs} ->
            FullPath = Path ++ [Name],
            Key = list_to_tuple(KVs),
            ListItemCfg = schema_to_cfg(I, FullPath, Keys),

            %% Create a top level entry for the list schema itself
            write(Db, ListItemCfg),
            ListItemsPath = FullPath ++ [Key],

            %% Create an entry for the list key
            ListKeyCfg = schema_list_key_to_cfg(I, ListItemsPath, Key),
            write(Db, ListKeyCfg),

            %% Create a leaf entry for each list key
            insert_list_keys(Db, ListItemsPath, I),
            insert_path_items(Db, Is, Value, ListItemsPath);

        %% Leafs of both kinds
        #{role := schema, node_type := Leaf, name := Name}
          when ?is_leaf(Leaf) ->
            FullPath = Path ++ [Name],
            Cfg = schema_to_cfg(I, FullPath, Value),
            write(Db, Cfg)
    end.

-spec insert_list_keys(permanent | {ets, ets:tid()}, item_path(), map_node()) -> ok.
insert_list_keys(Db, Path, #{role := schema, key_names := KeyNames,
                             key_values := KeyValues}) ->
    NVPairs = lists:zip(KeyNames, KeyValues),
    lists:foreach(fun({Name, Value}) ->
                          Cfg = #cfg{name = Name,
                                     path = Path ++ [Name],
                                     node_type = leaf,
                                     value = Value},
                          write(Db, Cfg)
                  end, NVPairs).

%% Traverse a path to be inserted in the Db and check whether any
%% existing nodes have a conflicting type.
check_conflict(Db, Is, Value) ->
    ?DBG("Check Conflict ~p~n",[Is]),
    check_conflict(Db, Is, Value, []).

check_conflict(Db, [I|Is], Value, Path) ->
    case I of
        #{role := schema, node_type := container, name := Name} ->
            FullPath = Path ++ [Name],
            case read(Db, FullPath) of
                [] ->
                    ok;
                [#cfg{node_type = container, name = Name}] ->
                    check_conflict(Db, Is, Value, FullPath);
                [#cfg{}] ->
                    {error, "schema conflict"}
            end;
        #{role := schema, node_type := list, name := Name,
          key_values := KVs} ->
            FullPath = Path ++ [Name],
            case read(Db, FullPath) of
                [] ->
                    ok;
                [#cfg{node_type = list, name = Name}] ->
                    ?DBG("List exists ~p~n",[FullPath]),
                    ListItemPath = FullPath ++ [list_to_tuple(KVs)],
                    ?DBG("Check List keys ~p~n",[ListItemPath]),
                    case read(Db, ListItemPath) of
                        [] ->
                            check_conflict(Db, Is, Value);
                        [#cfg{node_type = list_key}] ->
                            case validate_set_list(Db, ListItemPath, I) of
                                ok ->
                                    check_conflict(Db, Is, Value, ListItemPath);
                                {error, Reason} ->
                                    {error, Reason}
                            end;
                        [#cfg{}] ->
                            {error, "list item not marked as list"}
                    end;
                [#cfg{}] ->
                    {error, "list item schema conflict"}
            end;
        #{role := schema, node_type := Leaf, name := Name} when ?is_leaf(Leaf) ->
            FullPath = Path ++ [Name],
            case read(Db, FullPath) of
                [] ->
                    ok;
                [#cfg{node_type = Leaf}] when ?is_leaf(Leaf) ->
                    ok;
                [_] ->
                    {error, "leaf item schema conflict"}
            end
    end.

%% Delete a single list entry along with all nodes leading up to it that are
%% not still used by another list item or child
%%
-spec delete_path_items(permanent | {ets, ets:tid()}, map_path()) -> ok.
delete_path_items(Db, Path) ->
    %% Steps:
    %% 1. delete all children of the list item - its leaves
    %% 2. delete the list_key special node
    %% 3. delete the list node if this is the last list entry
    %% 4. delete all parent nodes that no longer have any children
    delete_path_items_all(Db, lists:reverse(Path)).

-spec delete_path_items_all(permanent | {ets, ets:tid()}, map_path()) -> ok.
delete_path_items_all(_Db, []) ->
    ok;
delete_path_items_all(Db, [I|Is]) ->
    case I of
        #{role := schema, node_type := list, path := Path, key_values := KVs} ->
            ListItemPath = Path ++ [list_to_tuple(KVs)],
            Pattern = #cfg{path = ListItemPath ++ '_', _ = '_'},
            ok = match_delete(Db, Pattern),
            %% See if we can also delete the list node, Check if there are any remaining list items
            ListNodePattern = #cfg{path = Path ++ '_', node_type = list_key, _ = '_'},
            case match(Db, ListNodePattern) of
                [] ->
                    ok = delete(Db, Path);
                [_|_] ->
                    ok
            end,
            delete_path_items_all(Db, Is);
        #{role := schema, node_type := container, path := Path} ->
            Pattern = #cfg{path = Path ++ '_', _ = '_'},
            case match(Db, Pattern) of
                [] ->
                    ok;
                [_] ->
                    %% Nothing below this point, delete the node and carry on up the tree
                    delete(Db, Path),
                    delete_path_items_all(Db, Is);
                [_|_] ->
                    ok
            end;
        _Else ->
            ok
    end.


%% Ensure the entries for the list keys exist. We already proved there
%% is an entry for the list item itself, so these leafs *must*
%% exist. Work checking though.
validate_set_list(Db, FullPath, #{key_names := KeyNames,
                                  key_values := KeyValues}) ->
    NVPairs = lists:zip(KeyNames, KeyValues),
    validate_set_list_keys(Db, FullPath, NVPairs).

validate_set_list_keys(_Db, _FullPath, []) ->
    ok;
validate_set_list_keys(Db, Path, [{Name, _Value}|Ks]) ->
    FullPath = Path ++ [Name],
    case read(Db, FullPath) of
        [] ->
            ?DBG("MISSING list key ~p~n",[FullPath]),
            {error, "Missing list key entry"};
        [#cfg{node_type = leaf}] ->
            validate_set_list_keys(Db, Path, Ks);
        [_] ->
            {error, "Invalid existing list key entry"}
    end.

%% Create a cfg record sutable to insert in the database from the schema
%% record and the full path and value.
schema_to_cfg(#{role := schema,
                node_type := NodeType, name := Name}, Path, Value) ->
    #cfg{node_type = NodeType,
         name = Name,
         path = Path,
         value = Value
        }.

schema_list_key_to_cfg(#{role := schema, key_names := KNs}, Path, Key) ->
    #cfg{node_type = list_key,
         name = Key,
         path = Path,
         value = KNs
        }.

-spec schema_path_to_key(schema_path()) -> item_path().
schema_path_to_key(Path) ->
    lists:foldl(fun(#{role := schema, node_type := list, key_values := Keys, name := Name}, Acc) when length(Keys) > 0 ->
                        Acc ++ [Name, list_to_tuple(Keys)];
                   (#{role := schema, name := Name}, Acc) ->
                        Acc ++ [Name]
                end, [], Path).

%%-------------------------------------------------------------------
%% @doc Construct a tree of configuration items from a flat list of
%% #cfg{} records such as might be extracted from the configuration
%% database.
%%
%% Container nodes have their value field set to a list of child nodes
%% @end
%% -------------------------------------------------------------------
-spec cfg_list_to_tree([#cfg{}]) -> [#cfg{}].
cfg_list_to_tree(Cfgs) ->
    cfg_list_to_tree(Cfgs, mgmtd_zntrees:root(root)).

cfg_list_to_tree([Cfg|Cfgs], Z) ->
    Z1 = zntree_insert_item(Cfg, mgmtd_zntrees:children(Z)),
    cfg_list_to_tree(Cfgs, Z1);
cfg_list_to_tree([], Z) ->
    %% Finally extract a simple cfg tree from the zntree, skipping root
    zntree_to_cfg_tree(mgmtd_zntrees:children(Z)).

    %% Insert an item in the zntree. Z points to the children of the root node
zntree_insert_item(#cfg{path = Path} = Cfg, Z) ->
    Z1 = zntree_node_at_path(Path, Z),
    Z2 = mgmtd_zntrees:insert(Cfg, Z1),
    %% Z2 now points to our new node. Point it back to the root node ready
    %% for another item to be inserted
    zntree_root(Z2).

zntree_node_at_path([_Path], Z) ->
    %% Z now points to the same level as Path
    Z;
zntree_node_at_path([P|Ps], Z) ->
    Z1 = zntree_search(P, Z),
    Z2 = mgmtd_zntrees:children(Z1),
    zntree_node_at_path(Ps, Z2).

%% Horizontal search left to right. Node must exist
zntree_search(P, Z) ->
    case mgmtd_zntrees:value(Z) of
        #cfg{name = P} ->
            Z;
        #cfg{} ->
            zntree_search(P, mgmtd_zntrees:right(Z))
    end.

zntree_root(Z) ->
    Z1 = mgmtd_zntrees:parent(Z),
    case mgmtd_zntrees:value(Z1) of
        root ->
            Z1;
        _ ->
            zntree_root(Z1)
    end.

%% Convert the zntree of our cfg records into a tree of #cfg{} records
-spec zntree_to_cfg_tree(mgmtd_zntrees:zntree()) -> list().
zntree_to_cfg_tree(Zntree) ->
    %% ?DBG("zn:~p~n",[Zntree]),
    zntree_to_cfg_tree(Zntree, []).

zntree_to_cfg_tree({_Thread, {_Left, _Right = []}}, Acc) ->
    Acc;
zntree_to_cfg_tree(Z, Acc) ->
    case mgmtd_zntrees:value(Z) of
        #cfg{node_type = Leaf} = Cfg when Leaf == leaf; Leaf == leaf_list ->
            zntree_to_cfg_tree(mgmtd_zntrees:right(Z), [Cfg | Acc]);
        #cfg{node_type = NT} = Cfg when NT == container; NT == list;
                                        NT == list_key ->
            Acc1 = [Cfg#cfg{value =
                                zntree_to_cfg_tree(mgmtd_zntrees:children(Z), [])}
                   | Acc],
            zntree_to_cfg_tree(mgmtd_zntrees:right(Z), Acc1)
    end.

simplify_tree([#cfg{node_type = container, name = Name, value = Children} |Ts]) ->
    [{Name, simplify_tree(Children)}|simplify_tree(Ts)];
simplify_tree([#cfg{node_type = list, name = Name, value = Children} |Ts]) ->
    [{Name, simplify_tree(Children)}|simplify_tree(Ts)];
simplify_tree([#cfg{node_type = list_key, name = Name, value = Children} |Ts]) ->
    [{Name, simplify_tree(Children)}|simplify_tree(Ts)];
simplify_tree([#cfg{name = Name, value = Value} | Cfgs]) ->
    [{Name, {value, Value}}|simplify_tree(Cfgs)];
simplify_tree([]) ->
    [].


