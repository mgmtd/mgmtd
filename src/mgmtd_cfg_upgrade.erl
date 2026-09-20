%%%-------------------------------------------------------------------
%%% @doc Automatic schema upgrade of existing configuration rows.
%%%
%%% Runs at database open, after any startup-store seed. Only rows
%%% already in the store are considered; missing schema nodes are not
%%% inserted. There is no previous-schema snapshot — identity is the
%%% stored path name, list-key names on `#cfg{}` rows, and the current
%%% schema.
%%%
%%% See `SCHEMA_UPGRADE.md`.
%%% @end
%%%-------------------------------------------------------------------
-module(mgmtd_cfg_upgrade).

-include("mgmtd_schema.hrl").

-export([maybe_upgrade/0]).

-spec maybe_upgrade() -> ok | {error, term()}.
maybe_upgrade() ->
    case current_rows() of
        {error, db_not_initialized} ->
            ok;
        {ok, Rows} ->
            case upgrade_rows(Rows) of
                {ok, New} ->
                    case normalize(New) =:= normalize(Rows) of
                        true ->
                            ok;
                        false ->
                            mgmtd_cfg_db:transaction(
                              fun() -> mgmtd_cfg_db:replace_all(New) end)
                    end;
                {error, _} = Err ->
                    Err
            end
    end.

%%--------------------------------------------------------------------
%% Current store
%%--------------------------------------------------------------------

current_rows() ->
    try
        {ok, mgmtd_cfg_db:match_object(
               #cfg{_ = mgmtd_schema:ets_pat('_')})}
    catch
        error:db_not_initialized ->
            {error, db_not_initialized}
    end.

normalize(Rows) ->
    lists:keysort(#cfg.path, Rows).

%%--------------------------------------------------------------------
%% Upgrade
%%--------------------------------------------------------------------

upgrade_rows(Rows) ->
    Map = maps:from_list([{P, C} || #cfg{path = P} = C <- Rows]),
    case upgrade_lists(Map, sets:new()) of
        {error, _} = Err ->
            Err;
        {ok, Map1} ->
            case drop_invalid(Map1) of
                {error, _} = Err ->
                    Err;
                {ok, Map2} ->
                    case coerce_leaves(Map2) of
                        {error, _} = Err ->
                            Err;
                        {ok, Map3} ->
                            {ok, maps:values(Map3)}
                    end
            end
    end.

%%--------------------------------------------------------------------
%% Lists / keys
%%--------------------------------------------------------------------

upgrade_lists(Map, Done) ->
    Remaining =
        lists:sort(fun shorter_path/2,
                   [P || P <- list_paths(Map), not sets:is_element(P, Done)]),
    case Remaining of
        [] ->
            {ok, Map};
        [ListPath | _] ->
            case upgrade_list(Map, ListPath) of
                {error, _} = Err ->
                    Err;
                {ok, Map1} ->
                    upgrade_lists(Map1, sets:add_element(ListPath, Done))
            end
    end.

list_paths(Map) ->
    [P || #cfg{path = P, node_type = list} <- maps:values(Map)].

shorter_path(A, B) ->
    length(A) =< length(B).

upgrade_list(Map, ListPath) ->
    case mgmtd_schema:lookup(ListPath) of
        #{node_type := list, config := true, key_names := KeyNames} = Schema ->
            upgrade_instances(Map, ListPath, Schema, KeyNames);
        _ ->
            {ok, Map}
    end.

upgrade_instances(Map, ListPath, Schema, KeyNames) ->
    Insts = [C || #cfg{node_type = list_key, path = P} = C <- maps:values(Map),
                  is_instance_path(ListPath, P)],
    case upgrade_instances(Insts, Map, ListPath, Schema, KeyNames, #{}) of
        {error, _} = Err ->
            Err;
        {ok, Map1, Remap} ->
            {ok, update_list_node(Map1, ListPath, KeyNames, Remap)}
    end.

upgrade_instances([], Map, _ListPath, _Schema, _KeyNames, Remap) ->
    {ok, Map, Remap};
upgrade_instances([Inst | Rest], Map, ListPath, Schema, KeyNames, Remap) ->
    case upgrade_instance(Map, ListPath, Schema, KeyNames, Inst) of
        {error, _} = Err ->
            Err;
        {ok, Map1, dropped} ->
            upgrade_instances(Rest, Map1, ListPath, Schema, KeyNames, Remap);
        {ok, Map1, {OldTuple, NewTuple}} ->
            Remap1 = Remap#{OldTuple => NewTuple},
            upgrade_instances(Rest, Map1, ListPath, Schema, KeyNames, Remap1)
    end.

is_instance_path(ListPath, Path) ->
    length(Path) =:= length(ListPath) + 1 andalso lists:prefix(ListPath, Path).

upgrade_instance(Map, ListPath, _Schema, KeyNames,
                 #cfg{path = InstPath, name = OldTuple} = Inst)
  when is_tuple(OldTuple) ->
    case instance_key_names(Inst, Map, ListPath, KeyNames, OldTuple) of
        {error, drop} ->
            {ok, drop_prefix(Map, InstPath), dropped};
        {ok, OldNames} ->
            case KeyNames -- OldNames of
                [_|_] ->
                    {ok, drop_prefix(Map, InstPath), dropped};
                [] ->
                    Tokens = tuple_to_list(OldTuple),
                    TokenMap = maps:from_list(lists:zip(OldNames, Tokens)),
                    case coerce_key_leaves(Map, InstPath, KeyNames, TokenMap) of
                        drop ->
                            {ok, drop_prefix(Map, InstPath), dropped};
                        {ok, NewTokens, KeyValues} ->
                            NewTuple = list_to_tuple(NewTokens),
                            NewPath = ListPath ++ [NewTuple],
                            apply_instance(Map, InstPath, NewPath, NewTuple,
                                           KeyNames, KeyValues, OldTuple)
                    end
            end
    end;
upgrade_instance(Map, _ListPath, _Schema, _KeyNames, #cfg{path = InstPath}) ->
    {ok, drop_prefix(Map, InstPath), dropped}.

instance_key_names(#cfg{value = Names}, _Map, _ListPath, _KeyNames, OldTuple)
  when is_list(Names), length(Names) =:= tuple_size(OldTuple),
       Names =/= [], is_list(hd(Names)) ->
    {ok, Names};
instance_key_names(_Inst, Map, ListPath, KeyNames, OldTuple) ->
    case maps:get(ListPath, Map, undefined) of
        #cfg{value = Names}
          when is_list(Names), length(Names) =:= tuple_size(OldTuple),
               Names =/= [], is_list(hd(Names)) ->
            {ok, Names};
        _ when tuple_size(OldTuple) =:= length(KeyNames) ->
            {ok, KeyNames};
        _ ->
            {error, drop}
    end.

coerce_key_leaves(Map, InstPath, KeyNames, TokenMap) ->
    coerce_key_leaves(Map, InstPath, KeyNames, TokenMap, [], []).

coerce_key_leaves(_Map, _InstPath, [], _TokenMap, Tokens, Values) ->
    {ok, lists:reverse(Tokens), lists:reverse(Values)};
coerce_key_leaves(Map, InstPath, [Name | Rest], TokenMap, Tokens, Values) ->
    Token = maps:get(Name, TokenMap),
    LeafPath = InstPath ++ [Name],
    case mgmtd_schema:lookup(LeafPath) of
        #{node_type := leaf} = Schema ->
            Stored =
                case maps:find(LeafPath, Map) of
                    {ok, #cfg{value = V}} -> V;
                    error -> Token
                end,
            case coerce_value(Schema, Stored) of
                {ok, Internal} ->
                    NewToken = value_to_token(Internal),
                    coerce_key_leaves(Map, InstPath, Rest, TokenMap,
                                      [NewToken | Tokens],
                                      [{Name, Internal} | Values]);
                {error, _} ->
                    drop
            end;
        _ ->
            drop
    end.

apply_instance(Map, InstPath, NewPath, NewTuple, KeyNames, KeyValues, OldTuple)
  when InstPath =:= NewPath ->
    Map1 = write_list_key(Map, InstPath, NewTuple, KeyNames),
    {ok, write_key_leaves(Map1, NewPath, KeyValues), {OldTuple, NewTuple}};
apply_instance(Map, InstPath, NewPath, NewTuple, KeyNames, KeyValues, OldTuple) ->
    case maps:is_key(NewPath, Map) of
        true ->
            {error, {schema_upgrade, NewPath, key_collision}};
        false ->
            Map1 = remap_prefix(Map, InstPath, NewPath),
            Map2 = write_list_key(Map1, NewPath, NewTuple, KeyNames),
            {ok, write_key_leaves(Map2, NewPath, KeyValues), {OldTuple, NewTuple}}
    end.

write_list_key(Map, InstPath, Tuple, KeyNames) ->
    Cfg = #cfg{path = InstPath,
               name = Tuple,
               node_type = list_key,
               value = KeyNames},
    Map#{InstPath => Cfg}.

write_key_leaves(Map, InstPath, KeyValues) ->
    lists:foldl(
      fun({Name, Internal}, Acc) ->
              Path = InstPath ++ [Name],
              Cfg = #cfg{path = Path,
                         name = Name,
                         node_type = leaf,
                         value = Internal},
              Acc#{Path => Cfg}
      end, Map, KeyValues).

remap_prefix(Map, OldPrefix, NewPrefix) ->
    maps:fold(
      fun(Path, #cfg{} = Cfg, Acc) ->
              case lists:prefix(OldPrefix, Path) of
                  false ->
                      Acc#{Path => Cfg};
                  true ->
                      NewPath = NewPrefix ++ lists:nthtail(length(OldPrefix), Path),
                      Acc#{NewPath => rewrite_cfg(OldPrefix, Path, NewPath, Cfg)}
              end
      end, #{}, Map).

rewrite_cfg(OldPrefix, OldPrefix, NewPath, #cfg{} = Cfg) ->
    Cfg#cfg{path = NewPath, name = lists:last(NewPath)};
rewrite_cfg(_OldPrefix, _OldPath, NewPath, #cfg{} = Cfg) ->
    Cfg#cfg{path = NewPath}.

drop_prefix(Map, Prefix) ->
    maps:filter(fun(Path, _) -> not lists:prefix(Prefix, Path) end, Map).

update_list_node(Map, ListPath, KeyNames, Remap) ->
    case maps:find(ListPath, Map) of
        error ->
            Map;
        {ok, #cfg{value = {ordered, Order}} = Cfg} ->
            NewOrder = [maps:get(T, Remap) || T <- Order, maps:is_key(T, Remap)],
            Map#{ListPath => Cfg#cfg{value = {ordered, NewOrder}}};
        {ok, #cfg{} = Cfg} ->
            Map#{ListPath => Cfg#cfg{value = KeyNames}}
    end.

%%--------------------------------------------------------------------
%% Drop rows that are not in the current config schema
%%--------------------------------------------------------------------

drop_invalid(Map) ->
    {ok, maps:filter(fun(Path, Cfg) -> keep_row(Path, Cfg) end, Map)}.

keep_row(Path, #cfg{node_type = list_key}) ->
    valid_key_tuples(Path) andalso
        case mgmtd_schema:lookup(Path) of
            #{node_type := list} ->
                true;
            _ ->
                false
        end;
keep_row(Path, #cfg{node_type = NodeType}) when NodeType =:= container;
                                               NodeType =:= list ->
    %% Named prefix roots are config=false containers; they still own
    %% the path of config descendants and must not be dropped.
    valid_key_tuples(Path) andalso
        case mgmtd_schema:lookup(Path) of
            #{node_type := NodeType} ->
                true;
            _ ->
                false
        end;
keep_row(Path, #cfg{node_type = NodeType}) ->
    valid_key_tuples(Path) andalso
        case mgmtd_schema:lookup(Path) of
            #{node_type := NodeType, config := true} ->
                true;
            _ ->
                false
        end.

valid_key_tuples(Path) ->
    valid_key_tuples(Path, []).

valid_key_tuples([], _Acc) ->
    true;
valid_key_tuples([T | Rest], Acc) when is_tuple(T) ->
    case mgmtd_schema:lookup(Acc) of
        #{node_type := list, config := true} ->
            valid_key_tuples(Rest, Acc ++ [T]);
        _ ->
            false
    end;
valid_key_tuples([P | Rest], Acc) ->
    valid_key_tuples(Rest, Acc ++ [P]).

%%--------------------------------------------------------------------
%% Leaf / leaf-list values
%%--------------------------------------------------------------------

coerce_leaves(Map) ->
    maps:fold(fun coerce_leaf_row/3, {ok, #{}}, Map).

coerce_leaf_row(_Path, _Cfg, {error, _} = Err) ->
    Err;
coerce_leaf_row(Path, #cfg{node_type = Leaf} = Cfg, {ok, Acc})
  when Leaf =:= leaf; Leaf =:= leaf_list ->
    case mgmtd_schema:lookup(Path) of
        #{node_type := Leaf} = Schema ->
            case coerce_value(Schema, Cfg#cfg.value) of
                {ok, New} ->
                    {ok, Acc#{Path => Cfg#cfg{value = New}}};
                {error, Reason} ->
                    {error, {schema_upgrade, Path, Reason}}
            end;
        _ ->
            {ok, Acc#{Path => Cfg}}
    end;
coerce_leaf_row(Path, Cfg, {ok, Acc}) ->
    {ok, Acc#{Path => Cfg}}.

-spec coerce_value(map(), term()) -> {ok, term()} | {error, term()}.
coerce_value(#{node_type := leaf_list} = Schema, Value) when is_list(Value) ->
    ElSchema = Schema#{node_type => leaf},
    case coerce_list_elems(ElSchema, Value, []) of
        {ok, _} = Ok ->
            Ok;
        {error, Reason} ->
            fallback_default(Schema, Reason)
    end;
coerce_value(#{node_type := leaf_list} = Schema, Value) ->
    fallback_default(Schema, {invalid_leaf_list, Value});
coerce_value(Schema, Value) ->
    case coerce_scalar(Schema, Value) of
        {ok, _} = Ok ->
            Ok;
        {error, Reason} ->
            fallback_default(Schema, Reason)
    end.

coerce_list_elems(_Schema, [], Acc) ->
    {ok, lists:reverse(Acc)};
coerce_list_elems(Schema, [V | Rest], Acc) ->
    case coerce_scalar(Schema, V) of
        {ok, New} ->
            coerce_list_elems(Schema, Rest, [New | Acc]);
        {error, _} = Err ->
            Err
    end.

coerce_scalar(Schema, Value) ->
    case try_cast(Schema, Value) of
        {ok, Cast} ->
            case is_canonical(maps:get(type, Schema, undefined), Cast) of
                true ->
                    {ok, Cast};
                false ->
                    coerce_via_string(Schema, Value)
            end;
        {error, _} ->
            coerce_via_string(Schema, Value)
    end.

coerce_via_string(Schema, Value) ->
    case stringify(Value) of
        {ok, Str} ->
            try_cast(Schema, Str);
        error ->
            {error, {cannot_stringify, Value}}
    end.

fallback_default(Schema, Reason) ->
    case schema_default(Schema) of
        {ok, Def} ->
            {ok, Def};
        false ->
            {error, Reason}
    end.

try_cast(#{node_type := leaf_list} = Schema, Value) when is_list(Value) ->
    mgmtd_schema:cast_value([Schema], Value);
try_cast(Schema, Value) ->
    mgmtd_schema:cast_value([Schema#{node_type => leaf}], Value).

schema_default(Schema) ->
    case maps:get(default, Schema, undefined) of
        undefined ->
            false;
        missing_default ->
            false;
        Def ->
            case try_cast(Schema, Def) of
                {ok, _} = Ok ->
                    Ok;
                {error, _} ->
                    {ok, Def}
            end
    end.

%%--------------------------------------------------------------------
%% Canonical form / stringify
%%--------------------------------------------------------------------

is_canonical({Tag, _}, V) ->
    is_canonical(Tag, V);
is_canonical(Type, V) ->
    case Type of
        string -> is_string(V);
        binary -> is_string(V);
        empty -> V =:= empty;
        boolean -> is_boolean(V);
        'inet:ip-address' -> is_ip(V);
        'inet:port-number' -> is_integer(V);
        'instance-identifier' -> is_string(V);
        decimal64 -> is_string(V) orelse is_integer(V);
        enum -> is_string(V);
        enumeration -> is_string(V);
        identityref -> is_string(V);
        leafref -> is_string(V);
        bits -> is_bits(V);
        union -> true;
        integer -> is_integer(V);
        uint8 -> is_integer(V);
        uint16 -> is_integer(V);
        uint32 -> is_integer(V);
        uint64 -> is_integer(V);
        int8 -> is_integer(V);
        int16 -> is_integer(V);
        int32 -> is_integer(V);
        int64 -> is_integer(V);
        _ -> true
    end.

is_string(L) when is_list(L) ->
    lists:all(fun(C) -> is_integer(C) end, L);
is_string(_) ->
    false.

is_bits(L) when is_list(L) ->
    lists:all(fun is_string/1, L);
is_bits(_) ->
    false.

is_ip(T) when tuple_size(T) =:= 4; tuple_size(T) =:= 8 ->
    true;
is_ip(_) ->
    false.

stringify(true) ->
    {ok, "true"};
stringify(false) ->
    {ok, "false"};
stringify(empty) ->
    {ok, "empty"};
stringify(I) when is_integer(I) ->
    {ok, integer_to_list(I)};
stringify(F) when is_float(F) ->
    {ok, lists:flatten(io_lib:format("~p", [F]))};
stringify(B) when is_binary(B) ->
    {ok, binary_to_list(B)};
stringify(A) when is_atom(A) ->
    {ok, atom_to_list(A)};
stringify(T) when is_tuple(T) ->
    case inet:ntoa(T) of
        S when is_list(S) ->
            {ok, S};
        {error, _} ->
            error
    end;
stringify(L) when is_list(L) ->
    case is_string(L) of
        true ->
            {ok, L};
        false ->
            case is_bits(L) of
                true ->
                    {ok, string:join(L, " ")};
                false ->
                    error
            end
    end;
stringify(_) ->
    error.

value_to_token(Value) ->
    case stringify(Value) of
        {ok, S} ->
            S;
        error ->
            lists:flatten(io_lib:format("~p", [Value]))
    end.
