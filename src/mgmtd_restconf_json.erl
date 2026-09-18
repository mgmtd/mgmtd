%%%-------------------------------------------------------------------
%% @doc Schema-driven RFC 7951 JSON encoding for RESTCONF GET.
%%
%% Target node is always a top-level `module:name` member. Nested
%% nodes of the same module are unqualified. List instances are JSON
%% arrays of objects.
%% @end
%%%-------------------------------------------------------------------
-module(mgmtd_restconf_json).

-export([encode/2, decode/3, exists/1]).

-include("mgmtd_schema.hrl").

-spec encode(term(), all | config | nonconfig | map()) ->
          {ok, map()} | {error, map()}.
encode(What, Content) when Content =:= all; Content =:= config; Content =:= nonconfig ->
    encode(What, #{content => Content, defaults => report_all});
encode(What, Opts) when is_map(Opts) ->
    Ctx = #{content => maps:get(content, Opts, all),
            defaults => maps:get(defaults, Opts, report_all)},
    encode_ctx(What, Ctx).

encode_ctx(datastore, Ctx) ->
    {ok, encode_datastore(Ctx)};
encode_ctx(yanglib_state, #{content := Content}) ->
    case include_config(false, Content) of
        true ->
            {ok, mgmtd_restconf_yanglib:modules_state()};
        false ->
            {error, not_found()}
    end;
encode_ctx(yanglib_id, #{content := Content}) ->
    case include_config(false, Content) of
        true ->
            {ok, #{<<"ietf-yang-library:module-set-id">> =>
                       list_to_binary(mgmtd_restconf_yanglib:module_set_id())}};
        false ->
            {error, not_found()}
    end;
encode_ctx({yanglib_module, Name, Rev}, #{content := Content}) ->
    case include_config(false, Content) of
        true ->
            case mgmtd_restconf_yanglib:find_module(Name, yanglib_rev(Rev)) of
                {ok, M} ->
                    {ok, #{<<"ietf-yang-library:module">> =>
                               [mgmtd_restconf_yanglib:module_json(M)]}};
                error ->
                    {error, not_found()}
            end;
        false ->
            {error, not_found()}
    end;
encode_ctx({yanglib_schema, Name, Rev}, #{content := Content}) ->
    case include_config(false, Content) of
        true ->
            case mgmtd_restconf_yanglib:find_module(Name, yanglib_rev(Rev)) of
                {ok, M} ->
                    case mgmtd_yang_export:schema_uri(M) of
                        undefined ->
                            {error, not_found()};
                        Uri ->
                            {ok, #{<<"ietf-yang-library:schema">> =>
                                       list_to_binary(Uri)}}
                    end;
                error ->
                    {error, not_found()}
            end;
        false ->
            {error, not_found()}
    end;
encode_ctx(#{item_path := Path, schema := Schema, module := Module},
           #{content := Content} = Ctx) ->
    case include_node(Schema, Content) of
        false ->
            {error, not_found()};
        true ->
            encode_target(Path, Schema, Module, Ctx)
    end.

encode_datastore(#{content := Content} = Ctx) ->
    User = lists:foldl(
             fun(Info, Acc) ->
                     maps:merge(Acc, encode_module_top(Info, Ctx))
             end, #{}, mgmtd_schema:loaded_schema_infos()),
    case include_config(false, Content) of
        true ->
            maps:merge(User, mgmtd_restconf_yanglib:modules_state());
        false ->
            User
    end.

encode_module_top(#{prefix := Prefix, module := Module}, Ctx) ->
    TopPath = prefix_base(Prefix),
    Children = restconf_children(TopPath, Prefix),
    lists:foldl(
      fun(Child, Acc) ->
              case encode_child(TopPath, Child, Module, Ctx, qualified) of
                  omit -> Acc;
                  {Key, Val} -> Acc#{Key => Val}
              end
      end, #{}, Children).

encode_target(Path, #{node_type := container} = Schema, Module, Ctx) ->
    Body = encode_container_body(Path, Schema, Module, Ctx),
    {ok, #{qname(Module, maps:get(name, Schema)) => Body}};
encode_target(Path, #{node_type := list, name := Name} = Schema, Module, Ctx) ->
    case lists:last(Path) of
        Key when is_tuple(Key) ->
            case instance_exists(Path, Schema) of
                false ->
                    {error, not_found()};
                true ->
                    case encode_list_item(Path, Schema, Module, Ctx) of
                        omit ->
                            {error, not_found()};
                        Map ->
                            {ok, #{qname(Module, Name) => [Map]}}
                    end
            end;
        _ ->
            {ok, #{qname(Module, Name) =>
                       encode_list_body(Path, Schema, Module, Ctx)}}
    end;
encode_target(Path, #{node_type := leaf, name := Name} = Schema, Module, Ctx) ->
    case leaf_json(Path, Schema, Ctx) of
        omit ->
            {error, not_found()};
        Val ->
            {ok, #{qname(Module, Name) => Val}}
    end;
encode_target(Path, #{node_type := leaf_list, name := Name} = Schema, Module, Ctx) ->
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
            case leaf_list_json(Path, Schema, Ctx) of
                omit ->
                    {error, not_found()};
                Vals ->
                    {ok, #{qname(Module, Name) => Vals}}
            end
    end;
encode_target(_Path, #{node_type := Type}, _Module, _Ctx)
  when Type =:= rpc; Type =:= action; Type =:= notification ->
    {error, #{tag => <<"operation-not-supported">>,
              http => 405,
              message => <<"not a data resource">>}}.

encode_container_body(Path, _Schema, Module, Ctx) ->
    Children = mgmtd_schema:children(Path, show),
    lists:foldl(
      fun(Child, Acc) ->
              case encode_child(Path, Child, Module, Ctx, local) of
                  omit -> Acc;
                  {Key, Val} -> Acc#{Key => Val}
              end
      end, #{}, Children).

encode_child(Parent, #{name := Name} = Child, Module, #{content := Content} = Ctx, Qual) ->
    case include_node(Child, Content) of
        false ->
            omit;
        true ->
            Path = Parent ++ [Name],
            ChildMod = child_module(Child, Module),
            Key = case Qual of
                      qualified ->
                          qname(ChildMod, Name);
                      local when ChildMod =/= Module ->
                          qname(ChildMod, Name);
                      local ->
                          list_to_binary(Name)
                  end,
            encode_child_value(Path, Child, ChildMod, Ctx, Key)
    end.

encode_child_value(Path, #{node_type := leaf} = Schema, _Module, Ctx, Key) ->
    case leaf_json(Path, Schema, Ctx) of
        omit -> omit;
        Val -> {Key, Val}
    end;
encode_child_value(Path, #{node_type := leaf_list} = Schema, _Module, Ctx, Key) ->
    case leaf_list_json(Path, Schema, Ctx) of
        omit -> omit;
        Vals -> {Key, Vals}
    end;
encode_child_value(Path, #{node_type := container} = Schema, Module, Ctx, Key) ->
    Body = encode_container_body(Path, Schema, Module, Ctx),
    case maps:size(Body) of
        0 -> omit;
        _ -> {Key, Body}
    end;
encode_child_value(Path, #{node_type := list} = Schema, Module, Ctx, Key) ->
    case encode_list_body(Path, Schema, Module, Ctx) of
        [] -> omit;
        Items -> {Key, Items}
    end;
encode_child_value(_Path, _Schema, _Module, _Ctx, _Key) ->
    omit.

encode_list_body(Path, Schema, Module, Ctx) ->
    Keys = list_keys(Path),
    lists:filtermap(
      fun(Key) ->
              case encode_list_item(Path ++ [Key], Schema, Module, Ctx) of
                  omit -> false;
                  Map -> {true, Map}
              end
      end, Keys).

encode_list_item(Path, _Schema, Module, Ctx) ->
    Children = mgmtd_schema:children(Path, show),
    Map = lists:foldl(
            fun(Child, Acc) ->
                    case encode_child(Path, Child, Module, Ctx, local) of
                        omit -> Acc;
                        {Key, Val} -> Acc#{Key => Val}
                    end
            end, #{}, Children),
    case maps:size(Map) of
        0 -> omit;
        _ -> Map
    end.

child_module(#{origin_module := Origin}, _Parent) when is_list(Origin) ->
    Origin;
child_module(_, Parent) ->
    Parent.

leaf_json(Path, Schema, Ctx) ->
    case read_leaf(Path, Schema) of
        none ->
            omit;
        {ok, Value, Src} ->
            case keep_value(Value, Src, Schema, Ctx) of
                false -> omit;
                true -> encode_value(maps:get(type, Schema), Value)
            end
    end.

leaf_list_json(Path, Schema, Ctx) ->
    {Vals, Src} = read_leaf_list_src(Path, Schema),
    case Vals of
        [] ->
            omit;
        _ ->
            case keep_value(Vals, Src, Schema, Ctx) of
                false ->
                    omit;
                true ->
                    Type = maps:get(type, Schema),
                    [encode_value(Type, V) || V <- Vals]
            end
    end.

keep_value(_Value, default, _Schema, #{defaults := explicit}) ->
    false;
keep_value(Value, _Src, Schema, #{defaults := trim}) ->
    Default = maps:get(default, Schema, undefined),
    not (Default =/= undefined andalso Value =:= Default);
keep_value(_Value, _Src, _Schema, _) ->
    true.

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
    case stored_leaf(Path) of
        {ok, Value} ->
            {ok, Value, stored};
        none ->
            case maps:get(default, Schema, undefined) of
                undefined -> none;
                Default -> {ok, Default, default}
            end
    end.

read_leaf_list(Path, Schema) ->
    {Vals, _Src} = read_leaf_list_src(Path, Schema),
    Vals.

read_leaf_list_src(Path, Schema) ->
    case stored_leaf(Path) of
        {ok, Vals} when is_list(Vals) ->
            {Vals, stored};
        _ ->
            case maps:get(default, Schema, undefined) of
                undefined -> {[], default};
                Default when is_list(Default) -> {Default, default};
                _ -> {[], default}
            end
    end.

%% Config: only rows actually in the DB count as stored (not schema
%% defaults injected by `mgmtd:lookup/1`). Operational data is stored.
stored_leaf(Path) ->
    case try_cfg_lookup(Path) of
        {ok, Value} ->
            {ok, Value};
        none ->
            case try_lookup(Path) of
                {ok, undefined} -> none;
                {ok, Value} ->
                    case mgmtd_schema:lookup(Path) of
                        #{config := false} -> {ok, Value};
                        _ -> none
                    end;
                _ ->
                    none
            end
    end.

try_cfg_lookup(Path) ->
    try mgmtd_cfg_db:lookup(Path) of
        [#cfg{value = Value}] ->
            {ok, Value};
        [] ->
            none
    catch
        error:db_not_initialized -> none;
        error:badarg -> none
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
    list_to_binary(ip_string(T));
encode_value(_Type, S) when is_list(S) ->
    unicode:characters_to_binary(S);
encode_value(_Type, B) when is_binary(B) ->
    B;
encode_value(_Type, A) when is_atom(A) ->
    atom_to_binary(A, utf8).

ip_string(T) ->
    case inet:ntoa(T) of
        {error, einval} ->
            lists:flatten(io_lib:format("~p", [T]));
        Str ->
            Str
    end.

yanglib_rev("") -> any;
yanglib_rev(Rev) -> Rev.

not_found() ->
    #{tag => <<"invalid-value">>,
      http => 404,
      message => <<"data resource not found">>}.

%%--------------------------------------------------------------------
%% Exists / decode (writes)
%%--------------------------------------------------------------------

-spec exists(map()) -> boolean().
exists(#{schema := #{node_type := list} = Schema, item_path := Path}) ->
    instance_exists(Path, Schema);
exists(#{schema := #{node_type := leaf} = Schema, item_path := Path}) ->
    read_leaf(Path, Schema) =/= none;
exists(#{schema := #{node_type := leaf_list} = Schema, item_path := Path}) ->
    case lists:last(Path) of
        {Val} ->
            leaf_list_has(Path, Schema, Val);
        _ ->
            read_leaf_list(Path, Schema) =/= []
    end;
exists(#{schema := #{node_type := container}}) ->
    true;
exists(_) ->
    false.

%% decode(Parsed, JsonMap, put|post|patch) -> {ok, Ops, CreatedPath} | {error, map()}
%% Ops = [{set, item_path(), term()} | {delete, item_path()}]
-spec decode(map(), map(), put | post | patch) ->
          {ok, list(), map()} | {error, map()}.
decode(Parsed, Body, Mode) when is_map(Body) ->
    try decode1(Parsed, Body, Mode) of
        {Ops, Created} ->
            {ok, Ops, Created}
    catch
        throw:{restconf_error, Err} ->
            {error, Err}
    end;
decode(_Parsed, _Body, _Mode) ->
    {error, #{tag => <<"malformed-message">>,
              http => 400,
              message => <<"request body must be a JSON object">>}}.

decode1(#{schema := #{config := false}}, _Body, _Mode) ->
    err(405, <<"operation-not-supported">>,
        <<"cannot write operational data">>);
decode1(#{schema := #{node_type := Type, name := Name} = Schema,
          item_path := Path, module := Module} = Parsed, Body, Mode) ->
    Inner = unwrap(Body, Module, Name, Type, Mode),
    case {Type, Mode, lists:last(Path)} of
        {list, post, Last} when not is_tuple(Last) ->
            decode_post_list(Path, Schema, Module, Inner);
        {list, put, Key} when is_tuple(Key) ->
            decode_put_instance(Parsed, Schema, Module, Inner);
        {list, patch, Key} when is_tuple(Key) ->
            decode_patch_instance(Parsed, Schema, Module, Inner);
        {leaf, Mode2, _} when Mode2 =/= post ->
            Val = from_json(maps:get(type, Schema), Inner),
            {[{set, Path, Val}], Parsed};
        {leaf_list, post, Last} when not is_tuple(Last) ->
            decode_post_leaf_list(Path, Schema, Module, Inner, Parsed);
        {leaf_list, Mode2, _} when Mode2 =/= post ->
            Val = from_json_list(maps:get(type, Schema), Inner),
            {[{set, Path, Val}], Parsed};
        {container, post, _} ->
            decode_post_container(Path, Schema, Module, Inner, Parsed);
        {container, put, _} ->
            Ops = decode_object(Path, Module, Inner, []),
            {lists:reverse(Ops), Parsed};
        {container, patch, _} ->
            Ops = decode_patch_object(Path, Module, Inner, []),
            {lists:reverse(Ops), Parsed};
        {list, put, Last} when not is_tuple(Last) ->
            err(405, <<"operation-not-supported">>,
                <<"PUT the list instance, not the list">>);
        _ ->
            err(405, <<"operation-not-supported">>,
                <<"method not allowed on this resource">>)
    end.

unwrap(Body, Module, Name, Type, Mode) ->
    Q = qname(Module, Name),
    N = list_to_binary(Name),
    case {maps:is_key(Q, Body), maps:is_key(N, Body)} of
        {true, _} ->
            unwrap_value(maps:get(Q, Body), Type, Mode);
        {false, true} ->
            unwrap_value(maps:get(N, Body), Type, Mode);
        {false, false} ->
            err(400, <<"malformed-message">>,
                "missing " ++ binary_to_list(Q) ++ " in request body")
    end.

unwrap_value(Val, list, post) ->
    to_item_list(Val);
unwrap_value(Val, list, put) ->
    to_item_list(Val);
unwrap_value(Val, list, patch) ->
    to_item_list(Val);
unwrap_value(Val, _Type, _Mode) ->
    Val.

to_item_list(List) when is_list(List) ->
    List;
to_item_list(Map) when is_map(Map) ->
    [Map];
to_item_list(_) ->
    err(400, <<"malformed-message">>, <<"list body must be an object or array">>).

decode_post_list(ListPath, Schema, Module, Items) ->
    case Items of
        [Item] when is_map(Item) ->
            {InstPath, Ops} = decode_new_item(ListPath, Schema, Module, Item),
            Created = #{module => Module,
                        prefix => maps:get(ns, Schema, default),
                        item_path => InstPath,
                        schema => Schema},
            {Ops, Created};
        [_] ->
            err(400, <<"malformed-message">>, <<"list item must be an object">>);
        _ ->
            err(400, <<"malformed-message">>,
                <<"POST must create exactly one list item">>)
    end.

decode_put_instance(#{item_path := InstPath, prefix := Prefix,
                      module := Module} = Parsed,
                    Schema, Module, Items) ->
    Item = one_item(Items),
    {_Path, Sets} = decode_new_item(lists:droplast(InstPath), Schema, Module, Item,
                                    lists:last(InstPath)),
    {[{delete, InstPath} | Sets], Parsed#{prefix => Prefix}}.

decode_patch_instance(#{item_path := InstPath, module := Module} = Parsed,
                      _Schema, Module, Items) ->
    Item = one_item(Items),
    Ops = decode_patch_object(InstPath, Module, Item, []),
    {lists:reverse(Ops), Parsed}.

decode_post_leaf_list(Path, Schema, _Module, Val, Parsed) ->
    Internal = case is_list(Val) of
                   true ->
                       case from_json_list(maps:get(type, Schema), Val) of
                           [One] ->
                               One;
                           _ ->
                               err(400, <<"malformed-message">>,
                                   <<"POST must create exactly one leaf-list entry">>)
                       end;
                   false ->
                       from_json(maps:get(type, Schema), Val)
               end,
    Existing = read_leaf_list(Path, Schema),
    Created = Parsed#{item_path => Path ++ [{Internal}]},
    {[{set, Path, Existing ++ [Internal]}], Created}.

decode_post_container(Path, _Schema, Module, Inner, Parsed) when is_map(Inner) ->
    case maps:size(Inner) of
        1 ->
            Ops = decode_object(Path, Module, Inner, []),
            {lists:reverse(Ops), Parsed};
        _ ->
            err(400, <<"malformed-message">>,
                <<"POST to a container must create one child">>)
    end;
decode_post_container(_Path, _Schema, _Module, _Inner, _Parsed) ->
    err(400, <<"malformed-message">>, <<"container body must be an object">>).

one_item([Item]) when is_map(Item) ->
    Item;
one_item([_]) ->
    err(400, <<"malformed-message">>, <<"list item must be an object">>);
one_item(_) ->
    err(400, <<"malformed-message">>, <<"expected one list item">>).

decode_new_item(ListPath, Schema, Module, Item) ->
    decode_new_item(ListPath, Schema, Module, Item, undefined).

decode_new_item(ListPath, #{key_names := KeyNames} = Schema, Module, Item, UrlKey) ->
    KeyStrs = key_tokens(ListPath, Schema, Item, UrlKey),
    Config = maps:get(config, Schema, true),
    Internals = [begin
                     {ok, I} = case mgmtd_schema:lookup(ListPath ++ [KN]) of
                                   #{type := Type} ->
                                       mgmtd_schema:cast(Type, S);
                                   _ ->
                                       {ok, S}
                               end,
                     I
                 end || {KN, S} <- lists:zip(KeyNames, KeyStrs)],
    Key = case Config of
              false -> list_to_tuple(Internals);
              _ -> list_to_tuple(KeyStrs)
          end,
    InstPath = ListPath ++ [Key],
    Sets = decode_object(InstPath, Module, Item, [{set, InstPath, undefined}]),
    {InstPath, lists:reverse(Sets)}.

key_tokens(ListPath, #{key_names := KeyNames}, Item, undefined) ->
    [body_key_token(ListPath, KN, Item) || KN <- KeyNames];
key_tokens(ListPath, #{key_names := KeyNames}, Item, UrlKey) when is_tuple(UrlKey) ->
    UrlParts = [key_token_from_internal(P) || P <- tuple_to_list(UrlKey)],
    lists:foreach(
      fun({KN, UrlPart}) ->
              case json_member(Item, KN) of
                  error ->
                      ok;
                  {ok, JVal} ->
                      #{type := Type} = mgmtd_schema:lookup(ListPath ++ [KN]),
                      case key_token(Type, from_json(Type, JVal)) of
                          UrlPart ->
                              ok;
                          _ ->
                              err(400, <<"invalid-value">>,
                                  <<"list keys in body do not match the URL">>)
                      end
              end
      end, lists:zip(KeyNames, UrlParts)),
    UrlParts.

body_key_token(ListPath, KN, Item) ->
    case json_member(Item, KN) of
        {ok, JVal} ->
            case mgmtd_schema:lookup(ListPath ++ [KN]) of
                #{type := Type} ->
                    key_token(Type, from_json(Type, JVal));
                _ ->
                    err(400, <<"invalid-value">>, "missing key leaf " ++ KN)
            end;
        error ->
            err(400, <<"invalid-value">>, "missing list key " ++ KN)
    end.

json_member(Map, Name) ->
    N = list_to_binary(Name),
    case maps:find(N, Map) of
        {ok, V} -> {ok, V};
        error -> error
    end.

key_token(_Type, Val) when is_list(Val) ->
    Val;
key_token(_Type, Val) when is_integer(Val) ->
    integer_to_list(Val);
key_token(_Type, Val) when is_tuple(Val), tuple_size(Val) =:= 4;
                           is_tuple(Val), tuple_size(Val) =:= 8 ->
    ip_string(Val);
key_token(_Type, Val) when is_binary(Val) ->
    binary_to_list(Val);
key_token(_Type, Val) when is_atom(Val) ->
    atom_to_list(Val).

key_token_from_internal(Val) ->
    key_token(string, Val).

decode_object(_Path, _Module, Map, Acc) when map_size(Map) =:= 0 ->
    Acc;
decode_object(Path, Module, Map, Acc) ->
    maps:fold(
      fun(Key, Val, A) ->
              Name = member_name(Key, Module),
              Child = Path ++ [Name],
              case mgmtd_schema:lookup(Child) of
                  false ->
                      err(400, <<"unknown-element">>,
                          "unknown data node " ++ Name);
                  Schema ->
                      decode_child(Child, Schema, Module, Val, A)
              end
      end, Acc, Map).

decode_patch_object(Path, Module, Map, Acc) ->
    maps:fold(
      fun(Key, null, A) ->
              Name = member_name(Key, Module),
              [{delete, Path ++ [Name]} | A];
         (Key, Val, A) ->
              Name = member_name(Key, Module),
              Child = Path ++ [Name],
              case mgmtd_schema:lookup(Child) of
                  false ->
                      err(400, <<"unknown-element">>,
                          "unknown data node " ++ Name);
                  Schema ->
                      decode_child(Child, Schema, Module, Val, A)
              end
      end, Acc, Map).

decode_child(Path, #{node_type := leaf} = Schema, _Module, Val, Acc) ->
    [{set, Path, from_json(maps:get(type, Schema), Val)} | Acc];
decode_child(Path, #{node_type := leaf_list} = Schema, _Module, Val, Acc) ->
    [{set, Path, from_json_list(maps:get(type, Schema), Val)} | Acc];
decode_child(Path, #{node_type := container}, Module, Val, Acc) when is_map(Val) ->
    decode_object(Path, Module, Val, Acc);
decode_child(Path, #{node_type := list} = Schema, Module, Val, Acc) ->
    lists:foldl(
      fun(Item, A) when is_map(Item) ->
              {_Inst, Ops} = decode_new_item(Path, Schema, Module, Item),
              Ops ++ A;
         (_, _) ->
              err(400, <<"malformed-message">>, <<"list item must be an object">>)
      end, Acc, to_item_list(Val));
decode_child(_Path, _Schema, _Module, _Val, _Acc) ->
    err(400, <<"malformed-message">>, <<"invalid node value">>).

member_name(Key, Module) when is_binary(Key) ->
    case binary:split(Key, <<":">>) of
        [Name] ->
            binary_to_list(Name);
        [Mod, Name] ->
            case binary_to_list(Mod) of
                Module ->
                    binary_to_list(Name);
                _ ->
                    err(400, <<"unknown-element">>,
                        "unexpected module " ++ binary_to_list(Mod))
            end
    end.

from_json_list(Type, List) when is_list(List) ->
    [from_json(Type, V) || V <- List];
from_json_list(_Type, _) ->
    err(400, <<"malformed-message">>, <<"leaf-list value must be a JSON array">>).

from_json(_Type, null) ->
    err(400, <<"invalid-value">>, <<"invalid leaf value">>);
from_json(boolean, B) when is_boolean(B) ->
    B;
from_json(empty, [null]) ->
    empty;
from_json(empty, null) ->
    empty;
from_json(Type, B) when is_binary(B) ->
    cast_or_err(Type, binary_to_list(B));
from_json(Type, N) when is_integer(N) ->
    cast_or_err(Type, N);
from_json(Type, B) when is_boolean(B) ->
    cast_or_err(Type, B);
from_json(_Type, F) when is_float(F) ->
    err(400, <<"invalid-value">>, <<"expected an integer value">>);
from_json(_Type, _) ->
    err(400, <<"invalid-value">>, <<"invalid leaf value">>).

cast_or_err(Type, Token) ->
    case mgmtd_schema:cast(Type, Token) of
        {ok, Internal} ->
            Internal;
        {error, Reason} ->
            err(400, <<"invalid-value">>, fmt_reason(Reason))
    end.

fmt_reason(S) when is_list(S) ->
    S;
fmt_reason(R) ->
    lists:flatten(io_lib:format("~p", [R])).

err(Http, Tag, Msg) ->
    throw({restconf_error, #{http => Http, tag => Tag, message => Msg}}).

