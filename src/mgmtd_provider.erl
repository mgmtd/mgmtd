%%%-------------------------------------------------------------------
%%% @doc Behaviour for an operational-data provider.
%%%
%%% Configuration is stored in the config DB. Operational data (`config
%%% = false`) is read from a host callback module named in the schema
%%% as `data_callback`. That module applies to the node and its
%%% descendants unless a child sets its own.
%%%
%%% Paths are the same item paths used by `mgmtd:lookup/1`, including
%%% list keys as tuples:
%%%
%%%     ["status", "interfaces", {"eth0"}, "mtu"]
%%%
%%% Returns:
%%%
%%%   get_value(Path) ->
%%%       {ok, Value} | {ok, not_found} | {error, Reason}
%%%
%%%   get_first(Path) ->
%%%       {ok, ListKey} | {ok, not_found} | {error, Reason}
%%%
%%%   get_next(Path, PrevKey) ->
%%%       {ok, ListKey} | {ok, not_found} | {error, Reason}
%%%
%%% `Path` for `get_first` / `get_next` is the list node (no key).
%%% `ListKey` is a tuple with one element per `key_names` entry.
%%%
%%% `list_keys/3` is a helper that walks `get_first` / `get_next` and
%%% applies the same match patterns ecli uses for list-key completion.
%%% Host modules that are used as `data_callback` from the CLI can
%%% implement `list_keys/3` as:
%%%
%%%     list_keys(_Txn, Path, Match) ->
%%%         mgmtd_provider:list_keys(?MODULE, Path, Match).
%%%
%%% See `mgmtd_test_provider` for an in-tree example.
%%% @end
%%%-------------------------------------------------------------------
-module(mgmtd_provider).

-include("mgmtd_schema.hrl").

-export([fetch/1, list_keys/2, list_keys/3, get_tree/1]).
-export([mod/1]).

-callback get_value(Path :: item_path()) ->
    {ok, term()} | {ok, not_found} | {error, term()}.

-callback get_first(Path :: item_path()) ->
    {ok, list_key()} | {ok, not_found} | {error, term()}.

-callback get_next(Path :: item_path(), Prev :: list_key()) ->
    {ok, list_key()} | {ok, not_found} | {error, term()}.

%% @doc Provider module stored on a schema node, if this is operational
%% data served by a host callback. `mgmtd` is the config-DB callback
%% used for configuration lists, not an operational provider.
-spec mod(item_path() | map_node()) -> atom() | undefined.
mod(#{config := false, data_callback := Mod})
  when is_atom(Mod), Mod =/= undefined, Mod =/= mgmtd ->
    Mod;
mod(#{}) ->
    undefined;
mod(Path) when is_list(Path) ->
    case mgmtd_schema:lookup(Path) of
        #{} = Map ->
            mod(Map);
        false ->
            undefined
    end;
mod(_) ->
    undefined.

%% @doc Read an operational leaf or leaf-list at Path.
-spec fetch(item_path()) -> {ok, term()} | {ok, not_found} | {error, term()}.
fetch(Path) ->
    case key_leaf_value(Path) of
        {ok, Value} ->
            {ok, Value};
        false ->
            case provider_mod(Path) of
                {ok, Mod} ->
                    call(Mod, get_value, [Path]);
                {error, _} = Err ->
                    Err
            end
    end.

%% @doc List keys at Path, filtered by Match (`'$1'` or an ETS-style
%% key tuple with `'$1'` / `'_'`). Looks up the provider from the schema.
-spec list_keys(item_path(), term()) -> {ok, [term()]} | {error, term()}.
list_keys(Path, Match) ->
    case provider_mod(Path) of
        {ok, Mod} ->
            list_keys(Mod, Path, Match);
        {error, _} = Err ->
            Err
    end.

-spec list_keys(module(), item_path(), term()) -> {ok, [term()]} | {error, term()}.
list_keys(Mod, Path, Match) ->
    case call(Mod, get_first, [Path]) of
        {ok, not_found} ->
            {ok, []};
        {ok, Key} ->
            collect_keys(Mod, Path, Match, Key, [], #{Key => true});
        {error, _} = Err ->
            Err
    end.

%% @doc Nested tree for `show` of an operational path. Same shape as
%% `mgmtd_cfg_db:simplify_tree/1`: `[{Name, Children} | {Name, {value, V}}]`.
-spec get_tree(item_path()) -> {ok, list()} | {error, term()}.
get_tree(Path) ->
    SchemaPath = schema_path(Path),
    case mgmtd_schema:lookup(SchemaPath) of
        false ->
            {error, unknown_schema_path};
        Schema ->
            tree_at(Path, Schema)
    end.

%%%===================================================================
%%% Internal
%%%===================================================================

provider_mod(Path) ->
    SchemaPath = schema_path(Path),
    case mgmtd_schema:lookup(SchemaPath) of
        false ->
            {error, unknown_schema_path};
        Schema ->
            case mod(Schema) of
                undefined ->
                    {error, no_data_callback};
                Mod ->
                    {ok, Mod}
            end
    end.

schema_path(Path) ->
    [El || El <- Path, not is_tuple(El)].

call(Mod, Fun, Args) ->
    try apply(Mod, Fun, Args) of
        {ok, _} = Ok ->
            Ok;
        {error, _} = Err ->
            Err;
        Other ->
            {error, {invalid_provider_return, Other}}
    catch
        Class:Reason ->
            {error, {provider_failed, {Class, Reason}}}
    end.

collect_keys(Mod, Path, Match, Key, Acc, Seen) ->
    Acc1 =
        case match_key(Match, Key) of
            {true, Value} ->
                [Value | Acc];
            false ->
                Acc
        end,
    case call(Mod, get_next, [Path, Key]) of
        {ok, not_found} ->
            {ok, lists:reverse(Acc1)};
        {ok, Next} ->
            case maps:is_key(Next, Seen) of
                true ->
                    {ok, lists:reverse(Acc1)};
                false ->
                    collect_keys(Mod, Path, Match, Next, Acc1,
                                 Seen#{Next => true})
            end;
        {error, _} = Err ->
            Err
    end.

%% `'$1'` as the whole match returns each full key tuple (lookup / tests).
%% A tuple match binds `'$1'` to that element's value (ecli completion).
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

%% List-key leaf values are in the path; do not require the provider
%% to serve them.
key_leaf_value(Path) ->
    case lists:reverse(Path) of
        [Name, Key | Rest] when is_list(Name), is_tuple(Key) ->
            ListPath = lists:reverse(Rest),
            case mgmtd_schema:lookup(ListPath) of
                #{node_type := list, key_names := KeyNames} ->
                    key_element(Name, KeyNames, Key);
                _ ->
                    false
            end;
        _ ->
            false
    end.

key_element(Name, KeyNames, Key) ->
    key_element(Name, KeyNames, Key, 1).

key_element(Name, [Name | _], Key, I) when I =< tuple_size(Key) ->
    {ok, element(I, Key)};
key_element(Name, [_ | Rest], Key, I) ->
    key_element(Name, Rest, Key, I + 1);
key_element(_, [], _, _) ->
    false.

tree_at(Path, #{node_type := leaf, name := Name} = Schema) ->
    tree_leaf(Path, Name, Schema);
tree_at(Path, #{node_type := leaf_list, name := Name} = Schema) ->
    tree_leaf(Path, Name, Schema);
tree_at(Path, #{node_type := container, name := Name}) ->
    case tree_children(Path) of
        {ok, Parts} ->
            {ok, [{Name, Parts}]};
        {error, _} = Err ->
            Err
    end;
tree_at(Path, #{node_type := list, name := Name}) ->
    case lists:last(Path) of
        Last when is_tuple(Last) ->
            tree_children(Path);
        _ ->
            case list_keys(Path, '$1') of
                {ok, Keys} ->
                    Items = lists:flatmap(
                              fun(Key) ->
                                      case tree_children(Path ++ [Key]) of
                                          {ok, Item} ->
                                              [{Key, Item}];
                                          {error, _} ->
                                              []
                                      end
                              end, Keys),
                    {ok, [{Name, Items}]};
                {error, _} = Err ->
                    Err
            end
    end.

tree_leaf(Path, Name, Schema) ->
    case fetch(Path) of
        {ok, not_found} ->
            case Schema of
                #{default := Default} when Default =/= undefined ->
                    {ok, [{Name, {value, Default}}]};
                _ ->
                    {ok, []}
            end;
        {ok, Value} ->
            {ok, [{Name, {value, Value}}]};
        {error, _} = Err ->
            Err
    end.

tree_children(Path) ->
    Children = mgmtd_schema:children(Path, show),
    Parts =
        lists:flatmap(
          fun(#{name := Name} = Child) ->
                  case tree_at(Path ++ [Name], Child) of
                      {ok, Part} ->
                          Part;
                      {error, _} ->
                          []
                  end
          end, Children),
    {ok, Parts}.
