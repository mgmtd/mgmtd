%% Evaluate YANG must/when with OTP xmerl_xpath over an XML projection
%% of the transaction tree (RFC 7950 §6.4).
%%
%% xmerl does not dispatch custom functions, so current() is rewritten
%% to an absolute path to the context node. Unprefixed XPath names are
%% matched by emitting local-name XML (no namespaces). Known YANG
%% prefixes in the expression (if:foo) are stripped to local names.
-module(mgmtd_yang_xpath).

-export([validate_txn/1]).

-include("mgmtd_schema.hrl").
-include_lib("xmerl/include/xmerl.hrl").

-spec validate_txn(mgmtd_cfg_txn:txn()) -> ok | {error, term()}.
validate_txn(Txn) ->
    try
        validate_txn1(Txn)
    catch
        error:Reason ->
            {error, {xpath_internal, Reason}};
        exit:Reason ->
            {error, {xpath_internal, Reason}}
    end.

validate_txn1(Txn) ->
    case has_constraints() of
        false ->
            ok;
        true ->
            Rows = mgmtd_cfg_txn:match_object(
                     Txn, #cfg{_ = mgmtd_schema:ets_pat('_')}),
            {Doc, Index} = project_xml(Rows),
            check_rows(Rows, Doc, Index)
    end.

has_constraints() ->
    case ets:info(mgmtd_commands) of
        undefined ->
            false;
        _ ->
            lists:any(fun schema_has_constraint/1, ets:tab2list(mgmtd_commands))
    end.

schema_has_constraint(#schema{opts = Opts}) ->
    lists:keymember(must, 1, Opts) orelse lists:keymember('when', 1, Opts);
schema_has_constraint(_) ->
    false.

check_rows([], _Doc, _Index) ->
    ok;
check_rows([#cfg{node_type = list} | Rest], Doc, Index) ->
    check_rows(Rest, Doc, Index);
check_rows([#cfg{path = Path} = Cfg | Rest], Doc, Index) ->
    case mgmtd_schema:lookup(Path) of
        #{opts := Opts} ->
            case check_opts(Cfg, Opts, Doc, Index) of
                ok ->
                    check_rows(Rest, Doc, Index);
                Error ->
                    Error
            end;
        _ ->
            check_rows(Rest, Doc, Index)
    end.

check_opts(#cfg{path = Path}, Opts, Doc, Index) ->
    case proplists:get_value('when', Opts, undefined) of
        undefined ->
            check_musts(Path, proplists:get_all_values(must, Opts), Doc, Index);
        WhenExpr ->
            case eval_bool(WhenExpr, Path, Doc, Index) of
                {ok, true} ->
                    check_musts(Path, proplists:get_all_values(must, Opts),
                                Doc, Index);
                {ok, false} ->
                    {error, {when_failed, Path, WhenExpr}};
                {error, _} = Err ->
                    Err
            end
    end.

check_musts(_Path, [], _Doc, _Index) ->
    ok;
check_musts(Path, [Must | Rest], Doc, Index) ->
    {Expr, Msg} = must_parts(Must),
    case eval_bool(Expr, Path, Doc, Index) of
        {ok, true} ->
            check_musts(Path, Rest, Doc, Index);
        {ok, false} ->
            {error, {must_failed, Path, Expr, Msg}};
        {error, _} = Err ->
            Err
    end.

must_parts(#{expr := Expr} = M) ->
    {Expr, maps:get(error_message, M, undefined)};
must_parts(Expr) when is_list(Expr) ->
    {Expr, undefined}.

eval_bool(Expr, Path, Doc, Index) ->
    case maps:find(Path, Index) of
        error ->
            {ok, true};
        {ok, ContextEl} ->
            Rewritten = rewrite_expr(Expr, Path),
            try
                Tokens = xmerl_xpath_scan:tokens(Rewritten),
                {ok, Parsed} = xmerl_xpath_parse:parse(Tokens),
                Ctx = xpath_context(ContextEl, Doc),
                {ok, xmerl_xpath_pred:eval(Parsed, Ctx)}
            catch
                exit:Reason ->
                    {error, {xpath_error, Path, Expr, Reason}};
                error:Reason ->
                    {error, {xpath_error, Path, Expr, Reason}}
            end
    end.

xpath_context(El, Doc) ->
    Parents = parent_nodes(El#xmlElement.parents, Doc),
    ContextNode = #xmlNode{type = element, node = El, parents = Parents},
    Whole = #xmlNode{type = root_node,
                     node = Doc,
                     parents = []},
    #xmlContext{context_node = ContextNode,
                nodeset = [ContextNode],
                whole_document = Whole}.

parent_nodes(Parents, Doc) ->
    parent_nodes(lists:reverse(Parents), doc_content(Doc), []).

parent_nodes([], _Content, Acc) ->
    Acc;
parent_nodes([{Name, Pos} | Rest], Content, Acc) ->
    E = locate_element(Name, Pos, Content),
    PN = #xmlNode{type = element, node = E, parents = Acc},
    parent_nodes(Rest, element_content(E), [PN | Acc]).

doc_content(#xmlDocument{content = C}) when is_list(C) -> C;
doc_content(#xmlDocument{content = C}) -> [C];
doc_content(#xmlElement{content = C}) -> C.

element_content(#xmlElement{content = C}) when is_list(C) -> C;
element_content(#xmlDocument{content = C}) when is_list(C) -> C;
element_content(#xmlDocument{content = C}) -> [C].

locate_element(Name, Pos, [E = #xmlElement{name = Name, pos = Pos} | _]) ->
    E;
locate_element(_Name, Pos, [#xmlElement{pos = P} | _]) when P >= Pos ->
    exit(invalid_parents);
locate_element(_Name, _Pos, []) ->
    exit(invalid_parents);
locate_element(Name, Pos, [_ | T]) ->
    locate_element(Name, Pos, T).

%%--------------------------------------------------------------------
%% Expression rewrite
%%--------------------------------------------------------------------

rewrite_expr(Expr, Path) ->
    Abs = instance_xpath(Path),
    WithCurrent = re:replace(Expr, "current\\s*\\(\\s*\\)",
                             "(" ++ escape_re(Abs) ++ ")",
                             [global, {return, list}]),
    strip_prefixes(WithCurrent, yang_prefix_names()).

escape_re(S) ->
    re:replace(S, "[\\\\&]", "\\\\&", [global, {return, list}]).

yang_prefix_names() ->
    [atom_to_list(P) || P <- mgmtd_schema:registered_schemas(), P =/= default].

%% Strip known YANG prefixes (if:foo → foo). Quote-aware.
strip_prefixes(Expr, Prefixes) ->
    strip_prefixes(Expr, Prefixes, out, []).

strip_prefixes([], _Pfxs, _State, Acc) ->
    lists:reverse(Acc);
strip_prefixes([$' | T], Pfxs, out, Acc) ->
    strip_prefixes(T, Pfxs, squote, [$' | Acc]);
strip_prefixes([$' | T], Pfxs, squote, Acc) ->
    strip_prefixes(T, Pfxs, out, [$' | Acc]);
strip_prefixes([$\" | T], Pfxs, out, Acc) ->
    strip_prefixes(T, Pfxs, dquote, [$\" | Acc]);
strip_prefixes([$\" | T], Pfxs, dquote, Acc) ->
    strip_prefixes(T, Pfxs, out, [$\" | Acc]);
strip_prefixes([C | T], Pfxs, State, Acc) when State =/= out ->
    strip_prefixes(T, Pfxs, State, [C | Acc]);
strip_prefixes(Expr, Pfxs, out, Acc) ->
    case take_qname(Expr) of
        {Pfx, Local, Rest} ->
            case lists:member(Pfx, Pfxs) of
                true ->
                    strip_prefixes(Rest, Pfxs, out, lists:reverse(Local, Acc));
                false ->
                    strip_prefixes(Rest, Pfxs, out,
                                   lists:reverse(Pfx ++ ":" ++ Local, Acc))
            end;
        false ->
            [C | T] = Expr,
            strip_prefixes(T, Pfxs, out, [C | Acc])
    end.

take_qname([C | _] = Expr) when C >= $a, C =< $z; C >= $A, C =< $Z; C =:= $_ ->
    {Ident, Rest0} = lists:splitwith(fun is_ncname_char/1, Expr),
    case Rest0 of
        [$: | Rest1] ->
            case Rest1 of
                [D | _] when D >= $a, D =< $z; D >= $A, D =< $Z; D =:= $_ ->
                    {Local, Rest} = lists:splitwith(fun is_ncname_char/1, Rest1),
                    {Ident, Local, Rest};
                _ ->
                    false
            end;
        _ ->
            false
    end;
take_qname(_) ->
    false.

is_ncname_char(C) when C >= $a, C =< $z; C >= $A, C =< $Z;
                       C >= $0, C =< $9; C =:= $_; C =:= $-; C =:= $. ->
    true;
is_ncname_char(_) ->
    false.

instance_xpath(Path) ->
    Pfxs = yang_prefix_names(),
    {Steps, _} =
        lists:foldl(
          fun(Seg, {Acc, Inst}) ->
                  Inst1 = Inst ++ [Seg],
                  case Seg of
                      S when is_list(S) ->
                          case Inst =:= [] andalso lists:member(S, Pfxs) of
                              true ->
                                  {Acc, Inst1};
                              false ->
                                  {[S | Acc], Inst1}
                          end;
                      Key when is_tuple(Key) ->
                          case Acc of
                              [ListName | AccRest] ->
                                  Preds = key_predicates(Inst, tuple_to_list(Key)),
                                  {[ListName ++ Preds | AccRest], Inst1};
                              [] ->
                                  {Acc, Inst1}
                          end
                  end
          end, {[], []}, Path),
    case lists:reverse(Steps) of
        [] -> "/";
        Ss -> "/" ++ string:join(Ss, "/")
    end.

key_predicates(ListPath, KeyVals) ->
    case mgmtd_schema:lookup(ListPath) of
        #{key_names := Names} when length(Names) =:= length(KeyVals) ->
            lists:flatten(
              [ [$[, N, $=, xpath_lit(key_text(V)), $]]
                || {N, V} <- lists:zip(Names, KeyVals) ]);
        _ ->
            []
    end.

xpath_lit(S) ->
    case lists:member($', S) of
        false -> [$' | S] ++ "'";
        true -> [$\" | S] ++ "\""
    end.

%%--------------------------------------------------------------------
%% XML projection (from flat #cfg{} rows; do not use the zipper)
%%--------------------------------------------------------------------

project_xml(Rows) ->
    {Content, Index, _} = emit_children([], Rows, [], 1, #{}),
    {#xmlDocument{content = Content}, Index}.

child_rows(Parent, Rows) ->
    Len = length(Parent),
    [C || #cfg{path = P} = C <- Rows,
          length(P) =:= Len + 1,
          lists:prefix(Parent, P)].

emit_children(Parent, Rows, Parents, Pos, Index) ->
    emit_kids(child_rows(Parent, Rows), Rows, Parents, Pos, Index).

emit_kids([], _Rows, _Parents, Pos, Index) ->
    {[], Index, Pos};
emit_kids([#cfg{node_type = list, name = Name, path = Path} | Rest],
          Rows, Parents, Pos, Index) ->
    Keys = [C || #cfg{node_type = list_key, path = P} = C <- Rows,
                 length(P) =:= length(Path) + 1,
                 lists:prefix(Path, P)],
    {Els1, Index1, Pos1} = emit_list_keys(Name, Keys, Rows, Parents, Pos, Index),
    {Els2, Index2, Pos2} = emit_kids(Rest, Rows, Parents, Pos1, Index1),
    {Els1 ++ Els2, Index2, Pos2};
emit_kids([#cfg{node_type = container, name = Name, path = Path} = C | Rest],
          Rows, Parents, Pos, Index) ->
    case Parents =:= [] andalso lists:member(Name, yang_prefix_names()) of
        true ->
            {Els1, Index1, Pos1} = emit_children(Path, Rows, Parents, Pos, Index),
            {Els2, Index2, Pos2} = emit_kids(Rest, Rows, Parents, Pos1, Index1),
            {Els1 ++ Els2, Index2, Pos2};
        false ->
            {Els1, Index1} = emit_container(C, Rows, Parents, Pos, Index),
            {Els2, Index2, Pos2} = emit_kids(Rest, Rows, Parents, Pos + 1, Index1),
            {Els1 ++ Els2, Index2, Pos2}
    end;
emit_kids([#cfg{node_type = list_key} | Rest], Rows, Parents, Pos, Index) ->
    emit_kids(Rest, Rows, Parents, Pos, Index);
emit_kids([#cfg{node_type = Leaf, name = Name, path = Path, value = Value} | Rest],
          Rows, Parents, Pos, Index)
  when Leaf =:= leaf; Leaf =:= leaf_list ->
    {Els1, Index1} = emit_leaf(Name, Path, Value, Parents, Pos, Index),
    {Els2, Index2, Pos2} = emit_kids(Rest, Rows, Parents, Pos + 1, Index1),
    {Els1 ++ Els2, Index2, Pos2};
emit_kids([_ | Rest], Rows, Parents, Pos, Index) ->
    emit_kids(Rest, Rows, Parents, Pos, Index).

emit_list_keys(_Name, [], _Rows, _Parents, Pos, Index) ->
    {[], Index, Pos};
emit_list_keys(Name, [#cfg{path = Path} | Rest], Rows, Parents, Pos, Index) ->
    ElName = name_atom(Name),
    NewParents = Parents ++ [{ElName, Pos}],
    {Content, Index1, _} = emit_children(Path, Rows, NewParents, 1, Index),
    El = xml_el(ElName, Parents, Pos, Content),
    Index2 = Index1#{Path => El},
    {Els2, Index3, Pos2} = emit_list_keys(Name, Rest, Rows, Parents, Pos + 1, Index2),
    {[El | Els2], Index3, Pos2}.

emit_container(#cfg{name = Name, path = Path}, Rows, Parents, Pos, Index) ->
    ElName = name_atom(Name),
    NewParents = Parents ++ [{ElName, Pos}],
    {Content, Index1, _} = emit_children(Path, Rows, NewParents, 1, Index),
    El = xml_el(ElName, Parents, Pos, Content),
    {[El], Index1#{Path => El}}.

emit_leaf(Name, Path, Value, Parents, Pos, Index) ->
    ElName = name_atom(Name),
    NewParents = Parents ++ [{ElName, Pos}],
    Text = #xmlText{parents = NewParents, pos = 1, value = leaf_text(Value)},
    El = xml_el(ElName, Parents, Pos, [Text]),
    {[El], Index#{Path => El}}.

xml_el(Name, Parents, Pos, Content) ->
    #xmlElement{name = Name,
                expanded_name = Name,
                parents = Parents,
                pos = Pos,
                content = Content,
                attributes = [],
                namespace = #xmlNamespace{}}.

name_atom(Name) when is_atom(Name) -> Name;
name_atom(Name) when is_list(Name) -> list_to_atom(Name).

leaf_text(true) -> "true";
leaf_text(false) -> "false";
leaf_text(I) when is_integer(I) -> integer_to_list(I);
leaf_text(B) when is_binary(B) -> binary_to_list(B);
leaf_text(L) when is_list(L) -> L;
leaf_text(T) when is_tuple(T), tuple_size(T) =:= 4 ->
    ntoa_text(T);
leaf_text(T) when is_tuple(T), tuple_size(T) =:= 8 ->
    ntoa_text(T);
leaf_text(Other) ->
    lists:flatten(io_lib:format("~p", [Other])).

ntoa_text(T) ->
    case inet:ntoa(T) of
        S when is_list(S) -> S;
        _ -> lists:flatten(io_lib:format("~p", [T]))
    end.

key_text(V) -> leaf_text(V).
