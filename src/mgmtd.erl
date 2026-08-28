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
%% For operational data it is required to provide the name of a
%% module that exports the mgmtd_provider behaviour functions:
%%
%% get_value(Path) -> {ok, Value} | {error, Reason}
%% get_first(Path) -> {ok, ListKey} | {error, Reason}
%% get_next(Path, ListKey) -> {ok, ListKey} | {error, Reason}
%%
%% Options:
%% config => true | false (default true)
%% callback => Module::atom()
%% namespace => NameSpace::string()

load_json_schema(File) ->
    mgmtd_schema:load_json_schema_file(File, #{config => true}).
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
%% built in configuration database.
list_keys(Txn, ListItemPath, ListKeyMatch) ->
    mgmtd_cfg_txn:list_keys(Txn, ListItemPath, ListKeyMatch).

%% @doc Subscribe to configuration change messages.
%% Config change messages will be sent to Pid.
%% Change messages are of the form:
%% {config_change, Path, Value}
%% where Value is the new list of list keys, a leaf value, or the complete tree
%% below a container
subscribe(Path, Pid) ->
    %% io:format(user, "Subscrive called ~p~n", [ets:tab2list(cfg)]),
    mgmtd_cfg_server:subscribe(Path, Pid).

%% @doc get the list of child nodes in the schema at path
%% -spec schema_children([atom()], set | show) -> [%{}].
schema_children(Path, CmdType) ->
    mgmtd_schema:children(Path, CmdType).

schema_children(Ns, Path, CmdType) ->
    mgmtd_schema:children(Ns, Path, CmdType).

%% Lookup API
%% @doc read current config at path at a single level outside of a
%% transaction. For a leaf this will be the configured value of the
%% leaf or its default if provided in the schema. For a list item this
%% will be the list of list keys, for a container item or full path to
%% a list item this will be a list of child nodes.

-spec lookup(item_path()) -> {ok, any()} | {error, unknown_schema_path}.
lookup(Path) ->
    lookup(?DEFAULT_NS, Path).

-spec lookup(ns(), item_path()) -> {ok, any()} | {error, unknown_schema_path}.
lookup(Ns, Path) ->
    SchemaPath = lists:filter(fun(El) -> not is_tuple(El) end, Path),
    case mgmtd_schema:lookup(Ns, SchemaPath) of
        false ->
            {error, unknown_schema_path};
        #{node_type := list, key_names := Keys} ->
            case lists:last(Path) of
                ListKey when is_tuple(ListKey) ->
                    %% It's a full path to a list entry, return the
                    %% names of the children of the list key
                    Cs = mgmtd_schema:children(SchemaPath),
                    {ok, lists:map(fun(#{name := Name}) -> Name end, Cs)};
                _ ->
                    %% User looked up the list key itself, return the list keys
                    Pattern = erlang:make_tuple(length(Keys), '_'),
                    {ok, mgmtd_cfg_db:list_keys(Path)}
            end;
        #{node_type := container} ->
            Cs = mgmtd_schema:children(SchemaPath),
            {ok, lists:map(fun(#{name := Name}) -> Name end, Cs)};
        #{node_type := Leaf, default := Default} when Leaf == leaf;
                                                      Leaf == leaf_list ->
            case mgmtd_cfg_db:lookup(Path) of
                [#cfg{value = Value}] ->
                    {ok, Value};
                [] when Default == undefined ->
                    {ok, undefined};
                [] ->
                    {ok, Default}
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
        fun(#{node_type := list, key_values := KeyValues, name := Name}, Acc) when is_tuple(KeyValues) ->
                [list_to_tuple(KeyValues), Name | Acc];
           (#{name := Name}, Acc) ->
                [Name | Acc]
        end, [], SchemaPath)).


%% A single command might set multiple parameter values
%% Generate separate set operations for each value
path_to_operations(SchemaPath) ->
    path_to_operations(SchemaPath, [], []).

path_to_operations([], _, Acc) ->
    lists:reverse(Acc);
path_to_operations([#{node_type := container} = Container| Ps], Path, Acc) ->
    path_to_operations(Ps, [Container | Path], Acc);
path_to_operations([#{node_type := list} = List| Ps], Path, Acc) ->
    path_to_operations(Ps, [List | Path], Acc);
path_to_operations([#{node_type := Leaf, value := Value} = Item | Ps], Path, Acc) when Leaf == leaf; Leaf == leaf_list ->
    path_to_operations(Ps, Path, [{lists:reverse([Item | Path]), Value} | Acc]).

