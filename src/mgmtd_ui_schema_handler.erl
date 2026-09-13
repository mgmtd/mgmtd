%%%-------------------------------------------------------------------
%% @doc Cowboy handler for `GET /mgmtd/schema`.
%% @end
%%%-------------------------------------------------------------------
-module(mgmtd_ui_schema_handler).

-export([init/2]).

-define(JSON, <<"application/json">>).

init(Req0, State) ->
    Req = handle(cowboy_req:method(Req0), Req0),
    {ok, Req, State}.

handle(<<"GET">>, Req) ->
    Body = iolist_to_binary(json:encode(mgmtd_ui_schema:snapshot())),
    cowboy_req:reply(200, #{<<"content-type">> => ?JSON,
                            <<"content-length">> => integer_to_binary(byte_size(Body))},
                     Body, Req);
handle(<<"HEAD">>, Req) ->
    Body = iolist_to_binary(json:encode(mgmtd_ui_schema:snapshot())),
    cowboy_req:reply(200, #{<<"content-type">> => ?JSON,
                            <<"content-length">> => integer_to_binary(byte_size(Body))},
                     <<>>, Req);
handle(<<"OPTIONS">>, Req) ->
    cowboy_req:reply(200, #{<<"allow">> => <<"GET, HEAD, OPTIONS">>}, <<>>, Req);
handle(_, Req) ->
    cowboy_req:reply(405, #{<<"allow">> => <<"GET, HEAD, OPTIONS">>}, <<>>, Req).
