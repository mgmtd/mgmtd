-module(mgmtd_schema_function).

-export([load/2]).

-include("../include/mgmtd.hrl").
-include("mgmtd_schema.hrl").

load(Fun, Opts) when is_function(Fun) ->
    NameSpace = maps:get(namespace, Opts, ?DEFAULT_NS),
    IsConfig = maps:get(config, Opts, false),
    ok = load(Fun, [], NameSpace, IsConfig),
    mgmtd_schema:register_schema(NameSpace).

load(Fun, Path, Ns, IsConfig) ->
    lists:foreach(fun(Child) ->
                          load_node(Child, Path, Ns, IsConfig)
                  end, Fun()).

load_node(#container{name = Name, desc = Desc, config = Config0} = Node, Path, Ns, IsConfig) ->
    Config = inherited_config(Config0, IsConfig),
    FullPath = lists:reverse([Name | Path]),
    Container =
        #schema{path = {FullPath, Ns},
                node_type = container,
                name = Name,
                desc = Desc,
                config = Config},
    true = ets:insert_new(mgmtd_commands, Container),
    load(Node#container.children, [Name | Path], Ns, Config);
load_node(#list{name = Name, desc = Desc, key_names = KeyNames, config = Config0} = Node, Path, Ns, IsConfig) ->
    Config = inherited_config(Config0, IsConfig),
    assert_key_names(KeyNames, Node#list.children),
    FullPath = lists:reverse([Name | Path]),
    LeafList =
        #schema{path = {FullPath, Ns},
                node_type = list,
                name = Name,
                key_names = KeyNames,
                data_callback = Node#list.data_callback,
                desc = Desc,
                min_elements = Node#list.min_elements,
                max_elements = Node#list.max_elements,
                has_list = true,
                config = Config},
                                                % io:format(user, "L - ~p~n", [lists:reverse(Path)]),
    true = ets:insert_new(mgmtd_commands, LeafList),
    ok = mark_has_list_descendent(Ns, Path),
    load(Node#list.children, [Name | Path], Ns, Config);
load_node(#leaf{name = Name, desc = Desc, type = Type, default = Default, config = Config0} = Node, Path, Ns, IsConfig) ->
    Config = inherited_config(Config0, IsConfig),
    FullPath = lists:reverse([Name | Path]),
    Leaf =
        #schema{path = {FullPath, Ns},
                node_type = leaf,
                name = Name,
                type = Type,
                desc = Desc,
                default = Default,
                mandatory = Node#leaf.mandatory,
                config = Config},
                                                %io:format(user, "L - ~p~n", [lists:reverse(Path)]),
    true = ets:insert_new(mgmtd_commands, Leaf);
load_node(#leaf_list{name = Name, desc = Desc, type = Type, config = Config0} = Node, Path, Ns, IsConfig) ->
    Config = inherited_config(Config0, IsConfig),
    FullPath = lists:reverse([Name | Path]),
    LeafList =
        #schema{path = {FullPath, Ns},
                node_type = leaf_list,
                name = Name,
                type = Type,
                desc = Desc,
                min_elements = Node#leaf_list.min_elements,
                max_elements = Node#leaf_list.max_elements,
                config = Config},
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

mark_has_list_descendent(_Ns, []) ->
    ok;
mark_has_list_descendent(Ns, Path) ->
    SchPath = lists:reverse(Path),
    [Node] = ets:lookup(mgmtd_commands, {SchPath, Ns}),
    ets:insert(mgmtd_commands, Node#schema{has_list = true}),
    mark_has_list_descendent(Ns, tl(Path)).


%% config is true only inside a config tree: a node with config = true
%% starts a tree, and descendants inherit true even if they leave the
%% record default (false).
inherited_config(NodeConfig, ParentConfig) ->
    ParentConfig orelse NodeConfig.
