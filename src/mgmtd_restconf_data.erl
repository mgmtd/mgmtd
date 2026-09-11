%%%-------------------------------------------------------------------
%% @doc RESTCONF `{+restconf}/data` GET.
%% @end
%%%-------------------------------------------------------------------
-module(mgmtd_restconf_data).

-export([get/2, resource/2]).

-define(JSON, <<"application/yang-data+json">>).

-spec get(binary(), cowboy_req:req()) -> cowboy_req:req().
get(Path, Req) ->
    case content_param(Req) of
        {error, Err} ->
            mgmtd_restconf_error:reply(Req, 400, Err);
        Content ->
            case resource(Path, Content) of
                {ok, Map} ->
                    Body = iolist_to_binary(json:encode(Map)),
                    cowboy_req:reply(200, #{<<"content-type">> => ?JSON}, Body, Req);
                {error, #{tag := _} = Err} ->
                    mgmtd_restconf_error:reply(Req, status(Err), Err)
            end
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
status(_) ->
    400.
