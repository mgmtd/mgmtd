-module(mgmtd_schema_json_draft4).

-export([load_file/1, load_file/2]).

-include("../include/mgmtd.hrl").
-include("mgmtd_schema.hrl").


load_file(File) ->
    load_file(File, #{config => true}).

load_file(File, Opts) ->
    {ok, Bin} = file:read_file(File),
    Schema = json:decode(Bin),
    ok = load_json_schema(Schema, Opts).

load_json_schema(#{<<"$schema">> := <<"http://json-schema.org/draft-04/schema#">>} = Schema,
                 Opts) ->
    NameSpace = maps:get(namespace, Opts, ?DEFAULT_NS),
    ok = load_json_schema(Schema, [], NameSpace, Opts),
    mgmtd_schema:register_schema(NameSpace).

load_json_schema(#{<<"properties">> := Props}, Path, Ns, Opts) ->
    load_json_properties(Props, Path, Ns, Opts).

load_json_properties(Props, Path, Ns, Opts) ->
    maps:foreach(fun(K, V) ->
                         Name = binary_to_list(K),
                         load_json_property(V, Name, [Name | Path], Ns, Opts)
                 end, Props).

load_json_property(#{<<"type">> := <<"object">>} = Object,
                   Key,
                   Path,
                   Ns,
                   #{config := Config} = Opts) ->
    %% A container
    Container =
        #schema{path = {lists:reverse(Path), Ns},
                node_type = container,
                name = Key,
                desc = maps:get(<<"description">>, Object, ""),
                config = Config},
    %% io:format(user, "O - ~p~n", [lists:reverse(Path)]),
    true = ets:insert_new(mgmtd_commands, Container),
    load_json_properties(maps:get(<<"properties">>, Object, #{}), Path, Ns, Opts);
load_json_property(#{<<"type">> := <<"array">>} = Object,
                   Key,
                   Path,
                   Ns,
                   #{config := Config} = Opts) ->
    %% An array, this could be a list or a leaf-list.
    %% Decide based on whether items is a single leaf type (leaf-list)
    case is_leaf_list_array(Object) of
        true ->
            Item = maps:get(<<"items">>, Object),
            Type = json_item_type(Item),
            Default = json_default(Type, Item),

            LeafList =
                #schema{path = {lists:reverse(Path), Ns},
                        node_type = leaf_list,
                        name = Key,
                        type = json_item_type(Item),
                        desc = maps:get(<<"description">>, Item, ""),
                        default = Default,
                        min_elements = maps:get(<<"minItems">>, Item, undefined),
                        max_elements = maps:get(<<"maxItems">>, Item, undefined),
                        data_callback = maps:get(callback, Opts, mgmtd),
                        mandatory = true,
                        config = Config
                       },
            true = ets:insert_new(mgmtd_commands, LeafList);
        false ->
            %% It's a full list of potentially any subtree
            %% Ideally we need to know which items make up the list key
            %% but for JSON schema if there is no 'key' element provided
            %% and this is for configuration data create one called
            %% 'index' of type integer.
            %% io:format(user, "A - ~p~n", [lists:reverse(Path)]),
            Keys =
                case Object of
                    #{<<"keys">> := ListKeys} ->
                        %% FIXME: check that ListKeys are indeed present in the
                        %% properties of this array
                        lists:map(fun(LK) -> binary_to_list(LK) end, ListKeys);
                    _ when Config ->
                        IndexLeaf = generated_index_leaf(Path, Ns, Config),
                        true = ets:insert_new(mgmtd_commands, IndexLeaf),
                        ["index"];
                    _ ->
                        %% Operational data doesn't require list index in Yang
                        []
                end,

            List =
                #schema{path = {lists:reverse(Path), Ns},
                        node_type = list,
                        name = Key,
                        desc = maps:get(<<"description">>, Object, ""),
                        key_names = Keys,
                        min_elements = maps:get(<<"minItems">>, Object, 0),
                        max_elements = maps:get(<<"maxItems">>, Object, undefined),
                        mandatory = false,
                        data_callback = maps:get(callback, Opts, mgmtd),
                        config = Config},
            true = ets:insert_new(mgmtd_commands, List),
            Items = maps:get(<<"items">>, Object),
            load_json_properties(maps:get(<<"properties">>, Items), Path, Ns, Opts)
    end;
load_json_property(#{} = Item, Key, Path, Ns, #{config := Config}) ->
    Type = json_item_type(Item),
    Default = json_default(Type, Item),
    Leaf =
        #schema{path = {lists:reverse(Path), Ns},
                node_type = leaf,
                name = Key,
                type = json_item_type(Item),
                desc = maps:get(<<"description">>, Item, <<"">>),
                default = Default,
                min_elements = maps:get(<<"minItems">>, Item, 0),
                max_elements = maps:get(<<"maxItems">>, Item, undefined),
                mandatory = true,
                config = Config},
                                                %io:format(user, "L - ~p~n", [lists:reverse(Path)]),
    true = ets:insert_new(mgmtd_commands, Leaf).

%% When no index is provided by the schema insert an integer based
%% one with name index
generated_index_leaf(Path, Ns, Config) ->
    #schema{path = {lists:reverse(["index" | Path]), Ns},
            node_type = leaf,
            name = "index",
            type = uint64,
            desc = <<"List index">>,
            mandatory = true,
            config = Config}.

%% It's not a perfect match, but model JSON arrays to either leaf-list
%% or list based on the content.
is_leaf_list_array(Object) ->
    Items = maps:get(<<"items">>, Object, #{}),
    case Items of
        #{<<"type">> := <<"object">>} ->
            false;
        _ ->
            true
    end.

json_item_type(#{<<"type">> := <<"integer">>}) ->
    int32;
json_item_type(#{<<"type">> := Type}) ->
    binary_to_atom(Type);
json_item_type(#{<<"pattern">> := _Pattern}) ->
    %% No type specified, but 'pattern' is only defined for strings
    %% JSON schema sure is permissive..
    string.

json_default(_Type, #{<<"default">> := Default}) ->
    Default;
json_default(_Type, _) ->
    missing_default.
