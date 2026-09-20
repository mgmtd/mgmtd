%%%-------------------------------------------------------------------
%% @doc JSON schema snapshot for the Web UI.
%%
%% Not RESTCONF. Walks loaded `#schema{}` the same way RESTCONF does
%% (named prefix containers are CLI-only) and emits a JSON-safe tree
%% with RESTCONF data paths.
%% @end
%%%-------------------------------------------------------------------
-module(mgmtd_ui_schema).

-export([snapshot/0]).

-include("mgmtd_schema.hrl").

-spec snapshot() -> map().
snapshot() ->
    Mods = [module_json(I) || I <- lists:sort(fun mod_ord/2, user_modules())],
    #{<<"modules">> => Mods}.

user_modules() ->
    [I || I <- mgmtd_schema:loaded_schema_infos(),
          maps:get(source, I, unknown) =/= builtin].

mod_ord(A, B) ->
    maps:get(module, A) =< maps:get(module, B).

module_json(#{prefix := Prefix, module := Module, namespace := URI,
              source := Source} = Info) ->
    Top = prefix_base(Prefix),
    Children = [node_json(Prefix, Module, Module, Top, C)
                || C <- restconf_children(Prefix, Top) ++ rpc_children(Prefix)],
    Base = #{<<"name">> => bin(Module),
             <<"prefix">> => atom_to_binary(Prefix, utf8),
             <<"namespace">> => bin(URI),
             <<"source">> => atom_to_binary(Source, utf8),
             <<"children">> => Children},
    case maps:get(revision, Info, undefined) of
        undefined -> Base;
        "" -> Base;
        Rev -> Base#{<<"revision">> => bin(Rev)}
    end.

node_json(Prefix, PrefixMod, ParentMod, ParentPath, Schema) ->
    Name = maps:get(name, Schema),
    Kind = maps:get(node_type, Schema),
    Path = ParentPath ++ [Name],
    ThisMod = child_module(Schema, ParentMod),
    Item = #{module => PrefixMod,
             prefix => Prefix,
             item_path => Path},
    JsonName = json_name(ThisMod, ParentMod, Name),
    Node0 = #{<<"kind">> => kind_bin(Kind),
              <<"name">> => bin(Name),
              <<"module">> => bin(PrefixMod),
              <<"qname">> => qname(PrefixMod, Name),
              <<"json_name">> => JsonName,
              <<"path">> => node_path(Kind, PrefixMod, Name, Item),
              <<"config">> => maps:get(config, Schema, false)},
    Node1 = put_opt(Node0, <<"desc">>, nonempty(maps:get(desc, Schema, ""))),
    Node2 = put_opt(Node1, <<"mandatory">>,
                  case maps:get(mandatory, Schema, false) of
                      true -> true;
                      _ -> undefined
                  end),
    Node3 = put_opt(Node2, <<"default">>, default_json(maps:get(default, Schema, undefined))),
    Node4 = case Kind of
                leaf -> Node3#{<<"type">> => type_json(maps:get(type, Schema, undefined))};
                leaf_list -> Node3#{<<"type">> => type_json(maps:get(type, Schema, undefined))};
                _ -> Node3
            end,
    Node5 = case Kind of
                list ->
                    put_opt(
                      Node4#{<<"key_names">> => [bin(K) || K <- maps:get(key_names, Schema, [])]},
                      <<"min_elements">>, min_el(maps:get(min_elements, Schema, 0)));
                leaf_list ->
                    put_opt(Node4, <<"min_elements">>, min_el(maps:get(min_elements, Schema, 0)));
                _ ->
                    Node4
            end,
    Node6 = put_opt(Node5, <<"max_elements">>,
                  max_el(maps:get(max_elements, Schema, unlimited))),
    Node7 = put_opt(Node6, <<"pattern">>, maps:get(pattern, Schema, undefined)),
    Node8 = case Kind of
                list -> Node7#{<<"ordered_by">> =>
                                   atom_to_binary(maps:get(ordered_by, Schema, system), utf8)};
                leaf_list -> Node7#{<<"ordered_by">> =>
                                        atom_to_binary(maps:get(ordered_by, Schema, system), utf8)};
                _ -> Node7
            end,
    case Kind of
        leaf -> Node8;
        leaf_list -> Node8;
        _ ->
            Kids = [node_json(Prefix, PrefixMod, ThisMod, Path, C)
                    || C <- restconf_children(Prefix, Path)],
            Node8#{<<"children">> => Kids}
    end.

restconf_children(Prefix, Path) ->
    Named = [atom_to_list(P) || #{prefix := P} <- mgmtd_schema:loaded_schema_infos(),
                                P =/= ?DEFAULT_NS],
    [C || C <- mgmtd_schema:children(Path, show),
          maps:get(node_type, C) =/= list_key,
          not (Prefix =:= ?DEFAULT_NS
               andalso Path =:= []
               andalso lists:member(maps:get(name, C), Named))].

rpc_children(Prefix) ->
    [R || R <- mgmtd_schema:rpcs(), maps:get(ns, R) =:= Prefix].

prefix_base(?DEFAULT_NS) ->
    [];
prefix_base(Prefix) ->
    [atom_to_list(Prefix)].

child_module(#{origin_module := Origin}, _Parent) when is_list(Origin) ->
    Origin;
child_module(_, Parent) ->
    Parent.

json_name(ThisMod, ParentMod, Name) when ThisMod =:= ParentMod ->
    bin(Name);
json_name(ThisMod, _ParentMod, Name) ->
    qname(ThisMod, Name).

kind_bin(leaf_list) ->
    <<"leaf-list">>;
kind_bin(Kind) ->
    atom_to_binary(Kind, utf8).

%% RFC 8040 §3.6: top-level rpc lives under `{+restconf}/operations`.
node_path(rpc, Module, Name, _Item) ->
    iolist_to_binary(["/restconf/operations/", Module, $:, Name]);
node_path(_Kind, _Module, _Name, Item) ->
    mgmtd_restconf_path:data_uri(Item).

qname(Module, Name) ->
    iolist_to_binary([Module, $:, Name]).

min_el(0) -> undefined;
min_el(N) -> N.

max_el(unlimited) -> undefined;
max_el(N) -> N.

nonempty("") -> undefined;
nonempty(undefined) -> undefined;
nonempty(S) -> bin(S).

put_opt(Map, _K, undefined) -> Map;
put_opt(Map, K, V) -> Map#{K => V}.

default_json(undefined) -> undefined;
default_json(empty) -> null;
default_json(V) when is_boolean(V); is_integer(V); is_float(V) -> V;
default_json(V) when is_binary(V) -> V;
default_json(V) when is_list(V) ->
    case io_lib:printable_unicode_list(V) of
        true -> bin(V);
        false -> [default_json(X) || X <- V]
    end;
default_json(V) ->
    iolist_to_binary(io_lib:format("~p", [V])).

type_json(undefined) ->
    #{<<"base">> => <<"unknown">>};
type_json(Atom) when is_atom(Atom) ->
    #{<<"base">> => atom_to_binary(Atom, utf8)};
type_json({enum, Members}) ->
    #{<<"base">> => <<"enumeration">>,
      <<"enum">> => [enum_json(M) || M <- Members]};
type_json({enumeration, Members}) ->
    type_json({enum, Members});
type_json({identityref, Base}) ->
    #{<<"base">> => <<"identityref">>, <<"base-identity">> => bin(Base)};
type_json({leafref, Path}) ->
    #{<<"base">> => <<"leafref">>, <<"path">> => bin(Path)};
type_json({leafref, Path, Require}) ->
    #{<<"base">> => <<"leafref">>,
      <<"path">> => bin(Path),
      <<"require-instance">> => Require};
type_json({union, Types}) ->
    #{<<"base">> => <<"union">>,
      <<"type">> => [type_json(T) || T <- Types]};
type_json({decimal64, F}) when is_integer(F) ->
    #{<<"base">> => <<"decimal64">>, <<"fraction-digits">> => F};
type_json({decimal64, F, Range}) when is_integer(F), is_list(Range) ->
    #{<<"base">> => <<"decimal64">>,
      <<"fraction-digits">> => F,
      <<"range">> => range_json(Range)};
type_json({bits, Bits}) when is_list(Bits) ->
    #{<<"base">> => <<"bits">>,
      <<"bit">> => [bit_json(B) || B <- Bits]};
type_json({Base, Range}) when is_atom(Base), is_list(Range), Base =/= enum,
                              Base =/= enumeration, Base =/= union, Base =/= bits ->
    case is_range_list(Range) of
        true ->
            #{<<"base">> => atom_to_binary(Base, utf8),
              <<"range">> => range_json(Range)};
        false ->
            #{<<"base">> => <<"callback">>,
              <<"callback-module">> => atom_to_binary(Base, utf8),
              <<"callback-type">> => iolist_to_binary(io_lib:format("~p", [Range]))}
    end;
type_json({Mod, Type}) when is_atom(Mod) ->
    #{<<"base">> => <<"callback">>,
      <<"callback-module">> => atom_to_binary(Mod, utf8),
      <<"callback-type">> => iolist_to_binary(io_lib:format("~p", [Type]))};
type_json(Other) ->
    #{<<"base">> => <<"unknown">>,
      <<"raw">> => iolist_to_binary(io_lib:format("~p", [Other]))}.

enum_json(#{name := N} = M) ->
    E0 = #{<<"name">> => bin(N)},
    E1 = put_opt(E0, <<"description">>, nonempty(maps:get(desc, M, undefined))),
    put_opt(E1, <<"value">>, maps:get(value, M, undefined));
enum_json({Name, Desc}) ->
    #{<<"name">> => bin(Name), <<"description">> => bin(Desc)};
enum_json(Name) ->
    #{<<"name">> => bin(Name)}.

bit_json(#{name := N} = M) ->
    put_opt(#{<<"name">> => bin(N)}, <<"position">>, maps:get(position, M, undefined));
bit_json({Name, Pos}) when is_integer(Pos) ->
    #{<<"name">> => bin(Name), <<"position">> => Pos};
bit_json(Name) ->
    #{<<"name">> => bin(Name)}.

range_json(Range) ->
    lists:foldl(fun({min, V}, Acc) -> Acc#{<<"min">> => V};
                   ({max, V}, Acc) -> Acc#{<<"max">> => V};
                   (_, Acc) -> Acc
                end, #{}, Range).

is_range_list(Range) ->
    Range =/= [] andalso
        lists:all(fun({min, I}) when is_integer(I) -> true;
                     ({max, I}) when is_integer(I) -> true;
                     (_) -> false
                  end, Range).

bin(B) when is_binary(B) ->
    B;
bin(L) when is_list(L) ->
    unicode:characters_to_binary(L);
bin(A) when is_atom(A) ->
    atom_to_binary(A, utf8);
bin(N) when is_integer(N) ->
    integer_to_binary(N).
