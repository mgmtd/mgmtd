%% Load RFC 7950 YANG modules into mgmtd schema ETS.
%%
%% PR 3: augment (local, uses, remote), identity/identityref, choice/case flatten.
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
                            nodes := [#container{} | #list{} | #leaf{} | #leaf_list{}],
                            identities => [map()],
                            remote_augments => [map()]}.

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
            compile(Stmts, Opts#{file => File});
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
            Ctx0 = init_ctx(Opts, Header, Name),
            case prepare_module(Body, Ctx0) of
                {error, _} = Err ->
                    Err;
                {ok, Merged, Ctx1} ->
                    case data_nodes(Merged, Ctx1) of
                        {error, _} = Err ->
                            Err;
                        {ok, Nodes0} ->
                            PrefixAtom = maps:get(prefix, Opts, maps:get(prefix, Header)),
                            NsUri = case maps:get(namespace, Opts, undefined) of
                                        undefined -> maps:get(namespace, Header);
                                        Override -> Override
                                    end,
                            Ids = maps:get(identities, Ctx1, []),
                            case apply_top_augments(Merged, Nodes0, Ctx1) of
                                {error, _} = Err ->
                                    Err;
                                {ok, Nodes, Remote} ->
                                    {ok, #{module => Name,
                                           prefix => PrefixAtom,
                                           namespace => NsUri,
                                           yang_version => maps:get(yang_version, Header, <<"1">>),
                                           nodes => Nodes,
                                           identities => Ids,
                                           remote_augments => Remote}}
                            end
                    end
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

init_ctx(Opts, Header, Name) ->
    File = maps:get(file, Opts, undefined),
    #{search_path => search_path(Opts, File),
      features => normalize_features(maps:get(features, Opts, all)),
      loaded => #{},
      file => File,
      opts => Opts,
      parent_config => true,
      uses_stack => [],
      module => list_to_binary(Name),
      mod_prefix => maps:get(prefix_bin, Header),
      typedefs => #{},
      groupings => #{},
      imports => #{}}.

search_path(Opts, File) ->
    FileDir = case File of
                  undefined -> [];
                  _ -> [filename:dirname(filename:absname(File))]
              end,
    User = maps:get(search_path, Opts, []),
    FileDir ++ User ++ priv_yang_dirs().

priv_yang_dirs() ->
    AppDir = case code:priv_dir(mgmtd) of
                 {error, _} -> [];
                 Dir -> [filename:join(Dir, "yang")]
             end,
    Local = case filelib:is_dir("priv/yang") of
                true -> ["priv/yang"];
                false -> []
            end,
    uniq_dirs(AppDir ++ Local).

uniq_dirs(Dirs) ->
    lists:reverse(lists:foldl(
                    fun(D, Acc) ->
                            case lists:member(D, Acc) of
                                true -> Acc;
                                false -> [D | Acc]
                            end
                    end, [], Dirs)).

header(Body) ->
    case {find_arg(namespace, Body), find_arg(prefix, Body)} of
        {undefined, _} ->
            {error, missing_namespace};
        {_, undefined} ->
            {error, missing_prefix};
        {Ns, Prefix0} ->
            PrefixBin = arg_bin(Prefix0),
            Ver = case find_arg('yang-version', Body) of
                      undefined -> <<"1">>;
                      V -> arg_bin(V)
                  end,
            {ok, #{namespace => arg_str(Ns),
                   prefix => prefix_atom(Prefix0),
                   prefix_bin => PrefixBin,
                   yang_version => Ver}}
    end.

load_compiled(Compiled, Opts) ->
    #{prefix := Prefix, namespace := NsUri, nodes := Nodes} = Compiled,
    LoadOpts = Opts#{prefix => Prefix, namespace => NsUri},
    TopNames = [node_name(N) || N <- Nodes],
    case mgmtd_schema:prepare_load(LoadOpts, yang, TopNames) of
        {ok, Prefix1, Namespace} ->
            Callback = maps:get(callback, Opts, undefined),
            case Nodes of
                [] ->
                    ok;
                _ ->
                    ok = mgmtd_schema_function:load_resolved(Prefix1, Nodes, Callback)
            end,
            ok = mgmtd_schema:register_schema(Prefix1, Namespace, yang),
            ok = mgmtd_schema:register_identities(maps:get(identities, Compiled, [])),
            apply_remote_augments(maps:get(remote_augments, Compiled, []), Callback);
        {error, _} = Err ->
            Err
    end.

%%--------------------------------------------------------------------
%% Imports, includes, local maps
%%--------------------------------------------------------------------

prepare_module(Body, Ctx0) ->
    case merge_includes(Body, Ctx0) of
        {error, _} = Err ->
            Err;
        {ok, Merged, Ctx1} ->
            case load_imports(Merged, Ctx1) of
                {error, _} = Err ->
                    Err;
                {ok, Imports, Ctx2} ->
                    Ids = collect_identities(Merged, maps:get(module, Ctx2),
                                             maps:get(mod_prefix, Ctx2), Imports)
                        ++ imported_identities(Imports),
                    Ctx3 = Ctx2#{imports => Imports,
                                 typedefs => collect_typedefs_here(Merged),
                                 groupings => collect_groupings_here(Merged),
                                 identities => Ids},
                    {ok, Merged, Ctx3}
            end
    end.

merge_includes(Body, Ctx) ->
    merge_includes(Body, Ctx, []).

merge_includes([], Ctx, Acc) ->
    {ok, lists:reverse(Acc), Ctx};
merge_includes([{include, Ln, Name, Sub} | Rest], Ctx, Acc) ->
    Rev = find_arg('revision-date', Sub),
    case load_mod(arg_str(Name), Rev, include, Ctx) of
        {error, _} = Err ->
            prepend_error(Err, Ln, Name);
        {ok, SubMod, Ctx1} ->
            merge_includes(Rest, Ctx1, lists:reverse(maps:get(body, SubMod)) ++ Acc)
    end;
merge_includes([Stmt | Rest], Ctx, Acc) ->
    merge_includes(Rest, Ctx, [Stmt | Acc]).

load_imports(Body, Ctx) ->
    load_imports(Body, Ctx, #{}).

load_imports([], Ctx, Acc) ->
    {ok, Acc, Ctx};
load_imports([{import, Ln, Name, Sub} | Rest], Ctx, Acc) ->
    case find_arg(prefix, Sub) of
        undefined ->
            {error, {Ln, missing_import_prefix, arg_str(Name)}};
        Prefix0 ->
            Rev = find_arg('revision-date', Sub),
            case load_mod(arg_str(Name), Rev, import, Ctx) of
                {error, _} = Err ->
                    prepend_error(Err, Ln, Name);
                {ok, Imp, Ctx1} ->
                    load_imports(Rest, Ctx1, Acc#{arg_bin(Prefix0) => Imp})
            end
    end;
load_imports([_ | Rest], Ctx, Acc) ->
    load_imports(Rest, Ctx, Acc).

load_mod(Name, Rev, Kind, Ctx) ->
    Key = {Name, rev_key(Rev)},
    case maps:find(Key, maps:get(loaded, Ctx)) of
        {ok, loading} ->
            {error, {circular_import, Name}};
        {ok, Mod} ->
            {ok, Mod, Ctx};
        error ->
            case find_yang_file(Name, Rev, Ctx) of
                {error, _} = Err ->
                    Err;
                {ok, File} ->
                    CtxL = Ctx#{loaded => maps:put(Key, loading, maps:get(loaded, Ctx)),
                                file => File},
                    case mgmtd_yang_parse:file(File, scan_opts(maps:get(opts, Ctx, #{}))) of
                        {error, _} = Err ->
                            Err;
                        {ok, Stmts} ->
                            build_mod(Stmts, Kind, Key, CtxL)
                    end
            end
    end.

rev_key(undefined) -> latest;
rev_key(Rev) -> arg_str(Rev).

build_mod([{module, _Ln, Name, Body}], import, Key, Ctx) ->
    case header(Body) of
        {error, _} = Err ->
            Err;
        {ok, Header} ->
            finish_mod(module, arg_bin(Name), Body, Header, Key, Ctx)
    end;
build_mod([{submodule, Ln, Name, Body}], include, Key, Ctx) ->
    case lists:keyfind('belongs-to', 1, Body) of
        false ->
            {error, {Ln, missing_belongs_to, arg_str(Name)}};
        {'belongs-to', _, _Parent, _Sub} ->
            PrefixBin = case find_arg(prefix, Body) of
                            undefined -> maps:get(mod_prefix, Ctx);
                            P -> arg_bin(P)
                        end,
            Header = #{prefix_bin => PrefixBin, prefix => prefix_atom(PrefixBin),
                       namespace => "", yang_version => <<"1">>},
            finish_mod(submodule, arg_bin(Name), Body, Header, Key, Ctx)
    end;
build_mod([{submodule, Ln, Name, _}], import, _Key, _Ctx) ->
    {error, {Ln, expected_module, arg_str(Name)}};
build_mod([{module, Ln, Name, _}], include, _Key, _Ctx) ->
    {error, {Ln, expected_submodule, arg_str(Name)}};
build_mod(Other, _Kind, _Key, _Ctx) ->
    {error, {expected_module, Other}}.

finish_mod(Kind, Name, Body, Header, Key, Ctx) ->
    case merge_includes(Body, Ctx) of
        {error, _} = Err ->
            Err;
        {ok, Merged0, Ctx1} ->
            Merged = strip_belongs_to(Merged0),
            case load_imports(Merged, Ctx1) of
                {error, _} = Err ->
                    Err;
                {ok, Imports, Ctx2} ->
                    ModPrefix = maps:get(prefix_bin, Header),
                    Mod = #{kind => Kind,
                            name => Name,
                            prefix => ModPrefix,
                            typedefs => collect_typedefs_here(Merged),
                            groupings => collect_groupings_here(Merged),
                            identities => collect_identities(Merged, Name, ModPrefix, Imports),
                            features => [arg_bin(A) || {feature, _, A, _} <- Merged],
                            imports => Imports,
                            body => Merged},
                    Loaded = maps:put(Key, Mod, maps:get(loaded, Ctx2)),
                    {ok, Mod, Ctx2#{loaded => Loaded}}
            end
    end.

strip_belongs_to(Body) ->
    [S || S <- Body, element(1, S) =/= 'belongs-to'].

find_yang_file(Name, Rev, Ctx) ->
    Names = yang_filenames(Name, Rev),
    find_yang_file_in(maps:get(search_path, Ctx), Names, Name).

yang_filenames(Name, undefined) ->
    [Name ++ ".yang"];
yang_filenames(Name, Rev) ->
    R = arg_str(Rev),
    [Name ++ "@" ++ R ++ ".yang", Name ++ ".yang"].

find_yang_file_in([], _Names, Name) ->
    {error, {module_not_found, Name}};
find_yang_file_in([Dir | Dirs], Names, Name) ->
    case first_existing([filename:join(Dir, N) || N <- Names]) of
        false ->
            find_yang_file_in(Dirs, Names, Name);
        File ->
            {ok, File}
    end.

first_existing([]) ->
    false;
first_existing([F | Fs]) ->
    case filelib:is_regular(F) of
        true -> F;
        false -> first_existing(Fs)
    end.

%%--------------------------------------------------------------------
%% Body walk
%%--------------------------------------------------------------------

data_nodes(Body, Ctx0) ->
    Ctx = Ctx0#{typedefs => maps:merge(maps:get(typedefs, Ctx0),
                                       collect_typedefs_here(Body)),
                groupings => maps:merge(maps:get(groupings, Ctx0),
                                        collect_groupings_here(Body))},
    data_nodes(Body, Ctx, []).

data_nodes([], _Ctx, Acc) ->
    {ok, lists:reverse(Acc)};
data_nodes([{uses, Ln, Arg, UsesSub} | Rest], Ctx, Acc) ->
    case expand_uses(Ln, Arg, UsesSub, Ctx) of
        {error, _} = Err ->
            Err;
        {ok, Nodes} ->
            data_nodes(Rest, Ctx, lists:reverse(Nodes) ++ Acc);
        skip ->
            data_nodes(Rest, Ctx, Acc)
    end;
data_nodes([{augment, _Ln, _Arg, _Sub} | Rest], Ctx, Acc) ->
    %% Applied after the tree is built (top-level) or after uses expansion.
    data_nodes(Rest, Ctx, Acc);
data_nodes([{choice, Ln, Arg, Sub} | Rest], Ctx, Acc) ->
    case flatten_choice(Ln, Arg, Sub, Ctx) of
        {error, _} = Err ->
            Err;
        {ok, Nodes} ->
            data_nodes(Rest, Ctx, lists:reverse(Nodes) ++ Acc);
        skip ->
            data_nodes(Rest, Ctx, Acc)
    end;
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

expand_uses(Ln, Arg, UsesSub, Ctx) ->
    case feature_ok(UsesSub, Ctx) of
        false ->
            skip;
        true ->
            GName = arg_bin(Arg),
            case lookup_grouping(GName, Ctx) of
                error ->
                    {error, {Ln, unknown_grouping, arg_str(Arg)}};
                {ok, GBody, GCtx0} ->
                    Stack = maps:get(uses_stack, Ctx, []),
                    case lists:member(GName, Stack) of
                        true ->
                            {error, {Ln, circular_uses, arg_str(Arg)}};
                        false ->
                            GCtx = GCtx0#{parent_config => maps:get(parent_config, Ctx),
                                          uses_stack => [GName | Stack],
                                          features => maps:get(features, Ctx)},
                            case data_nodes(GBody, GCtx) of
                                {error, _} = Err ->
                                    Err;
                                {ok, Nodes0} ->
                                    Refines = [{refine, RLn, P, I}
                                               || {refine, RLn, P, I} <- UsesSub],
                                    case apply_refines(Nodes0, Refines) of
                                        {error, _} = Err ->
                                            Err;
                                        {ok, Nodes1} ->
                                            case apply_uses_augments(UsesSub, Nodes1, Ctx) of
                                                {error, _} = Err ->
                                                    Err;
                                                {ok, Nodes2} ->
                                                    {ok, propagate_uses_opts(Nodes2, UsesSub)}
                                            end
                                    end
                            end
                    end
            end
    end.

compile_node(Kind, Ln, Arg, Sub, Ctx) ->
    case feature_ok(Sub, Ctx) of
        false ->
            {skip, if_feature};
        true ->
            compile_node_feature(Kind, Ln, Arg, Sub, Ctx)
    end.

compile_node_feature(container, _Ln, Arg, Sub, Ctx) ->
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
compile_node_feature(list, Ln, Arg, Sub, Ctx) ->
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
compile_node_feature(leaf, Ln, Arg, Sub, Ctx) ->
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
compile_node_feature('leaf-list', Ln, Arg, Sub, Ctx) ->
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
%% Refine (applied to compiled records after grouping expansion)
%%--------------------------------------------------------------------

apply_refines(Nodes, []) ->
    {ok, Nodes};
apply_refines(Nodes, [{refine, Ln, Path, Items} | Rest]) ->
    Ids = schema_id_path(arg_str(Path)),
    case refine_walk(Nodes, Ids, Items, Ln, arg_str(Path)) of
        {ok, Nodes1} ->
            apply_refines(Nodes1, Rest);
        Error ->
            Error
    end.

schema_id_path(Path) ->
    [local_id(P) || P <- string:tokens(string:trim(Path, both, "/"), "/")].

local_id(Id) ->
    case string:split(Id, ":") of
        [_Pfx, Name] -> Name;
        [Name] -> Name
    end.

refine_walk(_Nodes, [], _Items, Ln, Path) ->
    {error, {Ln, refine_not_found, Path}};
refine_walk(Nodes, [Id], Items, Ln, Path) ->
    case replace_named(Nodes, Id, fun(N) -> refine_node(N, Items) end) of
        {ok, Nodes1} -> {ok, Nodes1};
        not_found -> {error, {Ln, refine_not_found, Path}}
    end;
refine_walk(Nodes, [Id | Rest], Items, Ln, Path) ->
    case replace_named(Nodes, Id, fun(N) -> refine_children(N, Rest, Items, Ln, Path) end) of
        {ok, Nodes1} -> {ok, Nodes1};
        not_found -> {error, {Ln, refine_not_found, Path}}
    end.

replace_named(Nodes, Id, Fun) ->
    replace_named(Nodes, Id, Fun, [], false).

replace_named([], _Id, _Fun, _Acc, false) ->
    not_found;
replace_named([], _Id, _Fun, Acc, true) ->
    {ok, lists:reverse(Acc)};
replace_named([N | Ns], Id, Fun, Acc, Found) ->
    case node_name(N) =:= Id of
        true ->
            case Fun(N) of
                {error, _} = Err ->
                    Err;
                {ok, N1} ->
                    replace_named(Ns, Id, Fun, [N1 | Acc], true);
                N1 ->
                    replace_named(Ns, Id, Fun, [N1 | Acc], true)
            end;
        false ->
            replace_named(Ns, Id, Fun, [N | Acc], Found)
    end.

refine_children(#container{children = Ch} = N, Rest, Items, Ln, Path) ->
    case refine_walk(Ch(), Rest, Items, Ln, Path) of
        {ok, Ch1} -> N#container{children = fun() -> Ch1 end};
        Err -> Err
    end;
refine_children(#list{children = Ch} = N, Rest, Items, Ln, Path) ->
    case refine_walk(Ch(), Rest, Items, Ln, Path) of
        {ok, Ch1} -> N#list{children = fun() -> Ch1 end};
        Err -> Err
    end;
refine_children(_Other, _Rest, _Items, Ln, Path) ->
    {error, {Ln, refine_not_found, Path}}.

refine_node(#leaf{} = N, Items) ->
    N#leaf{desc = refine_desc(Items, N#leaf.desc),
           default = refine_default(Items, N#leaf.default, N#leaf.type),
           mandatory = refine_bool(mandatory, Items, N#leaf.mandatory),
           config = refine_bool(config, Items, N#leaf.config),
           opts = refine_merge_opts(Items, N#leaf.opts)};
refine_node(#leaf_list{} = N, Items) ->
    N#leaf_list{desc = refine_desc(Items, N#leaf_list.desc),
                min_elements = refine_min(Items, N#leaf_list.min_elements),
                max_elements = refine_max(Items, N#leaf_list.max_elements),
                config = refine_bool(config, Items, N#leaf_list.config),
                opts = refine_merge_opts(Items, N#leaf_list.opts)};
refine_node(#list{} = N, Items) ->
    N#list{desc = refine_desc(Items, N#list.desc),
           min_elements = refine_min(Items, N#list.min_elements),
           max_elements = refine_max(Items, N#list.max_elements),
           config = refine_bool(config, Items, N#list.config),
           opts = refine_merge_opts(Items, N#list.opts)};
refine_node(#container{} = N, Items) ->
    N#container{desc = refine_desc(Items, N#container.desc),
                config = refine_bool(config, Items, N#container.config),
                opts = refine_merge_opts(Items, N#container.opts)}.

refine_desc(Items, Default) ->
    case find_arg(description, Items) of
        undefined -> Default;
        Arg -> arg_str(Arg)
    end.

refine_default(Items, Default, Type) ->
    case find_arg(default, Items) of
        undefined -> Default;
        Arg -> coerce_default(Type, Arg)
    end.

refine_bool(Key, Items, Default) ->
    case find_arg(Key, Items) of
        undefined -> Default;
        true -> true;
        false -> false;
        _ -> Default
    end.

refine_min(Items, Default) ->
    case find_arg('min-elements', Items) of
        undefined -> Default;
        N -> arg_int(N)
    end.

refine_max(Items, Default) ->
    case find_arg('max-elements', Items) of
        undefined -> Default;
        unbounded -> unlimited;
        N -> arg_int(N)
    end.

refine_merge_opts(Items, Opts) ->
    Extra = lists:flatten([must_opts(Items), when_opt(Items),
                           unique_opt(Items), presence_opt(Items),
                           if_feature_opt(Items)]),
    Extra ++ Opts.

propagate_uses_opts(Nodes, UsesSub) ->
    Extra = lists:flatten([when_opt(UsesSub), if_feature_opt(UsesSub)]),
    case Extra of
        [] -> Nodes;
        _ -> [add_opts(N, Extra) || N <- Nodes]
    end.

add_opts(#container{opts = O} = N, Extra) -> N#container{opts = Extra ++ O};
add_opts(#list{opts = O} = N, Extra) -> N#list{opts = Extra ++ O};
add_opts(#leaf{opts = O} = N, Extra) -> N#leaf{opts = Extra ++ O};
add_opts(#leaf_list{opts = O} = N, Extra) -> N#leaf_list{opts = Extra ++ O}.

%%--------------------------------------------------------------------
%% choice / case (flatten)
%%--------------------------------------------------------------------

flatten_choice(_Ln, Arg, Sub, Ctx) ->
    case feature_ok(Sub, Ctx) of
        false ->
            skip;
        true ->
            ChoiceName = arg_str(Arg),
            Default = case find_arg(default, Sub) of
                          undefined -> undefined;
                          D -> arg_str(D)
                      end,
            flatten_cases(Sub, ChoiceName, Default, Ctx, [])
    end.

flatten_cases([], _CN, _Def, _Ctx, Acc) ->
    {ok, lists:reverse(Acc)};
flatten_cases([{'case', _Ln, Name, CaseSub} | Rest], CN, Def, Ctx, Acc) ->
    case feature_ok(CaseSub, Ctx) of
        false ->
            flatten_cases(Rest, CN, Def, Ctx, Acc);
        true ->
            case data_nodes(CaseSub, Ctx) of
                {error, _} = Err ->
                    Err;
                {ok, Nodes} ->
                    Tagged = [tag_choice(N, CN, arg_str(Name), Def) || N <- Nodes],
                    flatten_cases(Rest, CN, Def, Ctx, lists:reverse(Tagged) ++ Acc)
            end
    end;
flatten_cases([{Stmt, _, _, _} = S | Rest], CN, Def, Ctx, Acc)
  when Stmt =:= container; Stmt =:= list; Stmt =:= leaf;
       Stmt =:= 'leaf-list'; Stmt =:= choice; Stmt =:= uses ->
    case data_nodes([S], Ctx) of
        {error, _} = Err ->
            Err;
        {ok, []} ->
            flatten_cases(Rest, CN, Def, Ctx, Acc);
        {ok, Nodes} ->
            CaseName = node_name(hd(Nodes)),
            Tagged = [tag_choice(N, CN, CaseName, Def) || N <- Nodes],
            flatten_cases(Rest, CN, Def, Ctx, lists:reverse(Tagged) ++ Acc)
    end;
flatten_cases([_Other | Rest], CN, Def, Ctx, Acc) ->
    flatten_cases(Rest, CN, Def, Ctx, Acc).

tag_choice(Node, ChoiceName, CaseName, Default) ->
    Extra = [{choice, ChoiceName}, {'case', CaseName}]
        ++ case Default of
               undefined -> [];
               _ -> [{choice_default, Default}]
           end,
    add_opts(Node, Extra).

%%--------------------------------------------------------------------
%% augment
%%--------------------------------------------------------------------

apply_top_augments(Body, Nodes, Ctx) ->
    Augs = [{augment, Ln, Path, Sub} || {augment, Ln, Path, Sub} <- Body],
    apply_augments(Augs, Nodes, Ctx, []).

apply_uses_augments(UsesSub, Nodes, Ctx) ->
    Augs = [{augment, Ln, Path, Sub} || {augment, Ln, Path, Sub} <- UsesSub],
    case apply_augments(Augs, Nodes, Ctx#{augment_relative => true}, []) of
        {ok, Nodes1, []} ->
            {ok, Nodes1};
        {ok, _Nodes1, [#{path := P, line := Ln} | _]} ->
            {error, {Ln, absolute_augment_in_uses, P}};
        Error ->
            Error
    end.

apply_augments([], Nodes, _Ctx, Remote) ->
    {ok, Nodes, lists:reverse(Remote)};
apply_augments([{augment, Ln, Path, Sub} | Rest], Nodes, Ctx, Remote) ->
    case feature_ok(Sub, Ctx) of
        false ->
            apply_augments(Rest, Nodes, Ctx, Remote);
        true ->
            case parse_schema_node_id(arg_str(Path)) of
                {error, Reason} ->
                    {error, {Ln, Reason, arg_str(Path)}};
                {Kind, Steps} ->
                    apply_one_augment(Kind, Steps, Ln, Path, Sub, Rest, Nodes, Ctx, Remote)
            end
    end.

apply_one_augment(relative, Steps, Ln, Path, Sub, Rest, Nodes, Ctx, Remote) ->
    case maps:get(augment_relative, Ctx, false) of
        false ->
            {error, {Ln, relative_augment_outside_uses, arg_str(Path)}};
        true ->
            graft_augment(Steps, Ln, Path, Sub, Rest, Nodes, Ctx, Remote)
    end;
apply_one_augment(absolute, Steps, Ln, Path, Sub, Rest, Nodes, Ctx, Remote) ->
    case is_local_target(Steps, Ctx) of
        true ->
            graft_augment(Steps, Ln, Path, Sub, Rest, Nodes, Ctx, Remote);
        false ->
            case compile_augment_body(Sub, Ctx) of
                {error, _} = Err ->
                    Err;
                {ok, Children} ->
                    Remote1 = #{target => Steps, nodes => Children,
                                line => Ln, path => arg_str(Path)},
                    apply_augments(Rest, Nodes, Ctx, [Remote1 | Remote])
            end
    end.

graft_augment(Steps, Ln, Path, Sub, Rest, Nodes, Ctx, Remote) ->
    case compile_augment_body(Sub, Ctx) of
        {error, _} = Err ->
            Err;
        {ok, Children} ->
            Names = [Name || {_Pfx, Name} <- Steps],
            case graft(Nodes, Names, Children, Ln, arg_str(Path)) of
                {error, _} = Err ->
                    Err;
                {ok, Nodes1} ->
                    apply_augments(Rest, Nodes1, Ctx, Remote)
            end
    end.

compile_augment_body(Sub, Ctx) ->
    case data_nodes(Sub, Ctx) of
        {error, _} = Err ->
            Err;
        {ok, Nodes} ->
            {ok, propagate_uses_opts(Nodes, Sub)}
    end.

is_local_target(Steps, Ctx) ->
    Self = maps:get(mod_prefix, Ctx),
    lists:all(fun({undefined, _}) -> true;
                 ({Pfx, _}) -> Pfx =:= Self
              end, Steps).

parse_schema_node_id("/" ++ Rest) ->
    case parse_sn_steps(Rest) of
        {ok, []} -> {error, empty_schema_node_id};
        {ok, Steps} -> {absolute, Steps};
        Error -> Error
    end;
parse_schema_node_id(Path) ->
    case parse_sn_steps(Path) of
        {ok, []} -> {error, empty_schema_node_id};
        {ok, Steps} -> {relative, Steps};
        Error -> Error
    end.

parse_sn_steps(Path) ->
    Parts = [P || P <- string:tokens(Path, "/"), P =/= ""],
    {ok, [split_prefixed(P) || P <- Parts]}.

split_prefixed(Part) ->
    case string:split(Part, ":") of
        [Pfx, Name] -> {list_to_binary(Pfx), Name};
        [Name] -> {undefined, Name}
    end.

graft(_Nodes, [], _Extra, Ln, Path) ->
    {error, {Ln, augment_not_found, Path}};
graft(Nodes, [Name], Extra, Ln, Path) ->
    case replace_named(Nodes, Name, fun(N) -> append_children(N, Extra, Ln, Path) end) of
        {ok, _} = Ok -> Ok;
        not_found -> {error, {Ln, augment_not_found, Path}}
    end;
graft(Nodes, [Name | Rest], Extra, Ln, Path) ->
    case replace_named(Nodes, Name,
                       fun(N) -> graft_into(N, Rest, Extra, Ln, Path) end) of
        {ok, _} = Ok -> Ok;
        not_found -> {error, {Ln, augment_not_found, Path}}
    end.

graft_into(#container{children = Ch} = N, Rest, Extra, Ln, Path) ->
    case graft(Ch(), Rest, Extra, Ln, Path) of
        {ok, Ch1} -> N#container{children = fun() -> Ch1 end};
        Err -> Err
    end;
graft_into(#list{children = Ch} = N, Rest, Extra, Ln, Path) ->
    case graft(Ch(), Rest, Extra, Ln, Path) of
        {ok, Ch1} -> N#list{children = fun() -> Ch1 end};
        Err -> Err
    end;
graft_into(_Other, _Rest, _Extra, Ln, Path) ->
    {error, {Ln, augment_not_found, Path}}.

append_children(#container{children = Ch} = N, Extra, _Ln, _Path) ->
    N#container{children = fun() -> Ch() ++ Extra end};
append_children(#list{children = Ch} = N, Extra, _Ln, _Path) ->
    N#list{children = fun() -> Ch() ++ Extra end};
append_children(_Other, _Extra, Ln, Path) ->
    {error, {Ln, augment_not_a_data_node, Path}}.

apply_remote_augments([], _Callback) ->
    ok;
apply_remote_augments([#{target := Steps, nodes := Nodes, line := Ln, path := Path} | Rest], Callback) ->
    case remote_target(Steps) of
        {error, Reason} ->
            {error, {Ln, Reason, Path}};
        {Prefix, ParentPath} ->
            case mgmtd_schema_function:load_resolved_at(Prefix, ParentPath, Nodes, Callback) of
                ok ->
                    apply_remote_augments(Rest, Callback);
                {error, _} = Err ->
                    prepend_error(Err, Ln, Path)
            end
    end.

remote_target([]) ->
    {error, empty_schema_node_id};
remote_target([{Pfx0, Name} | Rest]) ->
    PfxBin = case Pfx0 of
                 undefined -> <<>>;
                 B -> B
             end,
    Prefix = prefix_atom(PfxBin),
    Local = [Name | [N || {_P, N} <- Rest]],
    case Prefix of
        '' ->
            {error, missing_augment_prefix};
        _ ->
            Path = case Prefix of
                       default -> Local;
                       _ -> [atom_to_list(Prefix) | Local]
                   end,
            {Prefix, Path}
    end.

%%--------------------------------------------------------------------
%% identities
%%--------------------------------------------------------------------

collect_identities(Body, ModName, ModPrefix, Imports) ->
    [begin
         Local = arg_bin(Name),
         Bases = [expand_id_ref(B, ModPrefix, ModName, Imports)
                  || {base, _, B, _} <- Sub],
         #{local => Local,
           module => ModName,
           prefix => ModPrefix,
           qname => <<ModName/binary, $:, Local/binary>>,
           bases => Bases}
     end || {identity, _, Name, Sub} <- Body].

imported_identities(Imports) ->
    imported_identities(maps:values(Imports), #{}).

imported_identities([], _Seen) ->
    [];
imported_identities([Imp | Rest], Seen) ->
    Name = maps:get(name, Imp),
    case maps:is_key(Name, Seen) of
        true ->
            imported_identities(Rest, Seen);
        false ->
            maps:get(identities, Imp, [])
                ++ imported_identities(maps:values(maps:get(imports, Imp, #{})) ++ Rest,
                                       Seen#{Name => true})
    end.

expand_id_ref(Arg, Ctx) when is_map(Ctx) ->
    expand_id_ref(Arg, maps:get(mod_prefix, Ctx), maps:get(module, Ctx),
                  maps:get(imports, Ctx)).

expand_id_ref(undefined, _Pfx, _Mod, _Imports) ->
    "";
expand_id_ref(Arg, ModPrefix, ModName, Imports) ->
    Bin = arg_bin(Arg),
    case binary:split(Bin, <<":">>) of
        [Local] ->
            binary_to_list(<<ModName/binary, $:, Local/binary>>);
        [Pfx, Local] when Pfx =:= ModPrefix ->
            binary_to_list(<<ModName/binary, $:, Local/binary>>);
        [Pfx, Local] ->
            case maps:find(Pfx, Imports) of
                {ok, Imp} ->
                    ImpName = maps:get(name, Imp),
                    binary_to_list(<<ImpName/binary, $:, Local/binary>>);
                error ->
                    binary_to_list(Bin)
            end
    end.

%%--------------------------------------------------------------------
%% Config, keys, cardinality
%%--------------------------------------------------------------------

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
    case lists:member(Name, Seen) of
        true ->
            {error, {Ln, circular_typedef, Name}};
        false ->
            case builtin_type(Name, Sub) of
                {ok, {identityref_raw, Base}} ->
                    {ok, {identityref, expand_id_ref(Base, Ctx)}};
                {ok, _} = Ok ->
                    Ok;
                unknown ->
                    case well_known_type(typedef_local_name(Name), Sub) of
                        {ok, _} = Ok ->
                            Ok;
                        unknown ->
                            case lookup_typedef(Name, Ctx) of
                                {ok, BaseName, BaseSub, DefCtx} ->
                                    case well_known_type(typedef_local_name(Name),
                                                         merge_type_sub(BaseSub, Sub)) of
                                        {ok, _} = Ok ->
                                            Ok;
                                        unknown ->
                                            resolve_type(BaseName,
                                                         merge_type_sub(BaseSub, Sub),
                                                         Ln, DefCtx, [Name | Seen])
                                    end;
                                error ->
                                    {error, {Ln, unknown_type, arg_str(Name)}}
                            end
                    end
            end
    end.

typedef_local_name(Name) ->
    case binary:split(Name, <<":">>) of
        [_Pfx, Local] -> Local;
        [Local] -> Local
    end.

%% Map well-known IETF typedefs onto mgmtd's existing casters.
well_known_type(<<"ip-address">>, _) -> {ok, 'inet:ip-address'};
well_known_type(<<"ipv4-address">>, _) -> {ok, 'inet:ip-address'};
well_known_type(<<"ipv6-address">>, _) -> {ok, 'inet:ip-address'};
well_known_type(<<"ip-address-no-zone">>, _) -> {ok, 'inet:ip-address'};
well_known_type(<<"ipv4-address-no-zone">>, _) -> {ok, 'inet:ip-address'};
well_known_type(<<"ipv6-address-no-zone">>, _) -> {ok, 'inet:ip-address'};
well_known_type(<<"port-number">>, Sub) -> int_type('inet:port-number', Sub);
well_known_type(_, _) -> unknown.

lookup_typedef(Name, Ctx) ->
    case binary:split(Name, <<":">>) of
        [Local] ->
            lookup_local_typedef(Local, Ctx);
        [Pfx, Local] ->
            case Pfx =:= maps:get(mod_prefix, Ctx) of
                true ->
                    lookup_local_typedef(Local, Ctx);
                false ->
                    case maps:find(Pfx, maps:get(imports, Ctx)) of
                        {ok, Imp} ->
                            case maps:find(Local, maps:get(typedefs, Imp)) of
                                {ok, {Base, Sub}} ->
                                    {ok, Base, Sub, import_ctx(Imp, Ctx)};
                                error ->
                                    error
                            end;
                        error ->
                            error
                    end
            end
    end.

lookup_local_typedef(Local, Ctx) ->
    case maps:find(Local, maps:get(typedefs, Ctx)) of
        {ok, {Base, Sub}} -> {ok, Base, Sub, Ctx};
        error -> error
    end.

lookup_grouping(Name, Ctx) ->
    case binary:split(Name, <<":">>) of
        [Local] ->
            lookup_local_grouping(Local, Ctx);
        [Pfx, Local] ->
            case Pfx =:= maps:get(mod_prefix, Ctx) of
                true ->
                    lookup_local_grouping(Local, Ctx);
                false ->
                    case maps:find(Pfx, maps:get(imports, Ctx)) of
                        {ok, Imp} ->
                            case maps:find(Local, maps:get(groupings, Imp)) of
                                {ok, Body} ->
                                    {ok, Body, import_ctx(Imp, Ctx)};
                                error ->
                                    error
                            end;
                        error ->
                            error
                    end
            end
    end.

lookup_local_grouping(Local, Ctx) ->
    case maps:find(Local, maps:get(groupings, Ctx)) of
        {ok, Body} -> {ok, Body, Ctx};
        error -> error
    end.

import_ctx(Imp, Ctx) ->
    Ctx#{typedefs => maps:get(typedefs, Imp),
         groupings => maps:get(groupings, Imp),
         imports => maps:get(imports, Imp),
         mod_prefix => maps:get(prefix, Imp),
         module => maps:get(name, Imp)}.

builtin_type(<<"binary">>, _Sub) -> {ok, string};
builtin_type(<<"bits">>, Sub) -> {ok, {bits, bit_names(Sub)}};
builtin_type(<<"boolean">>, _) -> {ok, boolean};
builtin_type(<<"decimal64">>, _) -> {ok, decimal64};
builtin_type(<<"empty">>, _) -> {ok, empty};
builtin_type(<<"enumeration">>, Sub) -> {ok, {enum, enums(Sub)}};
builtin_type(<<"identityref">>, Sub) ->
    {ok, {identityref_raw, find_arg(base, Sub)}};
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
%% Fallback when a module writes inet:* without importing ietf-inet-types.
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
    Range1 = case Mins of
                 [] -> [];
                 _ -> [{min, lists:min(Mins)}]
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

collect_typedefs_here(Body) ->
    lists:foldl(
      fun({typedef, _, Name, Sub}, Acc) ->
              case lists:keyfind(type, 1, Sub) of
                  {type, _, TypeName, TypeSub} ->
                      Acc#{arg_bin(Name) => {arg_bin(TypeName), TypeSub}};
                  false ->
                      Acc
              end;
         (_, Acc) ->
              Acc
      end, #{}, Body).

collect_groupings_here(Body) ->
    lists:foldl(
      fun({grouping, _, Name, Sub}, Acc) ->
              Acc#{arg_bin(Name) => Sub};
         (_, Acc) ->
              Acc
      end, #{}, Body).

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
%% if-feature
%%--------------------------------------------------------------------

normalize_features(all) -> all;
normalize_features(none) -> none;
normalize_features(List) when is_list(List) ->
    [feat_bin(F) || F <- List];
normalize_features(Map) when is_map(Map) ->
    maps:fold(fun(K, Vs, Acc) ->
                      P = feat_bin(K),
                      [feat_bin(V) || V <- Vs] ++
                          [<<P/binary, $:, (feat_bin(V))/binary>> || V <- Vs] ++ Acc
              end, [], Map).

feat_bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
feat_bin(B) when is_binary(B) -> B;
feat_bin(L) when is_list(L) -> list_to_binary(L).

feature_ok(Sub, Ctx) ->
    Exprs = [A || {'if-feature', _, A, _} <- Sub],
    lists:all(fun(E) -> eval_if_feature(E, Ctx) end, Exprs).

eval_if_feature(_Arg, #{features := all}) ->
    true;
eval_if_feature(Arg, #{features := none} = Ctx) ->
    eval_if_feature(Arg, Ctx#{features => []});
eval_if_feature(Arg, Ctx) ->
    Enabled = maps:get(features, Ctx),
    case parse_if_feature(arg_str(Arg)) of
        {ok, Expr} ->
            eval_feat_ast(Expr, Enabled);
        {error, _} ->
            lists:member(arg_bin(Arg), Enabled)
    end.

eval_feat_ast({'not', E}, Enabled) ->
    not eval_feat_ast(E, Enabled);
eval_feat_ast({'and', A, B}, Enabled) ->
    eval_feat_ast(A, Enabled) andalso eval_feat_ast(B, Enabled);
eval_feat_ast({'or', A, B}, Enabled) ->
    eval_feat_ast(A, Enabled) orelse eval_feat_ast(B, Enabled);
eval_feat_ast({feat, Name}, Enabled) ->
    Local = typedef_local_name(Name),
    lists:member(Name, Enabled) orelse lists:member(Local, Enabled).

parse_if_feature(Str) ->
    try if_or(tokens_if(Str)) of
        {Expr, []} -> {ok, Expr};
        _ -> {error, trailing}
    catch
        throw:Reason -> {error, Reason}
    end.

tokens_if(Str) ->
    tokens_if(Str, []).

tokens_if([], Acc) ->
    lists:reverse(Acc);
tokens_if([C | Rest], Acc) when C =:= $\s; C =:= $\t; C =:= $\n; C =:= $\r ->
    tokens_if(Rest, Acc);
tokens_if([$( | Rest], Acc) ->
    tokens_if(Rest, ['(' | Acc]);
tokens_if([$) | Rest], Acc) ->
    tokens_if(Rest, [')' | Acc]);
tokens_if(Str, Acc) ->
    {Tok, Rest} = if_ident(Str),
    tokens_if(Rest, [Tok | Acc]).

if_ident(Str) ->
    {Word, Rest} = lists:splitwith(
                     fun(C) ->
                             (C >= $a andalso C =< $z) orelse
                                 (C >= $A andalso C =< $Z) orelse
                                 (C >= $0 andalso C =< $9) orelse
                                 C =:= $_ orelse C =:= $- orelse
                                 C =:= $. orelse C =:= $:
                     end, Str),
    case Word of
        "and" -> {'and', Rest};
        "or" -> {'or', Rest};
        "not" -> {'not', Rest};
        [] -> throw(empty_ident);
        _ -> {{feat, list_to_binary(Word)}, Rest}
    end.

if_or(Toks) ->
    {E1, T1} = if_and(Toks),
    if_or_rest(E1, T1).

if_or_rest(E, ['or' | T]) ->
    {E2, T2} = if_and(T),
    if_or_rest({'or', E, E2}, T2);
if_or_rest(E, T) ->
    {E, T}.

if_and(Toks) ->
    {E1, T1} = if_not(Toks),
    if_and_rest(E1, T1).

if_and_rest(E, ['and' | T]) ->
    {E2, T2} = if_not(T),
    if_and_rest({'and', E, E2}, T2);
if_and_rest(E, T) ->
    {E, T}.

if_not(['not' | T]) ->
    {E, T1} = if_not(T),
    {{'not', E}, T1};
if_not(Toks) ->
    if_primary(Toks).

if_primary(['(' | T]) ->
    {E, T1} = if_or(T),
    case T1 of
        [')' | T2] -> {E, T2};
        _ -> throw(missing_rparen)
    end;
if_primary([{feat, _} = F | T]) ->
    {F, T};
if_primary(_) ->
    throw(expected_feature).

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
