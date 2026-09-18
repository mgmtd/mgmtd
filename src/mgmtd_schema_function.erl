-module(mgmtd_schema_function).

-export([load/2, load_node/4, load_node/5, load_resolved/3,
         load_resolved_at/4, load_resolved_at/5]).

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
            mgmtd_schema:register_schema(
              #{prefix => Prefix,
                namespace => Namespace,
                source => function,
                module => mgmtd_schema:restconf_module_name(Prefix, Opts)});
        {error, _} = Err ->
            Err
    end.

load_nodes(?DEFAULT_NS, Nodes, IsConfig, Callback) ->
    lists:foreach(fun(Child) ->
                          load_node(Child, [], ?DEFAULT_NS, IsConfig, Callback)
                  end, Nodes);
load_nodes(Prefix, Nodes, IsConfig, Callback) ->
    Name = atom_to_list(Prefix),
    case ets:lookup(mgmtd_schema:commands_tab(), {[Name], Prefix}) of
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
    true = ets:insert_new(mgmtd_schema:commands_tab(), Container),
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
                ordered_by = Node#list.ordered_by,
                has_list = true,
                has_user_ordered_list = Node#list.ordered_by =:= user,
                config = Config,
                opts = Node#list.opts},
                                                % io:format(user, "L - ~p~n", [lists:reverse(Path)]),
    true = ets:insert_new(mgmtd_schema:commands_tab(), LeafList),
    ok = mgmtd_schema:mark_has_list_descendent(Ns, Path),
    ok = maybe_mark_user_ordered(Node#list.ordered_by, Ns, Path),
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
    true = ets:insert_new(mgmtd_schema:commands_tab(), Leaf);
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
                ordered_by = Node#leaf_list.ordered_by,
                mandatory = Node#leaf_list.mandatory,
                config = Config,
                opts = Node#leaf_list.opts},
    true = ets:insert_new(mgmtd_schema:commands_tab(), LeafList);
load_node(#rpc{name = Name, desc = Desc} = Node, Path, Ns, _IsConfig, ParentCb) ->
    load_rpc_like(rpc, Name, Desc, Node#rpc.callback, Node#rpc.opts,
                  Node#rpc.input, Node#rpc.output, Path, Ns, ParentCb);
load_node(#action{name = Name, desc = Desc} = Node, Path, Ns, _IsConfig, ParentCb) ->
    load_rpc_like(action, Name, Desc, Node#action.callback, Node#action.opts,
                  Node#action.input, Node#action.output, Path, Ns, ParentCb);
load_node(#notification{name = Name, desc = Desc} = Node, Path, Ns, _IsConfig, ParentCb) ->
    Callback = mgmtd_schema:resolve_data_callback(undefined, ParentCb, false),
    FullPath = lists:reverse([Name | Path]),
    Rec = #schema{path = {FullPath, Ns},
                  prefix = Ns,
                  node_type = notification,
                  name = Name,
                  desc = Desc,
                  data_callback = Callback,
                  config = false,
                  opts = Node#notification.opts},
    true = ets:insert_new(mgmtd_schema:commands_tab(), Rec),
    load(Node#notification.children, [Name | Path], Ns, false, Callback).

%% Load records whose `config` flags are already resolved (YANG compiler).
load_resolved(Prefix, Nodes, Callback) ->
    load_nodes_resolved(Prefix, Nodes, Callback).

%% Insert compiled nodes as children of an existing schema path (remote augment).
load_resolved_at(Prefix, ParentPath, Nodes, Callback) ->
    load_resolved_at(Prefix, ParentPath, Nodes, Callback, undefined).

load_resolved_at(Prefix, ParentPath, Nodes, Callback, OriginModule) ->
    case ets:lookup(mgmtd_schema:commands_tab(), {ParentPath, Prefix}) of
        [] ->
            {error, {augment_target_missing, ParentPath, Prefix}};
        [_] ->
            Rev = lists:reverse(ParentPath),
            lists:foreach(fun(Child) ->
                                  load_node_resolved(Child, Rev, Prefix, Callback, OriginModule)
                          end, Nodes),
            ok
    end.

load_nodes_resolved(?DEFAULT_NS, Nodes, Callback) ->
    lists:foreach(fun(Child) ->
                          load_node_resolved(Child, [], ?DEFAULT_NS, Callback, undefined)
                  end, Nodes);
load_nodes_resolved(Prefix, Nodes, Callback) ->
    Name = atom_to_list(Prefix),
    case ets:lookup(mgmtd_schema:commands_tab(), {[Name], Prefix}) of
        [] ->
            Root = (mgmtd_schema:prefix_container(Prefix, Nodes))#container{config = true},
            load_node_resolved(Root, [], Prefix, Callback, undefined);
        [_] ->
            lists:foreach(fun(Child) ->
                                  load_node_resolved(Child, [Name], Prefix, Callback, undefined)
                          end, Nodes)
    end.

load_resolved_children(Fun, Path, Ns, Callback, Origin) ->
    lists:foreach(fun(Child) ->
                          load_node_resolved(Child, Path, Ns, Callback, Origin)
                  end, Fun()).

load_node_resolved(#container{name = Name, desc = Desc, config = Config} = Node, Path, Ns, ParentCb, Origin) ->
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
                opts = origin_opts(Node#container.opts, Origin)},
    true = ets:insert_new(mgmtd_schema:commands_tab(), Container),
    load_resolved_children(Node#container.children, [Name | Path], Ns, Callback, Origin);
load_node_resolved(#list{name = Name, desc = Desc, key_names = KeyNames, config = Config} = Node, Path, Ns, ParentCb, Origin) ->
    Callback = mgmtd_schema:resolve_data_callback(Node#list.data_callback, ParentCb, Config),
    assert_key_names(KeyNames, Node#list.children),
    FullPath = lists:reverse([Name | Path]),
    List =
        #schema{path = {FullPath, Ns},
                prefix = Ns,
                node_type = list,
                name = Name,
                key_names = KeyNames,
                data_callback = Callback,
                desc = Desc,
                min_elements = Node#list.min_elements,
                max_elements = Node#list.max_elements,
                ordered_by = Node#list.ordered_by,
                has_list = true,
                has_user_ordered_list = Node#list.ordered_by =:= user,
                config = Config,
                opts = origin_opts(Node#list.opts, Origin)},
    true = ets:insert_new(mgmtd_schema:commands_tab(), List),
    ok = mgmtd_schema:mark_has_list_descendent(Ns, Path),
    ok = maybe_mark_user_ordered(Node#list.ordered_by, Ns, Path),
    load_resolved_children(Node#list.children, [Name | Path], Ns, Callback, Origin);
load_node_resolved(#leaf{name = Name, desc = Desc, type = Type, default = Default, config = Config} = Node, Path, Ns, ParentCb, Origin) ->
    Callback = mgmtd_schema:resolve_data_callback(Node#leaf.data_callback, ParentCb, Config),
    FullPath = lists:reverse([Name | Path]),
    Pattern = proplists:get_value(pattern, Node#leaf.opts, undefined),
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
                pattern = Pattern,
                config = Config,
                opts = origin_opts(Node#leaf.opts, Origin)},
    true = ets:insert_new(mgmtd_schema:commands_tab(), Leaf);
load_node_resolved(#leaf_list{name = Name, desc = Desc, type = Type, config = Config} = Node, Path, Ns, ParentCb, Origin) ->
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
                ordered_by = Node#leaf_list.ordered_by,
                mandatory = Node#leaf_list.mandatory,
                config = Config,
                opts = origin_opts(Node#leaf_list.opts, Origin)},
    true = ets:insert_new(mgmtd_schema:commands_tab(), LeafList);
load_node_resolved(#rpc{name = Name, desc = Desc} = Node, Path, Ns, ParentCb, Origin) ->
    load_rpc_like_resolved(rpc, Name, Desc, Node#rpc.callback, Node#rpc.opts,
                           Node#rpc.input, Node#rpc.output, Path, Ns, ParentCb, Origin);
load_node_resolved(#action{name = Name, desc = Desc} = Node, Path, Ns, ParentCb, Origin) ->
    load_rpc_like_resolved(action, Name, Desc, Node#action.callback, Node#action.opts,
                           Node#action.input, Node#action.output, Path, Ns, ParentCb, Origin);
load_node_resolved(#notification{name = Name, desc = Desc} = Node, Path, Ns, ParentCb, Origin) ->
    Callback = mgmtd_schema:resolve_data_callback(undefined, ParentCb, false),
    FullPath = lists:reverse([Name | Path]),
    Rec = #schema{path = {FullPath, Ns},
                  prefix = Ns,
                  node_type = notification,
                  name = Name,
                  desc = Desc,
                  data_callback = Callback,
                  config = false,
                  opts = origin_opts(Node#notification.opts, Origin)},
    true = ets:insert_new(mgmtd_schema:commands_tab(), Rec),
    load_resolved_children(Node#notification.children, [Name | Path], Ns, Callback, Origin).

origin_opts(Opts, undefined) ->
    Opts;
origin_opts(Opts, Origin) ->
    case lists:keyfind(origin_module, 1, Opts) of
        false ->
            [{origin_module, Origin} | Opts];
        _ ->
            Opts
    end.

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
node_name(#container{name = Name}) -> Name;
node_name(#rpc{name = Name}) -> Name;
node_name(#action{name = Name}) -> Name;
node_name(#notification{name = Name}) -> Name.

load_rpc_like(Type, Name, Desc, NodeCb, Opts, InputFun, OutputFun, Path, Ns, ParentCb) ->
    Callback = mgmtd_schema:resolve_data_callback(NodeCb, ParentCb, false),
    FullPath = lists:reverse([Name | Path]),
    Rec = #schema{path = {FullPath, Ns},
                  prefix = Ns,
                  node_type = Type,
                  name = Name,
                  desc = Desc,
                  data_callback = Callback,
                  config = false,
                  opts = Opts},
    true = ets:insert_new(mgmtd_schema:commands_tab(), Rec),
    load_io("input", InputFun, [Name | Path], Ns, Callback),
    load_io("output", OutputFun, [Name | Path], Ns, Callback).

load_rpc_like_resolved(Type, Name, Desc, NodeCb, Opts, InputFun, OutputFun,
                       Path, Ns, ParentCb, Origin) ->
    Callback = mgmtd_schema:resolve_data_callback(NodeCb, ParentCb, false),
    FullPath = lists:reverse([Name | Path]),
    Rec = #schema{path = {FullPath, Ns},
                  prefix = Ns,
                  node_type = Type,
                  name = Name,
                  desc = Desc,
                  data_callback = Callback,
                  config = false,
                  opts = origin_opts(Opts, Origin)},
    true = ets:insert_new(mgmtd_schema:commands_tab(), Rec),
    load_io_resolved("input", InputFun, [Name | Path], Ns, Callback, Origin),
    load_io_resolved("output", OutputFun, [Name | Path], Ns, Callback, Origin).

load_io(Name, Fun, Path, Ns, Callback) ->
    Container = #container{name = Name,
                           config = false,
                           children = Fun},
    load_node(Container, Path, Ns, false, Callback).

load_io_resolved(Name, Fun, Path, Ns, Callback, Origin) ->
    Container = #container{name = Name,
                           config = false,
                           children = Fun},
    load_node_resolved(Container, Path, Ns, Callback, Origin).

%% config is true only inside a config tree: a node with config = true
%% starts a tree, and descendants inherit true even if they leave the
%% record default (false).
inherited_config(NodeConfig, ParentConfig) ->
    ParentConfig orelse NodeConfig.

maybe_mark_user_ordered(user, Ns, Path) ->
    mgmtd_schema:mark_has_user_ordered_list_descendent(Ns, Path);
maybe_mark_user_ordered(_, _Ns, _Path) ->
    ok.
