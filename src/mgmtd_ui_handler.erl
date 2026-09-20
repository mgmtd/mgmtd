%%%-------------------------------------------------------------------
%% @doc Default Cowboy callback for the erlydtl HTML UI.
%%
%% Hosts may use this module in their dispatch (`mgmtd_ui:cowboy_routes/0`)
%% or call `mgmtd_ui:http_get/2` and `mgmtd_ui:http_post/2` from their
%% own callbacks. mgmtd does not start a listener for these routes.
%% @end
%%%-------------------------------------------------------------------
-module(mgmtd_ui_handler).

-export([init/2]).

init(Req0, State) ->
    Method = cowboy_req:method(Req0),
    Req = handle(Method, State, Req0),
    {ok, Req, State}.

handle(<<"GET">>, index, Req) ->
    mgmtd_ui:http_get(index, Req);
handle(<<"HEAD">>, index, Req) ->
    mgmtd_ui:http_get(index, Req);
handle(<<"GET">>, content, Req) ->
    mgmtd_ui:http_get(content, Req);
handle(<<"HEAD">>, content, Req) ->
    mgmtd_ui:http_get(content, Req);
handle(<<"POST">>, save, Req) ->
    mgmtd_ui:http_post(save, Req);
handle(<<"POST">>, add, Req) ->
    mgmtd_ui:http_post(add, Req);
handle(<<"POST">>, delete, Req) ->
    mgmtd_ui:http_post(delete, Req);
handle(<<"POST">>, rpc, Req) ->
    mgmtd_ui:http_post(rpc, Req);
handle(<<"OPTIONS">>, State, Req)
  when State =:= index; State =:= content ->
    cowboy_req:reply(200, #{<<"allow">> => <<"GET, HEAD, OPTIONS">>}, <<>>, Req);
handle(<<"OPTIONS">>, _, Req) ->
    cowboy_req:reply(200, #{<<"allow">> => <<"POST, OPTIONS">>}, <<>>, Req);
handle(_, State, Req) when State =:= index; State =:= content ->
    cowboy_req:reply(405, #{<<"allow">> => <<"GET, HEAD, OPTIONS">>}, <<>>, Req);
handle(_, _, Req) ->
    cowboy_req:reply(405, #{<<"allow">> => <<"POST, OPTIONS">>}, <<>>, Req).
