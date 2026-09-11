%%%-------------------------------------------------------------------
%% @doc RESTCONF `{+restconf}/data` GET and edits.
%%
%% One HTTP request is one `txn_*` against running.
%% @end
%%%-------------------------------------------------------------------
-module(mgmtd_restconf_data).

-compile({no_auto_import, [put/2]}).

-export([get/2, resource/2,
         put/2, post/2, patch/2, delete/1,
         http/3]).

-define(JSON, <<"application/yang-data+json">>).

-spec get(binary(), cowboy_req:req()) -> cowboy_req:req().
get(Path, Req) ->
    http(<<"GET">>, Path, Req).

-spec http(binary(), binary(), cowboy_req:req()) -> cowboy_req:req().
http(<<"GET">>, Path, Req) ->
    case content_param(Req) of
        {error, Err} ->
            mgmtd_restconf_error:reply(Req, 400, Err);
        Content ->
            reply_result(Req, resource(Path, Content), get)
    end;
http(<<"DELETE">>, Path, Req) ->
    reply_result(Req, delete(Path), delete);
http(Method, Path, Req) ->
    case read_json_body(Req) of
        {error, Err, Req1} ->
            mgmtd_restconf_error:reply(Req1, status(Err), Err);
        {ok, Body, Req1} ->
            Result = case Method of
                         <<"PUT">> -> put(Path, Body);
                         <<"POST">> -> post(Path, Body);
                         <<"PATCH">> -> patch(Path, Body);
                         _ ->
                             {error, #{tag => <<"operation-not-supported">>,
                                       http => 405,
                                       message => <<"method not allowed">>}}
                     end,
            reply_result(Req1, Result, Method)
    end.

-spec resource(binary() | string(), all | config | nonconfig) ->
          {ok, map()} | {error, map()}.
resource(Path, Content) ->
    case mgmtd_restconf_path:parse(Path) of
        {error, Err} ->
            {error, Err};
        {ok, Parsed} ->
            mgmtd_restconf_json:encode(Parsed, Content)
    end.

-spec put(binary() | string(), map()) ->
          {ok, created | replaced} | {error, map()}.
put(Path, Body) ->
    with_parsed_config(Path, fun(Parsed) ->
        case mgmtd_restconf_json:decode(Parsed, Body, put) of
            {error, Err} ->
                {error, Err};
            {ok, Ops, _Created} ->
                Existed = mgmtd_restconf_json:exists(Parsed),
                case run_txn(Ops) of
                    ok when Existed ->
                        {ok, replaced};
                    ok ->
                        {ok, created};
                    {error, _} = Err ->
                        Err
                end
        end
    end).

-spec post(binary() | string(), map()) ->
          {ok, binary()} | {error, map()}.
post(Path, Body) ->
    with_parsed_config(Path, fun(Parsed) ->
        case mgmtd_restconf_json:decode(Parsed, Body, post) of
            {error, Err} ->
                {error, Err};
            {ok, Ops, Created} ->
                case mgmtd_restconf_json:exists(Created) of
                    true ->
                        {error, #{tag => <<"data-exists">>,
                                  http => 409,
                                  message => <<"data resource already exists">>}};
                    false ->
                        case run_txn(Ops) of
                            ok ->
                                {ok, mgmtd_restconf_path:data_uri(Created)};
                            {error, _} = Err ->
                                Err
                        end
                end
        end
    end).

-spec patch(binary() | string(), map()) -> ok | {error, map()}.
patch(Path, Body) ->
    with_parsed_config(Path, fun(Parsed) ->
        case mgmtd_restconf_json:exists(Parsed)
             orelse is_container(Parsed) of
            false ->
                {error, #{tag => <<"invalid-value">>,
                          http => 404,
                          message => <<"data resource not found">>}};
            true ->
                case mgmtd_restconf_json:decode(Parsed, Body, patch) of
                    {error, Err} ->
                        {error, Err};
                    {ok, Ops, _} ->
                        run_txn(Ops)
                end
        end
    end).

-spec delete(binary() | string()) -> ok | {error, map()}.
delete(Path) ->
    with_parsed_config(Path, fun(Parsed) ->
        case mgmtd_restconf_json:exists(Parsed) of
            false ->
                {error, #{tag => <<"invalid-value">>,
                          http => 404,
                          message => <<"data resource not found">>}};
            true ->
                run_txn([{delete, maps:get(item_path, Parsed)}])
        end
    end).

with_parsed_config(Path, Fun) ->
    case mgmtd_restconf_path:parse(Path) of
        {error, Err} ->
            {error, Err};
        {ok, datastore} ->
            not_writable(<<"datastore">>);
        {ok, yanglib_state} ->
            not_writable(<<"ietf-yang-library">>);
        {ok, yanglib_id} ->
            not_writable(<<"ietf-yang-library">>);
        {ok, #{schema := #{config := false}}} ->
            not_writable(<<"operational data">>);
        {ok, Parsed} ->
            Fun(Parsed)
    end.

not_writable(What) ->
    {error, #{tag => <<"operation-not-supported">>,
              http => 405,
              message => <<"cannot write ", What/binary>>}}.

is_container(#{schema := #{node_type := container}}) -> true;
is_container(_) -> false.

run_txn(Ops) ->
    Txn0 = mgmtd:txn_new(),
    case apply_ops(Txn0, Ops) of
        {ok, Txn1} ->
            case mgmtd:txn_commit(Txn1) of
                {ok, _} ->
                    ok;
                {error, Reason} ->
                    try mgmtd:txn_exit(Txn1) catch _:_ -> ok end,
                    {error, #{tag => <<"operation-failed">>,
                              http => 409,
                              message => fmt(Reason)}}
            end;
        {error, _} = Err ->
            try mgmtd:txn_exit(Txn0) catch _:_ -> ok end,
            Err
    end.

apply_ops(Txn, []) ->
    {ok, Txn};
apply_ops(Txn, [{delete, Path} | Rest]) ->
    case mgmtd_schema:lookup_path(Path) of
        {ok, SP} ->
            {ok, Txn1} = mgmtd:txn_delete(Txn, SP),
            apply_ops(Txn1, Rest);
        {error, _} ->
            apply_ops(Txn, Rest)
    end;
apply_ops(Txn, [{set, Path, Value} | Rest]) ->
    SetPath = case Value of
                  undefined -> Path;
                  _ -> Path ++ [Value]
              end,
    case mgmtd_schema:lookup_path(SetPath) of
        {ok, SP} ->
            case mgmtd:txn_set(Txn, SP) of
                {ok, Txn1} ->
                    apply_ops(Txn1, Rest);
                {error, Reason} ->
                    {error, #{tag => <<"invalid-value">>,
                              http => 400,
                              message => fmt(Reason)}}
            end;
        {error, Reason} ->
            {error, #{tag => <<"invalid-value">>,
                      http => 400,
                      message => fmt(Reason)}}
    end.

read_json_body(Req) ->
    case content_type_ok(Req) of
        {error, Err} ->
            {error, Err, Req};
        ok ->
            case cowboy_req:read_body(Req, #{length => 1000000}) of
                {ok, <<>>, Req1} ->
                    {error, #{tag => <<"malformed-message">>,
                              http => 400,
                              message => <<"empty request body">>}, Req1};
                {ok, Bin, Req1} ->
                    try json:decode(Bin) of
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
            end
    end.

content_type_ok(Req) ->
    case cowboy_req:header(<<"content-type">>, Req) of
        undefined ->
            ok;
        CT ->
            case {binary:match(CT, <<"yang-data+xml">>),
                  binary:match(CT, <<"yang-data+json">>),
                  binary:match(CT, <<"application/json">>)} of
                {Nomatch, _, _} when Nomatch =/= nomatch ->
                    {error, #{tag => <<"operation-not-supported">>,
                              http => 415,
                              message => <<"XML encoding not supported">>}};
                {_, Json, App} when Json =/= nomatch; App =/= nomatch ->
                    ok;
                _ ->
                    {error, #{tag => <<"invalid-value">>,
                              http => 415,
                              message => <<"unsupported media type">>}}
            end
    end.

reply_result(Req, {ok, Map}, get) when is_map(Map) ->
    Body = iolist_to_binary(json:encode(Map)),
    cowboy_req:reply(200, #{<<"content-type">> => ?JSON}, Body, Req);
reply_result(Req, {ok, created}, _) ->
    cowboy_req:reply(201, #{}, <<>>, Req);
reply_result(Req, {ok, replaced}, _) ->
    cowboy_req:reply(204, #{}, <<>>, Req);
reply_result(Req, {ok, Location}, <<"POST">>) when is_binary(Location) ->
    cowboy_req:reply(201, #{<<"location">> => Location}, <<>>, Req);
reply_result(Req, ok, _) ->
    cowboy_req:reply(204, #{}, <<>>, Req);
reply_result(Req, {error, #{tag := _} = Err}, _) ->
    mgmtd_restconf_error:reply(Req, status(Err), Err).

content_param(Req) ->
    Qs = cowboy_req:parse_qs(Req),
    case lists:keyfind(<<"content">>, 1, Qs) of
        false ->
            all;
        {_, <<"all">>} ->
            all;
        {_, <<"config">>} ->
            config;
        {_, <<"nonconfig">>} ->
            nonconfig;
        {_, Other} ->
            {error, #{tag => <<"invalid-value">>,
                      http => 400,
                      message => <<"invalid content parameter: ", Other/binary>>}}
    end.

status(#{http := Code}) ->
    Code;
status(#{tag := <<"invalid-value">>}) ->
    404;
status(#{tag := <<"data-exists">>}) ->
    409;
status(#{tag := <<"operation-not-supported">>}) ->
    405;
status(_) ->
    400.

fmt(S) when is_list(S) ->
    S;
fmt(B) when is_binary(B) ->
    binary_to_list(B);
fmt(R) ->
    lists:flatten(io_lib:format("~p", [R])).
