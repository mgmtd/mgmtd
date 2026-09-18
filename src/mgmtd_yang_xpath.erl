%% Evaluate YANG must/when/leafref/unique/mandatory/min-elements/
%% max-elements with OTP xmerl_xpath over an XML projection of the
%% transaction tree (RFC 7950 §6.4, §7.6.5, §7.7.5, §7.8.6, §10).
%%
%% xmerl does not dispatch custom functions. current() is rewritten to
%% an absolute path. RFC 7950 §10 functions are rewritten in the parsed
%% AST to literals/numbers/true()/false() (deref to a node-set, then
%% relative steps). Unprefixed XPath names match local-name XML.
-module(mgmtd_yang_xpath).

-export([validate_txn/1]).

-include("mgmtd_schema.hrl").
-include_lib("xmerl/include/xmerl.hrl").
-include_lib("xmerl/include/xmerl_xpath.hrl").

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
            Reverse = maps:fold(fun(P, E, Acc) -> Acc#{E => P} end, #{}, Index),
            ByPath = maps:from_list([{P, C} || #cfg{path = P} = C <- Rows]),
            Env = #{doc => Doc, index => Index, reverse => Reverse,
                    rows => Rows, by_path => ByPath},
            case check_rows(Rows, Env) of
                ok ->
                    case check_uniques(Rows) of
                        ok ->
                            check_cardinality(Env);
                        Error ->
                            Error
                    end;
                Error ->
                    Error
            end
    end.

has_constraints() ->
    case ets:info(mgmtd_commands) of
        undefined ->
            false;
        _ ->
            lists:any(fun schema_has_constraint/1, ets:tab2list(mgmtd_commands))
    end.

schema_has_constraint(#schema{opts = Opts, type = Type,
                              mandatory = Mand,
                              min_elements = Min,
                              max_elements = Max}) ->
    Mand =:= true
        orelse (is_integer(Min) andalso Min > 0)
        orelse (Max =/= unlimited)
        orelse lists:keymember(must, 1, Opts)
        orelse lists:keymember('when', 1, Opts)
        orelse lists:keymember(unique, 1, Opts)
        orelse is_ref_type(Type);
schema_has_constraint(_) ->
    false.

is_ref_type({leafref, _}) -> true;
is_ref_type({leafref, _, _}) -> true;
is_ref_type('instance-identifier') -> true;
is_ref_type({'instance-identifier', _}) -> true;
is_ref_type(_) -> false.

check_rows([], _Env) ->
    ok;
check_rows([#cfg{node_type = list} | Rest], Env) ->
    check_rows(Rest, Env);
check_rows([#cfg{path = Path} = Cfg | Rest], Env) ->
    case mgmtd_schema:lookup(Path) of
        #{} = Schema ->
            case check_opts(Cfg, Schema, Env) of
                ok ->
                    check_rows(Rest, Env);
                Error ->
                    Error
            end;
        _ ->
            check_rows(Rest, Env)
    end.

check_opts(#cfg{path = Path} = Cfg, #{opts := Opts} = Schema, Env) ->
    case proplists:get_value('when', Opts, undefined) of
        undefined ->
            after_when(Cfg, Schema, Env);
        WhenExpr ->
            case eval_bool(WhenExpr, Path, Env) of
                {ok, true} ->
                    after_when(Cfg, Schema, Env);
                {ok, false} ->
                    {error, {when_failed, Path, WhenExpr}};
                {error, _} = Err ->
                    Err
            end
    end.

after_when(Cfg, #{opts := Opts} = Schema, Env) ->
    case check_musts(Cfg#cfg.path, proplists:get_all_values(must, Opts), Env) of
        ok ->
            check_ref(Cfg, Schema, Env);
        Error ->
            Error
    end.

check_musts(_Path, [], _Env) ->
    ok;
check_musts(Path, [Must | Rest], Env) ->
    {Expr, Msg} = must_parts(Must),
    case eval_bool(Expr, Path, Env) of
        {ok, true} ->
            check_musts(Path, Rest, Env);
        {ok, false} ->
            {error, {must_failed, Path, Expr, Msg}};
        {error, _} = Err ->
            Err
    end.

must_parts(#{expr := Expr} = M) ->
    {Expr, maps:get(error_message, M, undefined)};
must_parts(Expr) when is_list(Expr) ->
    {Expr, undefined}.

check_ref(#cfg{path = Path, value = Val} = Cfg, Schema, Env) ->
    case maps:get(type, Schema, undefined) of
        {leafref, RefPath} ->
            check_leafref(Cfg, RefPath, true, Env);
        {leafref, RefPath, Require} ->
            check_leafref(Cfg, RefPath, Require, Env);
        'instance-identifier' ->
            check_iid(Path, Val, true, Env);
        {'instance-identifier', Require} ->
            check_iid(Path, Val, Require, Env);
        _ ->
            ok
    end.

check_leafref(_Cfg, _RefPath, false, _Env) ->
    ok;
check_leafref(#cfg{path = Path, value = Val}, RefPath, true, Env) ->
    #{index := Index, doc := Doc} = Env,
    case maps:find(Path, Index) of
        error ->
            ok;
        {ok, El} ->
            Ctx = xpath_context(El, Doc),
            Rewritten = rewrite_expr(RefPath, Path),
            case expr_nodeset(Rewritten, Ctx, Env) of
                {ok, NS} ->
                    Want = leaf_text(Val),
                    case lists:any(fun(N) -> node_string(N) =:= Want end, NS) of
                        true ->
                            ok;
                        false ->
                            {error, {leafref_failed, Path, RefPath, Val}}
                    end;
                {error, _} = Err ->
                    Err
            end
    end.

check_iid(_Path, _Val, false, _Env) ->
    ok;
check_iid(Path, Val, true, #{doc := Doc} = Env) ->
    Ctx = xpath_context_doc(Doc),
    Rewritten = strip_prefixes(leaf_text(Val), yang_prefix_names()),
    case expr_nodeset(Rewritten, Ctx, Env) of
        {ok, []} ->
            {error, {instance_identifier_failed, Path, Val}};
        {ok, _} ->
            ok;
        {error, _} = Err ->
            Err
    end.

check_uniques(Rows) ->
    case ets:info(mgmtd_commands) of
        undefined ->
            ok;
        _ ->
            check_unique_schemas(
              [S || S <- ets:tab2list(mgmtd_commands), is_unique_list(S)],
              Rows)
    end.

is_unique_list(#schema{node_type = list, opts = Opts}) ->
    lists:keymember(unique, 1, Opts);
is_unique_list(_) ->
    false.

check_unique_schemas([], _Rows) ->
    ok;
check_unique_schemas([#schema{path = {ListPath, _}, opts = Opts} | Rest], Rows) ->
    Uniques = proplists:get_value(unique, Opts, []),
    case check_unique_constraints(ListPath, Uniques, Rows) of
        ok ->
            check_unique_schemas(Rest, Rows);
        Error ->
            Error
    end.

check_unique_constraints(_ListPath, [], _Rows) ->
    ok;
check_unique_constraints(ListPath, [Descendants | Rest], Rows) ->
    Keys = [C || #cfg{node_type = list_key, path = P} = C <- Rows,
                 instance_schema_path(P) =:= ListPath],
    Groups = group_by_parent(Keys),
    case lists:any(fun(Entries) -> unique_dup(Entries, Descendants, Rows) end,
                   Groups) of
        true ->
            {error, {unique_failed, ListPath, Descendants}};
        false ->
            check_unique_constraints(ListPath, Rest, Rows)
    end.

group_by_parent(Keys) ->
    Map = lists:foldl(
            fun(#cfg{path = P} = C, Acc) ->
                    Parent = lists:droplast(P),
                    Acc#{Parent => [C | maps:get(Parent, Acc, [])]}
            end, #{}, Keys),
    maps:values(Map).

unique_dup(Entries, Descendants, Rows) ->
    {Seen, Dup} =
        lists:foldl(
          fun(#cfg{path = KeyPath}, {Acc, Found}) ->
                  case unique_tuple(KeyPath, Descendants, Rows) of
                      skip ->
                          {Acc, Found};
                      Tuple ->
                          case maps:is_key(Tuple, Acc) of
                              true -> {Acc, true};
                              false -> {Acc#{Tuple => true}, Found}
                          end
                  end
          end, {#{}, false}, Entries),
    _ = Seen,
    Dup.

unique_tuple(KeyPath, Descendants, Rows) ->
    unique_tuple(KeyPath, Descendants, Rows, []).

unique_tuple(_KeyPath, [], _Rows, Acc) ->
    list_to_tuple(lists:reverse(Acc));
unique_tuple(KeyPath, [Desc | Rest], Rows, Acc) ->
    LeafPath = KeyPath ++ descendant_path(Desc),
    case lists:keyfind(LeafPath, #cfg.path, Rows) of
        #cfg{value = Val} ->
            unique_tuple(KeyPath, Rest, Rows, [Val | Acc]);
        false ->
            skip
    end.

descendant_path(Desc) ->
    [local_step(S) || S <- string:tokens(Desc, "/")].

local_step(Id) ->
    case string:split(Id, ":") of
        [_Pfx, Name] -> Name;
        [Name] -> Name
    end.

instance_schema_path([]) ->
    [];
instance_schema_path([H | T]) when is_tuple(H) ->
    instance_schema_path(T);
instance_schema_path([H | T]) ->
    [H | instance_schema_path(T)].

%%--------------------------------------------------------------------
%% mandatory / min-elements / max-elements (RFC 7950 §7.6.5, §7.7.5, §7.8.6)
%%
%% Enforced when the parent is present (module root is always present).
%% `when` false → not applicable. Flattened choice: only if that case
%% is selected. config=false is skipped (not in the config datastore).
%%--------------------------------------------------------------------

check_cardinality(Env) ->
    check_level([], Env).

check_level(InstPath, Env) ->
    check_nodes(mgmtd_schema:children(InstPath, show), InstPath, Env).

check_nodes([], _Parent, _Env) ->
    ok;
check_nodes([Schema | Rest], Parent, Env) ->
    case check_node(Schema, Parent, Env) of
        ok ->
            check_nodes(Rest, Parent, Env);
        Error ->
            Error
    end.

check_node(#{config := false}, _Parent, _Env) ->
    ok;
check_node(#{name := Name} = Schema, Parent, Env) ->
    Path = Parent ++ [Name],
    case when_applies(Schema, Path, Env) of
        {ok, false} ->
            ok;
        {ok, true} ->
            case case_applies(Schema, Parent, Env) of
                false ->
                    ok;
                true ->
                    check_node1(Schema, Path, Env)
            end;
        {error, _} = Err ->
            Err
    end;
check_node(_, _Parent, _Env) ->
    ok.

when_applies(#{opts := Opts}, Path, Env) when is_list(Opts) ->
    case proplists:get_value('when', Opts, undefined) of
        undefined ->
            {ok, true};
        Expr ->
            eval_when(Expr, Path, Env)
    end;
when_applies(_, _Path, _Env) ->
    {ok, true}.

%% A flattened choice node is only required if its case is selected
%% (some node from that case exists). Choice-level mandatory is the
%% exclusive-case gap, not this pass.
case_applies(#{opts := Opts}, Parent, Env) when is_list(Opts) ->
    case proplists:get_value(choice, Opts, undefined) of
        undefined ->
            true;
        Choice ->
            Case = proplists:get_value('case', Opts),
            lists:any(
              fun(Sib) ->
                      same_choice_case(Sib, Choice, Case)
                          andalso sibling_present(Sib, Parent, Env)
              end, mgmtd_schema:children(Parent, show))
    end;
case_applies(_, _Parent, _Env) ->
    true.

same_choice_case(#{opts := Opts}, Choice, Case) when is_list(Opts) ->
    proplists:get_value(choice, Opts, undefined) =:= Choice
        andalso proplists:get_value('case', Opts, undefined) =:= Case;
same_choice_case(_, _Choice, _Case) ->
    false.

sibling_present(#{name := Name, node_type := Type} = Schema, Parent, Env) ->
    node_present(Type, Schema, Parent ++ [Name], Env);
sibling_present(_, _Parent, _Env) ->
    false.

check_node1(#{node_type := leaf, mandatory := true}, Path, Env) ->
    case node_present(leaf, #{}, Path, Env) of
        true ->
            ok;
        false ->
            {error, {mandatory_failed, Path}}
    end;
check_node1(#{node_type := leaf}, _Path, _Env) ->
    ok;
check_node1(#{node_type := leaf_list} = Schema, Path, Env) ->
    check_count(Path, leaf_list_count(Path, Env), min_of(Schema), max_of(Schema));
check_node1(#{node_type := list} = Schema, Path, Env) ->
    Keys = list_instance_keys(Path, Env),
    case check_count(Path, length(Keys), min_of(Schema), max_of(Schema)) of
        ok ->
            check_list_instances(Path, Keys, Env);
        Error ->
            Error
    end;
check_node1(#{node_type := container, mandatory := true} = Schema, Path, Env) ->
    case node_present(container, Schema, Path, Env) of
        false ->
            {error, {mandatory_failed, Path}};
        true ->
            check_level(Path, Env)
    end;
check_node1(#{node_type := container} = Schema, Path, Env) ->
    case node_present(container, Schema, Path, Env) of
        true ->
            check_level(Path, Env);
        false ->
            ok
    end;
check_node1(_, _Path, _Env) ->
    ok.

check_list_instances(_Path, [], _Env) ->
    ok;
check_list_instances(Path, [Key | Rest], Env) ->
    case check_level(Path ++ [Key], Env) of
        ok ->
            check_list_instances(Path, Rest, Env);
        Error ->
            Error
    end.

check_count(Path, Count, Min, Max) ->
    if Count < Min ->
            {error, {min_elements_failed, Path, Min, Count}};
       Max =/= unlimited andalso Count > Max ->
            {error, {max_elements_failed, Path, Max, Count}};
       true ->
            ok
    end.

min_of(#{node_type := leaf_list, mandatory := true, min_elements := Min})
  when is_integer(Min), Min < 1 ->
    1;
min_of(#{min_elements := Min}) when is_integer(Min) ->
    Min;
min_of(_) ->
    0.

max_of(#{max_elements := Max}) ->
    Max;
max_of(_) ->
    unlimited.

node_present(leaf, _Schema, Path, #{by_path := ByPath}) ->
    maps:is_key(Path, ByPath);
node_present(leaf_list, _Schema, Path, Env) ->
    leaf_list_count(Path, Env) > 0;
node_present(list, _Schema, Path, Env) ->
    list_instance_keys(Path, Env) =/= [];
node_present(container, Schema, Path, Env) ->
    is_module_root(Schema)
        orelse maps:is_key(Path, maps:get(by_path, Env))
        orelse has_descendant(Path, maps:get(rows, Env));
node_present(_, _Schema, Path, #{by_path := ByPath}) ->
    maps:is_key(Path, ByPath).

is_module_root(#{node_type := container, path := [Name], ns := Ns})
  when Ns =/= default ->
    atom_to_list(Ns) =:= Name;
is_module_root(_) ->
    false.

has_descendant(Path, Rows) ->
    lists:any(fun(#cfg{path = P}) ->
                      P =/= Path andalso lists:prefix(Path, P)
              end, Rows).

leaf_list_count(Path, #{by_path := ByPath}) ->
    case maps:find(Path, ByPath) of
        {ok, #cfg{value = Vals}} when is_list(Vals) ->
            length(Vals);
        {ok, _} ->
            1;
        error ->
            0
    end.

list_instance_keys(ListPath, #{rows := Rows}) ->
    Len = length(ListPath),
    [lists:last(P) || #cfg{node_type = list_key, path = P} <- Rows,
                      length(P) =:= Len + 1,
                      lists:prefix(ListPath, P),
                      is_tuple(lists:last(P))].

eval_when(Expr, Path, #{index := Index} = Env) ->
    case maps:is_key(Path, Index) of
        true ->
            eval_bool(Expr, Path, Env);
        false ->
            eval_bool_synthetic(Expr, Path, Env)
    end.

eval_bool_synthetic(Expr, Path, Env) ->
    Rewritten = rewrite_expr(Expr, Path),
    try
        Tokens = xmerl_xpath_scan:tokens(Rewritten),
        {ok, Parsed} = xmerl_xpath_parse:parse(Tokens),
        Ctx = synthetic_context(Path, Env),
        Ast1 = collapse_ns(rewrite_ast(Parsed, Ctx, Env)),
        {ok, xmerl_xpath_pred:eval(Ast1, Ctx)}
    catch
        exit:Reason ->
            {error, {xpath_error, Path, Expr, Reason}};
        error:Reason ->
            {error, {xpath_error, Path, Expr, Reason}}
    end.

synthetic_context(Path, #{index := Index, doc := Doc}) ->
    Name = name_atom(lists:last(Path)),
    Parent = lists:droplast(Path),
    Dummy =
        case maps:find(Parent, Index) of
            {ok, #xmlElement{name = PName, pos = PPos, parents = PParents}} ->
                xml_el(Name, PParents ++ [{PName, PPos}], 1, []);
            error ->
                xml_el(Name, [], 1, [])
        end,
    xpath_context(Dummy, Doc).

eval_bool(Expr, Path, #{index := Index, doc := Doc} = Env) ->
    case maps:find(Path, Index) of
        error ->
            {ok, true};
        {ok, ContextEl} ->
            Rewritten = rewrite_expr(Expr, Path),
            try
                Tokens = xmerl_xpath_scan:tokens(Rewritten),
                {ok, Parsed} = xmerl_xpath_parse:parse(Tokens),
                Ctx = xpath_context(ContextEl, Doc),
                Ast1 = collapse_ns(rewrite_ast(Parsed, Ctx, Env)),
                {ok, xmerl_xpath_pred:eval(Ast1, Ctx)}
            catch
                exit:Reason ->
                    {error, {xpath_error, Path, Expr, Reason}};
                error:Reason ->
                    {error, {xpath_error, Path, Expr, Reason}}
            end
    end.

expr_nodeset(Expr, Ctx, Env) ->
    try
        Tokens = xmerl_xpath_scan:tokens(Expr),
        {ok, Parsed} = xmerl_xpath_parse:parse(Tokens),
        {ok, ast_nodeset(rewrite_ast(Parsed, Ctx, Env), Ctx, Env)}
    catch
        exit:Reason ->
            {error, {xpath_error, Expr, Reason}};
        error:Reason ->
            {error, {xpath_error, Expr, Reason}}
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

xpath_context_doc(Doc) ->
    Whole = #xmlNode{type = root_node, node = Doc, parents = []},
    #xmlContext{context_node = Whole,
                nodeset = [Whole],
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
%% RFC 7950 §10 functions (rewritten in the parsed AST)
%%--------------------------------------------------------------------

yang_fun('re-match') -> true;
yang_fun(deref) -> true;
yang_fun('derived-from') -> true;
yang_fun('derived-from-or-self') -> true;
yang_fun('enum-value') -> true;
yang_fun('bit-is-set') -> true;
yang_fun(_) -> false.

rewrite_ast({function_call, F, Args}, Ctx, Env) ->
    Args1 = [rewrite_ast(A, Ctx, Env) || A <- Args],
    case yang_fun(F) of
        true ->
            eval_yang_fun(F, Args1, Ctx, Env);
        false ->
            {function_call, F, Args1}
    end;
rewrite_ast({refine, Left, Step}, Ctx, Env) ->
    case rewrite_ast(Left, Ctx, Env) of
        {yang_nodeset, NS} ->
            {yang_nodeset, apply_rel_step(NS, Step, Ctx)};
        Left1 ->
            {refine, Left1, Step}
    end;
rewrite_ast({comp, Op, A, B}, Ctx, Env) ->
    {comp, Op,
     collapse_ns(rewrite_ast(A, Ctx, Env)),
     collapse_ns(rewrite_ast(B, Ctx, Env))};
rewrite_ast({bool, Op, A, B}, Ctx, Env) ->
    {bool, Op,
     collapse_ns(rewrite_ast(A, Ctx, Env)),
     collapse_ns(rewrite_ast(B, Ctx, Env))};
rewrite_ast({arith, Op, A, B}, Ctx, Env) ->
    {arith, Op,
     collapse_ns(rewrite_ast(A, Ctx, Env)),
     collapse_ns(rewrite_ast(B, Ctx, Env))};
rewrite_ast({path, Type, PE}, Ctx, Env) ->
    {path, Type, rewrite_ast(PE, Ctx, Env)};
rewrite_ast({negative, A}, Ctx, Env) ->
    {negative, collapse_ns(rewrite_ast(A, Ctx, Env))};
rewrite_ast({pred, E}, Ctx, Env) ->
    {pred, rewrite_ast(E, Ctx, Env)};
rewrite_ast(Other, _Ctx, _Env) ->
    Other.

collapse_ns({yang_nodeset, NS}) ->
    {literal, nodeset_string(NS)};
collapse_ns(Other) ->
    Other.

eval_yang_fun('re-match', [Subject, Pattern], Ctx, _Env) ->
    S = arg_string(Subject, Ctx),
    P = arg_string(Pattern, Ctx),
    bool_ast(re_match(S, P));
eval_yang_fun(deref, [Arg], Ctx, Env) ->
    NS = arg_nodeset(Arg, Ctx, Env),
    {yang_nodeset, deref_nodes(NS, Ctx, Env)};
eval_yang_fun('derived-from', [Arg, Ident], Ctx, _Env) ->
    Name = arg_string(Arg, Ctx),
    Base = arg_string(Ident, Ctx),
    bool_ast(derived_from(Name, Base, false));
eval_yang_fun('derived-from-or-self', [Arg, Ident], Ctx, _Env) ->
    Name = arg_string(Arg, Ctx),
    Base = arg_string(Ident, Ctx),
    bool_ast(derived_from(Name, Base, true));
eval_yang_fun('enum-value', [Arg], Ctx, Env) ->
    {number, enum_value(Arg, Ctx, Env)};
eval_yang_fun('bit-is-set', [Arg, Bit], Ctx, _Env) ->
    S = arg_string(Arg, Ctx),
    B = arg_string(Bit, Ctx),
    bool_ast(lists:member(B, string:tokens(S, " \t")));
eval_yang_fun(_, _, _, _) ->
    bool_ast(false).

bool_ast(true) -> {function_call, true, []};
bool_ast(false) -> {function_call, false, []}.

re_match(Subject, Pattern) ->
    Re = "^(?:" ++ Pattern ++ ")$",
    try re:run(Subject, Re, [{capture, none}]) of
        match -> true;
        nomatch -> false
    catch
        error:_ -> false
    end.

derived_from(Name, Base, true) ->
    mgmtd_schema:identity_derived_from(Name, Base);
derived_from(Name, Base, false) ->
    mgmtd_schema:identity_derived_from(Name, Base)
        andalso not mgmtd_schema:identity_derived_from(Base, Name).

enum_value(Arg, Ctx, Env) ->
    NS = arg_nodeset(Arg, Ctx, Env),
    case NS of
        [N | _] ->
            Str = node_string(N),
            case path_of_node(N, Env) of
                {ok, Path} ->
                    case mgmtd_schema:lookup(Path) of
                        #{type := {enum, Members}} ->
                            enum_int(Str, Members);
                        #{type := {enumeration, Members}} ->
                            enum_int(Str, Members);
                        _ ->
                            nan
                    end;
                error ->
                    nan
            end;
        [] ->
            nan
    end.

enum_int(Name, Members) ->
    enum_int(Name, Members, 0).

enum_int(Name, [M | Rest], I) ->
    case enum_member_name(M) of
        Name ->
            case M of
                #{value := V} -> V;
                _ -> I
            end;
        _ ->
            Next = case M of
                       #{value := V} -> V + 1;
                       _ -> I + 1
                   end,
            enum_int(Name, Rest, Next)
    end;
enum_int(_, [], _) ->
    nan.

enum_member_name(#{name := Name}) -> Name;
enum_member_name({Name, _Desc}) -> Name;
enum_member_name(Name) when is_list(Name) -> Name.

deref_nodes(NS, Ctx, Env) ->
    lists:append([deref_one(N, Ctx, Env) || N <- NS]).

deref_one(N, Ctx, Env) ->
    case path_of_node(N, Env) of
        {ok, Path} ->
            case mgmtd_schema:lookup(Path) of
                #{type := {leafref, RefPath}} ->
                    deref_leafref(N, Path, RefPath, Ctx, Env);
                #{type := {leafref, RefPath, _}} ->
                    deref_leafref(N, Path, RefPath, Ctx, Env);
                #{type := 'instance-identifier'} ->
                    deref_iid(N, Ctx, Env);
                #{type := {'instance-identifier', _}} ->
                    deref_iid(N, Ctx, Env);
                _ ->
                    []
            end;
        error ->
            []
    end.

deref_leafref(N, Path, RefPath, _Ctx, #{doc := Doc} = Env) ->
    El = node_el(N),
    Ctx1 = xpath_context(El, Doc),
    Rewritten = rewrite_expr(RefPath, Path),
    Want = node_string(N),
    case expr_nodeset(Rewritten, Ctx1, Env) of
        {ok, Targets} ->
            [T || T <- Targets, node_string(T) =:= Want];
        {error, _} ->
            []
    end.

deref_iid(N, Ctx, Env) ->
    case expr_nodeset(strip_prefixes(node_string(N), yang_prefix_names()),
                      Ctx#xmlContext{context_node = Ctx#xmlContext.whole_document},
                      Env) of
        {ok, NS} -> NS;
        {error, _} -> []
    end.

arg_string({yang_nodeset, NS}, _Ctx) ->
    nodeset_string(NS);
arg_string({literal, S}, _Ctx) ->
    S;
arg_string({number, N}, _Ctx) when is_integer(N) ->
    integer_to_list(N);
arg_string({number, N}, _Ctx) when is_float(N) ->
    lists:flatten(io_lib:format("~p", [N]));
arg_string({function_call, true, []}, _Ctx) ->
    "true";
arg_string({function_call, false, []}, _Ctx) ->
    "false";
arg_string(Expr, Ctx) ->
    case xmerl_xpath_pred:string(Ctx, [Expr]) of
        #xmlObj{value = V} when is_list(V) -> V;
        #xmlObj{value = V} -> lists:flatten(io_lib:format("~p", [V]))
    end.

arg_nodeset({yang_nodeset, NS}, _Ctx, _Env) ->
    NS;
arg_nodeset({path, Type, PE}, Ctx, _Env) ->
    path_nodeset(Type, PE, Ctx);
arg_nodeset({function_call, current, []}, Ctx, _Env) ->
    [Ctx#xmlContext.context_node];
arg_nodeset({refine, _, _} = R, Ctx, Env) ->
    ast_nodeset(rewrite_ast(R, Ctx, Env), Ctx, Env);
arg_nodeset(Other, Ctx, Env) ->
    ast_nodeset(Other, Ctx, Env).

ast_nodeset({yang_nodeset, NS}, _Ctx, _Env) ->
    NS;
ast_nodeset({path, Type, PE}, Ctx, _Env) ->
    path_nodeset(Type, PE, Ctx);
ast_nodeset({refine, Left, Step}, Ctx, Env) ->
    apply_rel_step(ast_nodeset(Left, Ctx, Env), Step, Ctx);
ast_nodeset(_, _Ctx, _Env) ->
    [].

path_nodeset(Type, PE, Ctx) ->
    #state{context = C1} = xmerl_xpath:eval_path(Type, PE, Ctx),
    C1#xmlContext.nodeset.

apply_rel_step(NS, Step, Ctx) ->
    lists:append(
      [begin
           C1 = Ctx#xmlContext{context_node = Node, nodeset = [Node]},
           #state{context = C2} = xmerl_xpath:eval_path(rel, Step, C1),
           C2#xmlContext.nodeset
       end || Node <- NS]).

path_of_node(N, #{reverse := Reverse}) ->
    maps:find(node_el(N), Reverse).

node_el(#xmlNode{node = El}) -> El;
node_el(#xmlElement{} = El) -> El;
node_el(Other) -> Other.

nodeset_string([]) -> "";
nodeset_string([N | _]) -> node_string(N).

node_string(#xmlNode{node = El}) ->
    node_string(El);
node_string(#xmlElement{content = C}) ->
    lists:flatten([V || #xmlText{value = V} <- flatten_content(C)]);
node_string(#xmlText{value = V}) ->
    V;
node_string(_) ->
    "".

flatten_content(C) when is_list(C) ->
    lists:flatten(
      [case X of
           #xmlElement{content = Inner} -> flatten_content(Inner);
           #xmlText{} = T -> [T];
           _ -> []
       end || X <- C]);
flatten_content(C) ->
    flatten_content([C]).

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
%%
%% Schema defaults are injected into the accessible tree (RFC 7950
%% §7.6.1 / §11) so `when`/`must` see them. They are not persisted.
%%--------------------------------------------------------------------

project_xml(Rows) ->
    Rows1 = Rows ++ default_rows(Rows),
    {Content, Index, _} = emit_children([], Rows1, [], 1, #{}),
    {#xmlDocument{content = Content}, Index}.

default_rows(Rows) ->
    ByPath = maps:from_list([{P, true} || #cfg{path = P} <- Rows]),
    Parents = lists:usort(
                [[] | [P || #cfg{path = P, node_type = T} <- Rows,
                            T =:= container orelse T =:= list_key]]),
    lists:append([defaults_at(P, ByPath) || P <- Parents]).

defaults_at(Parent, ByPath) ->
    Kids = try mgmtd_schema:children(Parent, show) of
               Cs when is_list(Cs) -> Cs
           catch
               _:_ -> []
           end,
    lists:append([maybe_default_cfg(Parent, K, ByPath) || K <- Kids]).

maybe_default_cfg(_Parent, #{config := false}, _ByPath) ->
    [];
maybe_default_cfg(Parent, #{node_type := Leaf, name := Name} = Schema, ByPath)
  when Leaf =:= leaf; Leaf =:= leaf_list ->
    Default = maps:get(default, Schema, undefined),
    Path = Parent ++ [Name],
    case Default =:= undefined orelse maps:is_key(Path, ByPath) of
        true ->
            [];
        false ->
            [#cfg{path = Path, name = Name, node_type = Leaf, value = Default}]
    end;
maybe_default_cfg(_, _, _) ->
    [].

child_rows(Parent, Rows) ->
    Len = length(Parent),
    [C || #cfg{path = P} = C <- Rows,
          length(P) =:= Len + 1,
          lists:prefix(Parent, P)].

emit_children(Parent, Rows, Parents, Pos, Index) ->
    emit_kids(child_rows(Parent, Rows), Rows, Parents, Pos, Index).

emit_kids([], _Rows, _Parents, Pos, Index) ->
    {[], Index, Pos};
emit_kids([#cfg{node_type = list, name = Name, path = Path, value = Val} | Rest],
          Rows, Parents, Pos, Index) ->
    Keys0 = [C || #cfg{node_type = list_key, path = P} = C <- Rows,
                  length(P) =:= length(Path) + 1,
                  lists:prefix(Path, P)],
    Keys = order_key_rows(Val, Keys0),
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

order_key_rows({ordered, Order}, KeyRows) ->
    ByKey = maps:from_list([{lists:last(P), C} || #cfg{path = P} = C <- KeyRows]),
    Ordered = [maps:get(K, ByKey) || K <- Order, maps:is_key(K, ByKey)],
    Extra = [C || #cfg{path = P} = C <- KeyRows,
                  not lists:member(lists:last(P), Order)],
    Ordered ++ Extra;
order_key_rows(_, KeyRows) ->
    KeyRows.

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

emit_leaf(Name, Path, empty, Parents, Pos, Index) ->
    ElName = name_atom(Name),
    El = xml_el(ElName, Parents, Pos, []),
    {[El], Index#{Path => El}};
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
leaf_text(empty) -> "";
leaf_text(I) when is_integer(I) -> integer_to_list(I);
leaf_text(B) when is_binary(B) -> binary_to_list(B);
leaf_text([H | _] = Bits) when is_list(H) -> string:join(Bits, " ");
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
