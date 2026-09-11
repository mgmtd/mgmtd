%%%-------------------------------------------------------------------
%% @doc Cowboy handler for RESTCONF discovery and data resources.
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
handle(Method, Path, Req) ->
    case is_data_path(Path) of
        true ->
            data_method(Method, Path, Req);
        false when Method =:= <<"GET">> ->
            not_found(Req);
        false ->
            method_not_allowed(Req)
    end.

data_method(<<"GET">>, Path, Req) ->
    case negotiate(Req) of
        xml ->
            mgmtd_restconf_error:reply(
              Req, 406,
              #{tag => <<"operation-not-supported">>,
                message => <<"XML encoding not supported">>});
        json ->
            mgmtd_restconf_data:http(<<"GET">>, Path, Req)
    end;
data_method(Method, Path, Req)
  when Method =:= <<"PUT">>; Method =:= <<"POST">>;
       Method =:= <<"PATCH">>; Method =:= <<"DELETE">> ->
    mgmtd_restconf_data:http(Method, Path, Req);
data_method(_Method, _Path, Req) ->
    method_not_allowed(Req).

is_data_path(<<"/restconf/data">>) -> true;
is_data_path(<<"/restconf/data/", _/binary>>) -> true;
is_data_path(_) -> false.

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

not_found(Req) ->
    cowboy_req:reply(404, #{}, <<>>, Req).

method_not_allowed(Req) ->
    cowboy_req:reply(405, #{<<"allow">> => <<"GET">>}, <<>>, Req).

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
