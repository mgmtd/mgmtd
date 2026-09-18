%%%-------------------------------------------------------------------
%%% @doc Invoke YANG `rpc` / `action` via a host callback module.
%%%
%%% The module is the schema node's `data_callback` (set on `#rpc{}` /
%%% `#action{}` or inherited from load-option `callback => Module`).
%%% It implements `invoke/2`:
%%%
%%%     invoke(Path, Input) ->
%%%         {ok, OutputMap} | {ok, empty} | {error, Reason}
%%%
%%% `Path` is an item path (`["prefix", "rpc-name"]`, or an action
%%% under a list instance). `Input` / `OutputMap` are maps keyed by
%%% child names (strings) with already-cast Erlang values.
%%%
%%% RPCs do not write the config DB. The callback may open its own txn.
%%% @end
%%%-------------------------------------------------------------------
-module(mgmtd_rpc).

-include("mgmtd_schema.hrl").

-export([invoke/2, lookup/1]).

-callback invoke(Path :: item_path(), Input :: map()) ->
    {ok, map()} | {ok, empty} | {error, term()}.

-spec lookup(item_path()) -> {ok, map_node()} | {error, map()}.
lookup(Path) ->
    case mgmtd_schema:lookup(Path) of
        #{node_type := Type} = Schema
          when Type =:= rpc; Type =:= action ->
            {ok, Schema};
        #{} ->
            {error, #{tag => <<"invalid-value">>,
                      http => 400,
                      message => <<"not an rpc or action">>}};
        false ->
            {error, #{tag => <<"invalid-value">>,
                      http => 404,
                      message => <<"unknown operation">>}}
    end.

-spec invoke(item_path(), map()) ->
          {ok, map()} | {ok, empty} | {error, map()}.
invoke(Path, Input) when is_map(Input) ->
    case lookup(Path) of
        {error, _} = Err ->
            Err;
        {ok, #{node_type := action} = Schema} ->
            case action_target_exists(Path) of
                false ->
                    {error, #{tag => <<"invalid-value">>,
                              http => 404,
                              message => <<"action target does not exist">>}};
                true ->
                    invoke1(Path, Schema, Input)
            end;
        {ok, Schema} ->
            invoke1(Path, Schema, Input)
    end;
invoke(_Path, _Input) ->
    {error, #{tag => <<"malformed-message">>,
              http => 400,
              message => <<"rpc input must be a map">>}}.

invoke1(Path, Schema, Input) ->
    case validate_payload(Path ++ ["input"], Input) of
        {error, _} = Err ->
            Err;
        {ok, Cast} ->
            case callback_mod(Schema) of
                undefined ->
                    {error, #{tag => <<"operation-failed">>,
                              http => 500,
                              message => <<"no rpc callback">>}};
                Mod ->
                    call(Mod, Path, Cast, Path ++ ["output"])
            end
    end.

callback_mod(#{data_callback := Mod})
  when is_atom(Mod), Mod =/= undefined, Mod =/= mgmtd ->
    Mod;
callback_mod(_) ->
    undefined.

call(Mod, Path, Input, OutputPath) ->
    try Mod:invoke(Path, Input) of
        {ok, empty} ->
            {ok, empty};
        {ok, Out} when is_map(Out) ->
            case output_is_empty(OutputPath) of
                true ->
                    {ok, empty};
                false ->
                    validate_payload(OutputPath, Out)
            end;
        {error, #{tag := _} = Err} ->
            {error, Err};
        {error, Reason} ->
            {error, #{tag => <<"operation-failed">>,
                      http => 500,
                      message => fmt(Reason)}};
        Other ->
            {error, #{tag => <<"operation-failed">>,
                      http => 500,
                      message => fmt({bad_rpc_return, Other})}}
    catch
        C:R:S ->
            {error, #{tag => <<"operation-failed">>,
                      http => 500,
                      message => fmt({C, R, S})}}
    end.

output_is_empty(Path) ->
    case mgmtd_schema:lookup(Path) of
        false ->
            true;
        _ ->
            mgmtd_schema:children(Path, schema) =:= []
    end.

action_target_exists(Path) ->
    Parent = lists:droplast(Path),
    case mgmtd_schema:lookup(Parent) of
        #{node_type := list} = Schema ->
            case lists:reverse(Parent) of
                [Key | _] when is_tuple(Key) ->
                    instance_exists(Parent, Schema);
                _ ->
                    false
            end;
        #{node_type := container} ->
            true;
        _ ->
            false
    end.

instance_exists(Path, #{node_type := list}) ->
    case lists:reverse(Path) of
        [Key | Rest] when is_tuple(Key) ->
            ListPath = lists:reverse(Rest),
            case mgmtd:lookup(ListPath) of
                {ok, Keys} when is_list(Keys) ->
                    lists:member(Key, Keys);
                _ ->
                    false
            end;
        _ ->
            false
    end.

%%--------------------------------------------------------------------
%% Payload walk (input or output)
%%--------------------------------------------------------------------

validate_payload(Path, Map) when is_map(Map) ->
    try
        {ok, walk_object(Path, stringify_keys(Map))}
    catch
        throw:{rpc_error, Err} ->
            {error, Err}
    end;
validate_payload(_Path, _) ->
    {error, #{tag => <<"malformed-message">>,
              http => 400,
              message => <<"payload must be a map">>}}.

stringify_keys(Map) ->
    maps:fold(
      fun(K, V, Acc) ->
              Acc#{to_name(K) => V}
      end, #{}, Map).

walk_object(Path, Map) ->
    Children = mgmtd_schema:children(Path, schema),
    Known = [maps:get(name, C) || C <- Children,
                                  not mgmtd_schema:is_operation_node(C)],
    Unknown = maps:keys(Map) -- Known,
    case Unknown of
        [Bad | _] ->
            fail(400, <<"unknown-element">>, "unknown data node " ++ Bad);
        [] ->
            lists:foldl(
              fun(Child, Acc) ->
                      take_child(Path, Child, Map, Acc)
              end, #{}, Children)
    end.

take_child(Parent, #{name := Name} = Child, Map, Acc) ->
    case maps:find(Name, Map) of
        error ->
            case maps:get(mandatory, Child, false) of
                true ->
                    fail(400, <<"missing-element">>,
                         "missing mandatory node " ++ Name);
                false ->
                    Acc
            end;
        {ok, Val} ->
            Acc#{Name => decode_child(Parent ++ [Name], Child, Val)}
    end.

decode_child(_Path, #{node_type := leaf, type := Type}, Val) ->
    cast_leaf(Type, Val);
decode_child(_Path, #{node_type := leaf_list, type := Type}, Val) when is_list(Val) ->
    [cast_leaf(Type, V) || V <- Val];
decode_child(_Path, #{node_type := leaf_list}, _) ->
    fail(400, <<"malformed-message">>, <<"leaf-list value must be a list">>);
decode_child(Path, #{node_type := container}, Val) when is_map(Val) ->
    walk_object(Path, stringify_keys(Val));
decode_child(_Path, #{node_type := container}, _) ->
    fail(400, <<"malformed-message">>, <<"container value must be a map">>);
decode_child(Path, #{node_type := list} = Schema, Val) ->
    Items = case Val of
                L when is_list(L) -> L;
                M when is_map(M) -> [M];
                _ -> fail(400, <<"malformed-message">>,
                          <<"list value must be a list of maps">>)
            end,
    [decode_list_item(Path, Schema, Item) || Item <- Items];
decode_child(_Path, _Schema, _Val) ->
    fail(400, <<"malformed-message">>, <<"invalid node value">>).

decode_list_item(ListPath, #{key_names := KeyNames}, Item) when is_map(Item) ->
    Map0 = stringify_keys(Item),
    Body = walk_object(ListPath, Map0),
    Keys = [begin
                case maps:find(KN, Body) of
                    {ok, V} -> V;
                    error ->
                        fail(400, <<"missing-element">>,
                             "missing list key " ++ KN)
                end
            end || KN <- KeyNames],
    Body#{<<"$key">> => list_to_tuple(Keys)};
decode_list_item(_ListPath, _Schema, _) ->
    fail(400, <<"malformed-message">>, <<"list item must be a map">>).

cast_leaf(_Type, empty) ->
    empty;
cast_leaf(Type, Val) ->
    case mgmtd_schema:cast(Type, from_json_token(Val)) of
        {ok, Internal} ->
            Internal;
        {error, Reason} ->
            fail(400, <<"invalid-value">>, fmt(Reason))
    end.

from_json_token(B) when is_binary(B) -> binary_to_list(B);
from_json_token(Other) -> Other.

to_name(B) when is_binary(B) ->
    case binary:split(B, <<":">>) of
        [_, Local] -> binary_to_list(Local);
        [Local] -> binary_to_list(Local)
    end;
to_name(L) when is_list(L) -> L;
to_name(A) when is_atom(A) -> atom_to_list(A).

fail(Http, Tag, Msg) ->
    throw({rpc_error, #{http => Http, tag => Tag, message => Msg}}).

fmt(S) when is_list(S) -> S;
fmt(B) when is_binary(B) -> binary_to_list(B);
fmt(R) -> lists:flatten(io_lib:format("~p", [R])).
