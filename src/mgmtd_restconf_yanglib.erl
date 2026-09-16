%%%-------------------------------------------------------------------
%% @doc Synthesized ietf-yang-library (RFC 7895) from loaded_schemas.
%%
%% JSON Schema and Erlang function schemas appear as RESTCONF modules
%% with a synthesized `urn:mgmtd:<prefix>` namespace. YANG modules use
%% their real module name, namespace URI, and revision.
%% @end
%%%-------------------------------------------------------------------
-module(mgmtd_restconf_yanglib).

-export([yang_library_revision/0, module_set_id/0, modules/0,
         modules_state/0, api_root/0, yang_library_version/0,
         find_module/1, find_module/2, module_json/1]).

-include("mgmtd_schema.hrl").

-define(YANGLIB_REV, "2016-06-21").
-define(RESTCONF_REV, "2017-01-26").
-define(YANGLIB_NS, "urn:ietf:params:xml:ns:yang:ietf-yang-library").
-define(RESTCONF_NS, "urn:ietf:params:xml:ns:yang:ietf-restconf").

-spec yang_library_revision() -> string().
yang_library_revision() ->
    ?YANGLIB_REV.

-spec module_set_id() -> string().
module_set_id() ->
    Tuples = [{maps:get(name, M),
               maps:get(revision, M),
               maps:get(namespace, M)}
              || M <- modules()],
    <<Hash:128>> = erlang:md5(term_to_binary(lists:usort(Tuples))),
    lists:flatten(io_lib:format("~32.16.0b", [Hash])).

%% Loaded schemas plus RESTCONF builtins and RFC 6991 typedef modules.
-spec modules() -> [map()].
modules() ->
    Loaded = [schema_to_module(I) || I <- mgmtd_schema:loaded_schema_infos()],
    Names = [maps:get(name, M) || M <- Loaded],
    Std = [S || S <- mgmtd_yang_export:stdlib_modules(),
                not lists:member(maps:get(name, S), Names)],
    [M || {_, M} <- lists:keysort(1, [{maps:get(name, M), M}
                                      || M <- Loaded ++ Std ++ builtins()])].

-spec modules_state() -> map().
modules_state() ->
    #{<<"ietf-yang-library:modules-state">> =>
          #{<<"module-set-id">> => bin(module_set_id()),
            <<"module">> => [module_json(M) || M <- modules()]}}.

-spec api_root() -> map().
api_root() ->
    #{<<"ietf-restconf:restconf">> =>
          #{<<"data">> => #{},
            <<"operations">> => #{},
            <<"yang-library-version">> => bin(?YANGLIB_REV)}}.

-spec yang_library_version() -> map().
yang_library_version() ->
    #{<<"ietf-restconf:yang-library-version">> => bin(?YANGLIB_REV)}.

-spec find_module(string()) -> {ok, map()} | error.
find_module(Name) when is_list(Name) ->
    find_module(Name, any).

-spec find_module(string(), any | string()) -> {ok, map()} | error.
find_module(Name, Rev) when is_list(Name) ->
    case [M || M <- modules(),
               maps:get(name, M) =:= Name,
               rev_ok(Rev, maps:get(revision, M, ""))] of
        [M | _] ->
            {ok, M};
        [] ->
            error
    end.

rev_ok(any, _) -> true;
rev_ok(Rev, Stored) -> Rev =:= Stored.

schema_to_module(#{prefix := Prefix, module := Module,
                   namespace := URI, source := Source} = Info) ->
    #{name => Module,
      revision => revision(maps:get(revision, Info, undefined)),
      namespace => URI,
      prefix => Prefix,
      source => Source,
      conformance_type => implement}.

builtins() ->
    [#{name => "ietf-yang-library",
       revision => ?YANGLIB_REV,
       namespace => ?YANGLIB_NS,
       prefix => yanglib,
       source => builtin,
       conformance_type => implement},
     #{name => "ietf-restconf",
       revision => ?RESTCONF_REV,
       namespace => ?RESTCONF_NS,
       prefix => rc,
       source => builtin,
       conformance_type => implement}].

module_json(M) ->
    Conf = case maps:get(conformance_type, M, implement) of
               import -> <<"import">>;
               _ -> <<"implement">>
           end,
    Base = #{<<"name">> => bin(maps:get(name, M)),
             <<"revision">> => bin(maps:get(revision, M)),
             <<"namespace">> => bin(maps:get(namespace, M)),
             <<"conformance-type">> => Conf},
    case mgmtd_yang_export:schema_uri(M) of
        undefined ->
            Base;
        Uri ->
            Base#{<<"schema">> => bin(Uri)}
    end.

revision(undefined) ->
    "";
revision(Rev) ->
    Rev.

bin(B) when is_binary(B) ->
    B;
bin(L) when is_list(L) ->
    list_to_binary(L).
