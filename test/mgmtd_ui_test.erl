%%%-------------------------------------------------------------------
%%% @doc HTML UI (erlydtl) mounted on a host Cowboy listener.
%%% @end
%%%-------------------------------------------------------------------
-module(mgmtd_ui_test).

-include_lib("eunit/include/eunit.hrl").
-include("../include/mgmtd.hrl").

-define(DB, "test_db_ui").
-define(LISTENER, mgmtd_ui_test_http).

ui_test_() ->
    {setup, fun setup/0, fun teardown/1,
     [fun standalone_index_has_chrome/0,
      fun content_is_fragment/0,
      fun css_is_served/0,
      fun tree_lists_schema/0,
      fun oper_tree_hides_config/0,
      fun oper_path_infers_mode/0,
      fun unset_leaf_shows_emdash/0,
      fun wrong_mode_offers_switch/0,
      fun select_leaf_and_save/0,
      fun invalid_leaf_shows_field_error/0,
      fun list_add_nested_and_delete/0,
      fun stale_etag_shows_error/0]}.

setup() ->
    start_mgmtd(),
    lists:foreach(fun mgmtd:remove_schema/1, mgmtd:registered_schemas()),
    ok = mgmtd_cfg_db:remove_db(?DB, [{backend, mnesia}]),
    ok = mgmtd:load_function_schema(fun mgmtd_test_schema:cfg_schema/0),
    ok = mgmtd:load_function_schema(fun logger_schema/0,
                                    #{namespace => kernel, config => true}),
    ok = mgmtd:load_function_schema(fun mgmtd_test_provider:schema/0),
    ok = mgmtd_cfg_db:init(?DB, [{backend, mnesia}]),
    ok = mgmtd_ui:compile(),
    {ok, _} = application:ensure_all_started(cowboy),
    {ok, _} = application:ensure_all_started(inets),
    Dispatch = cowboy_router:compile([{'_', mgmtd_ui:cowboy_routes()}]),
    {ok, _} = cowboy:start_clear(?LISTENER, [{port, 0}],
                                 #{env => #{dispatch => Dispatch}}),
    ok.

teardown(_) ->
    _ = cowboy:stop_listener(?LISTENER),
    lists:foreach(fun mgmtd:remove_schema/1, mgmtd:registered_schemas()),
    ok = mgmtd_cfg_db:remove_db(?DB, [{backend, mnesia}]),
    ok.

start_mgmtd() ->
    case mgmtd_sup:start_link() of
        {ok, _} -> ok;
        {error, {already_started, _}} -> ok
    end.

logger_schema() ->
    [#list{name = "logger",
           desc = "OTP logger handlers",
           key_names = ["id"],
           config = true,
           children = fun logger_handler/0}].

logger_handler() ->
    [#leaf{name = "id", type = string, desc = "Handler id"},
     #leaf{name = "level",
           type = {enum, ["error", "info"]},
           desc = "Handler log level"},
     #container{name = "config",
                desc = "Handler-specific config",
                children = fun logger_config/0}].

logger_config() ->
    [#leaf{name = "file", type = string, desc = "Log file"}].

standalone_index_has_chrome() ->
    {Code, Headers, Body} = http_get("/mgmtd/ui"),
    ?assertEqual(200, Code),
    CT = proplists:get_value("content-type", Headers),
    ?assert(is_list(CT) andalso string:find(CT, "text/html") =/= nomatch),
    ?assert(is_substring("<html", Body)),
    ?assert(is_substring("<h1>mgmtd</h1>", Body)),
    ?assert(is_substring("class=\"mgmtd-ui\"", Body)),
    ?assert(is_substring("data-mode=\"config\"", Body)),
    ?assert(is_substring("class=\"mode-switch\"", Body)),
    ?assert(is_substring("Select a configuration node.", Body)),
    ?assertNot(is_substring("Select an operational node.", Body)).

content_is_fragment() ->
    {Code, _, Body} = http_get("/mgmtd/ui/content"),
    ?assertEqual(200, Code),
    ?assertNot(is_substring("<html", Body)),
    ?assertNot(is_substring("<h1>mgmtd</h1>", Body)),
    ?assert(is_substring("class=\"mgmtd-ui\"", Body)),
    ?assert(is_substring("class=\"mode-switch\"", Body)),
    ?assert(is_substring("mgmtd_ui.css", Body)).

css_is_served() ->
    {Code, Headers, Body} = http_get("/mgmtd/ui/static/mgmtd_ui.css"),
    ?assertEqual(200, Code),
    CT = proplists:get_value("content-type", Headers),
    ?assert(is_list(CT) andalso string:find(CT, "css") =/= nomatch),
    ?assert(is_substring(".mgmtd-ui", Body)).

tree_lists_schema() ->
    {_, _, Body} = http_get("/mgmtd/ui"),
    ?assert(is_substring(">default<", Body)),
    ?assert(is_substring(">kernel<", Body)),
    ?assert(is_substring(">server<", Body)),
    ?assert(is_substring(">logger<", Body)),
    ?assertNot(is_substring(">status<", Body)),
    ?assertNot(is_substring(">orphan<", Body)),
    %% List children stay off the tree (hrefs are query-encoded).
    ?assertNot(is_substring("servers%2Fport", Body)).

oper_tree_hides_config() ->
    {200, _, Body} = http_get("/mgmtd/ui?mode=oper"),
    ?assert(is_substring("data-mode=\"oper\"", Body)),
    ?assert(is_substring(">status<", Body)),
    ?assert(is_substring(">uptime<", Body)),
    ?assert(is_substring(">orphan<", Body)),
    ?assert(is_substring("Select an operational node.", Body)),
    ?assertNot(is_substring(">server<", Body)),
    ?assertNot(is_substring(">logger<", Body)),
    ?assertNot(is_substring(">interface<", Body)),
    ?assert(is_substring("mode=oper", Body)).

oper_path_infers_mode() ->
    Path = "/restconf/data/default:status/uptime",
    {200, _, Body} = http_get("/mgmtd/ui?path=" ++ Path),
    ?assert(is_substring("data-mode=\"oper\"", Body)),
    ?assert(is_substring("1d4h", Body)),
    ?assert(is_substring("read only", Body)),
    ?assertNot(is_substring("name=\"value\"", Body)),
    List = "/restconf/data/default:status/interfaces",
    {200, _, Ifaces} = http_get("/mgmtd/ui?path=" ++ List),
    ?assert(is_substring(">eth0<", Ifaces)),
    ?assert(is_substring(">eth1<", Ifaces)),
    ?assertNot(is_substring("Add interfaces", Ifaces)),
    ?assertNot(is_substring("Delete", Ifaces)).

unset_leaf_shows_emdash() ->
    Path = "/restconf/data/default:orphan/n",
    {200, _, Body} = http_get("/mgmtd/ui?path=" ++ Path),
    ?assert(binary:match(Body, <<"—"/utf8>>) =/= nomatch),
    ?assert(is_substring("class=\"display-value\"", Body)).

wrong_mode_offers_switch() ->
    Path = "/restconf/data/default:interface/speed",
    {200, _, Body} = http_get("/mgmtd/ui?mode=oper&path=" ++ Path),
    ?assert(is_substring("This node is configuration.", Body)),
    ?assert(is_substring("Open in Config", Body)),
    ?assertNot(is_substring("name=\"value\"", Body)).

select_leaf_and_save() ->
    Path = "/restconf/data/default:interface/speed",
    {200, _, Before} = http_get("/mgmtd/ui?path=" ++ Path),
    ?assert(is_substring("name=\"value\"", Before)),
    Etag = mgmtd_restconf_data:etag_value(),
    {Code, Headers, Body} =
        form_post("/mgmtd/ui/save",
                  [{<<"path">>, Path},
                   {<<"return">>, Path},
                   {<<"view">>, <<"index">>},
                   {<<"etag">>, Etag},
                   {<<"value">>, <<"1GbE">>}]),
    ?assertEqual(303, Code),
    Loc = proplists:get_value("location", Headers),
    ?assert(is_list(Loc) andalso string:find(Loc, "/mgmtd/ui") =/= nomatch),
    {ok, #{<<"default:speed">> := <<"1GbE">>}} =
        mgmtd_restconf_data:resource(Path, config),
    ?assertEqual(<<>>, Body).

invalid_leaf_shows_field_error() ->
    List = "/restconf/data/default:server/servers",
    {ok, _} = mgmtd_restconf_data:post(
                List,
                #{<<"default:servers">> =>
                      [#{<<"name">> => <<"badport">>, <<"port">> => 10}]}),
    Leaf = "/restconf/data/default:server/servers=badport/port",
    {Code, _, Body} =
        form_post("/mgmtd/ui/save",
                  [{<<"path">>, Leaf},
                   {<<"return">>, List},
                   {<<"view">>, <<"index">>},
                   {<<"etag">>, mgmtd_restconf_data:etag_value()},
                   {<<"value">>, <<"nope">>}]),
    ?assertEqual(200, Code),
    ?assert(is_substring("field-error", Body)),
    ?assert(is_substring("expected an integer", Body)).

list_add_nested_and_delete() ->
    List = "/restconf/data/kernel:logger",
    {200, _, Form} = http_get("/mgmtd/ui?path=" ++ List),
    ?assert(is_substring("name=\"item.id\"", Form)),
    ?assert(is_substring("name=\"item.config.file\"", Form)),
    ?assert(is_substring("Add logger", Form)),
    {303, _, _} =
        form_post("/mgmtd/ui/add",
                  [{<<"path">>, List},
                   {<<"return">>, List},
                   {<<"view">>, <<"index">>},
                   {<<"etag">>, mgmtd_restconf_data:etag_value()},
                   {<<"item.id">>, <<"ui1">>},
                   {<<"item.level">>, <<"error">>},
                   {<<"item.config.file">>, <<"log/ui1.log">>}]),
    {ok, #{<<"kernel:logger">> := [Item]}} =
        mgmtd_restconf_data:resource(List, config),
    ?assertEqual(<<"ui1">>, maps:get(<<"id">>, Item)),
    ?assertEqual(<<"error">>, maps:get(<<"level">>, Item)),
    ?assertEqual(#{<<"file">> => <<"log/ui1.log">>}, maps:get(<<"config">>, Item)),
    {200, _, Shown} = http_get("/mgmtd/ui?path=" ++ List),
    ?assert(is_substring(">ui1<", Shown)),
    ?assert(is_substring("log/ui1.log", Shown)),
    Inst = "/restconf/data/kernel:logger=ui1",
    {303, _, _} =
        form_post("/mgmtd/ui/delete",
                  [{<<"path">>, Inst},
                   {<<"return">>, List},
                   {<<"view">>, <<"index">>},
                   {<<"etag">>, mgmtd_restconf_data:etag_value()}]),
    {error, #{http := 404}} = mgmtd_restconf_data:resource(Inst, config).

stale_etag_shows_error() ->
    Path = "/restconf/data/default:interface/speed",
    {200, _, Body} =
        form_post("/mgmtd/ui/save",
                  [{<<"path">>, Path},
                   {<<"return">>, Path},
                   {<<"view">>, <<"index">>},
                   {<<"etag">>, <<"\"-1\"">>},
                   {<<"value">>, <<"1GbE">>}]),
    ?assert(is_substring("etag mismatch", Body)).

http_get(Path) ->
    Url = lists:flatten(
            io_lib:format("http://127.0.0.1:~p~s",
                          [ranch:get_port(?LISTENER), Path])),
    {ok, {{_, Code, _}, Headers, Body}} =
        httpc:request(get, {Url, []}, [{timeout, 5000}],
                      [{body_format, binary}]),
    {Code, Headers, Body}.

form_post(Path, Fields) ->
    Url = lists:flatten(
            io_lib:format("http://127.0.0.1:~p~s",
                          [ranch:get_port(?LISTENER), Path])),
    Body = cow_qs:qs([{to_bin(K), to_bin(V)} || {K, V} <- Fields]),
    {ok, {{_, Code, _}, Headers, Resp}} =
        httpc:request(post,
                      {Url, [], "application/x-www-form-urlencoded", Body},
                      [{timeout, 5000}, {autoredirect, false}],
                      [{body_format, binary}]),
    {Code, Headers, Resp}.

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> unicode:characters_to_binary(L).

is_substring(Needle, Haystack) when is_list(Needle), is_binary(Haystack) ->
    binary:match(Haystack, list_to_binary(Needle)) =/= nomatch.
