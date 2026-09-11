%%%-------------------------------------------------------------------
%% @doc Cowboy handler for RESTCONF discovery and the data stub.
%% @end
%%%-------------------------------------------------------------------
-module(mgmtd_restconf_handler).

-export([init/2]).

-define(JSON, <<"application/yang-data+json">>).
-define(XRD, <<"application/xrd+xml">>).

init(Req0, State) ->
    Method = cowboy_req:method(Req0),
    Path = cowboy_req:path(Req0),
    Req = handle(Method, Path, Req0),
    {ok, Req, State}.

handle(<<"GET">>, <<"/.well-known/host-meta">>, Req) ->
    host_meta(Req);
handle(<<"GET">>, <<"/restconf">>, Req) ->
    json_get(Req, fun mgmtd_restconf_yanglib:api_root/0);
handle(<<"GET">>, <<"/restconf/">>, Req) ->
    json_get(Req, fun mgmtd_restconf_yanglib:api_root/0);
handle(<<"GET">>, <<"/restconf/yang-library-version">>, Req) ->
    json_get(Req, fun mgmtd_restconf_yanglib:yang_library_version/0);
handle(<<"GET">>, <<"/restconf/operations">>, Req) ->
    json_get(Req, fun() -> #{<<"ietf-restconf:operations">> => #{}} end);
handle(<<"GET">>, <<"/restconf/operations/">>, Req) ->
    json_get(Req, fun() -> #{<<"ietf-restconf:operations">> => #{}} end);
handle(<<"GET">>, <<"/restconf/data/ietf-yang-library:modules-state">>, Req) ->
    json_get(Req, fun mgmtd_restconf_yanglib:modules_state/0);
handle(<<"GET">>, <<"/restconf/data">>, Req) ->
    not_implemented(Req);
handle(<<"GET">>, <<"/restconf/data/">>, Req) ->
    not_implemented(Req);
handle(<<"GET">>, Path, Req) ->
    case binary:match(Path, <<"/restconf/data/">>) of
        {0, _} ->
            not_implemented(Req);
        nomatch ->
            not_found(Req)
    end;
handle(_Method, _Path, Req) ->
    not_found(Req).

host_meta(Req) ->
    Body = <<"<XRD xmlns='http://docs.oasis-open.org/ns/xri/xrd-1.0'>\n",
             "  <Link rel='restconf' href='/restconf'/>\n",
             "</XRD>\n">>,
    cowboy_req:reply(200, #{<<"content-type">> => ?XRD}, Body, Req).

json_get(Req, Fun) ->
    case negotiate(Req) of
        json ->
            Body = iolist_to_binary(json:encode(Fun())),
            cowboy_req:reply(200, #{<<"content-type">> => ?JSON}, Body, Req);
        xml ->
            mgmtd_restconf_error:reply(
              Req, 406,
              #{tag => <<"operation-not-supported">>,
                message => <<"XML encoding not supported">>})
    end.

not_implemented(Req) ->
    mgmtd_restconf_error:reply(
      Req, 501,
      #{tag => <<"operation-not-supported">>,
        message => <<"RESTCONF data resource not implemented">>}).

not_found(Req) ->
    cowboy_req:reply(404, #{}, <<>>, Req).

%% JSON unless the client asked only for yang-data+xml.
negotiate(Req) ->
    case cowboy_req:header(<<"accept">>, Req) of
        undefined ->
            json;
        Accept ->
            HasXml = binary:match(Accept, <<"yang-data+xml">>) =/= nomatch,
            HasJson = binary:match(Accept, <<"yang-data+json">>) =/= nomatch
                orelse binary:match(Accept, <<"*/*">>) =/= nomatch,
            case HasXml andalso not HasJson of
                true ->
                    xml;
                false ->
                    json
            end
    end.
