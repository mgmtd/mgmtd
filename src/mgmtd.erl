%%%-------------------------------------------------------------------
%% @doc mgmtd public API
%% Global repository for management information schemas
%% @end
%%%-------------------------------------------------------------------
-module(mgmtd).

-export([start/0]).

-export([subscribe/2,
         load_json_schema/1, load_json_schema/2,
         load_function_schema/1, load_function_schema/2,
         remove_schema/0, remove_schema/1,
         registered_schemas/0,
         load_config_db/1]).
%% Transaction API
-export([txn_new/0, txn_exit/1, txn_set/2, txn_delete/2, txn_show/2, txn_commit/1]).
%% Schema API
-export([schema_children/2, schema_children/3]).

-export([lookup/1, lookup/2]).
%% Data Callback API towards included configuration database
-export([list_keys/3]).

-include("../include/mgmtd.hrl").
-include("mgmtd_schema.hrl").

start() ->
    application:start(mgmtd).

%% @doc Load the json schema in File.
%% Call this function for each json schema file that makes up the
%% whole schema of the system.
%% This step must be completed before loading the configuration database.
%%
%% JSON schema doesn't have a native way to mark parts of the tree as
%% configuration or operational data. If both types are needed store them
%% in separate files and load them independently with the
%% appropriate option.
%%
%% For operational data provide a module that implements the
%% `mgmtd_provider` behaviour (`get_value` / `get_first` / `get_next`).
%% Set it as `data_callback` on the function-schema node (inherited by
%% descendants) or as `callback => Module` at JSON load time.
%%
%% Options:
%% config => true | false (default false)
%% callback => Module::atom()    %% operational-data provider (mgmtd_provider)
%% namespace => Prefix::atom()   %% CLI / sys.config identity; default is 'default'
%% prefix => Prefix::atom()      %% optional; if omitted, namespace is the prefix
%%                               %% For YANG later: namespace is a URI string and
%%                               %% prefix is required.

load_json_schema(File) ->
    mgmtd_schema:load_json_schema_file(File, #{config => false}).
load_json_schema(File, Opts) when is_map(Opts) ->
    mgmtd_schema:load_json_schema_file(File, Opts).

remove_schema() ->
    mgmtd_schema:remove_schema().

remove_schema(Ns) ->
    mgmtd_schema:remove_schema(Ns).

%% @doc Load a schema defined in Erlang code.
%%
load_function_schema(Fun) ->
    mgmtd_schema:load_function_schema(Fun, #{}).

load_function_schema(Fun, Opts) ->
    mgmtd_schema:load_function_schema(Fun, Opts).

registered_schemas() ->
    mgmtd_schema:registered_schemas().

%% @doc Load the configuration database.
%% Call this function after loading the schema(s) early
%% during startup of your system to enable
%% access to configuration and enable subscriptions.
%% The configuration database needs write access to the
%% directory at DirPath where it stores its files
load_config_db(DirPath) ->
    %% Stuff to do here:
    %% 1. read the config
    %% 2. check it against the loaded schema
    ok.

%% @doc Get the item at Path in the tree.
%% For leaf nodes returns the value of the leaf
%% For list nodes returns the list keys
%% For container nodes returns the names of the child nodes
get_item(Path) ->
    {ok, value}.

%%--------------------------------------------------------------------
%% Configuration session transaction API
%%
%%
%% @doc Long lived transaction started e.g. when user enters configuration
%% mode in the CLI. Creates a copy of the configuration for making
%% transaction local changes
%% --------------------------------------------------------------------
-spec txn_new() -> mgmtd_cfg_txn:txn().
txn_new() ->
    mgmtd_cfg_server:new_txn().

txn_exit(Txn) ->
    mgmtd_cfg_server:exit_txn(Txn).

txn_set(Txn, SchemaPath) ->
    %% io:format(user, "Setting path ~p in Txn ~p~n", [pp_path(SchemaPath), Txn]),
    Operations = path_to_operations(SchemaPath),
    %% io:format(user, "Setting path ~p in Txn ~p~n", [pp_path(SchemaPath), Operations]),
    txn_set_operations(Txn, Operations).

txn_set_operations(Txn, []) ->
    {ok, Txn};
txn_set_operations(Txn, [{Path, Value} | Ops]) ->
    case mgmtd_cfg_txn:set(Txn, Path, Value) of
        {ok, Txn1} ->
            txn_set_operations(Txn1, Ops);
        {error, _Err} = Err ->
            Err
    end.

txn_delete(Txn, SchemaPath) ->
    %% io:format(user, "Deleting path ~p in Txn ~p~n", [pp_path(SchemaPath), Txn]),
    mgmtd_cfg_txn:delete(Txn, SchemaPath).

txn_show(Txn, SchemaPath) ->
    ?DBG("TXN SHOW ~p~n", [SchemaPath]),
    Tree = mgmtd_cfg_txn:get_tree(Txn, SchemaPath),
    {ok, Tree}.

txn_commit(Txn) ->
    mgmtd_cfg_server:commit(Txn).

%% Built in set of data_callback API callbacks when using the
%% built in configuration database. Operational lists are served by
%% the schema `data_callback` module (`get_first` / `get_next`).
list_keys(Txn, ListItemPath, ListKeyMatch) ->
    case mgmtd_provider:mod(ListItemPath) of
        undefined ->
            case mgmtd_schema:lookup(ListItemPath) of
                #{config := false} ->
                    [];
                _ ->
                    mgmtd_cfg_txn:list_keys(Txn, ListItemPath, ListKeyMatch)
            end;
        Mod ->
            case mgmtd_provider:list_keys(Mod, ListItemPath, ListKeyMatch) of
                {ok, Keys} ->
                    Keys;
                {error, _} ->
                    []
            end
    end.

%% @doc Subscribe to configuration change messages.
%%
%% An initial snapshot is sent immediately, then a message after each
%% successful commit that changes anything in the subscribed subtree:
%%
%%     {config_change, Ref, Ops}
%%
%% `Ops` is a list of changes to apply, deletes first, then adds, then
%% leaf values:
%%
%%     {delete, ListPath, ListKey}
%%     {add,    ListPath, ListKey}
%%     {set,    Path,     Value}
%%
%% A container or list path includes every change under it. A path that
%% names a list instance only includes that instance. A leaf path that
%% omits the list instance (e.g. `["server", "servers", "port"]`)
%% matches that leaf in every list item.
subscribe(Path, Pid) ->
    mgmtd_cfg_server:subscribe(Path, Pid).

%% @doc get the list of child nodes in the schema at path
%% -spec schema_children([atom()], set | show) -> [%{}].
schema_children(Path, CmdType) ->
    mgmtd_schema:children(Path, CmdType).

schema_children(Ns, Path, CmdType) ->
    mgmtd_schema:children(Ns, Path, CmdType).

%% Lookup API
%% @doc Read the current value at path, outside a transaction.
%% Configuration leaves come from the config DB (or the schema default).
%% Operational leaves (`config = false`) are read from the node's
%% `data_callback` module (`mgmtd_provider:get_value/1`).
%% A list path returns the list keys; a container or a full path to a
%% list item returns the names of the child nodes.

-spec lookup(item_path()) -> {ok, any()} | {error, term()}.
lookup(Path) ->
    {Ns, Local} = mgmtd_schema:split_item_path(Path),
    lookup_at(Ns, Local, Path).

-spec lookup(ns(), item_path()) -> {ok, any()} | {error, term()}.
lookup(Ns, Path) ->
    lookup_at(Ns, Path, mgmtd_schema:cli_path(Ns, Path)).

lookup_at(Ns, Local, DbPath) ->
    SchemaPath = lists:filter(fun(El) -> not is_tuple(El) end,
                              mgmtd_schema:cli_path(Ns, Local)),
    case mgmtd_schema:lookup(Ns, SchemaPath) of
        false ->
            {error, unknown_schema_path};
        Schema ->
            lookup_schema(Ns, SchemaPath, DbPath, Schema)
    end.

lookup_schema(Ns, SchemaPath, DbPath, #{node_type := list} = Schema) ->
    case lists:last(DbPath) of
        ListKey when is_tuple(ListKey) ->
            %% Full path to a list entry: names of the children
            Cs = mgmtd_schema:children(Ns, SchemaPath, show),
            {ok, lists:map(fun(#{name := Name}) -> Name end, Cs)};
        _ ->
            lookup_list_keys(DbPath, Schema)
    end;
lookup_schema(Ns, SchemaPath, _DbPath, #{node_type := container}) ->
    Cs = mgmtd_schema:children(Ns, SchemaPath, show),
    {ok, lists:map(fun(#{name := Name}) -> Name end, Cs)};
lookup_schema(_Ns, _SchemaPath, DbPath, #{node_type := Leaf} = Schema)
  when Leaf == leaf; Leaf == leaf_list ->
    lookup_leaf(DbPath, Schema).

lookup_list_keys(DbPath, Schema) ->
    case mgmtd_provider:mod(Schema) of
        undefined ->
            case Schema of
                #{config := false} ->
                    {error, no_data_callback};
                _ ->
                    {ok, mgmtd_cfg_db:list_keys(DbPath)}
            end;
        Mod ->
            mgmtd_provider:list_keys(Mod, DbPath, '$1')
    end.

lookup_leaf(DbPath, Schema) ->
    Default = maps:get(default, Schema, undefined),
    case mgmtd_provider:mod(Schema) of
        undefined ->
            case Schema of
                #{config := false} ->
                    {error, no_data_callback};
                _ ->
                    case mgmtd_cfg_db:lookup(DbPath) of
                        [#cfg{value = Value}] ->
                            {ok, Value};
                        [] when Default == undefined ->
                            {ok, undefined};
                        [] ->
                            {ok, Default}
                    end
            end;
        _Mod ->
            case mgmtd_provider:fetch(DbPath) of
                {ok, not_found} when Default == undefined ->
                    {ok, undefined};
                {ok, not_found} ->
                    {ok, Default};
                Other ->
                    Other
            end
    end.



schema_list_to_path(SchemaItems) ->
    lists:map(fun(#{role := schema, name := Name}) -> Name end, SchemaItems).

schema_list_to_path([#{role := schema} = Last], Acc) ->
    {Last, lists:reverse(Acc)};
schema_list_to_path([#{role := schema, name := Name} | Ss], Acc) ->
    schema_list_to_path(Ss, [Name | Acc]).

-spec pp_path(map_path()) -> mgmtd_schema:item_path().
pp_path(SchemaPath) ->
    lists:reverse(
      lists:foldl(
        fun(#{node_type := list, key_values := KeyValues, name := Name}, Acc) when is_list(KeyValues) ->
                [list_to_tuple(KeyValues), Name | Acc];
           (#{name := Name}, Acc) ->
                [Name | Acc]
        end, [], SchemaPath)).


%% A single command might set multiple parameter values
%% Generate separate set operations for each value
path_to_operations(SchemaPath) ->
    path_to_operations(SchemaPath, [], []).

%% Keys-only set: path ended on a keyed list with no leaf. Create the
%% list identity; remaining leaves can be filled in later in the txn.
path_to_operations([], [#{node_type := list, key_values := KVs} | _] = Path, [])
  when KVs =/= [] ->
    [{lists:reverse(Path), undefined}];
path_to_operations([], _, Acc) ->
    lists:reverse(Acc);
path_to_operations([#{node_type := container} = Container| Ps], Path, Acc) ->
    path_to_operations(Ps, [Container | Path], Acc);
path_to_operations([#{node_type := list} = List| Ps], Path, Acc) ->
    path_to_operations(Ps, [List | Path], Acc);
path_to_operations([#{node_type := Leaf, value := Value} = Item | Ps], Path, Acc) when Leaf == leaf; Leaf == leaf_list ->
    path_to_operations(Ps, Path, [{lists:reverse([Item | Path]), Value} | Acc]).

