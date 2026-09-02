-module(mgmtd_schema_function).

-export([load/2, load_node/4, load_node/5]).

-include("../include/mgmtd.hrl").
-include("mgmtd_schema.hrl").

load(Fun, Opts) when is_function(Fun) ->
    IsConfig = maps:get(config, Opts, false),
    Callback = maps:get(callback, Opts, undefined),
    Nodes = Fun(),
    TopNames = node_names(Nodes),
    case mgmtd_schema:prepare_load(Opts, function, TopNames) of
        {ok, Prefix, Namespace} ->
            ok = load_nodes(Prefix, Nodes, IsConfig, Callback),
            mgmtd_schema:register_schema(Prefix, Namespace, function);
        {error, _} = Err ->
            Err
    end.

load_nodes(?DEFAULT_NS, Nodes, IsConfig, Callback) ->
    lists:foreach(fun(Child) ->
                          load_node(Child, [], ?DEFAULT_NS, IsConfig, Callback)
                  end, Nodes);
load_nodes(Prefix, Nodes, IsConfig, Callback) ->
    Name = atom_to_list(Prefix),
    case ets:lookup(mgmtd_commands, {[Name], Prefix}) of
        [] ->
            load_node(mgmtd_schema:prefix_container(Prefix, Nodes),
                      [], Prefix, IsConfig, Callback);
        [_] ->
            lists:foreach(fun(Child) ->
                                  load_node(Child, [Name], Prefix, IsConfig, Callback)
                          end, Nodes)
    end.

load(Fun, Path, Ns, IsConfig, Callback) ->
    lists:foreach(fun(Child) ->
                          load_node(Child, Path, Ns, IsConfig, Callback)
                  end, Fun()).

load_node(Node, Path, Ns, IsConfig) ->
    load_node(Node, Path, Ns, IsConfig, undefined).

load_node(#container{name = Name, desc = Desc, config = Config0} = Node, Path, Ns, IsConfig, ParentCb) ->
    Config = inherited_config(Config0, IsConfig),
    Callback = mgmtd_schema:resolve_data_callback(Node#container.data_callback, ParentCb, Config),
    FullPath = lists:reverse([Name | Path]),
    Container =
        #schema{path = {FullPath, Ns},
                prefix = Ns,
                node_type = container,
                name = Name,
                desc = Desc,
                data_callback = Callback,
                config = Config,
                opts = Node#container.opts},
    true = ets:insert_new(mgmtd_commands, Container),
    load(Node#container.children, [Name | Path], Ns, Config, Callback);
load_node(#list{name = Name, desc = Desc, key_names = KeyNames, config = Config0} = Node, Path, Ns, IsConfig, ParentCb) ->
    Config = inherited_config(Config0, IsConfig),
    Callback = mgmtd_schema:resolve_data_callback(Node#list.data_callback, ParentCb, Config),
    assert_key_names(KeyNames, Node#list.children),
    FullPath = lists:reverse([Name | Path]),
    LeafList =
        #schema{path = {FullPath, Ns},
                prefix = Ns,
                node_type = list,
                name = Name,
                key_names = KeyNames,
                data_callback = Callback,
                desc = Desc,
                min_elements = Node#list.min_elements,
                max_elements = Node#list.max_elements,
                has_list = true,
                config = Config,
                opts = Node#list.opts},
                                                % io:format(user, "L - ~p~n", [lists:reverse(Path)]),
    true = ets:insert_new(mgmtd_commands, LeafList),
    ok = mgmtd_schema:mark_has_list_descendent(Ns, Path),
    load(Node#list.children, [Name | Path], Ns, Config, Callback);
load_node(#leaf{name = Name, desc = Desc, type = Type, default = Default, config = Config0} = Node, Path, Ns, IsConfig, ParentCb) ->
    Config = inherited_config(Config0, IsConfig),
    Callback = mgmtd_schema:resolve_data_callback(Node#leaf.data_callback, ParentCb, Config),
    FullPath = lists:reverse([Name | Path]),
    Leaf =
        #schema{path = {FullPath, Ns},
                prefix = Ns,
                node_type = leaf,
                name = Name,
                type = Type,
                desc = Desc,
                default = Default,
                mandatory = Node#leaf.mandatory,
                data_callback = Callback,
                config = Config,
                opts = Node#leaf.opts},
                                                %io:format(user, "L - ~p~n", [lists:reverse(Path)]),
    true = ets:insert_new(mgmtd_commands, Leaf);
load_node(#leaf_list{name = Name, desc = Desc, type = Type, config = Config0} = Node, Path, Ns, IsConfig, ParentCb) ->
    Config = inherited_config(Config0, IsConfig),
    Callback = mgmtd_schema:resolve_data_callback(Node#leaf_list.data_callback, ParentCb, Config),
    FullPath = lists:reverse([Name | Path]),
    LeafList =
        #schema{path = {FullPath, Ns},
                prefix = Ns,
                node_type = leaf_list,
                name = Name,
                type = Type,
                desc = Desc,
                data_callback = Callback,
                min_elements = Node#leaf_list.min_elements,
                max_elements = Node#leaf_list.max_elements,
                config = Config,
                opts = Node#leaf_list.opts},
    true = ets:insert_new(mgmtd_commands, LeafList).

assert_key_names(KeyNames, ChildrenFun) ->
    Children = ChildrenFun(),
    ChildNames = node_names(Children),
    case KeyNames -- ChildNames of
        [] -> ok;
        MissingNames ->
            io:format("Error, Missing list key entry"),
            error({missing_list_keys, MissingNames})
    end.

node_names(Children) ->
    lists:map(fun(Child) -> node_name(Child) end, Children).

node_name(#leaf{name = Name}) -> Name;
node_name(#leaf_list{name = Name}) -> Name;
node_name(#list{name = Name}) -> Name;
node_name(#container{name = Name}) -> Name.

%% config is true only inside a config tree: a node with config = true
%% starts a tree, and descendants inherit true even if they leave the
%% record default (false).
inherited_config(NodeConfig, ParentConfig) ->
    ParentConfig orelse NodeConfig.
