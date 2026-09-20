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

-export([init/2, remove_db/2, transaction/1, copy_to_ets/0, replace_all/1]).

-export([insert_path_items/3, check_conflict/3, delete_path_items/2,
         move_item/3]).

-export([cfg_list_to_tree/1, simplify_tree/1, schema_path_to_key/1]).

%% Dirty operations towards current config database
-export([lookup/1, lookup/2, list_keys/1, list_keys/2, list_keys/3,
         match_object/1, match_object/2]).

%%--------------------------------------------------------------------
%% Wrapper functions around the operations towards the chosen storage
%% engine
%%--------------------------------------------------------------------

%% @doc Called once at startup so the chosen database backend can create tables.
%%
%% When the main store does not yet exist, a separately configured
%% startup store (`{startup, [{backend, sys_config}, {file, Path}]}`
%% in `Opts` or application env `startup`) is read once and written
%% into the new main store.
%%
%% After the store is open, `mgmtd_cfg_upgrade` walks existing rows
%% against the currently loaded schema (deleted nodes, type coercion,
%% list-key changes). Missing schema nodes are not inserted.
-spec init(file:filename(), proplists:proplist()) -> ok | {error, term()}.
init(DbLocation, Opts) ->
    Backend = proplists:get_value(backend, Opts, mnesia),
    BackendMod = backend_mod(Backend),
    case BackendMod:init(DbLocation, Opts) of
        {ok, Created} when Created =:= new; Created =:= existing ->
            finish_init(DbLocation, Opts, BackendMod, Created);
        ok ->
            finish_init(DbLocation, Opts, BackendMod, existing);
        {error, _} = Err ->
            Err
    end.

finish_init(DbLocation, Opts, BackendMod, Created) ->
    ets:insert(mgmtd_meta, {backend, BackendMod}),
    true = ets:insert(mgmtd_meta, {db_location, DbLocation}),
    case mgmtd_cfg_rollback:init(DbLocation, rollback_count(Opts)) of
        ok ->
            after_open(Created, DbLocation, Opts);
        {error, _} = RollbackErr ->
            RollbackErr
    end.

after_open(Created, DbLocation, Opts) ->
    case mgmtd_cfg_startup:maybe_load(Created, Opts) of
        ok ->
            case mgmtd_cfg_upgrade:maybe_upgrade() of
                ok ->
                    ok;
                {error, _} = UpgErr ->
                    abort_open(Created, DbLocation, Opts, UpgErr)
            end;
        {error, _} = SeedErr ->
            abort_open(Created, DbLocation, Opts, SeedErr)
    end.

abort_open(new, DbLocation, Opts, Err) ->
    _ = remove_db(DbLocation, Opts),
    Err;
abort_open(existing, _DbLocation, _Opts, Err) ->
    Err.

remove_db(DbLocation, Opts) ->
    Backend = proplists:get_value(backend, Opts, mnesia),
    BackendMod = backend_mod(Backend),
    ok = BackendMod:remove_db(DbLocation, Opts),
    try ets:delete(mgmtd_meta, db_location) catch error:badarg -> true end,
    try ets:delete(mgmtd_meta, backend) catch error:badarg -> true end,
    ok.

transaction(Fun) when is_function(Fun) ->
    BackendMod = backend(),
    BackendMod:transaction(Fun).

-spec read(permanent | {ets, ets:table()}, item_path()) -> list().
read(permanent, Key) ->
    BackendMod = backend(),
    BackendMod:read(Key);
read({ets, Ets}, Path) ->
    ets:lookup(Ets, Path).

-spec write(permanent | {ets, ets:table()}, #cfg{}) -> ok.
write(permanent, #cfg{} = Cfg) ->
    BackendMod = backend(),
    BackendMod:write(Cfg);
write({ets, Ets}, #cfg{} = Cfg) ->
    to_ok(ets:insert(Ets, Cfg)).

-spec delete(permanent | {ets, ets:table()}, item_path()) -> ok.
delete(permanent, Path) ->
    BackendMod = backend(),
    BackendMod:delete(Path);
delete({ets, Ets}, Path) ->
    to_ok(ets:delete(Ets, Path)).

lookup(Path) ->
    lookup(permanent, Path).

-spec lookup(permanent | {ets, ets:table()}, item_path()) -> list().
lookup(permanent, Path) ->
    BackendMod = backend(),
    BackendMod:lookup(Path);
lookup({ets, Ets}, Path) ->
    ets:lookup(Ets, Path).

match_delete(permanent, Pattern) ->
    BackendMod = backend(),
    BackendMod:match_delete(Pattern);
match_delete({ets, Ets}, Pattern) ->
    to_ok(ets:match_delete(Ets, Pattern)).

%% Transactional match (used inside backend:transaction/1 on commit).
match(permanent, Pattern) ->
    BackendMod = backend(),
    BackendMod:match(Pattern);
match({ets, Ets}, Pattern) ->
    ets:match_object(Ets, Pattern).

%% Dirty / lock-free match of #cfg{} records. Used for operational-mode
%% show, which has no txn and must not enter a backend transaction.
-spec match_object(term()) -> [#cfg{}].
match_object(Pattern) ->
    match_object(permanent, Pattern).

-spec match_object(permanent | {ets, ets:table()}, term()) -> [#cfg{}].
match_object(permanent, Pattern) ->
    BackendMod = backend(),
    cfg_rows(BackendMod:match_object(Pattern));
match_object({ets, Ets}, Pattern) ->
    cfg_rows(ets:match_object(Ets, ets_pattern(Pattern))).

-spec ets_pattern(eqwalizer:dynamic()) -> ets:match_pattern().
ets_pattern(Pattern) -> Pattern.

-spec cfg_rows(eqwalizer:dynamic()) -> [#cfg{}].
cfg_rows(Rows) -> Rows.

list_keys(Path) ->
    list_keys(Path, '$1').

list_keys(Path, Pattern) ->
    list_keys(permanent, Path, Pattern).

list_keys(permanent, Path, Pattern) ->
    BackendMod = backend(),
    order_keys(permanent, Path, Pattern, BackendMod:select(Path, Pattern));
list_keys({ets, Ets}, Path, Pattern) ->
    Raw = ets:select(Ets, [{#cfg{path = mgmtd_schema:ets_pat(Path ++ [Pattern]), _ = mgmtd_schema:ets_pat('_')}, [], ['$1']}]),
    order_keys({ets, Ets}, Path, Pattern, Raw).

copy_to_ets() ->
    BackendMod = backend(),
    BackendMod:copy_to_ets().

%% Replace every `#cfg{}` row with `Rows`. Must run inside `transaction/1`.
-spec replace_all([#cfg{}]) -> ok.
replace_all(Rows) when is_list(Rows) ->
    match_delete(permanent, #cfg{_ = mgmtd_schema:ets_pat('_')}),
    lists:foreach(fun(#cfg{} = Cfg) -> write(permanent, Cfg) end, Rows),
    ok.

rollback_count(Opts) ->
    case proplists:get_value(rollback, Opts, undefined) of
        undefined ->
            env_rollback_count();
        N when is_integer(N), N >= 0 ->
            N;
        Props when is_list(Props) ->
            case proplists:get_value(count, Props, 10) of
                N when is_integer(N), N >= 0 -> N;
                _ -> 10
            end;
        _ ->
            10
    end.

env_rollback_count() ->
    case application:get_env(mgmtd, rollback, []) of
        N when is_integer(N), N >= 0 ->
            N;
        Props when is_list(Props) ->
            case proplists:get_value(count, Props, 10) of
                N when is_integer(N), N >= 0 -> N;
                _ -> 10
            end;
        _ ->
            10
    end.

backend() ->
    case ets:lookup(mgmtd_meta, backend) of
        [{_, Mod}] ->
            Mod;
        [] ->
            error(db_not_initialized)
    end.

backend_mod(mnesia) -> mgmtd_cfg_db_mnesia;
backend_mod(sys_config) -> mgmtd_cfg_db_sys_config;
backend_mod(json) -> mgmtd_cfg_db_json.

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
-spec insert_path_items(permanent | {ets, ets:table()}, map_path(), term()) -> ok.
insert_path_items(Db, Is, Value) ->
    insert_path_items(Db, Is, Value, []).

-spec insert_path_items(permanent | {ets, ets:table()}, map_path(), term(), item_path()) -> ok.
insert_path_items(_Db, [], _Value, _Path) ->
    ok;
insert_path_items(Db, [I | Is], Value, Path) ->
    case I of
        #{role := schema, node_type := container, name := Name} ->
            FullPath = Path ++ [Name],
            Cfg = schema_to_cfg(I, FullPath, undefined),
            write(Db, Cfg),
            insert_path_items(Db, Is, Value, FullPath);

        %% List items
        #{role := schema, node_type := list, name := Name,
          key_names := Keys, key_values := KVs} = I ->
            FullPath = Path ++ [Name],
            Key = list_to_tuple(KVs),
            write_list_node(Db, I, FullPath, Name, Keys, Key),
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

-spec insert_list_keys(permanent | {ets, ets:table()}, item_path(), map_node()) -> ok.
insert_list_keys(Db, Path, #{role := schema, key_names := KeyNames} = I) ->
    %% key_values are the path identity (CLI tokens). Prefer schema-cast
    %% key_internal_values so key leaves match their declared types.
    KeyValues = case I of
                    #{key_internal_values := Internal} -> Internal;
                    #{key_values := Vals} -> Vals
                end,
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

check_conflict(_Db, [], _Value, _Path) ->
    ok;
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
-spec delete_path_items(permanent | {ets, ets:table()}, map_path()) -> ok.
delete_path_items(Db, Path) ->
    %% Steps:
    %% 1. delete all children of the list item - its leaves
    %% 2. delete the list_key special node
    %% 3. delete the list node if this is the last list entry
    %% 4. delete all parent nodes that no longer have any children
    delete_path_items_all(Db, lists:reverse(Path)).

-spec delete_path_items_all(permanent | {ets, ets:table()}, map_path()) -> ok.
delete_path_items_all(_Db, []) ->
    ok;
delete_path_items_all(Db, [I|Is]) ->
    case I of
        #{role := schema, node_type := list, path := Path, key_values := KVs} ->
            Key = list_to_tuple(KVs),
            ListItemPath = Path ++ [Key],
            Pattern = #cfg{path = mgmtd_schema:ets_tail(ListItemPath), _ = mgmtd_schema:ets_pat('_')},
            ok = match_delete(Db, Pattern),
            %% See if we can also delete the list node, Check if there are any remaining list items
            ListNodePattern = #cfg{path = mgmtd_schema:ets_tail(Path), node_type = list_key, _ = mgmtd_schema:ets_pat('_')},
            case match(Db, ListNodePattern) of
                [] ->
                    ok = delete(Db, Path);
                [_|_] ->
                    remove_from_order(Db, Path, Key)
            end,
            delete_path_items_all(Db, Is);
        #{role := schema, node_type := container, path := Path} ->
            Pattern = #cfg{path = mgmtd_schema:ets_tail(Path), _ = mgmtd_schema:ets_pat('_')},
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

-spec schema_path_to_key(map_path()) -> item_path().
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
    Orders = maps:from_list(
               [{P, Ks} || #cfg{node_type = list, path = P, value = {ordered, Ks}} <- Cfgs]),
    reorder_cfg_tree(cfg_list_to_tree(Cfgs, mgmtd_zntrees:root(root)), Orders).

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
simplify_tree([#cfg{node_type = leaf_list, name = Name, value = Value} | Cfgs]) ->
    [{Name, {leaf_list, Value}}|simplify_tree(Cfgs)];
simplify_tree([#cfg{node_type = leaf, name = Name, value = Value} | Cfgs]) ->
    [{Name, {value, Value}}|simplify_tree(Cfgs)];
simplify_tree([]) ->
    [].

%%--------------------------------------------------------------------
%% ordered-by user
%%
%% User order is stored on the list node's `#cfg.value` as
%% `{ordered, [KeyTuple, ...]}`. System-ordered lists keep `value` as
%% the key names (legacy) and are returned in backend path order.
%%--------------------------------------------------------------------

-spec move_item(permanent | {ets, ets:table()}, item_path(),
                first | last | {before, term()} | {'after', term()}) ->
          {ok, list()} | {error, term()}.
move_item(Db, ItemPath, Where) ->
    case move_target(ItemPath) of
        {error, _} = Err ->
            Err;
        {list, ListPath, Key} ->
            move_list_item(Db, ListPath, Key, Where);
        {leaf_list, Path, Val} ->
            move_leaf_list(Db, Path, Val, Where)
    end.

write_list_node(Db, Schema, FullPath, Name, KeyNames, Key) ->
    case mgmtd_schema:ordered_by(Schema) of
        user ->
            NewOrder = case read(Db, FullPath) of
                           [#cfg{value = {ordered, Keys}}] ->
                               place_last(Keys, Key);
                           [#cfg{node_type = list}] ->
                               place_last(raw_child_keys(Db, FullPath), Key);
                           [] ->
                               [Key]
                       end,
            write(Db, #cfg{node_type = list, name = Name, path = FullPath,
                           value = {ordered, NewOrder}});
        system ->
            write(Db, #cfg{node_type = list, name = Name, path = FullPath,
                           value = KeyNames})
    end.

remove_from_order(Db, ListPath, Key) ->
    case read(Db, ListPath) of
        [#cfg{value = {ordered, Keys}} = Cfg] ->
            write(Db, Cfg#cfg{value = {ordered, lists:delete(Key, Keys)}});
        _ ->
            ok
    end.

order_keys(Db, Path, Pattern, Raw) ->
    case lookup(Db, Path) of
        [#cfg{node_type = list, value = {ordered, Order}}] ->
            apply_order(Order, Pattern, Raw);
        _ ->
            Raw
    end.

%% `Raw` is whatever `select` bound: full key tuples for `'$1'`, or the
%% `'$1'` element for a tuple match (`{'$1'}` from ecli completion).
apply_order(Order, Pattern, Raw) ->
    Set = maps:from_list([{V, true} || V <- Raw]),
    Ordered = [V || K <- Order,
                    {true, V} <- [match_key(Pattern, K)],
                    maps:is_key(V, Set)],
    Extra = [V || V <- Raw, not lists:member(V, Ordered)],
    Ordered ++ Extra.

%% Same contract as the ecli list-key match: `'$1'` is the full key,
%% a tuple binds `'$1'` to that element.
match_key('$1', Key) ->
    {true, Key};
match_key(Pattern, Key)
  when is_tuple(Pattern), is_tuple(Key),
       tuple_size(Pattern) =:= tuple_size(Key) ->
    match_elements(tuple_to_list(Pattern), tuple_to_list(Key), undefined);
match_key(_, _) ->
    false.

match_elements(['$1' | Ps], [V | Ks], undefined) ->
    match_elements(Ps, Ks, V);
match_elements(['_' | Ps], [_ | Ks], Acc) ->
    match_elements(Ps, Ks, Acc);
match_elements([P | Ps], [P | Ks], Acc) ->
    match_elements(Ps, Ks, Acc);
match_elements([], [], Acc) ->
    {true, Acc};
match_elements(_, _, _) ->
    false.

raw_child_keys(Db, Path) ->
    Pattern = #cfg{path = mgmtd_schema:ets_tail(Path),
                   node_type = list_key,
                   _ = mgmtd_schema:ets_pat('_')},
    [lists:last(P) || #cfg{path = P} <- match(Db, Pattern)].

move_target(ItemPath) ->
    move_target_rev(lists:reverse(ItemPath)).

move_target_rev([Key | Rest]) when is_tuple(Key) ->
    Parent = lists:reverse(Rest),
    case mgmtd_schema:lookup(Parent) of
        #{node_type := list} = Schema ->
            case mgmtd_schema:ordered_by(Schema) of
                user -> {list, Parent, Key};
                system -> {error, {not_user_ordered, Parent}}
            end;
        #{node_type := leaf_list} = Schema ->
            case mgmtd_schema:ordered_by(Schema) of
                user ->
                    Val = case Key of {V} -> V; V -> V end,
                    {leaf_list, Parent, Val};
                system ->
                    {error, {not_user_ordered, Parent}}
            end;
        _ ->
            move_target_rev(Rest)
    end;
move_target_rev([_ | Rest]) ->
    move_target_rev(Rest);
move_target_rev([]) ->
    {error, not_ordered_list}.

move_list_item(Db, ListPath, Key, Where) ->
    case read(Db, ListPath) of
        [#cfg{value = {ordered, Keys}} = Cfg] ->
            case lists:member(Key, Keys) of
                false ->
                    {error, {list_entry_not_found, Key}};
                true ->
                    case place_at(Keys, Key, Where) of
                        {ok, New} ->
                            write(Db, Cfg#cfg{value = {ordered, New}}),
                            {ok, New};
                        {error, _} = Err ->
                            Err
                    end
            end;
        _ ->
            {error, {list_entry_not_found, Key}}
    end.

move_leaf_list(Db, Path, Val, Where) ->
    case read(Db, Path) of
        [#cfg{node_type = leaf_list, value = Vals} = Cfg] when is_list(Vals) ->
            case lists:member(Val, Vals) of
                false ->
                    {error, {list_entry_not_found, Val}};
                true ->
                    case place_at(Vals, Val, Where) of
                        {ok, New} ->
                            write(Db, Cfg#cfg{value = New}),
                            {ok, New};
                        {error, _} = Err ->
                            Err
                    end
            end;
        _ ->
            {error, {list_entry_not_found, Val}}
    end.

place_last(Keys, Key) ->
    case lists:member(Key, Keys) of
        true -> Keys;
        false -> Keys ++ [Key]
    end.

place_at(Keys, Key, first) ->
    {ok, [Key | lists:delete(Key, Keys)]};
place_at(Keys, Key, last) ->
    {ok, lists:delete(Key, Keys) ++ [Key]};
place_at(Keys, Key, {before, Point}) when Key =:= Point ->
    {ok, Keys};
place_at(Keys, Key, {'after', Point}) when Key =:= Point ->
    {ok, Keys};
place_at(Keys, Key, {before, Point}) ->
    insert_relative(lists:delete(Key, Keys), Key, Point, before);
place_at(Keys, Key, {'after', Point}) ->
    insert_relative(lists:delete(Key, Keys), Key, Point, 'after');
place_at(_Keys, _Key, Other) ->
    {error, {invalid_insert, Other}}.

insert_relative(Keys, Key, Point, Side) ->
    case lists:splitwith(fun(K) -> K =/= Point end, Keys) of
        {_, []} ->
            {error, {point_not_found, Point}};
        {Pre, [P | Post]} when Side =:= before ->
            {ok, Pre ++ [Key, P | Post]};
        {Pre, [P | Post]} when Side =:= 'after' ->
            {ok, Pre ++ [P, Key | Post]}
    end.

reorder_cfg_tree(Nodes, Orders) ->
    [reorder_cfg_node(N, Orders) || N <- Nodes].

reorder_cfg_node(#cfg{node_type = list, path = Path, value = Children} = C, Orders)
  when is_list(Children) ->
    Kids = reorder_cfg_tree(Children, Orders),
    C#cfg{value = sort_list_key_rows(Kids, maps:get(Path, Orders, undefined))};
reorder_cfg_node(#cfg{node_type = NT, value = Children} = C, Orders)
  when (NT =:= container orelse NT =:= list_key), is_list(Children) ->
    C#cfg{value = reorder_cfg_tree(Children, Orders)};
reorder_cfg_node(C, _Orders) ->
    C.

sort_list_key_rows(Kids, undefined) ->
    Kids;
sort_list_key_rows(Kids, Order) ->
    ByName = maps:from_list([{N, K} || #cfg{name = N} = K <- Kids]),
    Ordered = [maps:get(K, ByName) || K <- Order, maps:is_key(K, ByName)],
    Extra = [K || #cfg{name = N} = K <- Kids, not lists:member(N, Order)],
    Ordered ++ Extra.


