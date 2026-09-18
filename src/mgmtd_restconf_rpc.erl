%%%-------------------------------------------------------------------
%%% @doc RESTCONF `{+restconf}/operations` and nested `action` POST.
%%%
%%% RFC 8040 §3.6 / §4.4.2: GET lists rpcs as empty resources; POST
%%% invokes. Nested actions are POST to the data instance.
%%% @end
%%%-------------------------------------------------------------------
-module(mgmtd_restconf_rpc).

-export([operations_json/0, operation_json/2,
         parse_operation/1,
         post_rpc/3, post_action/3,
         http_operations/3, http_action/3]).

-include("mgmtd_schema.hrl").

-define(JSON, <<"application/yang-data+json">>).

-spec operations_json() -> map().
operations_json() ->
    #{<<"ietf-restconf:operations">> =>
          maps:from_list(
            [{qname(rpc_module(R), maps:get(name, R)), [null]}
             || R <- mgmtd_schema:rpcs()])}.

-spec operation_json(string(), string()) -> {ok, map()} | {error, map()}.
operation_json(Module, Name) ->
    case find_rpc(Module, Name) of
        {ok, _} ->
            {ok, #{qname(Module, Name) => [null]}};
        error ->
            {error, #{tag => <<"invalid-value">>,
                      http => 404,
                      message => <<"unknown operation">>}}
    end.

-spec parse_operation(binary()) ->
          {ok, list} | {ok, {rpc, string(), string(), item_path()}} |
          {error, map()}.
parse_operation(<<"/restconf/operations">>) ->
    {ok, list};
parse_operation(<<"/restconf/operations/">>) ->
    {ok, list};
parse_operation(<<"/restconf/operations/", Rest/binary>>) ->
    case binary:split(Rest, <<"/">>, [global]) of
        [Seg] when Seg =/= <<>> ->
            parse_rpc_ident(Seg);
        _ ->
            {error, #{tag => <<"invalid-value">>,
                      http => 400,
                      message => <<"invalid operations path">>}}
    end;
parse_operation(_) ->
    {error, #{tag => <<"invalid-value">>,
              http => 400,
              message => <<"not a RESTCONF operations resource">>}}.

parse_rpc_ident(Seg) ->
    case binary:split(Seg, <<":">>) of
        [ModBin, NameBin] ->
            Module = binary_to_list(ModBin),
            Name = binary_to_list(NameBin),
            case find_rpc(Module, Name) of
                {ok, Path} ->
                    {ok, {rpc, Module, Name, Path}};
                error ->
                    {error, #{tag => <<"invalid-value">>,
                              http => 404,
                              message => <<"unknown operation">>}}
            end;
        _ ->
            {error, #{tag => <<"invalid-value">>,
                      http => 400,
                      message => <<"operation must be module:name">>}}
    end.

find_rpc(Module, Name) ->
    case [R || R <- mgmtd_schema:rpcs(),
               rpc_module(R) =:= Module,
               maps:get(name, R) =:= Name] of
        [R | _] ->
            {ok, maps:get(path, R)};
        [] ->
            error
    end.

rpc_module(#{ns := Prefix}) ->
    case [M || #{prefix := P, module := M} <- mgmtd_schema:loaded_schema_infos(),
               P =:= Prefix] of
        [M | _] -> M;
        [] -> atom_to_list(Prefix)
    end.

-spec post_rpc(item_path(), string(), map()) ->
          {ok, empty} | {ok, map()} | {error, map()}.
post_rpc(Path, Module, Body) ->
    case unwrap_input(Module, Body) of
        {error, _} = Err ->
            Err;
        {ok, Input} ->
            wrap_output(Module, mgmtd_rpc:invoke(Path, Input))
    end.

-spec post_action(item_path(), string(), map()) ->
          {ok, empty} | {ok, map()} | {error, map()}.
post_action(Path, Module, Body) ->
    post_rpc(Path, Module, Body).

unwrap_input(Module, Body) when is_map(Body) ->
    Q = qname(Module, "input"),
    case {maps:is_key(Q, Body), maps:is_key(<<"input">>, Body), map_size(Body)} of
        {true, _, _} ->
            inner_map(maps:get(Q, Body));
        {false, true, _} ->
            inner_map(maps:get(<<"input">>, Body));
        {false, false, 0} ->
            {ok, #{}};
        {false, false, _} ->
            %% RFC 8040 wraps input; allow a bare object of input children.
            {ok, Body}
    end;
unwrap_input(_Module, undefined) ->
    {ok, #{}};
unwrap_input(_Module, _) ->
    {error, #{tag => <<"malformed-message">>,
              http => 400,
              message => <<"request body must be a JSON object">>}}.

inner_map(Map) when is_map(Map) ->
    {ok, Map};
inner_map(_) ->
    {error, #{tag => <<"malformed-message">>,
              http => 400,
              message => <<"input must be a JSON object">>}}.

wrap_output(_Module, {ok, empty}) ->
    {ok, empty};
wrap_output(Module, {ok, Out}) when is_map(Out) ->
    {ok, #{qname(Module, "output") => encode_object(Out)}};
wrap_output(_Module, {error, _} = Err) ->
    Err.

encode_object(Map) ->
    maps:fold(
      fun(<<"$key">>, _, Acc) ->
              Acc;
         (K, V, Acc) ->
              Acc#{json_key(K) => encode_val(V)}
      end, #{}, Map).

json_key(B) when is_binary(B) -> B;
json_key(L) when is_list(L) -> unicode:characters_to_binary(L);
json_key(A) when is_atom(A) -> atom_to_binary(A, utf8).

encode_val(empty) -> [null];
encode_val(M) when is_map(M) -> encode_object(M);
encode_val(L) when is_list(L), L =/= [], is_map(hd(L)) ->
    [encode_object(I) || I <- L];
encode_val(L) when is_list(L) ->
    case io_lib:printable_unicode_list(L) of
        true -> unicode:characters_to_binary(L);
        false -> [encode_val(V) || V <- L]
    end;
encode_val(N) when is_integer(N) -> N;
encode_val(F) when is_float(F) -> F;
encode_val(B) when is_boolean(B) -> B;
encode_val(B) when is_binary(B) -> B;
encode_val(T) when is_tuple(T), tuple_size(T) =:= 4;
                   is_tuple(T), tuple_size(T) =:= 8 ->
    case inet:ntoa(T) of
        {error, einval} -> list_to_binary(io_lib:format("~p", [T]));
        S -> list_to_binary(S)
    end;
encode_val(A) when is_atom(A) -> atom_to_binary(A, utf8);
encode_val(Other) -> list_to_binary(io_lib:format("~p", [Other])).

-spec http_operations(binary(), binary(), cowboy_req:req()) -> cowboy_req:req().
http_operations(Method, Path, Req) ->
    case parse_operation(Path) of
        {error, Err} ->
            mgmtd_restconf_error:reply(Req, status(Err), Err);
        {ok, list} ->
            http_list(Method, Req);
        {ok, {rpc, Module, Name, RpcPath}} ->
            http_one(Method, Module, Name, RpcPath, Req)
    end.

http_list(<<"OPTIONS">>, Req) ->
    cowboy_req:reply(200, #{<<"allow">> => <<"GET, HEAD, OPTIONS">>}, <<>>, Req);
http_list(<<"GET">>, Req) ->
    json_reply(Req, 200, operations_json());
http_list(<<"HEAD">>, Req) ->
    json_head(Req, operations_json());
http_list(_, Req) ->
    cowboy_req:reply(405, #{<<"allow">> => <<"GET, HEAD, OPTIONS">>}, <<>>, Req).

http_one(<<"OPTIONS">>, _Module, _Name, _Path, Req) ->
    cowboy_req:reply(200, #{<<"allow">> => <<"GET, HEAD, POST, OPTIONS">>}, <<>>, Req);
http_one(<<"GET">>, Module, Name, _Path, Req) ->
    case operation_json(Module, Name) of
        {ok, Map} -> json_reply(Req, 200, Map);
        {error, Err} -> mgmtd_restconf_error:reply(Req, status(Err), Err)
    end;
http_one(<<"HEAD">>, Module, Name, _Path, Req) ->
    case operation_json(Module, Name) of
        {ok, Map} -> json_head(Req, Map);
        {error, Err} -> mgmtd_restconf_error:reply(Req, status(Err), Err)
    end;
http_one(<<"POST">>, Module, _Name, Path, Req) ->
    post_http(fun(Body) -> post_rpc(Path, Module, Body) end, Req);
http_one(_, _Module, _Name, _Path, Req) ->
    cowboy_req:reply(405, #{<<"allow">> => <<"GET, HEAD, POST, OPTIONS">>}, <<>>, Req).

-spec http_action(binary(), map(), cowboy_req:req()) -> cowboy_req:req().
http_action(<<"OPTIONS">>, _Parsed, Req) ->
    cowboy_req:reply(200, #{<<"allow">> => <<"POST, OPTIONS">>}, <<>>, Req);
http_action(<<"POST">>, #{item_path := Path, module := Module}, Req) ->
    post_http(fun(Body) -> post_action(Path, Module, Body) end, Req);
http_action(_, _Parsed, Req) ->
    cowboy_req:reply(405, #{<<"allow">> => <<"POST, OPTIONS">>}, <<>>, Req).

post_http(Fun, Req) ->
    case read_body(Req) of
        {error, Err, Req1} ->
            mgmtd_restconf_error:reply(Req1, status(Err), Err);
        {ok, Body, Req1} ->
            case Fun(Body) of
                {ok, empty} ->
                    cowboy_req:reply(204, #{}, <<>>, Req1);
                {ok, Map} ->
                    json_reply(Req1, 200, Map);
                {error, #{tag := _} = Err} ->
                    mgmtd_restconf_error:reply(Req1, status(Err), Err)
            end
    end.

read_body(Req) ->
    case cowboy_req:read_body(Req, #{length => 1000000}) of
        {ok, <<>>, Req1} ->
            {ok, #{}, Req1};
        {ok, Bin, Req1} ->
            try mgmtd_json:decode(Bin) of
                Map when is_map(Map) ->
                    {ok, Map, Req1};
                _ ->
                    {error, #{tag => <<"malformed-message">>,
                              http => 400,
                              message => <<"request body must be a JSON object">>},
                     Req1}
            catch
                _:_ ->
                    {error, #{tag => <<"malformed-message">>,
                              http => 400,
                              message => <<"malformed JSON">>}, Req1}
            end;
        {more, _, Req1} ->
            {error, #{tag => <<"malformed-message">>,
                      http => 413,
                      message => <<"request body too large">>}, Req1}
    end.

json_reply(Req, Status, Map) ->
    Body = iolist_to_binary(mgmtd_json:encode(Map)),
    cowboy_req:reply(Status,
                     #{<<"content-type">> => ?JSON,
                       <<"content-length">> => integer_to_binary(byte_size(Body))},
                     Body, Req).

json_head(Req, Map) ->
    Body = iolist_to_binary(mgmtd_json:encode(Map)),
    cowboy_req:reply(200,
                     #{<<"content-type">> => ?JSON,
                       <<"content-length">> => integer_to_binary(byte_size(Body))},
                     <<>>, Req).

qname(Module, Name) ->
    list_to_binary([Module, $:, Name]).

status(#{http := N}) when is_integer(N) -> N;
status(#{tag := <<"invalid-value">>}) -> 400;
status(#{tag := <<"malformed-message">>}) -> 400;
status(#{tag := <<"unknown-element">>}) -> 400;
status(#{tag := <<"missing-element">>}) -> 400;
status(_) -> 500.
