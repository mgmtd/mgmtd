%%%-------------------------------------------------------------------
%%% @doc Diff the current configuration session against a baseline.
%%%
%%% Default baseline is the snapshot of running taken at `txn_new/0`,
%%% so the result is the net uncommitted edits in this session.
%%% @end
%%%-------------------------------------------------------------------
-module(mgmtd_cfg_diff).

-include("mgmtd_schema.hrl").

-export([diff/3, format/1]).

-export_type([change/0]).

-type tree() :: list().
-type change() :: {add, item_path(), tree()}
                | {delete, item_path(), tree()}
                | {set, item_path(), term(), term()}.

-spec diff(mgmtd_cfg_txn:txn() | undefined, item_path() | map_path(), map()) ->
          {ok, [change()]} | {error, term()}.
diff(undefined, _Path, _Opts) ->
    {ok, []};
diff(Txn, Path, Opts) when is_map(Opts) ->
    ItemPath = to_item_path(Path),
    case against_tree(Txn, Opts) of
        {error, _} = Err ->
            Err;
        {ok, Old} ->
            New = mgmtd_cfg_txn:tree(Txn),
            Changes = diff_trees(Old, New, []),
            {ok, filter_prefix(Changes, ItemPath)}
    end.

-spec format([change()]) -> iodata().
format([]) ->
    [];
format(Changes) ->
    Sorted = lists:sort(fun(A, B) -> change_path(A) =< change_path(B) end, Changes),
    Hunks = group_hunks(Sorted),
    [format_hunk(H) || H <- Hunks].

%%--------------------------------------------------------------------
%% Against
%%--------------------------------------------------------------------

against_tree(Txn, Opts) ->
    case maps:get(against, Opts, session) of
        session ->
            {ok, mgmtd_cfg_txn:baseline_tree(Txn)};
        running ->
            {ok, mgmtd_cfg_txn:get_tree(undefined, [])};
        {rollback, N} when is_integer(N), N >= 0 ->
            case mgmtd_cfg_rollback:read(N) of
                {ok, Rows} ->
                    {ok, mgmtd_cfg_db:simplify_tree(
                           mgmtd_cfg_db:cfg_list_to_tree(Rows))};
                {error, _} = Err ->
                    Err
            end;
        Other ->
            {error, {unknown_against, Other}}
    end.

to_item_path([]) ->
    [];
to_item_path([#{role := schema} | _] = Path) ->
    mgmtd_cfg_db:schema_path_to_key(Path);
to_item_path(Path) when is_list(Path) ->
    Path.

%%--------------------------------------------------------------------
%% Tree diff
%%--------------------------------------------------------------------

diff_trees(Old, New, Path) ->
    OldMap = index_tree(Old),
    NewMap = index_tree(New),
    Names = lists:usort(maps:keys(OldMap) ++ maps:keys(NewMap)),
    lists:flatmap(
      fun(Name) ->
              diff_node(maps:find(Name, OldMap),
                        maps:find(Name, NewMap),
                        Path ++ [Name])
      end, Names).

index_tree(Tree) when is_list(Tree) ->
    maps:from_list(Tree);
index_tree(_) ->
    #{}.

diff_node(error, {ok, New}, Path) ->
    [add_change(Path, New)];
diff_node({ok, Old}, error, Path) ->
    [delete_change(Path, Old)];
diff_node({ok, Same}, {ok, Same}, _Path) ->
    [];
diff_node({ok, {value, Old}}, {ok, {value, New}}, Path) ->
    [{set, Path, Old, New}];
diff_node({ok, {leaf_list, Old}}, {ok, {leaf_list, New}}, Path) ->
    [{set, Path, Old, New}];
diff_node({ok, {value, Old}}, {ok, {leaf_list, New}}, Path) ->
    [{set, Path, Old, New}];
diff_node({ok, {leaf_list, Old}}, {ok, {value, New}}, Path) ->
    [{set, Path, Old, New}];
diff_node({ok, OldC}, {ok, NewC}, Path) when is_list(OldC), is_list(NewC) ->
    diff_trees(OldC, NewC, Path);
diff_node({ok, Old}, {ok, New}, Path) ->
    [delete_change(Path, Old), add_change(Path, New)].

add_change(Path, {value, V}) ->
    {set, Path, undefined, V};
add_change(Path, {leaf_list, V}) ->
    {set, Path, undefined, V};
add_change(Path, Children) when is_list(Children) ->
    {add, Path, Children}.

delete_change(Path, {value, V}) ->
    {set, Path, V, undefined};
delete_change(Path, {leaf_list, V}) ->
    {set, Path, V, undefined};
delete_change(Path, Children) when is_list(Children) ->
    {delete, Path, Children}.

filter_prefix(Changes, []) ->
    Changes;
filter_prefix(Changes, Prefix) ->
    [C || C <- Changes, lists:prefix(Prefix, change_path(C))].

change_path({add, Path, _}) -> Path;
change_path({delete, Path, _}) -> Path;
change_path({set, Path, _, _}) -> Path.

%%--------------------------------------------------------------------
%% Junos-style formatter
%%--------------------------------------------------------------------

group_hunks(Changes) ->
    lists:reverse(
      lists:foldl(
        fun(Change, Acc) ->
                Edit = edit_path(Change),
                Lines = change_lines(Change),
                case Acc of
                    [] ->
                        [{Edit, Lines}];
                    [{Edit, Prev} | Rest] ->
                        [{Edit, Prev ++ Lines} | Rest];
                    _ ->
                        [{Edit, Lines} | Acc]
                end
        end, [], Changes)).

edit_path({set, Path, _, _}) ->
    droplast_path(Path);
edit_path({add, Path, _}) ->
    droplast_path(Path);
edit_path({delete, Path, _}) ->
    droplast_path(Path).

droplast_path([]) ->
    [];
droplast_path(Path) ->
    lists:droplast(Path).

change_lines({set, Path, Old, New}) ->
    Name = lists:last(Path),
    del_line(Name, Old) ++ add_line(Name, New);
change_lines({add, Path, Tree}) ->
    signed_tree("+", [{lists:last(Path), Tree}], 0);
change_lines({delete, Path, Tree}) ->
    signed_tree("-", [{lists:last(Path), Tree}], 0).

del_line(_Name, undefined) ->
    [];
del_line(Name, Val) ->
    [signed_leaf("-", 0, Name, Val)].

add_line(_Name, undefined) ->
    [];
add_line(Name, Val) ->
    [signed_leaf("+", 0, Name, Val)].

format_hunk({EditPath, Lines}) ->
    ["[edit", edit_label(EditPath), "]\r\n", Lines].

edit_label([]) ->
    [];
edit_label(Path) ->
    [" ", lists:join(" ", [fmt_seg(S) || S <- Path])].

signed_tree(_Sign, [], _Indent) ->
    [];
signed_tree(Sign, [{Name, {value, Val}} | Rest], Indent) ->
    [signed_leaf(Sign, Indent, Name, Val)
     | signed_tree(Sign, Rest, Indent)];
signed_tree(Sign, [{Name, {leaf_list, Vals}} | Rest], Indent) ->
    [signed_leaf(Sign, Indent, Name, Vals)
     | signed_tree(Sign, Rest, Indent)];
signed_tree(Sign, [{Name, Children} | Rest], Indent) when is_list(Children) ->
    [line(Sign, Indent, [fmt_seg(Name), " {"]),
     signed_tree(Sign, Children, Indent + 2),
     line(Sign, Indent, "}")
     | signed_tree(Sign, Rest, Indent)].

signed_leaf(Sign, Indent, Name, Val) ->
    line(Sign, Indent, [fmt_seg(Name), " ", fmt_value(Val), ";"]).

line(Sign, Indent, Content) ->
    [Sign, "  ", spaces(Indent), Content, "\r\n"].

spaces(N) when N =< 0 ->
    [];
spaces(N) ->
    lists:duplicate(N, $\s).

fmt_seg(T) when is_tuple(T) ->
    lists:join(" ", [fmt_seg(X) || X <- tuple_to_list(T)]);
fmt_seg(N) when is_atom(N) ->
    atom_to_list(N);
fmt_seg(N) when is_binary(N) ->
    unicode:characters_to_list(N);
fmt_seg(N) when is_integer(N) ->
    integer_to_list(N);
fmt_seg(N) when is_list(N) ->
    N;
fmt_seg(Other) ->
    lists:flatten(io_lib:format("~p", [Other])).

fmt_value({value, V}) ->
    fmt_value(V);
fmt_value({leaf_list, Vals}) ->
    fmt_value(Vals);
fmt_value(Bin) when is_binary(Bin) ->
    unicode:characters_to_list(Bin);
fmt_value(Int) when is_integer(Int) ->
    integer_to_list(Int);
fmt_value(true) ->
    "true";
fmt_value(false) ->
    "false";
fmt_value(Atom) when is_atom(Atom) ->
    atom_to_list(Atom);
fmt_value({A, B, C, D}) when is_integer(A), is_integer(B),
                             is_integer(C), is_integer(D) ->
    lists:flatten(io_lib:format("~p.~p.~p.~p", [A, B, C, D]));
fmt_value(List) when is_list(List) ->
    case io_lib:printable_unicode_list(List) of
        true ->
            List;
        false ->
            ["[ ", lists:join(" ", [fmt_value(V) || V <- List]), " ]"]
    end;
fmt_value(Else) ->
    lists:flatten(io_lib:format("~p", [Else])).
