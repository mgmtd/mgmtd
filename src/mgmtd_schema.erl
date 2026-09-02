%%%-------------------------------------------------------------------
%% @doc mgmtd schema access
%% Global repository for management information schemas
%% Supports:
%%   * configuration and operational data schemas
%%   * Yang and JSON Schemas
%% @end
%%%-------------------------------------------------------------------
-module(mgmtd_schema).

-export([load_json_schema_file/1, load_json_schema_file/2, load_function_schema/2]).
-export([remove_schema/0, remove_schema/1]).
-export([prepare_load/3, register_schema/1, register_schema/3,
         unregister_schema/1, registered_schemas/0]).
-export([prefix_container/2, mark_has_list_descendent/2]).
-export([lookup/1, lookup/2, get_default/1, get_default/2]).
-export([lookup_path/1]).
-export([children/1, children/2, children/3]).
-export([split_item_path/1, cli_path/2]).
-export([cast_value/2, cast_list_key_values/1]).
-export([codec/1, data_callback/1, resolve_data_callback/3]).
-export([ets_pat/1, ets_tail/1]).

-include("../include/mgmtd.hrl").
-include("mgmtd_schema.hrl").

%% @doc
%% Ideally we want to have the same internal representation of JSON schema
%% and Yang - a superset of the capabilities of both
%% with the same concepts in each dealt with by the same code
%%
%% Schema is stored in the mgmtd_commands ets table, keyed by {Path, Prefix}.
%% Named prefixes are loaded as a real #container{} whose name is the prefix,
%% so descendant schema paths start with that name. Default prefix is silent.
%% A YANG namespace URI, when present, lives in the loaded_schemas registry.
%%
%% Mappings between JSON schema and Yang node types
%%
%% -----------------------------------
%% | Yang      | JSON Schema         |
%% -----------------------------------
%% | container | object              |
%% | list      | array of object     |
%% | leaf-list | array of basic type |
%% | leaf      | not object or array |
%% -----------------------------------
%%
%% min and max mappings
%% ------------------------------------------------------------------------
%% | Yang                                     | JSON Schema               |
%% ------------------------------------------------------------------------
%% | min-elements for lists and leaf-lists    | minItems for arrays
%% | max-elements for lists and leaf-lists    | maxItems for arrays
%% | length N or N..M for string types        | minLength and maxLength strings
%% | range N or N..M or multiple for integers | minimum and maximum
%% |                                           | exclusiveMinimum / exclusiveMaximum
%% |                                           | (draft-07: numbers, not booleans)
%%
%% JSON schema union types - not allowed. Could maybe map to Yang Choice?
%% For now, each leaf is only allowed to have a single type
%%
%% In Yang each subtree can be independentally configured to hold
%% either config or operational data. For JSON Schema this attribute
%% needs to be provided at load time.
%%
-spec load_json_schema_file(FilePath :: file:filename()) ->
          ok | {error, Reason :: term()}.
load_json_schema_file(File) ->
    mgmtd_schema_json_draft7:load_file(File).

-spec load_json_schema_file(FilePath :: file:filename(), Opts :: map()) ->
          ok | {error, Reason :: term()}.
load_json_schema_file(File, Opts) ->
    mgmtd_schema_json_draft7:load_file(File, Opts).

load_function_schema(Fun, Opts) ->
    mgmtd_schema_function:load(Fun, Opts).

remove_schema() ->
    remove_schema(?DEFAULT_NS).

remove_schema(Ns) ->
    unregister_schema(Ns),
    ets:match_delete(mgmtd_commands, #schema{path = ets_pat({'_', Ns}), _ = ets_pat('_')}),
    ok.

%% @doc Validate load options and name-clash rules before inserting nodes.
%% Same prefix with the same namespace is additive (several files, one identity).
-spec prepare_load(map(), schema_source(), [string()]) ->
          {ok, prefix(), namespace()} | {error, term()}.
prepare_load(Opts, _Source, TopNames) when is_map(Opts), is_list(TopNames) ->
    case identity_from_opts(Opts) of
        {error, _} = Err ->
            Err;
        {ok, Prefix, Namespace} ->
            case validate_prefix(Prefix) of
                {error, _} = Err ->
                    Err;
                ok ->
                    case check_identity(Prefix, Namespace) of
                        {error, _} = Err ->
                            Err;
                        ok ->
                            case check_name_clash(Prefix, TopNames) of
                                {error, _} = Err ->
                                    Err;
                                ok ->
                                    {ok, Prefix, Namespace}
                            end
                    end
            end
    end.

register_schema(Name) ->
    register_schema(Name, Name, unknown).

register_schema(Prefix, Namespace, Source) ->
    Info = #{prefix => Prefix, namespace => Namespace, source => Source},
    case schema_infos() of
        [] ->
            true = ets:insert(mgmtd_meta, {loaded_schemas, [Info]}),
            ok;
        Current ->
            case [I || #{prefix := P} = I <- Current, P =:= Prefix] of
                [_|_] ->
                    ok;
                [] ->
                    true = ets:insert(mgmtd_meta, {loaded_schemas, [Info | Current]}),
                    ok
            end
    end.

unregister_schema(Name) ->
    case schema_infos() of
        [] ->
            ok;
        Current ->
            Rest = [I || #{prefix := P} = I <- Current, P =/= Name],
            true = ets:insert(mgmtd_meta, {loaded_schemas, Rest}),
            ok
    end.

registered_schemas() ->
    [P || #{prefix := P} <- schema_infos()].

-spec lookup(Path :: item_path()) -> map() | false.
lookup(Path) ->
    {Ns, Local} = split_item_path(Path),
    lookup(Ns, Local).

-spec lookup(NameSpace :: ns(), Path :: item_path()) -> map() | false.
lookup(Ns, Path) ->
    SchemaPath = item_path_to_schema_path(Path),
    case ets:lookup(mgmtd_commands, {SchemaPath, Ns}) of
        [#schema{} = Res] ->
            schema_to_map(Res, show);
        [] ->
            false
    end.

get_default(Path) ->
    {Ns, Local} = split_item_path(Path),
    get_default(Ns, Local).

get_default(Ns, Path) ->
    case lookup(Ns, Path) of
        false ->
            {error, path_not_in_schema};
        #{node_type := NodeType, default := Default} when ?is_leaf(NodeType) ->
            {ok, Default};
        _ ->
            {error, missing_default}
    end.

children(Path) ->
    children(Path, show).

children(Path, CmdType) ->
    {Ns, Local} = split_item_path(Path),
    children(Ns, Local, CmdType).

-spec children(ns(), item_path(), cmd_type()) -> list().
children(Ns, Path, delete) ->
    SchemaPath = item_path_to_schema_path(cli_path(Ns, Path)),
    Recs = ets:match_object(mgmtd_commands, #schema{path = {SchemaPath ++ ['_'], Ns}, has_list = true, _ = ets_pat('_')}),
    ?DBG("Found children in schema db at path ~p~n~p~n", [SchemaPath, Recs]),
    maybe_add_prefixes(Ns, Path, delete,
                       lists:map(fun(R) -> schema_to_map(R, delete) end, Recs));
children(Ns, Path, CmdType) ->
    SchemaPath = item_path_to_schema_path(cli_path(Ns, Path)),
    ?DBG("Finding children in schema db at path ~p~n", [SchemaPath]),
    Recs = ets:match_object(mgmtd_commands, #schema{path = {SchemaPath ++ ['_'], Ns}, _ = ets_pat('_')}),
    maybe_add_prefixes(Ns, Path, CmdType,
                       lists:map(fun(R) -> schema_to_map(R, CmdType) end, Recs)).

-spec item_path_to_schema_path(item_path()) -> schema_path().
item_path_to_schema_path([]) ->
    [];
item_path_to_schema_path([P | Ps]) when is_list(P); P =:= '_' ->
    [P | item_path_to_schema_path(Ps)];
item_path_to_schema_path([P | Ps]) when is_tuple(P) ->
    item_path_to_schema_path(Ps).

%% CLI / config-DB path. Named-prefix schema paths already start with
%% the prefix name; prepend only when the caller passed a local path.
-spec cli_path(prefix(), item_path()) -> item_path().
cli_path(?DEFAULT_NS, Path) ->
    Path;
cli_path(Prefix, Path) ->
    Name = atom_to_list(Prefix),
    case Path of
        [Name | _] ->
            Path;
        _ ->
            [Name | Path]
    end.

%% Split a CLI / config-DB path into {Prefix, SchemaPath}.
%% Named-prefix schema paths keep the prefix name as the first element.
-spec split_item_path(item_path()) -> {prefix(), item_path()}.
split_item_path([]) ->
    {?DEFAULT_NS, []};
split_item_path([First | _Rest] = Path) when is_list(First) ->
    case prefix_from_cli_name(First) of
        {ok, Prefix} ->
            {Prefix, Path};
        false ->
            {?DEFAULT_NS, Path}
    end;
split_item_path(Path) ->
    {?DEFAULT_NS, Path}.

prefix_from_cli_name(Name) ->
    case [P || P <- named_prefixes(), atom_to_list(P) =:= Name] of
        [Prefix] ->
            {ok, Prefix};
        _ ->
            false
    end.

named_prefixes() ->
    [P || #{prefix := P} <- schema_infos(), P =/= ?DEFAULT_NS].

schema_infos() ->
    case ets:lookup(mgmtd_meta, loaded_schemas) of
        [] ->
            [];
        [{_, Infos}] ->
            Infos
    end.

maybe_add_prefixes(?DEFAULT_NS, [], delete, Maps) ->
    Maps ++ prefix_child_maps(delete, fun(#schema{has_list = HasList}) -> HasList end);
maybe_add_prefixes(?DEFAULT_NS, [], CmdType, Maps) ->
    Maps ++ prefix_child_maps(CmdType, fun(_) -> true end);
maybe_add_prefixes(_Ns, _Path, _CmdType, Maps) ->
    Maps.

prefix_child_maps(CmdType, Pred) ->
    lists:filtermap(
      fun(Prefix) ->
              case ets:lookup(mgmtd_commands, {[atom_to_list(Prefix)], Prefix}) of
                  [S] ->
                      case Pred(S) of
                          true -> {true, schema_to_map(S, CmdType)};
                          false -> false
                      end;
                  [] ->
                      false
              end
      end, named_prefixes()).

%% Named prefix as a real container so load-time flags (has_list, config)
%% are computed the same way as for any other node.
-spec prefix_container(prefix(), list()) -> #container{}.
prefix_container(Prefix, Children) when is_atom(Prefix), is_list(Children) ->
    Name = atom_to_list(Prefix),
    #container{name = Name,
               desc = "Schema prefix " ++ Name,
               children = fun() -> Children end}.

%% Path is the reverse parent path (not including the list node).
-spec mark_has_list_descendent(prefix(), [string()]) -> ok.
mark_has_list_descendent(_Ns, []) ->
    ok;
mark_has_list_descendent(Ns, Path) ->
    SchPath = lists:reverse(Path),
    [Node] = ets:lookup(mgmtd_commands, {SchPath, Ns}),
    ets:insert(mgmtd_commands, Node#schema{has_list = true}),
    mark_has_list_descendent(Ns, tl(Path)).

identity_from_opts(Opts) ->
    PrefixOpt = maps:get(prefix, Opts, undefined),
    NsOpt = maps:get(namespace, Opts, undefined),
    identity_from_opts(PrefixOpt, NsOpt).

identity_from_opts(undefined, undefined) ->
    {ok, ?DEFAULT_NS, ?DEFAULT_NS};
identity_from_opts(Prefix, undefined) when is_atom(Prefix) ->
    {ok, Prefix, Prefix};
identity_from_opts(undefined, Ns) when is_atom(Ns) ->
    {ok, Ns, Ns};
identity_from_opts(undefined, Ns) when is_list(Ns) ->
    {error, missing_prefix};
identity_from_opts(Prefix, Ns) when is_atom(Prefix) ->
    {ok, Prefix, Ns};
identity_from_opts(Prefix, _Ns) ->
    {error, {invalid_prefix, Prefix}}.

validate_prefix(Prefix) when is_atom(Prefix) ->
    Name = atom_to_list(Prefix),
    case re:run(Name, "^[A-Za-z_][A-Za-z0-9_.-]*$", [{capture, none}]) of
        match ->
            ok;
        nomatch ->
            {error, {invalid_prefix, Prefix}}
    end;
validate_prefix(Prefix) ->
    {error, {invalid_prefix, Prefix}}.

check_identity(Prefix, Namespace) ->
    case [I || #{prefix := P} = I <- schema_infos(), P =:= Prefix] of
        [] ->
            check_namespace_unique(Prefix, Namespace);
        [#{namespace := Namespace}] ->
            ok;
        [#{namespace := Other}] ->
            {error, {prefix_namespace_mismatch, Prefix, Other}}
    end.

check_namespace_unique(_Prefix, Namespace) ->
    case [P || #{prefix := P, namespace := Ns} <- schema_infos(),
               Ns =:= Namespace, is_list(Namespace)] of
        [] ->
            ok;
        [OtherPrefix | _] ->
            {error, {duplicate_namespace, Namespace, OtherPrefix}}
    end.

check_name_clash(?DEFAULT_NS, TopNames) ->
    Named = [atom_to_list(P) || P <- named_prefixes()],
    case [N || N <- TopNames, lists:member(N, Named)] of
        [] ->
            ok;
        [Clash | _] ->
            {error, {prefix_conflicts_with_node, Clash}}
    end;
check_name_clash(Prefix, _TopNames) ->
    PrefixName = atom_to_list(Prefix),
    case lists:member(PrefixName, default_top_level_names()) of
        true ->
            {error, {prefix_conflicts_with_node, PrefixName}};
        false ->
            ok
    end.

default_top_level_names() ->
    Recs = ets:match_object(
             mgmtd_commands,
             #schema{path = {['_'], ?DEFAULT_NS}, _ = ets_pat('_')}),
    [Name || #schema{name = Name} <- Recs].

%% ETS match specs use '_' wildcards, which are not valid stored field values.
-spec ets_pat(term()) -> eqwalizer:dynamic().
ets_pat(X) -> X.

%% Improper list Path ++ '_' used as an ETS path prefix match.
-spec ets_tail(item_path()) -> eqwalizer:dynamic().
ets_tail(Path) -> Path ++ ets_pat('_').

%% @doc Given a path of the form ["server", "servers", {"S1"}, "port"]
%% (or ["example", "server", ...] for a named prefix) return a list of
%% schema items for the same path with any data after a leaf considered
%% to be a value. Named prefixes are a loaded root container.
lookup_path(Path) ->
    {Ns, Local} = split_item_path(Path),
    lookup_path(Ns, Local, [], []).

lookup_path(Ns, [P | Ps], PathSoFar, [#{node_type := list} = L | Acc]) when is_tuple(P) ->
    case lookup(Ns, PathSoFar) of
        #{} ->
            ListItem = L#{key_values := tuple_to_list(P)},
            lookup_path(Ns, Ps, PathSoFar, [ListItem | Acc]);
        false ->
            {error, {unknown_path, PathSoFar}}
    end;
lookup_path(Ns, [P | Ps], PathSoFar, Acc) ->
    NextPath = PathSoFar ++ [P],
    case lookup(Ns, NextPath) of
        #{node_type := Leaf} = Map when ?is_leaf(Leaf)  ->
            [Val | _Pss] = Ps,
            {ok, lists:reverse([Map#{value => Val} | Acc])};
        #{} = Map ->
            lookup_path(Ns, Ps, NextPath, [Map | Acc]);
        false ->
            {error, {unknown_path, PathSoFar}}
    end;
lookup_path(_Ns, [], _, Acc) ->
    {ok, lists:reverse(Acc)}.

schema_to_map(#schema{path = {Path, Ns}} = S, CmdType) ->
    #{role => schema,
      path => Path,
      ns => Ns,
      node_type => S#schema.node_type,
      name => S#schema.name,
      desc => S#schema.desc,
      type => S#schema.type,
      default => S#schema.default,
      key_names => S#schema.key_names,
      key_values => [],
      min_elements => S#schema.min_elements,
      max_elements => S#schema.max_elements,
      pattern => S#schema.pattern,
      mandatory => S#schema.mandatory,
      config => S#schema.config,
      data_callback => S#schema.data_callback,
      cmd_type => CmdType,
      has_list => S#schema.has_list,
      opts => S#schema.opts,
      children => fun(ChildPath) -> children(ChildPath, CmdType) end }.

%% @doc Operational-data provider module named as `data_callback` on a
%% schema node. `undefined` and `mgmtd` mean "not a host provider"
%% (`mgmtd` is the config-DB list-key callback).
-spec data_callback(item_path() | map_node()) -> atom() | undefined.
data_callback(#{data_callback := Mod}) when is_atom(Mod), Mod =/= undefined ->
    Mod;
data_callback(#{}) ->
    undefined;
data_callback(Path) when is_list(Path) ->
    case lookup(Path) of
        #{} = Map ->
            data_callback(Map);
        false ->
            undefined
    end;
data_callback(_) ->
    undefined.

%% @doc Resolve `data_callback` at load time. `undefined` inherits from
%% the parent. Configuration nodes with no provider keep `mgmtd` so ecli
%% list-key completion still hits the config DB.
-spec resolve_data_callback(atom() | undefined, atom() | undefined, boolean()) ->
          atom() | undefined.
resolve_data_callback(undefined, undefined, true) ->
    mgmtd;
resolve_data_callback(undefined, undefined, false) ->
    undefined;
resolve_data_callback(undefined, Parent, Config) ->
    resolve_data_callback(Parent, undefined, Config);
resolve_data_callback(NodeCb, _Parent, _Config) ->
    NodeCb.

%% @doc Persistence codec module named in schema `opts` as `{codec, Mod}`.
%% Used by the sys.config backend as a term adapter at that node.
-spec codec(item_path() | map_node()) -> atom() | undefined.
codec(#{opts := Opts}) when is_list(Opts) ->
    case lists:keyfind(codec, 1, Opts) of
        {codec, Mod} when is_atom(Mod) ->
            Mod;
        _ ->
            undefined
    end;
codec(Path) when is_list(Path) ->
    case lookup(Path) of
        #{} = Map ->
            codec(Map);
        false ->
            undefined
    end;
codec(_) ->
    undefined.

%% @doc Validate Item against the schema stored at Path.
%% The item must be a value of a leaf or leaf-list
%%
-spec validate(Path :: schema_path(), Item :: term()) -> ok | {error, Reason :: term()}.
validate(Path, Item) ->
    ok.

cast_value(Path, Value) ->
    try case lists:last(Path) of
            #{node_type := leaf, type := Type} ->
                cast(Type, Value);
            #{node_type := leaf_list, type := Type} when is_list(Value) ->
                lists:map(fun(Val) ->
                                  case cast(Type, Val) of
                                      {ok, InternalVal} ->
                                          {ok, InternalVal};
                                      Err ->
                                          throw(Err)
                                  end
                          end, Value);
            #{node_type := list, key_values := KVs} when KVs =/= [] ->
                {ok, undefined};
            _ ->
                {error, "Invalid path"}
        end
    catch error:Reason:_Trace ->
            {error, Reason}
    end.

%% Cast list-key leaf values according to each key leaf's schema type.
%% `key_values` stay as the original path tokens so lookups keep working
%% with the identity the caller used. Typed values go in `key_internal_values`.
-spec cast_list_key_values(map_path()) -> {ok, map_path()} | {error, term()}.
cast_list_key_values(Path) ->
    cast_list_key_values(Path, []).

cast_list_key_values([], Acc) ->
    {ok, lists:reverse(Acc)};
cast_list_key_values([#{node_type := list, key_names := Names,
                        key_values := Vals, path := ListPath} = Node | Rest], Acc) ->
    case Vals of
        [] ->
            cast_list_key_values(Rest, [Node | Acc]);
        _ ->
            case cast_key_leaf_values(ListPath, Names, Vals) of
                {ok, Internal} ->
                    cast_list_key_values(Rest, [Node#{key_internal_values => Internal} | Acc]);
                {error, _} = Err ->
                    Err
            end
    end;
cast_list_key_values([Node | Rest], Acc) ->
    cast_list_key_values(Rest, [Node | Acc]).

cast_key_leaf_values(_ListPath, Names, Vals) when length(Names) =/= length(Vals) ->
    {error, "Incorrect number of list keys"};
cast_key_leaf_values(ListPath, Names, Vals) ->
    cast_key_leaf_pairs(ListPath, lists:zip(Names, Vals), []).

cast_key_leaf_pairs(_ListPath, [], Acc) ->
    {ok, lists:reverse(Acc)};
cast_key_leaf_pairs(ListPath, [{Name, Val} | Rest], Acc) ->
    case lookup(ListPath ++ [Name]) of
        #{node_type := leaf, type := Type} ->
            case cast(Type, Val) of
                {ok, Internal} ->
                    cast_key_leaf_pairs(ListPath, Rest, [Internal | Acc]);
                {error, _} = Err ->
                    Err
            end;
        _ ->
            {error, "Missing list key schema"}
    end.


cast({uint64, Range}, Token) ->
    FullRange = merge_ranges(uint64_range(), Range),
    cast_integer(Token, FullRange);
cast(uint64, Token) -> cast_integer(Token, uint64_range());

cast({uint32, Range}, Token) ->
    FullRange = merge_ranges(uint32_range(), Range),
    cast_integer(Token, FullRange);
cast(uint32, Token) -> cast_integer(Token, uint32_range());

cast({uint16, Range}, Token) ->
    FullRange = merge_ranges(uint16_range(), Range),
    cast_integer(Token, FullRange);
cast(uint16, Token) -> cast_integer(Token, uint16_range());

cast({uint8, Range}, Token) ->
    FullRange = merge_ranges(uint8_range(), Range),
    cast_integer(Token, FullRange);
cast(uint8, Token) -> cast_integer(Token, uint8_range());

cast({int64, Range}, Token) ->
    FullRange = merge_ranges(int64_range(), Range),
    cast_integer(Token, FullRange);
cast(int64, Token) -> cast_integer(Token, int64_range());

cast({int32, Range}, Token) ->
    FullRange = merge_ranges(int32_range(), Range),
    cast_integer(Token, FullRange);
cast(int32, Token) -> cast_integer(Token, int32_range());

cast({int16, Range}, Token) ->
    FullRange = merge_ranges(int16_range(), Range),
    cast_integer(Token, FullRange);
cast(int16, Token) -> cast_integer(Token, int16_range());

cast({int8, Range}, Token) ->
    FullRange = merge_ranges(int8_range(), Range),
    cast_integer(Token, FullRange);
cast(int8, Token) -> cast_integer(Token, int8_range());

cast(string, Token) -> {ok, Token};
cast(boolean, B) when is_boolean(B) -> {ok, B};
cast(boolean, "true") -> {ok, true};
cast(boolean, "false") -> {ok, false};
cast({enum, AllowedVals}, Token) -> cast_enum(Token, AllowedVals);
cast({enumeration, AllowedVals}, Token) -> cast_enum(Token, AllowedVals);
cast('inet:port-number', Token) -> cast_integer(Token, uint16_range());
cast('inet:ip-address', Addr) when tuple_size(Addr) =:= 4; tuple_size(Addr) =:= 8 ->
    {ok, Addr};
cast('inet:ip-address', Token) -> cast_ip_address(Token);
cast({union, _Types}, _Token) -> {error, "union types are not supported yet"};
cast({bits, _Bits}, _Token) -> {error, "bits types are not supported yet"};
cast({leafref, _Path}, _Token) -> {error, "leafref types are not supported yet"};
cast({identityref, _Base}, _Token) -> {error, "identityref types are not supported yet"};
cast({Mod, Type}, Token) when is_atom(Mod) ->
    case is_yang_constructor(Mod) of
        true ->
            {error, {unknown_type, {Mod, Type}}};
        false ->
            case Mod:cast_value(Type, Token) of
                {ok, Value} -> {ok, Value};
                {error, _Err} = Err ->
                    Err
            end
    end;
cast(Type, _Token) ->
    io:format("MGMTD unsupported leaf type: ~p\n", [Type]),
    {error, {unknown_type, Type}}.

%% YANG `{Tag, Payload}' constructors. Must not be dispatched as Mod:cast_value/2.
is_yang_constructor(enum) -> true;
is_yang_constructor(enumeration) -> true;
is_yang_constructor(union) -> true;
is_yang_constructor(bits) -> true;
is_yang_constructor(leafref) -> true;
is_yang_constructor(identityref) -> true;
is_yang_constructor(uint8) -> true;
is_yang_constructor(uint16) -> true;
is_yang_constructor(uint32) -> true;
is_yang_constructor(uint64) -> true;
is_yang_constructor(int8) -> true;
is_yang_constructor(int16) -> true;
is_yang_constructor(int32) -> true;
is_yang_constructor(int64) -> true;
is_yang_constructor(integer) -> true;
is_yang_constructor(decimal64) -> true;
is_yang_constructor(_) -> false.

merge_ranges([{min, Min} | Rs], UserRange) ->
    case lists:keyfind(min, 1, UserRange) of
        {min, UMin} when UMin > Min ->
            [{min, UMin} | merge_ranges(Rs, UserRange)];
        _ ->
            [{min, Min} | merge_ranges(Rs, UserRange)]
    end;
merge_ranges([{max, Max} | Rs], UserRange) ->
    case lists:keyfind(max, 1, UserRange) of
        {max, UMax} when UMax < Max ->
            [{max, UMax} | merge_ranges(Rs, UserRange)];
        _ ->
            [{max, Max} | merge_ranges(Rs, UserRange)]
    end;
merge_ranges([], _) ->
    [].

uint64_range() -> [{min, 0}, {max, 18446744073709551615}].
uint32_range() -> [{min, 0}, {max, 4294967295}].
uint16_range() -> [{min, 0}, {max, 65535}].
uint8_range() -> [{min, 0}, {max, 255}].

int64_range() -> [{min, -9223372036854775808}, {max, 9223372036854775807}].
int32_range() -> [{min, -2147483648}, {max, 2147483647}].
int16_range() -> [{min, -32768}, {max, 32767}].
int8_range() -> [{min, -128}, {max, 127}].

cast_integer(Int, Range) when is_integer(Int) ->
    cast_integer_in_range(Int, Range);
cast_integer(Token, Range) ->
    case catch list_to_integer(Token) of
        {'EXIT', _} ->
            {error, "Expected an integer value"};
        Int ->
            cast_integer_in_range(Int, Range)
    end.

cast_integer_in_range(Int, [{min, Min} | Rs]) when Int >= Min ->
    cast_integer_in_range(Int, Rs);
cast_integer_in_range(Int, [{max, Max} | Rs]) when Int =< Max ->
    cast_integer_in_range(Int, Rs);
cast_integer_in_range(Int, []) ->
    {ok, Int};
cast_integer_in_range(_Int, _) ->
    {error, "Value out of range"}.

cast_enum(Token, [Member | Rest]) ->
    case enum_member_name(Member) of
        Token -> {ok, Token};
        _ -> cast_enum(Token, Rest)
    end;
cast_enum(_Token, []) ->
    {error, "Unknown enum value"}.

enum_member_name(#{name := Name}) -> Name;
enum_member_name({Name, _Desc}) -> Name;
enum_member_name(Name) when is_list(Name) -> Name.

cast_ip_address(Token) ->
    case inet:parse_address(Token) of
        {ok, _} = Ok -> Ok;
        {error, _Err} -> {error, "Invalid IP Address"}
    end.
