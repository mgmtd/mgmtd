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
         modules_state/0, api_root/0, yang_library_version/0]).

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

%% Loaded schemas plus the RESTCONF built-in modules.
-spec modules() -> [map()].
modules() ->
    Loaded = [schema_to_module(I) || I <- mgmtd_schema:loaded_schema_infos()],
    [M || {_, M} <- lists:keysort(1, [{maps:get(name, M), M}
                                      || M <- Loaded ++ builtins()])].

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

schema_to_module(#{prefix := Prefix, module := Module,
                   namespace := URI, source := Source} = Info) ->
    #{name => Module,
      revision => revision(maps:get(revision, Info, undefined)),
      namespace => URI,
      prefix => atom_to_list(Prefix),
      source => Source,
      conformance_type => implement}.

builtins() ->
    [#{name => "ietf-yang-library",
       revision => ?YANGLIB_REV,
       namespace => ?YANGLIB_NS,
       prefix => "yanglib",
       source => builtin,
       conformance_type => implement},
     #{name => "ietf-restconf",
       revision => ?RESTCONF_REV,
       namespace => ?RESTCONF_NS,
       prefix => "rc",
       source => builtin,
       conformance_type => implement}].

module_json(M) ->
    #{<<"name">> => bin(maps:get(name, M)),
      <<"revision">> => bin(maps:get(revision, M)),
      <<"namespace">> => bin(maps:get(namespace, M)),
      <<"conformance-type">> => <<"implement">>}.

revision(undefined) ->
    "";
revision(Rev) ->
    Rev.

bin(B) when is_binary(B) ->
    B;
bin(L) when is_list(L) ->
    list_to_binary(L).
