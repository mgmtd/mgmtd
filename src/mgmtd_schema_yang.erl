%% Load RFC 7950 YANG modules into mgmtd schema ETS.
%%
%% PR 1 subset: self-contained modules (container/list/leaf/leaf-list,
%% builtin types, range, enumeration, same-module typedefs). import,
%% grouping/uses, augment, identity, and choice are later slices.
-module(mgmtd_schema_yang).

-export([load_file/1, load_file/2]).
-export([compile_file/1, compile_file/2]).
-export([compile/1, compile/2]).

-include("../include/mgmtd.hrl").
-include("mgmtd_schema.hrl").

-type compile_result() :: #{module := string(),
                            prefix := atom(),
                            namespace := string(),
                            yang_version := binary() | atom(),
                            nodes := [#container{} | #list{} | #leaf{} | #leaf_list{}]}.

-spec load_file(file:filename()) -> ok | {error, term()}.
load_file(File) ->
    load_file(File, #{}).

-spec load_file(file:filename(), map()) -> ok | {error, term()}.
load_file(File, Opts) when is_map(Opts) ->
    case compile_file(File, Opts) of
        {ok, Compiled} ->
            load_compiled(Compiled, Opts);
        Error ->
            Error
    end.

-spec compile_file(file:filename()) -> {ok, compile_result()} | {error, term()}.
compile_file(File) ->
    compile_file(File, #{}).

-spec compile_file(file:filename(), map()) ->
          {ok, compile_result()} | {error, term()}.
compile_file(File, Opts) ->
    case mgmtd_yang_parse:file(File, scan_opts(Opts)) of
        {ok, Stmts} ->
            compile(Stmts, Opts);
        Error ->
            Error
    end.

-spec compile([mgmtd_yang_parse:stmt()]) ->
          {ok, compile_result()} | {error, term()}.
compile(Stmts) ->
    compile(Stmts, #{}).

-spec compile([mgmtd_yang_parse:stmt()], map()) ->
          {ok, compile_result()} | {error, term()}.
compile([{module, _Ln, Name0, Body}], Opts) ->
    Name = arg_str(Name0),
    case header(Body) of
        {error, _} = Err ->
            Err;
        {ok, Header} ->
            PrefixAtom = maps:get(prefix, Opts, maps:get(prefix, Header)),
            NsUri = case maps:get(namespace, Opts, undefined) of
                        undefined -> maps:get(namespace, Header);
                        Override -> Override
                    end,
            Typedefs = collect_typedefs(Body),
            Ctx = #{typedefs => Typedefs,
                    parent_config => true,
                    module => Name},
            case data_nodes(Body, Ctx) of
                {error, _} = Err ->
                    Err;
                {ok, Nodes} ->
                    {ok, #{module => Name,
                           prefix => PrefixAtom,
                           namespace => NsUri,
                           yang_version => maps:get(yang_version, Header, <<"1">>),
                           nodes => Nodes}}
            end
    end;
compile([{submodule, Ln, Name, _Body}], _Opts) ->
    {error, {Ln, submodule_not_supported, arg_str(Name)}};
compile([], _Opts) ->
    {error, empty_yang_module};
compile([Other | _], _Opts) ->
    {error, {expected_module, Other}}.

scan_opts(Opts) ->
    case maps:get(open_hook, Opts, undefined) of
        undefined -> [];
        Hook -> [{open_hook, Hook}]
    end.

header(Body) ->
    case {find_arg(namespace, Body), find_arg(prefix, Body)} of
        {undefined, _} ->
            {error, missing_namespace};
        {_, undefined} ->
            {error, missing_prefix};
        {Ns, Prefix0} ->
            PrefixAtom = prefix_atom(Prefix0),
            Ver = case find_arg('yang-version', Body) of
                      undefined -> <<"1">>;
                      V -> arg_bin(V)
                  end,
            {ok, #{namespace => arg_str(Ns),
                   prefix => PrefixAtom,
                   yang_version => Ver}}
    end.

load_compiled(#{prefix := Prefix, namespace := NsUri, nodes := Nodes}, Opts) ->
    LoadOpts = Opts#{prefix => Prefix, namespace => NsUri},
    TopNames = [node_name(N) || N <- Nodes],
    case mgmtd_schema:prepare_load(LoadOpts, yang, TopNames) of
        {ok, Prefix1, Namespace} ->
            Callback = maps:get(callback, Opts, undefined),
            ok = mgmtd_schema_function:load_resolved(Prefix1, Nodes, Callback),
            mgmtd_schema:register_schema(Prefix1, Namespace, yang);
        {error, _} = Err ->
            Err
    end.

%%--------------------------------------------------------------------
%% Body walk
%%--------------------------------------------------------------------

data_nodes(Body, Ctx) ->
    data_nodes(Body, Ctx, []).

data_nodes([], _Ctx, Acc) ->
    {ok, lists:reverse(Acc)};
data_nodes([{uses, Ln, Arg, _} | _], _Ctx, _Acc) ->
    {error, {Ln, unsupported_statement, uses, arg_str(Arg)}};
data_nodes([{augment, Ln, Arg, _} | _], _Ctx, _Acc) ->
    {error, {Ln, unsupported_statement, augment, arg_str(Arg)}};
data_nodes([{choice, Ln, Arg, _} | _], _Ctx, _Acc) ->
    {error, {Ln, unsupported_statement, choice, arg_str(Arg)}};
data_nodes([{Stmt, Ln, Arg, Sub} | Rest], Ctx, Acc)
  when Stmt =:= container; Stmt =:= list; Stmt =:= leaf; Stmt =:= 'leaf-list' ->
    case compile_node(Stmt, Ln, Arg, Sub, Ctx) of
        {ok, Node} ->
            data_nodes(Rest, Ctx, [Node | Acc]);
        {skip, _} ->
            data_nodes(Rest, Ctx, Acc);
        Error ->
            Error
    end;
data_nodes([_Other | Rest], Ctx, Acc) ->
    data_nodes(Rest, Ctx, Acc).

compile_node(container, _Ln, Arg, Sub, Ctx) ->
    case node_config(Sub, Ctx) of
        skip ->
            {skip, config};
        Config ->
            ChildCtx = Ctx#{parent_config => Config},
            case data_nodes(Sub, ChildCtx) of
                {ok, Children} ->
                    {ok, #container{name = arg_str(Arg),
                                    desc = find_desc(Sub),
                                    config = Config,
                                    children = fun() -> Children end,
                                    opts = node_opts(Sub)}};
                Error ->
                    Error
            end
    end;
compile_node(list, Ln, Arg, Sub, Ctx) ->
    case node_config(Sub, Ctx) of
        skip ->
            {skip, config};
        Config ->
            ChildCtx = Ctx#{parent_config => Config},
            case data_nodes(Sub, ChildCtx) of
                {ok, Children} ->
                    Keys = key_names(Sub),
                    case Keys of
                        [] ->
                            {error, {Ln, missing_key, arg_str(Arg)}};
                        _ ->
                            {ok, #list{name = arg_str(Arg),
                                       desc = find_desc(Sub),
                                       key_names = Keys,
                                       min_elements = min_elements(Sub),
                                       max_elements = max_elements(Sub),
                                       config = Config,
                                       children = fun() -> Children end,
                                       opts = node_opts(Sub)}}
                    end;
                Error ->
                    Error
            end
    end;
compile_node(leaf, Ln, Arg, Sub, Ctx) ->
    case node_config(Sub, Ctx) of
        skip ->
            {skip, config};
        Config ->
            case compile_type(Sub, Ctx) of
                {ok, Type} ->
                    Default = compile_default(Sub, Type),
                    {ok, #leaf{name = arg_str(Arg),
                               type = Type,
                               desc = find_desc(Sub),
                               default = Default,
                               mandatory = is_true(find_arg(mandatory, Sub)),
                               config = Config,
                               opts = node_opts(Sub)}};
                Error ->
                    prepend_error(Error, Ln, Arg)
            end
    end;
compile_node('leaf-list', Ln, Arg, Sub, Ctx) ->
    case node_config(Sub, Ctx) of
        skip ->
            {skip, config};
        Config ->
            case compile_type(Sub, Ctx) of
                {ok, Type} ->
                    {ok, #leaf_list{name = arg_str(Arg),
                                    type = Type,
                                    desc = find_desc(Sub),
                                    config = Config,
                                    min_elements = min_elements(Sub),
                                    max_elements = max_elements(Sub),
                                    opts = node_opts(Sub)}};
                Error ->
                    prepend_error(Error, Ln, Arg)
            end
    end.

prepend_error({error, Reason}, Ln, Arg) ->
    {error, {Ln, arg_str(Arg), Reason}}.

%%--------------------------------------------------------------------
%% Config, keys, cardinality
%%--------------------------------------------------------------------

%% if-feature is ignored until feature support lands; config false is kept.
node_config(Sub, Ctx) ->
    Parent = maps:get(parent_config, Ctx),
    case find_arg(config, Sub) of
        true -> true;
        false -> false;
        undefined -> Parent
    end.

key_names(Sub) ->
    case find_arg(key, Sub) of
        undefined -> [];
        Arg -> string:tokens(arg_str(Arg), " \t")
    end.

min_elements(Sub) ->
    case find_arg('min-elements', Sub) of
        undefined -> 0;
        N -> arg_int(N)
    end.

max_elements(Sub) ->
    case find_arg('max-elements', Sub) of
        undefined -> unlimited;
        unbounded -> unlimited;
        N -> arg_int(N)
    end.

%%--------------------------------------------------------------------
%% Types
%%--------------------------------------------------------------------

compile_type(Sub, Ctx) ->
    case lists:keyfind(type, 1, Sub) of
        {type, Ln, Arg, TypeSub} ->
            resolve_type(arg_bin(Arg), TypeSub, Ln, Ctx, []);
        false ->
            {error, missing_type}
    end.

resolve_type(Name, Sub, Ln, Ctx, Seen) ->
    case builtin_type(Name, Sub) of
        {ok, _} = Ok ->
            Ok;
        unknown ->
            case lists:member(Name, Seen) of
                true ->
                    {error, {Ln, circular_typedef, Name}};
                false ->
                    Typedefs = maps:get(typedefs, Ctx),
                    case maps:find(Name, Typedefs) of
                        {ok, {BaseName, BaseSub}} ->
                            resolve_type(BaseName, merge_type_sub(BaseSub, Sub),
                                         Ln, Ctx, [Name | Seen]);
                        error ->
                            {error, {Ln, unknown_type, arg_str(Name)}}
                    end
            end
    end.

builtin_type(<<"binary">>, _Sub) -> {ok, string};
builtin_type(<<"bits">>, Sub) -> {ok, {bits, bit_names(Sub)}};
builtin_type(<<"boolean">>, _) -> {ok, boolean};
builtin_type(<<"decimal64">>, _) -> {ok, decimal64};
builtin_type(<<"empty">>, _) -> {ok, empty};
builtin_type(<<"enumeration">>, Sub) -> {ok, {enum, enums(Sub)}};
builtin_type(<<"identityref">>, Sub) ->
    {ok, {identityref, arg_str(find_arg(base, Sub))}};
builtin_type(<<"instance-identifier">>, _) -> {ok, string};
builtin_type(<<"int8">>, Sub) -> int_type(int8, Sub);
builtin_type(<<"int16">>, Sub) -> int_type(int16, Sub);
builtin_type(<<"int32">>, Sub) -> int_type(int32, Sub);
builtin_type(<<"int64">>, Sub) -> int_type(int64, Sub);
builtin_type(<<"uint8">>, Sub) -> int_type(uint8, Sub);
builtin_type(<<"uint16">>, Sub) -> int_type(uint16, Sub);
builtin_type(<<"uint32">>, Sub) -> int_type(uint32, Sub);
builtin_type(<<"uint64">>, Sub) -> int_type(uint64, Sub);
builtin_type(<<"leafref">>, Sub) ->
    {ok, {leafref, arg_str(find_arg(path, Sub))}};
builtin_type(<<"string">>, _Sub) ->
    {ok, string};
builtin_type(<<"union">>, Sub) ->
    {ok, {union, [T || {type, _, T, _} <- Sub]}};
builtin_type(<<"inet:ip-address">>, _) -> {ok, 'inet:ip-address'};
builtin_type(<<"inet:ipv4-address">>, _) -> {ok, 'inet:ip-address'};
builtin_type(<<"inet:ipv6-address">>, _) -> {ok, 'inet:ip-address'};
builtin_type(<<"inet:port-number">>, _) -> {ok, 'inet:port-number'};
builtin_type(_, _) -> unknown.

int_type(Type, Sub) ->
    case parse_range(find_arg(range, Sub)) of
        undefined -> {ok, Type};
        Range -> {ok, {Type, Range}}
    end.

enums(Sub) ->
    lists:filtermap(
      fun({enum, _Ln, Name, EnumSub}) ->
              Member = #{name => arg_str(Name),
                         desc => find_desc(EnumSub)},
              Member1 = case find_arg(value, EnumSub) of
                            undefined -> Member;
                            V -> Member#{value => arg_int(V)}
                        end,
              {true, Member1};
         (_) ->
              false
      end, Sub).

bit_names(Sub) ->
    [arg_str(N) || {bit, _, N, _} <- Sub].

parse_range(undefined) ->
    undefined;
parse_range(Arg) ->
    Text = arg_str(Arg),
    Parts = [string:trim(P) || P <- string:tokens(Text, "|")],
    Bounds = [range_part(P) || P <- Parts],
    Mins = [Min || {Min, _} <- Bounds, is_integer(Min)],
    Maxs = [Max || {_, Max} <- Bounds, is_integer(Max)],
    Range = [],
    Range1 = case Mins of
                 [] -> Range;
                 _ -> [{min, lists:min(Mins)} | Range]
             end,
    Range2 = case Maxs of
                 [] -> Range1;
                 _ -> Range1 ++ [{max, lists:max(Maxs)}]
             end,
    case Range2 of
        [] -> undefined;
        _ -> Range2
    end.

range_part("min" ++ Rest) ->
    {min, range_upper(Rest)};
range_part(Part) ->
    case string:split(Part, "..") of
        [Lo, Hi] -> {range_bound(string:trim(Lo), min),
                     range_bound(string:trim(Hi), max)};
        [Single] ->
            N = range_bound(string:trim(Single), min),
            {N, N}
    end.

range_upper([]) -> max;
range_upper(".." ++ Hi) -> range_bound(string:trim(Hi), max).

range_bound("min", min) -> min;
range_bound("max", max) -> max;
range_bound("min", _) -> min;
range_bound("max", _) -> max;
range_bound(S, _) ->
    try list_to_integer(S) of
        N -> N
    catch
        error:_ -> undefined
    end.

collect_typedefs(Body) ->
    collect_typedefs(Body, #{}).

collect_typedefs([], Acc) ->
    Acc;
collect_typedefs([{typedef, _Ln, Name, Sub} | Rest], Acc) ->
    case lists:keyfind(type, 1, Sub) of
        {type, _, TypeName, TypeSub} ->
            collect_typedefs(Rest, Acc#{arg_bin(Name) => {arg_bin(TypeName), TypeSub}});
        false ->
            collect_typedefs(Rest, Acc)
    end;
collect_typedefs([{Stmt, _, _, Sub} | Rest], Acc)
  when Stmt =:= grouping; Stmt =:= container; Stmt =:= list ->
    collect_typedefs(Rest, collect_typedefs(Sub, Acc));
collect_typedefs([_ | Rest], Acc) ->
    collect_typedefs(Rest, Acc).

merge_type_sub(BaseSub, ExtraSub) ->
    ExtraSub ++ BaseSub.

compile_default(Sub, Type) ->
    case find_arg(default, Sub) of
        undefined -> undefined;
        Arg -> coerce_default(Type, Arg)
    end.

coerce_default(boolean, true) -> true;
coerce_default(boolean, false) -> false;
coerce_default(Type, Arg) ->
    S = arg_str(Arg),
    case is_int_type(Type) of
        true ->
            try list_to_integer(S) of
                N -> N
            catch
                error:_ -> S
            end;
        false ->
            S
    end.

is_int_type(T) when T =:= int8; T =:= int16; T =:= int32; T =:= int64;
                    T =:= uint8; T =:= uint16; T =:= uint32; T =:= uint64;
                    T =:= 'inet:port-number' ->
    true;
is_int_type({T, _Range}) ->
    is_int_type(T);
is_int_type(_) ->
    false.

%%--------------------------------------------------------------------
%% opts / extras kept for later XPath and constraints
%%--------------------------------------------------------------------

node_opts(Sub) ->
    lists:flatten([must_opts(Sub),
                   when_opt(Sub),
                   unique_opt(Sub),
                   presence_opt(Sub),
                   pattern_opt(Sub),
                   if_feature_opt(Sub)]).

must_opts(Sub) ->
    [{must, #{expr => arg_str(Arg),
              error_message => find_str('error-message', MustSub)}}
     || {must, _, Arg, MustSub} <- Sub].

when_opt(Sub) ->
    case lists:keyfind('when', 1, Sub) of
        {'when', _, Arg, _} -> [{'when', arg_str(Arg)}];
        false -> []
    end.

unique_opt(Sub) ->
    Uniques = [string:tokens(arg_str(Arg), " \t")
               || {unique, _, Arg, _} <- Sub],
    case Uniques of
        [] -> [];
        _ -> [{unique, Uniques}]
    end.

presence_opt(Sub) ->
    case find_arg(presence, Sub) of
        undefined -> [];
        Arg -> [{presence, arg_str(Arg)}]
    end.

pattern_opt(Sub) ->
    case lists:keyfind(type, 1, Sub) of
        {type, _, _, TypeSub} ->
            case find_arg(pattern, TypeSub) of
                undefined -> [];
                Arg -> [{pattern, arg_str(Arg)}]
            end;
        false ->
            []
    end.

if_feature_opt(Sub) ->
    Feats = [arg_str(A) || {'if-feature', _, A, _} <- Sub],
    case Feats of
        [] -> [];
        _ -> [{'if-feature', Feats}]
    end.

%%--------------------------------------------------------------------
%% Statement helpers
%%--------------------------------------------------------------------

find_arg(Key, Stmts) ->
    case lists:keyfind(Key, 1, Stmts) of
        {Key, _, Arg, _} -> Arg;
        false -> undefined
    end.

find_desc(Stmts) ->
    case find_arg(description, Stmts) of
        undefined -> "";
        Arg -> arg_str(Arg)
    end.

find_str(Key, Stmts) ->
    case find_arg(Key, Stmts) of
        undefined -> undefined;
        Arg -> arg_str(Arg)
    end.

is_true(true) -> true;
is_true(_) -> false.

arg_str(B) when is_binary(B) -> binary_to_list(B);
arg_str(A) when is_atom(A) -> atom_to_list(A);
arg_str(L) when is_list(L) -> L;
arg_str(I) when is_integer(I) -> integer_to_list(I);
arg_str([]) -> "".

arg_bin(B) when is_binary(B) -> B;
arg_bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
arg_bin(L) when is_list(L) -> list_to_binary(L).

arg_int(I) when is_integer(I) -> I;
arg_int(A) when is_atom(A) -> list_to_integer(atom_to_list(A));
arg_int(B) when is_binary(B) -> binary_to_integer(B);
arg_int(L) when is_list(L) -> list_to_integer(L).

prefix_atom(A) when is_atom(A) -> A;
prefix_atom(B) when is_binary(B) -> binary_to_atom(B, utf8);
prefix_atom(L) when is_list(L) -> list_to_atom(L).

node_name(#container{name = N}) -> N;
node_name(#list{name = N}) -> N;
node_name(#leaf{name = N}) -> N;
node_name(#leaf_list{name = N}) -> N.
