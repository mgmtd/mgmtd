%%%-------------------------------------------------------------------
%% @doc Cowboy handler for RESTCONF discovery and data resources.
%% @end
%%%-------------------------------------------------------------------
-module(mgmtd_restconf_handler).

-export([init/2]).

-define(JSON, <<"application/yang-data+json">>).
-define(YANG, <<"application/yang">>).
-define(XRD, <<"application/xrd+xml">>).

init(Req0, State) ->
    Path = cowboy_req:path(Req0),
    io:format("RESTCONF ~p ~p~n", [cowboy_req:method(Req0), Path]),
    {ok, dispatch(Path, Req0), State}.

dispatch(<<"/.well-known/host-meta">>, Req) ->
    handle(cowboy_req:method(Req), <<"/.well-known/host-meta">>, Req);
dispatch(Path, Req0) ->
    case check_auth(Req0) of
        {ok, Role, Req} ->
            Method = cowboy_req:method(Req),
            case mgmtd_aaa:permits(Role, access_for(Method)) of
                true ->
                    handle(Method, Path, Req);
                false ->
                    forbidden(Req)
            end;
        {error, Req} ->
            Req
    end.

check_auth(Req) ->
    case mgmtd_aaa:http_required() of
        false ->
            {ok, admin, Req};
        true ->
            require_basic(Req)
    end.

require_basic(Req) ->
    case parse_authorization(Req) of
        {basic, User, Pass} ->
            case mgmtd_aaa:authenticate(User, Pass) of
                {ok, Role} ->
                    {ok, Role, Req};
                error ->
                    {error, unauthorized(Req)}
            end;
        _ ->
            {error, unauthorized(Req)}
    end.

parse_authorization(Req) ->
    try cowboy_req:parse_header(<<"authorization">>, Req) of
        Auth ->
            Auth
    catch
        _:_ ->
            malformed
    end.

access_for(<<"GET">>) -> read;
access_for(<<"HEAD">>) -> read;
access_for(<<"OPTIONS">>) -> read;
access_for(_) -> write.

unauthorized(Req) ->
    cowboy_req:reply(
      401,
      #{<<"www-authenticate">> => <<"Basic realm=\"mgmtd\"">>,
        <<"content-type">> => ?JSON},
      mgmtd_restconf_error:encode(
        #{tag => <<"access-denied">>,
          message => <<"authentication required">>}),
      Req).

forbidden(Req) ->
    mgmtd_restconf_error:reply(
      Req, 403,
      #{tag => <<"access-denied">>,
        message => <<"permission denied">>}).

handle(<<"GET">>, <<"/.well-known/host-meta">>, Req) ->
    host_meta(Req);
handle(<<"HEAD">>, <<"/.well-known/host-meta">>, Req) ->
    cowboy_req:reply(200, #{<<"content-type">> => ?XRD}, <<>>, Req);
handle(<<"OPTIONS">>, Path, Req) ->
    case is_operations_path(Path) of
        true ->
            mgmtd_restconf_rpc:http_operations(<<"OPTIONS">>, Path, Req);
        false ->
            case action_ref(Path) of
                {ok, Parsed} ->
                    mgmtd_restconf_rpc:http_action(<<"OPTIONS">>, Parsed, Req);
                false ->
                    case is_data_path(Path) of
                        true ->
                            mgmtd_restconf_data:http(<<"OPTIONS">>, Path, Req);
                        false ->
                            cowboy_req:reply(200, #{<<"allow">> => <<"GET, HEAD, OPTIONS">>}, <<>>, Req)
                    end
            end
    end;
handle(<<"GET">>, <<"/restconf">>, Req) ->
    json_get(Req, fun mgmtd_restconf_yanglib:api_root/0);
handle(<<"GET">>, <<"/restconf/">>, Req) ->
    json_get(Req, fun mgmtd_restconf_yanglib:api_root/0);
handle(<<"HEAD">>, <<"/restconf">>, Req) ->
    json_head(Req, fun mgmtd_restconf_yanglib:api_root/0);
handle(<<"HEAD">>, <<"/restconf/">>, Req) ->
    json_head(Req, fun mgmtd_restconf_yanglib:api_root/0);
handle(<<"GET">>, <<"/restconf/yang-library-version">>, Req) ->
    json_get(Req, fun mgmtd_restconf_yanglib:yang_library_version/0);
handle(<<"HEAD">>, <<"/restconf/yang-library-version">>, Req) ->
    json_head(Req, fun mgmtd_restconf_yanglib:yang_library_version/0);
handle(Method, Path, Req) ->
    case is_operations_path(Path) of
        true ->
            mgmtd_restconf_rpc:http_operations(Method, Path, Req);
        false ->
            case is_yang_path(Path) of
                true ->
                    yang_method(Method, Path, Req);
                false ->
                    case is_data_path(Path) of
                        true ->
                            data_method(Method, Path, Req);
                        false when Method =:= <<"GET">> ->
                            not_found(Req);
                        false ->
                            method_not_allowed(Req)
                    end
            end
    end.

data_method(Method, Path, Req)
  when Method =:= <<"GET">>; Method =:= <<"HEAD">> ->
    case negotiate(Req) of
        xml ->
            mgmtd_restconf_error:reply(
              Req, 406,
              #{tag => <<"operation-not-supported">>,
                message => <<"XML encoding not supported">>});
        json ->
            case action_ref(Path) of
                {ok, Parsed} ->
                    mgmtd_restconf_rpc:http_action(Method, Parsed, Req);
                false ->
                    mgmtd_restconf_data:http(Method, Path, Req)
            end
    end;
data_method(Method, Path, Req)
  when Method =:= <<"PUT">>; Method =:= <<"POST">>;
       Method =:= <<"PATCH">>; Method =:= <<"DELETE">> ->
    case action_ref(Path) of
        {ok, Parsed} ->
            mgmtd_restconf_rpc:http_action(Method, Parsed, Req);
        false ->
            mgmtd_restconf_data:http(Method, Path, Req)
    end;
data_method(_Method, _Path, Req) ->
    method_not_allowed(Req).

action_ref(Path) ->
    case mgmtd_restconf_path:parse(Path) of
        {ok, #{schema := #{node_type := action}} = Parsed} ->
            {ok, Parsed};
        _ ->
            false
    end.

is_data_path(<<"/restconf/data">>) -> true;
is_data_path(<<"/restconf/data/", _/binary>>) -> true;
is_data_path(_) -> false.

is_operations_path(<<"/restconf/operations">>) -> true;
is_operations_path(<<"/restconf/operations/", _/binary>>) -> true;
is_operations_path(_) -> false.

is_yang_path(<<"/restconf/yang/", _/binary>>) -> true;
is_yang_path(_) -> false.

yang_method(<<"OPTIONS">>, _Path, Req) ->
    cowboy_req:reply(200, #{<<"allow">> => <<"GET, HEAD, OPTIONS">>}, <<>>, Req);
yang_method(Method, Path, Req)
  when Method =:= <<"GET">>; Method =:= <<"HEAD">> ->
    case yang_module(Path) of
        {error, not_found} ->
            not_found(Req);
        {ok, Name, Rev} ->
            case mgmtd:export_yang(Name, Rev) of
                {ok, Body} ->
                    Hdrs = #{<<"content-type">> => ?YANG,
                             <<"content-length">> => integer_to_binary(byte_size(Body))},
                    case Method of
                        <<"GET">> ->
                            cowboy_req:reply(200, Hdrs, Body, Req);
                        <<"HEAD">> ->
                            cowboy_req:reply(200, Hdrs, <<>>, Req)
                    end;
                {error, not_found} ->
                    not_found(Req)
            end
    end;
yang_method(_Method, _Path, Req) ->
    cowboy_req:reply(405, #{<<"allow">> => <<"GET, HEAD, OPTIONS">>}, <<>>, Req).

yang_module(<<"/restconf/yang/", Rest/binary>>) ->
    Parts = [P || P <- binary:split(Rest, <<"/">>, [global]), P =/= <<>>],
    case Parts of
        [Name] ->
            {ok, binary_to_list(Name), undefined};
        [Name, Rev] ->
            {ok, binary_to_list(Name), binary_to_list(Rev)};
        _ ->
            {error, not_found}
    end.

host_meta(Req) ->
    Body = <<"<XRD xmlns='http://docs.oasis-open.org/ns/xri/xrd-1.0'>\n",
             "  <Link rel='restconf' href='/restconf'/>\n",
             "</XRD>\n">>,
    cowboy_req:reply(200, #{<<"content-type">> => ?XRD}, Body, Req).

json_get(Req, Fun) ->
    case negotiate(Req) of
        json ->
            Body = iolist_to_binary(mgmtd_json:encode(Fun())),
            cowboy_req:reply(200, json_headers(Body), Body, Req);
        xml ->
            mgmtd_restconf_error:reply(
              Req, 406,
              #{tag => <<"operation-not-supported">>,
                message => <<"XML encoding not supported">>})
    end.

json_head(Req, Fun) ->
    case negotiate(Req) of
        json ->
            Body = iolist_to_binary(mgmtd_json:encode(Fun())),
            cowboy_req:reply(200, json_headers(Body), <<>>, Req);
        xml ->
            mgmtd_restconf_error:reply(
              Req, 406,
              #{tag => <<"operation-not-supported">>,
                message => <<"XML encoding not supported">>})
    end.

json_headers(Body) ->
    #{<<"content-type">> => ?JSON,
      <<"content-length">> => integer_to_binary(byte_size(Body))}.

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
