%%%-------------------------------------------------------------------
%% @doc Schema-driven RFC 7951 JSON encoding for RESTCONF GET.
%%
%% Target node is always a top-level `module:name` member. Nested
%% nodes of the same module are unqualified. List instances are JSON
%% arrays of objects.
%% @end
%%%-------------------------------------------------------------------
-module(mgmtd_restconf_json).

-export([encode/2]).

-include("mgmtd_schema.hrl").

-spec encode(term(), all | config | nonconfig) ->
          {ok, map()} | {error, map()}.
encode(datastore, Content) ->
    {ok, encode_datastore(Content)};
encode(yanglib_state, Content) ->
    case include_config(false, Content) of
        true ->
            {ok, mgmtd_restconf_yanglib:modules_state()};
        false ->
            {error, not_found()}
    end;
encode(yanglib_id, Content) ->
    case include_config(false, Content) of
        true ->
            {ok, #{<<"ietf-yang-library:module-set-id">> =>
                       list_to_binary(mgmtd_restconf_yanglib:module_set_id())}};
        false ->
            {error, not_found()}
    end;
encode(#{item_path := Path, schema := Schema, module := Module}, Content) ->
    case include_node(Schema, Content) of
        false ->
            {error, not_found()};
        true ->
            encode_target(Path, Schema, Module, Content)
    end.

encode_datastore(Content) ->
    User = lists:foldl(
             fun(Info, Acc) ->
                     maps:merge(Acc, encode_module_top(Info, Content))
             end, #{}, mgmtd_schema:loaded_schema_infos()),
    case include_config(false, Content) of
        true ->
            maps:merge(User, mgmtd_restconf_yanglib:modules_state());
        false ->
            User
    end.

encode_module_top(#{prefix := Prefix, module := Module}, Content) ->
    TopPath = prefix_base(Prefix),
    Children = restconf_children(TopPath, Prefix),
    lists:foldl(
      fun(Child, Acc) ->
              case encode_child(TopPath, Child, Module, Content, qualified) of
                  omit -> Acc;
                  {Key, Val} -> Acc#{Key => Val}
              end
      end, #{}, Children).

encode_target(Path, #{node_type := container} = Schema, Module, Content) ->
    case encode_container_body(Path, Schema, Module, Content) of
        Body ->
            {ok, #{qname(Module, maps:get(name, Schema)) => Body}}
    end;
encode_target(Path, #{node_type := list, name := Name} = Schema, Module, Content) ->
    case lists:last(Path) of
        Key when is_tuple(Key) ->
            case instance_exists(Path, Schema) of
                false ->
                    {error, not_found()};
                true ->
                    case encode_list_item(Path, Schema, Module, Content) of
                        omit ->
                            {error, not_found()};
                        Map ->
                            {ok, #{qname(Module, Name) => [Map]}}
                    end
            end;
        _ ->
            {ok, #{qname(Module, Name) =>
                       encode_list_body(Path, Schema, Module, Content)}}
    end;
encode_target(Path, #{node_type := leaf, name := Name} = Schema, Module, _Content) ->
    case read_leaf(Path, Schema) of
        none ->
            {error, not_found()};
        {ok, Value} ->
            {ok, #{qname(Module, Name) => encode_value(maps:get(type, Schema), Value)}}
    end;
encode_target(Path, #{node_type := leaf_list, name := Name} = Schema, Module, _Content) ->
    case lists:last(Path) of
        {Val} ->
            case leaf_list_has(Path, Schema, Val) of
                false ->
                    {error, not_found()};
                true ->
                    Type = maps:get(type, Schema),
                    {ok, #{qname(Module, Name) => [encode_value(Type, Val)]}}
            end;
        _ ->
            Vals = read_leaf_list(Path, Schema),
            {ok, #{qname(Module, Name) =>
                       [encode_value(maps:get(type, Schema), V) || V <- Vals]}}
    end.

encode_container_body(Path, _Schema, Module, Content) ->
    Children = mgmtd_schema:children(Path, show),
    lists:foldl(
      fun(Child, Acc) ->
              case encode_child(Path, Child, Module, Content, local) of
                  omit -> Acc;
                  {Key, Val} -> Acc#{Key => Val}
              end
      end, #{}, Children).

encode_child(Parent, #{name := Name} = Child, Module, Content, Qual) ->
    case include_node(Child, Content) of
        false ->
            omit;
        true ->
            Path = Parent ++ [Name],
            Key = case Qual of
                      qualified -> qname(Module, Name);
                      local -> list_to_binary(Name)
                  end,
            encode_child_value(Path, Child, Module, Content, Key)
    end.

encode_child_value(Path, #{node_type := leaf} = Schema, _Module, _Content, Key) ->
    case read_leaf(Path, Schema) of
        none ->
            omit;
        {ok, Value} ->
            {Key, encode_value(maps:get(type, Schema), Value)}
    end;
encode_child_value(Path, #{node_type := leaf_list} = Schema, _Module, _Content, Key) ->
    case read_leaf_list(Path, Schema) of
        [] ->
            omit;
        Vals ->
            Type = maps:get(type, Schema),
            {Key, [encode_value(Type, V) || V <- Vals]}
    end;
encode_child_value(Path, #{node_type := container} = Schema, Module, Content, Key) ->
    Body = encode_container_body(Path, Schema, Module, Content),
    case maps:size(Body) of
        0 -> omit;
        _ -> {Key, Body}
    end;
encode_child_value(Path, #{node_type := list} = Schema, Module, Content, Key) ->
    case encode_list_body(Path, Schema, Module, Content) of
        [] -> omit;
        Items -> {Key, Items}
    end;
encode_child_value(_Path, _Schema, _Module, _Content, _Key) ->
    omit.

encode_list_body(Path, Schema, Module, Content) ->
    Keys = list_keys(Path),
    lists:filtermap(
      fun(Key) ->
              case encode_list_item(Path ++ [Key], Schema, Module, Content) of
                  omit -> false;
                  Map -> {true, Map}
              end
      end, lists:sort(Keys)).

encode_list_item(Path, _Schema, Module, Content) ->
    Children = mgmtd_schema:children(Path, show),
    Map = lists:foldl(
            fun(Child, Acc) ->
                    case encode_child(Path, Child, Module, Content, local) of
                        omit -> Acc;
                        {Key, Val} -> Acc#{Key => Val}
                    end
            end, #{}, Children),
    case maps:size(Map) of
        0 -> omit;
        _ -> Map
    end.

instance_exists(Path, #{node_type := list}) ->
    case lists:reverse(Path) of
        [Key | Rest] when is_tuple(Key) ->
            lists:member(Key, list_keys(lists:reverse(Rest)));
        _ ->
            true
    end.

leaf_list_has(Path, Schema, Val) ->
    case lists:reverse(Path) of
        [{Val} | Rest] ->
            ListPath = lists:reverse(Rest),
            lists:member(Val, read_leaf_list(ListPath, Schema))
                orelse lists:member(cast_leaf_list_val(Schema, Val),
                                    read_leaf_list(ListPath, Schema));
        _ ->
            false
    end.

cast_leaf_list_val(#{type := Type}, Val) ->
    case mgmtd_schema:cast(Type, Val) of
        {ok, Internal} -> Internal;
        _ -> Val
    end.

list_keys(Path) ->
    case try_lookup(Path) of
        {ok, Keys} when is_list(Keys) ->
            [K || K <- Keys, is_tuple(K)];
        _ ->
            []
    end.

read_leaf(Path, Schema) ->
    case try_lookup(Path) of
        {ok, undefined} ->
            none;
        {ok, Value} ->
            {ok, Value};
        _ ->
            case maps:get(default, Schema, undefined) of
                undefined -> none;
                Default -> {ok, Default}
            end
    end.

read_leaf_list(Path, Schema) ->
    case try_lookup(Path) of
        {ok, Vals} when is_list(Vals) ->
            Vals;
        _ ->
            case maps:get(default, Schema, undefined) of
                undefined -> [];
                Default when is_list(Default) -> Default;
                _ -> []
            end
    end.

try_lookup(Path) ->
    try mgmtd:lookup(Path) of
        {ok, _} = Ok ->
            Ok;
        {error, _} = Err ->
            Err
    catch
        error:db_not_initialized ->
            {error, db_not_initialized};
        error:badarg ->
            {error, no_schema}
    end.

include_node(Schema, Content) ->
    include_config(maps:get(config, Schema, false), Content).

include_config(true, nonconfig) -> false;
include_config(false, config) -> false;
include_config(_, _) -> true.

restconf_children(TopPath, Prefix) ->
    Named = [atom_to_list(P) || #{prefix := P} <- mgmtd_schema:loaded_schema_infos(),
                                P =/= ?DEFAULT_NS],
    [C || C <- mgmtd_schema:children(TopPath, show),
          not (Prefix =:= ?DEFAULT_NS
               andalso lists:member(maps:get(name, C), Named))].

prefix_base(?DEFAULT_NS) ->
    [];
prefix_base(Prefix) ->
    [atom_to_list(Prefix)].

qname(Module, Name) ->
    list_to_binary([Module, $:, Name]).

encode_value(_Type, empty) ->
    [null];
encode_value(boolean, B) when is_boolean(B) ->
    B;
encode_value(binary, B) when is_binary(B) ->
    base64:encode(B);
encode_value(_Type, N) when is_integer(N) ->
    N;
encode_value(_Type, F) when is_float(F) ->
    F;
encode_value(_Type, B) when is_boolean(B) ->
    B;
encode_value(_Type, T) when is_tuple(T), tuple_size(T) =:= 4;
                            is_tuple(T), tuple_size(T) =:= 8 ->
    list_to_binary(inet:ntoa(T));
encode_value(_Type, S) when is_list(S) ->
    unicode:characters_to_binary(S);
encode_value(_Type, B) when is_binary(B) ->
    B;
encode_value(_Type, A) when is_atom(A) ->
    atom_to_binary(A, utf8).

not_found() ->
    #{tag => <<"invalid-value">>,
      http => 404,
      message => <<"data resource not found">>}.
