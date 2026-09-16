%%%-------------------------------------------------------------------
%% @doc RFC 7950 YANG 1.1 text for a loaded schema.
%%
%% YANG modules loaded from a file keep their original source. Function
%% and JSON Schema modules (and YANG whose file is gone) are generated
%% from the live ETS tree: groupings already expanded, remote augments
%% emitted as `augment` in the origin module.
%%
%% `ietf-inet-types` and `ietf-yang-types` are served from `priv/yang`.
%% @end
%%%-------------------------------------------------------------------
-module(mgmtd_yang_export).

-export([text/1, text/2, schema_uri/1, exportable/1, stdlib_modules/0]).

-include("mgmtd_schema.hrl").

-define(INET, "ietf-inet-types").
-define(YANG, "ietf-yang-types").
-define(INET_REV, "2013-07-15").
-define(YANG_REV, "2013-07-15").

-spec text(string() | binary()) -> {ok, binary()} | {error, not_found}.
text(Name) ->
    text(Name, undefined).

-spec text(string() | binary(), string() | binary() | undefined) ->
          {ok, binary()} | {error, not_found}.
text(Name, Rev) ->
    case find(to_list(Name), rev_key(Rev)) of
        {ok, #{yang_source := Bin}} when is_binary(Bin) ->
            {ok, Bin};
        {ok, #{source := stdlib, file := File}} ->
            file:read_file(File);
        {ok, Info} ->
            {ok, iolist_to_binary(generate(Info))};
        error ->
            {error, not_found}
    end.

%% Path-absolute URI for the RFC 8040 schema leaf, or undefined.
-spec schema_uri(map()) -> string() | undefined.
schema_uri(M) when is_map(M) ->
    case exportable(M) of
        false ->
            undefined;
        true ->
            Name = maps:get(name, M, maps:get(module, M, undefined)),
            case {Name, revision_str(maps:get(revision, M, undefined))} of
                {undefined, _} ->
                    undefined;
                {N, ""} ->
                    "/restconf/yang/" ++ N;
                {N, Rev} ->
                    "/restconf/yang/" ++ N ++ "/" ++ Rev
            end
    end.

-spec exportable(map()) -> boolean().
exportable(#{source := builtin}) ->
    false;
exportable(#{source := stdlib}) ->
    true;
exportable(#{module := _}) ->
    true;
exportable(#{name := _}) ->
    true;
exportable(_) ->
    false.

find(Name, Rev) ->
    case find_loaded(Name, Rev) of
        {ok, _} = Ok ->
            Ok;
        error ->
            find_stdlib(Name, Rev)
    end.

find_loaded(Name, Rev) ->
    case [I || I <- mgmtd_schema:loaded_schema_infos(),
               maps:get(module, I) =:= Name,
               rev_matches(Rev, maps:get(revision, I, undefined))] of
        [Info | _] ->
            {ok, Info};
        [] ->
            error
    end.

find_stdlib(Name, Rev) ->
    case stdlib(Name) of
        {ok, Info} ->
            case rev_matches(Rev, maps:get(revision, Info)) of
                true ->
                    {ok, Info};
                false ->
                    error
            end;
        error ->
            error
    end.

-spec stdlib_modules() -> [map()].
stdlib_modules() ->
    [Info || {ok, Info} <- [stdlib(?INET), stdlib(?YANG)]].

stdlib(?INET) ->
    stdlib_info(?INET, ?INET_REV, "urn:ietf:params:xml:ns:yang:ietf-inet-types",
                "ietf-inet-types.yang");
stdlib(?YANG) ->
    stdlib_info(?YANG, ?YANG_REV, "urn:ietf:params:xml:ns:yang:ietf-yang-types",
                "ietf-yang-types.yang");
stdlib(_) ->
    error.

stdlib_info(Name, Rev, URI, File) ->
    case stdlib_file(File) of
        {ok, Path} ->
            {ok, #{name => Name,
                   module => Name,
                   revision => Rev,
                   namespace => URI,
                   source => stdlib,
                   prefix => prefix_atom(Name),
                   file => Path,
                   conformance_type => import}};
        error ->
            error
    end.

stdlib_file(File) ->
    Dirs = case code:priv_dir(mgmtd) of
               {error, _} -> [];
               Dir -> [filename:join(Dir, "yang")]
           end ++ ["priv/yang"],
    first_file([filename:join(D, File) || D <- Dirs]).

first_file([P | Rest]) ->
    case filelib:is_regular(P) of
        true -> {ok, P};
        false -> first_file(Rest)
    end;
first_file([]) ->
    error.

rev_key(undefined) -> any;
rev_key("") -> any;
rev_key(<<>>) -> any;
rev_key(Rev) -> to_list(Rev).

rev_matches(any, _) -> true;
rev_matches("", undefined) -> true;
rev_matches("", "") -> true;
rev_matches(Rev, undefined) -> Rev =:= "";
rev_matches(Rev, Stored) -> Rev =:= Stored.

revision_str(undefined) -> "";
revision_str(Rev) -> Rev.

to_list(B) when is_binary(B) -> binary_to_list(B);
to_list(L) when is_list(L) -> L.

prefix_atom(Name) ->
    list_to_atom(lists:map(fun($-) -> $_; (C) -> C end, Name)).

%%--------------------------------------------------------------------
%% Generate YANG 1.1 from the live schema tree
%%--------------------------------------------------------------------

generate(#{prefix := Prefix, module := Module, namespace := URI} = Info) ->
    Acc0 = #{imports => #{}, indent => 0},
    {Identities, Acc1} = identities(Module, Acc0),
    {Body, Acc2} = data_body(Prefix, Module, Acc1),
    {Augments, Acc3} = augments(Module, Acc2),
    Header = header(Info, URI, Acc3),
    ["module ", quote_ident(Module), " {\n",
     Header,
     Identities,
     Body,
     Augments,
     "}\n"].

header(Info, URI, #{imports := Imports}) ->
    Prefix = maps:get(prefix, Info),
    Src = maps:get(source, Info, unknown),
    [pad(1), "yang-version 1.1;\n",
     pad(1), "namespace ", quote_str(URI), ";\n",
     pad(1), "prefix ", quote_ident(atom_to_list(Prefix)), ";\n\n",
     import_stmts(maps:to_list(Imports), Prefix),
     pad(1), "description\n",
     pad(2), quote_str(source_desc(Src)), ";\n",
     revision_stmt(maps:get(revision, Info, undefined))].

source_desc(function) ->
    "Generated by mgmtd from an Erlang function schema.";
source_desc(json) ->
    "Generated by mgmtd from a JSON Schema draft-07 module.";
source_desc(yang) ->
    "Generated by mgmtd from the loaded YANG schema tree.";
source_desc(_) ->
    "Generated by mgmtd.".

revision_stmt(undefined) ->
    "\n";
revision_stmt("") ->
    "\n";
revision_stmt(Rev) ->
    [$\n, pad(1), "revision ", Rev, " {\n",
     pad(2), "description\n", pad(3), quote_str("Schema revision."), ";\n",
     pad(1), "}\n\n"].

import_stmts([], _Self) ->
    [];
import_stmts(List, Self) ->
    SelfName = atom_to_list(Self),
    [[pad(1), "import ", quote_ident(Mod), " {\n",
      pad(2), "prefix ", quote_ident(Pfx), ";\n",
      pad(1), "}\n"]
     || {Mod, Pfx} <- lists:sort(List), Mod =/= SelfName] ++ [$\n].

identities(Module, Acc) ->
    ModBin = list_to_binary(Module),
    Ids = unique_qnames(
            [Id || Id <- maps:values(mgmtd_schema:identities()),
                   maps:get(module, Id, undefined) =:= ModBin]),
    {[[identity_stmt(Id)] || Id <- Ids], Acc}.

unique_qnames(Ids) ->
    {_, Uniq} =
        lists:foldl(
          fun(Id, {Seen, Acc}) ->
                  Q = maps:get(qname, Id),
                  case maps:is_key(Q, Seen) of
                      true -> {Seen, Acc};
                      false -> {Seen#{Q => true}, Acc ++ [Id]}
                  end
          end, {#{}, []}, Ids),
    Uniq.

identity_stmt(#{local := Local} = Id) ->
    Bases = maps:get(bases, Id, []),
    LocalS = to_list(Local),
    case Bases of
        [] ->
            [pad(1), "identity ", quote_ident(LocalS), ";\n"];
        _ ->
            [pad(1), "identity ", quote_ident(LocalS), " {\n",
             [[pad(2), "base ", quote_ident(base_ref(B, maps:get(module, Id))), ";\n"]
              || B <- Bases],
             pad(1), "}\n"]
    end.

base_ref(Base, ModBin) ->
    S = to_list(Base),
    Prefix = to_list(ModBin) ++ ":",
    case lists:prefix(Prefix, S) of
        true -> lists:nthtail(length(Prefix), S);
        false -> S
    end.

data_body(Prefix, Module, Acc) ->
    Kids = own_children(Prefix, prefix_base(Prefix), Module),
    emit_nodes(Kids, Prefix, Module, 1, Acc).

own_children(Prefix, Path, Module) ->
    Named = [atom_to_list(P) || #{prefix := P} <- mgmtd_schema:loaded_schema_infos(),
                                P =/= ?DEFAULT_NS],
    [C || C <- mgmtd_schema:children(Path, show),
          maps:get(node_type, C) =/= list_key,
          not foreign_origin(C, Module),
          not (Prefix =:= ?DEFAULT_NS
               andalso Path =:= []
               andalso lists:member(maps:get(name, C), Named))].

foreign_origin(#{origin_module := Origin}, Module)
  when is_list(Origin), Origin =/= Module ->
    true;
foreign_origin(_, _) ->
    false.

emit_nodes(Nodes, Prefix, Module, Ind, Acc) ->
    {Plain, Choices} = split_choices(Nodes),
    {PlainTxt, Acc1} = lists:mapfoldl(
                         fun(N, A) -> emit_node(N, Prefix, Module, Ind, A) end,
                         Acc, sort_nodes(Plain)),
    {ChoiceTxt, Acc2} = lists:mapfoldl(
                          fun(G, A) -> emit_choice(G, Prefix, Module, Ind, A) end,
                          Acc1, lists:keysort(1, Choices)),
    {PlainTxt ++ ChoiceTxt, Acc2}.

split_choices(Nodes) ->
    lists:foldl(
      fun(N, {Plain, Choices}) ->
              case proplists:get_value(choice, maps:get(opts, N, [])) of
                  undefined ->
                      {Plain ++ [N], Choices};
                  CN ->
                      Case = proplists:get_value('case', maps:get(opts, N, []), CN),
                      Def = proplists:get_value(choice_default, maps:get(opts, N, []),
                                                undefined),
                      {Plain, add_choice(Choices, CN, Case, Def, N)}
              end
      end, {[], []}, Nodes).

add_choice(Choices, CN, Case, Def, N) ->
    case lists:keyfind(CN, 1, Choices) of
        {CN, Def0, Cases} ->
            lists:keystore(CN, 1, Choices, {CN, pick_def(Def0, Def), add_case(Cases, Case, N)});
        false ->
            Choices ++ [{CN, Def, [{Case, [N]}]}]
    end.

pick_def(undefined, D) -> D;
pick_def(D, _) -> D.

add_case(Cases, Case, N) ->
    case lists:keyfind(Case, 1, Cases) of
        {Case, Ns} -> lists:keystore(Case, 1, Cases, {Case, Ns ++ [N]});
        false -> Cases ++ [{Case, [N]}]
    end.

sort_nodes(Nodes) ->
    lists:sort(fun(A, B) -> maps:get(name, A) =< maps:get(name, B) end, Nodes).

emit_choice({Name, Def, Cases}, Prefix, Module, Ind, Acc) ->
    {CaseTxt, Acc1} =
        lists:mapfoldl(
          fun({CName, Ns}, A) ->
                  {Body, A1} = emit_nodes(Ns, Prefix, Module, Ind + 2, A),
                  {[pad(Ind + 1), "case ", quote_ident(CName), " {\n",
                    Body,
                    pad(Ind + 1), "}\n"], A1}
          end, Acc, Cases),
    Default = case Def of
                  undefined -> [];
                  D -> [pad(Ind + 1), "default ", quote_ident(D), ";\n"]
              end,
    {[pad(Ind), "choice ", quote_ident(Name), " {\n",
      Default,
      CaseTxt,
      pad(Ind), "}\n"], Acc1}.

emit_node(#{node_type := container} = N, Prefix, Module, Ind, Acc) ->
    Path = maps:get(path, N),
    {KidsTxt, Acc1} = emit_nodes(own_children(Prefix, Path, Module),
                                 Prefix, Module, Ind + 1, Acc),
    {block(Ind, "container", maps:get(name, N),
           node_body(N, Ind + 1) ++ KidsTxt), Acc1};
emit_node(#{node_type := list} = N, Prefix, Module, Ind, Acc) ->
    Path = maps:get(path, N),
    Keys = maps:get(key_names, N, []),
    {KidsTxt, Acc1} = emit_nodes(own_children(Prefix, Path, Module),
                                 Prefix, Module, Ind + 1, Acc),
    KeyStmt = case Keys of
                  [] -> [];
                  _ -> [pad(Ind + 1), "key ", quote_str(string:join(Keys, " ")), ";\n"]
              end,
    Extra = list_extras(N, Ind + 1),
    {block(Ind, "list", maps:get(name, N),
           node_body(N, Ind + 1) ++ KeyStmt ++ Extra ++ KidsTxt), Acc1};
emit_node(#{node_type := leaf} = N, _Prefix, _Module, Ind, Acc) ->
    {TypeTxt, Acc1} = emit_type(maps:get(type, N, string), N, Ind + 1, Acc),
    {block(Ind, "leaf", maps:get(name, N),
           node_body(N, Ind + 1) ++ TypeTxt ++ default_stmt(N, Ind + 1)), Acc1};
emit_node(#{node_type := leaf_list} = N, _Prefix, _Module, Ind, Acc) ->
    {TypeTxt, Acc1} = emit_type(maps:get(type, N, string), N, Ind + 1, Acc),
    Extra = list_extras(N, Ind + 1),
    {block(Ind, "leaf-list", maps:get(name, N),
           node_body(N, Ind + 1) ++ TypeTxt ++ Extra), Acc1};
emit_node(_, _Prefix, _Module, _Ind, Acc) ->
    {[], Acc}.

block(Ind, Kind, Name, Body) ->
    [pad(Ind), Kind, $ , quote_ident(Name), " {\n", Body, pad(Ind), "}\n"].

node_body(N, Ind) ->
    Opts = maps:get(opts, N, []),
    [desc_stmt(maps:get(desc, N, ""), Ind),
     config_stmt(maps:get(config, N, false), Ind),
     mandatory_stmt(maps:get(mandatory, N, false), Ind),
     presence_stmt(Opts, Ind),
     when_stmt(Opts, Ind),
     must_stmts(Opts, Ind),
     if_feature_stmts(Opts, Ind)].

desc_stmt("", _) -> [];
desc_stmt(undefined, _) -> [];
desc_stmt(D, Ind) ->
    [pad(Ind), "description\n", pad(Ind + 1), quote_str(D), ";\n"].

config_stmt(false, Ind) -> [pad(Ind), "config false;\n"];
config_stmt(_, _) -> [].

mandatory_stmt(true, Ind) -> [pad(Ind), "mandatory true;\n"];
mandatory_stmt(_, _) -> [].

presence_stmt(Opts, Ind) ->
    case proplists:get_value(presence, Opts) of
        undefined -> [];
        Desc -> [pad(Ind), "presence ", quote_str(Desc), ";\n"]
    end.

when_stmt(Opts, Ind) ->
    case proplists:get_value('when', Opts) of
        undefined -> [];
        Expr -> [pad(Ind), "when ", quote_str(Expr), ";\n"]
    end.

must_stmts(Opts, Ind) ->
    [must_stmt(M, Ind) || {must, M} <- Opts].

must_stmt(#{expr := Expr} = M, Ind) ->
    case maps:get(error_message, M, undefined) of
        undefined ->
            [pad(Ind), "must ", quote_str(Expr), ";\n"];
        Msg ->
            [pad(Ind), "must ", quote_str(Expr), " {\n",
             pad(Ind + 1), "error-message ", quote_str(Msg), ";\n",
             pad(Ind), "}\n"]
    end.

if_feature_stmts(Opts, Ind) ->
    case proplists:get_value('if-feature', Opts) of
        undefined -> [];
        Feats -> [[pad(Ind), "if-feature ", quote_ident(F), ";\n"] || F <- Feats]
    end.

list_extras(N, Ind) ->
    Opts = maps:get(opts, N, []),
    Min = maps:get(min_elements, N, 0),
    Max = maps:get(max_elements, N, unlimited),
    Ordered = maps:get(ordered_by, N, system),
    [case Min of 0 -> []; _ -> [pad(Ind), "min-elements ", integer_to_list(Min), ";\n"] end,
     case Max of unlimited -> []; _ -> [pad(Ind), "max-elements ", integer_to_list(Max), ";\n"] end,
     case Ordered of user -> [pad(Ind), "ordered-by user;\n"]; _ -> [] end,
     unique_stmts(Opts, Ind)].

unique_stmts(Opts, Ind) ->
    case proplists:get_value(unique, Opts) of
        undefined -> [];
        Groups ->
            [[pad(Ind), "unique ", quote_str(string:join(G, " ")), ";\n"]
             || G <- Groups]
    end.

default_stmt(N, Ind) ->
    case maps:get(default, N, undefined) of
        undefined -> [];
        missing_default -> [];
        empty -> [];
        D -> [pad(Ind), "default ", default_val(D), ";\n"]
    end.

default_val(true) -> "true";
default_val(false) -> "false";
default_val(I) when is_integer(I) -> integer_to_list(I);
default_val(F) when is_float(F) -> float_to_list(F);
default_val(B) when is_binary(B) -> quote_str(binary_to_list(B));
default_val(S) when is_list(S) -> quote_str(S);
default_val(A) when is_atom(A) -> quote_str(atom_to_list(A));
default_val(Other) -> quote_str(lists:flatten(io_lib:format("~p", [Other]))).

%%--------------------------------------------------------------------
%% Types
%%--------------------------------------------------------------------

emit_type(Type, Node, Ind, Acc) ->
    Pattern = maps:get(pattern, Node, undefined),
    emit_type1(Type, Pattern, Ind, Acc).

emit_type1(undefined, Pattern, Ind, Acc) ->
    emit_type1(string, Pattern, Ind, Acc);
emit_type1(string, Pattern, Ind, Acc) when Pattern =/= undefined ->
    {[pad(Ind), "type string {\n",
      pad(Ind + 1), "pattern ", quote_str(Pattern), ";\n",
      pad(Ind), "}\n"], Acc};
emit_type1(Atom, _P, Ind, Acc) when is_atom(Atom) ->
    named_type(atom_to_list(Atom), Ind, Acc);
emit_type1({enum, Members}, _P, Ind, Acc) ->
    {[pad(Ind), "type enumeration {\n",
      [enum_stmt(M, Ind + 1) || M <- Members],
      pad(Ind), "}\n"], Acc};
emit_type1({enumeration, Members}, P, Ind, Acc) ->
    emit_type1({enum, Members}, P, Ind, Acc);
emit_type1({union, Types}, _P, Ind, Acc) ->
    {Inner, Acc1} = lists:mapfoldl(
                      fun(T, A) -> emit_type1(T, undefined, Ind + 1, A) end,
                      Acc, Types),
    {[pad(Ind), "type union {\n", Inner, pad(Ind), "}\n"], Acc1};
emit_type1({bits, Bits}, _P, Ind, Acc) ->
    {[pad(Ind), "type bits {\n",
      [bit_stmt(B, Ind + 1) || B <- Bits],
      pad(Ind), "}\n"], Acc};
emit_type1({decimal64, Digits}, _P, Ind, Acc) when is_integer(Digits) ->
    {[pad(Ind), "type decimal64 {\n",
      pad(Ind + 1), "fraction-digits ", integer_to_list(Digits), ";\n",
      pad(Ind), "}\n"], Acc};
emit_type1({decimal64, Digits, Range}, _P, Ind, Acc) ->
    {[pad(Ind), "type decimal64 {\n",
      pad(Ind + 1), "fraction-digits ", integer_to_list(Digits), ";\n",
      range_stmt(Range, Ind + 1),
      pad(Ind), "}\n"], Acc};
emit_type1({identityref, Base}, _P, Ind, Acc) ->
    {BaseTxt, Acc1} = identity_base(Base, Acc),
    {[pad(Ind), "type identityref {\n",
      pad(Ind + 1), "base ", BaseTxt, ";\n",
      pad(Ind), "}\n"], Acc1};
emit_type1({leafref, Path}, _P, Ind, Acc) ->
    {[pad(Ind), "type leafref {\n",
      pad(Ind + 1), "path ", quote_str(Path), ";\n",
      pad(Ind), "}\n"], Acc};
emit_type1({leafref, Path, Require}, _P, Ind, Acc) ->
    Req = case Require of
              false -> [pad(Ind + 1), "require-instance false;\n"];
              _ -> []
          end,
    {[pad(Ind), "type leafref {\n",
      pad(Ind + 1), "path ", quote_str(Path), ";\n",
      Req,
      pad(Ind), "}\n"], Acc};
emit_type1({'instance-identifier', Require}, _P, Ind, Acc) ->
    case Require of
        false ->
            {[pad(Ind), "type instance-identifier {\n",
              pad(Ind + 1), "require-instance false;\n",
              pad(Ind), "}\n"], Acc};
        _ ->
            named_type("instance-identifier", Ind, Acc)
    end;
emit_type1({Base, Range}, _P, Ind, Acc) when is_atom(Base), is_list(Range) ->
    case is_int_base(Base) of
        true ->
            {[pad(Ind), "type ", atom_to_list(Base), " {\n",
              range_stmt(Range, Ind + 1),
              pad(Ind), "}\n"], Acc};
        false ->
            callback_type(Base, Range, Ind, Acc)
    end;
emit_type1({Mod, Type}, _P, Ind, Acc) when is_atom(Mod) ->
    callback_type(Mod, Type, Ind, Acc);
emit_type1(Other, _P, Ind, Acc) ->
    named_type(lists:flatten(io_lib:format("~p", [Other])), Ind, Acc).

named_type("inet:ip-address", Ind, Acc) ->
    simple_type("inet:ip-address", Ind, need_import(Acc, ?INET, "inet"));
named_type("inet:port-number", Ind, Acc) ->
    simple_type("inet:port-number", Ind, need_import(Acc, ?INET, "inet"));
named_type("inet:ipv4-address", Ind, Acc) ->
    simple_type("inet:ipv4-address", Ind, need_import(Acc, ?INET, "inet"));
named_type("inet:ipv6-address", Ind, Acc) ->
    simple_type("inet:ipv6-address", Ind, need_import(Acc, ?INET, "inet"));
named_type("integer", Ind, Acc) ->
    simple_type("int64", Ind, Acc);
named_type("number", Ind, Acc) ->
    {[pad(Ind), "type decimal64 {\n",
      pad(Ind + 1), "fraction-digits 6;\n",
      pad(Ind), "}\n"], Acc};
named_type(Name, Ind, Acc) ->
    simple_type(Name, Ind, Acc).

simple_type(Name, Ind, Acc) ->
    {[pad(Ind), "type ", Name, ";\n"], Acc}.

need_import(#{imports := Imps} = Acc, Mod, Pfx) ->
    Acc#{imports := Imps#{Mod => Pfx}}.

is_int_base(T) ->
    lists:member(T, [uint8, uint16, uint32, uint64,
                     int8, int16, int32, int64]).

range_stmt(Range, Ind) ->
    Min = proplists:get_value(min, Range),
    Max = proplists:get_value(max, Range),
    Spec = case {Min, Max} of
               {undefined, undefined} -> undefined;
               {undefined, Mx} -> "min.." ++ integer_to_list(Mx);
               {Mn, undefined} -> integer_to_list(Mn) ++ "..max";
               {Mn, Mx} -> integer_to_list(Mn) ++ ".." ++ integer_to_list(Mx)
           end,
    case Spec of
        undefined -> [];
        _ -> [pad(Ind), "range ", quote_str(Spec), ";\n"]
    end.

enum_stmt(#{name := N} = M, Ind) ->
    Body = [desc_stmt(maps:get(desc, M, undefined), Ind + 1),
            case maps:get(value, M, undefined) of
                undefined -> [];
                V -> [pad(Ind + 1), "value ", integer_to_list(V), ";\n"]
            end],
    enum_block(N, Body, Ind);
enum_stmt({Name, Desc}, Ind) ->
    enum_block(Name, desc_stmt(Desc, Ind + 1), Ind);
enum_stmt(Name, Ind) ->
    [pad(Ind), "enum ", quote_ident(to_list(Name)), ";\n"].

enum_block(Name, [], Ind) ->
    [pad(Ind), "enum ", quote_ident(to_list(Name)), ";\n"];
enum_block(Name, Body, Ind) ->
    [pad(Ind), "enum ", quote_ident(to_list(Name)), " {\n", Body, pad(Ind), "}\n"].

bit_stmt(#{name := N} = M, Ind) ->
    case maps:get(position, M, undefined) of
        undefined ->
            [pad(Ind), "bit ", quote_ident(to_list(N)), ";\n"];
        P ->
            [pad(Ind), "bit ", quote_ident(to_list(N)), " {\n",
             pad(Ind + 1), "position ", integer_to_list(P), ";\n",
             pad(Ind), "}\n"]
    end;
bit_stmt({Name, Pos}, Ind) when is_integer(Pos) ->
    [pad(Ind), "bit ", quote_ident(to_list(Name)), " {\n",
     pad(Ind + 1), "position ", integer_to_list(Pos), ";\n",
     pad(Ind), "}\n"];
bit_stmt(Name, Ind) ->
    [pad(Ind), "bit ", quote_ident(to_list(Name)), ";\n"].

identity_base(Base, Acc) ->
    S = to_list(Base),
    case string:split(S, ":") of
        [Mod, _Local] ->
            {S, need_import(Acc, Mod, yang_prefix(Mod))};
        _ ->
            {S, Acc}
    end.

yang_prefix(Mod) ->
    lists:map(fun($-) -> $_; (C) -> C end, Mod).

callback_type(Mod, Type, Ind, Acc) ->
    Note = lists:flatten(io_lib:format("mgmtd callback ~p:~p", [Mod, Type])),
    {[pad(Ind), "type string;\n",
      pad(Ind), "description\n", pad(Ind + 1), quote_str(Note), ";\n"], Acc}.

%%--------------------------------------------------------------------
%% Remote augments (nodes tagged origin_module)
%%--------------------------------------------------------------------

augments(Module, Acc) ->
    Groups = collect_augments(Module),
    lists:mapfoldl(
      fun({{TgtMod, ParentPath}, Nodes}, A) ->
              emit_augment(TgtMod, ParentPath, Nodes, Module, A)
      end, Acc, lists:sort(maps:to_list(Groups))).

collect_augments(Module) ->
    lists:foldl(
      fun(#{prefix := Prefix}, Acc) ->
              walk_augments(Prefix, prefix_base(Prefix), Module, Acc)
      end, #{}, mgmtd_schema:loaded_schema_infos()).

walk_augments(Prefix, Path, Module, Acc) ->
    lists:foldl(
      fun(Child, Acc1) ->
              Name = maps:get(name, Child),
              ChildPath = Path ++ [Name],
              case maps:get(origin_module, Child, undefined) of
                  Module ->
                      Tgt = module_of_prefix(Prefix),
                      Parent = strip_prefix(Prefix, Path),
                      Key = {Tgt, Parent},
                      Acc1#{Key => maps:get(Key, Acc1, []) ++ [Child#{prefix => Prefix}]};
                  _ ->
                      case maps:get(node_type, Child) of
                          leaf -> Acc1;
                          leaf_list -> Acc1;
                          _ -> walk_augments(Prefix, ChildPath, Module, Acc1)
                      end
              end
      end, Acc, mgmtd_schema:children(Path, show)).

module_of_prefix(Prefix) ->
    case [M || #{prefix := P, module := M} <- mgmtd_schema:loaded_schema_infos(),
               P =:= Prefix] of
        [M | _] -> M;
        [] -> atom_to_list(Prefix)
    end.

strip_prefix(Prefix, [Name | Rest]) ->
    case atom_to_list(Prefix) of
        Name -> Rest;
        _ -> [Name | Rest]
    end;
strip_prefix(_, Path) ->
    Path.

emit_augment(TgtMod, ParentPath, Nodes, Module, Acc0) ->
    Acc1 = need_import(Acc0, TgtMod, yang_prefix(TgtMod)),
    Target = augment_path(TgtMod, ParentPath),
    %% Nodes already live in the target tree; emit them without walking
    %% further origin tags (they are the augment payload).
    Prefix = maps:get(prefix, hd(Nodes)),
    {Body, Acc2} = emit_nodes(Nodes, Prefix, Module, 2, Acc1),
    {[pad(1), "augment ", quote_str(Target), " {\n",
      Body,
      pad(1), "}\n"], Acc2}.

augment_path(TgtMod, []) ->
    "/" ++ TgtMod ++ ":*";
augment_path(TgtMod, [First | Rest]) ->
    lists:flatten(["/", TgtMod, $:, First,
                   [["/", N] || N <- Rest]]).

prefix_base(?DEFAULT_NS) ->
    [];
prefix_base(Prefix) ->
    [atom_to_list(Prefix)].

%%--------------------------------------------------------------------
%% Quoting
%%--------------------------------------------------------------------

pad(N) ->
    lists:duplicate(N * 2, $\s).

quote_ident(Name) ->
    S = to_list(Name),
    case is_ident(S) of
        true -> S;
        false -> quote_str(S)
    end.

is_ident([C | Rest]) when C >= $A, C =< $Z; C >= $a, C =< $z; C =:= $_ ->
    lists:all(fun ident_char/1, Rest);
is_ident(_) ->
    false.

ident_char(C) when C >= $A, C =< $Z; C >= $a, C =< $z;
                   C >= $0, C =< $9; C =:= $_; C =:= $-; C =:= $. ->
    true;
ident_char(_) ->
    false.

quote_str(S) ->
    [$", escape(to_list(S)), $"].

escape([]) -> [];
escape([$\\ | T]) -> [$\\, $\\ | escape(T)];
escape([$" | T]) -> [$\\, $" | escape(T)];
escape([$\n | T]) -> [$\\, $n | escape(T)];
escape([$\t | T]) -> [$\\, $t | escape(T)];
escape([H | T]) -> [H | escape(T)].
