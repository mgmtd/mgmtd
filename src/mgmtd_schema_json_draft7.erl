-module(mgmtd_schema_json_draft7).

-export([load_file/1, load_file/2]).

-include("../include/mgmtd.hrl").
-include("mgmtd_schema.hrl").

-define(DRAFT7_SCHEMA, <<"http://json-schema.org/draft-07/schema#">>).


load_file(File) ->
    load_file(File, #{}).

load_file(File, Opts) ->
    {ok, Bin} = file:read_file(File),
    Schema = json:decode(Bin),
    load_json_schema(Schema, maps:merge(#{config => false}, Opts)).

load_json_schema(#{<<"$schema">> := ?DRAFT7_SCHEMA} = Schema, Opts) ->
    NameSpace = maps:get(namespace, Opts, ?DEFAULT_NS),
    ok = load_json_schema(Schema, [], NameSpace, Opts),
    mgmtd_schema:register_schema(NameSpace);
load_json_schema(#{<<"$schema">> := Other}, _Opts) ->
    {error, {unsupported_json_schema, Other}};
load_json_schema(_Schema, _Opts) ->
    {error, {unsupported_json_schema, missing_dollar_schema}}.

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
                desc = json_desc(Object),
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
                        desc = json_desc(Item),
                        default = Default,
                        min_elements = maps:get(<<"minItems">>, Object, 0),
                        max_elements = maps:get(<<"maxItems">>, Object, unlimited),
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
                        desc = json_desc(Object),
                        key_names = Keys,
                        min_elements = maps:get(<<"minItems">>, Object, 0),
                        max_elements = maps:get(<<"maxItems">>, Object, unlimited),
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
                desc = json_desc(Item),
                default = Default,
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
            desc = "List index",
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

json_item_type(#{<<"const">> := Val}) ->
    %% Draft-06+ const is a single allowed value; model as a one-member enum.
    {enum, [json_enum_member(Val)]};
json_item_type(#{<<"enum">> := Vals}) when is_list(Vals) ->
    %% JSON Schema enum is a constraint; model it as a YANG enumeration
    %% so CLI completion and set-path validation share the same type form.
    {enum, [json_enum_member(V) || V <- Vals]};
json_item_type(#{<<"type">> := <<"integer">>} = Item) ->
    json_integer_type(Item);
json_item_type(#{<<"type">> := Type}) ->
    binary_to_atom(Type);
json_item_type(#{<<"pattern">> := _Pattern}) ->
    %% No type specified, but 'pattern' is only defined for strings
    %% JSON schema sure is permissive..
    string.

%% Draft-07 exclusiveMinimum/exclusiveMaximum are numbers, not booleans.
json_integer_type(Item) ->
    Range = json_integer_range(Item),
    case Range of
        [] -> int32;
        _ -> {int32, Range}
    end.

json_integer_range(Item) ->
    Min = json_integer_bound(Item, <<"minimum">>, <<"exclusiveMinimum">>, min),
    Max = json_integer_bound(Item, <<"maximum">>, <<"exclusiveMaximum">>, max),
    Min ++ Max.

json_integer_bound(Item, InclusiveKey, ExclusiveKey, Tag) ->
    Inc = json_number(maps:get(InclusiveKey, Item, undefined)),
    Exc = json_number(maps:get(ExclusiveKey, Item, undefined)),
    IncBound = case Inc of
                   undefined -> undefined;
                   IncN -> inclusive_int_bound(Tag, IncN)
               end,
    ExcBound = case Exc of
                   undefined -> undefined;
                   ExcN -> exclusive_int_bound(Tag, ExcN)
               end,
    case {Tag, IncBound, ExcBound} of
        {_, undefined, undefined} -> [];
        {_, undefined, E} -> [{Tag, E}];
        {_, I, undefined} -> [{Tag, I}];
        {min, I, E} -> [{min, max(I, E)}];
        {max, I, E} -> [{max, min(I, E)}]
    end.

json_number(N) when is_number(N) -> N;
json_number(_) -> undefined.

%% Inclusive min is ceil(N); inclusive max is floor(N).
inclusive_int_bound(min, Bound) -> erlang:ceil(Bound);
inclusive_int_bound(max, Bound) -> erlang:floor(Bound).

%% Draft-07 exclusive bounds are numeric: integers must be strictly
%% greater / less than the given number.
exclusive_int_bound(min, Bound) -> erlang:floor(Bound) + 1;
exclusive_int_bound(max, Bound) -> erlang:ceil(Bound) - 1.

json_enum_member(Bin) when is_binary(Bin) -> binary_to_list(Bin);
json_enum_member(Int) when is_integer(Int) -> integer_to_list(Int);
json_enum_member(true) -> "true";
json_enum_member(false) -> "false";
json_enum_member(null) -> "null";
json_enum_member(Str) when is_list(Str) -> Str.

json_default(_Type, #{<<"default">> := Default}) ->
    Default;
json_default(_Type, _) ->
    missing_default.

json_desc(Map) ->
    case maps:get(<<"description">>, Map, "") of
        Bin when is_binary(Bin) -> binary_to_list(Bin);
        Str -> Str
    end.
