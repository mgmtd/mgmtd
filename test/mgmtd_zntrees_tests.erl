%%%-------------------------------------------------------------------
%%% @author Sean Hinde <sean@Seans-MacBook.local>
%%% @doc zntrees test module taken from ferd.ca blogpost:
%%%      https://ferd.ca/yet-another-article-on-zippers.html
%%%
%%% @end
%%% Created : 24 Feb 2025 by Sean Hinde <sean@Seans-MacBook.local>
%%%-------------------------------------------------------------------

-module(mgmtd_zntrees_tests).
-import(mgmtd_zntrees, [root/1, value/1,
                  replace/2, insert/2, delete/1,
                  left/1, right/1, parent/1, rparent/1, children/1]).
-include_lib("eunit/include/eunit.hrl").

-define(TEST_TREE, {[], % thread
                    {[], [{a, {[], [{d, {[], []}},
                                    {e, {[], []}}]}},
                          {b, {[], [{f, {[], []}},
                                    {g, {[], [{k, {[], []}}]}}]}},
                          {c, {[], [{h, {[], []}},
                                    {i, {[], []}},
                                    {j, {[], []}}]}}]}}).

root_test_() ->
    [?_assertEqual({[], {[], [{a,{[], []}}]}}, root(a))].

value_test_() ->
    [?_assertError(function_clause, value(children(root(a)))), % FIX THIS
     ?_assertEqual(a, value(root(a))),
     ?_assertEqual(b, value(right(?TEST_TREE)))].

replace_test_() ->
    [?_assertEqual(r, value(replace(r, root(a)))),
     ?_assertEqual(r, value(replace(r, right(?TEST_TREE)))),
     ?_assertMatch({[], {[], [{a, {_,_}}, {r, {_,_}}, {c, {_,_}}]}},
                   left(replace(r, left(right(right(?TEST_TREE))))))].

insert_test_() ->
    [?_assertEqual({[], {[], [{x, {[], []}}, {a, {[], []}}]}},
                   insert(x, root(a))),
     ?_assertMatch({[], {[], [{a,{_,_}}, {r,{_,_}}, {b,{_,_}}, {c,{_,_}}]}},
                   left(insert(r, right(?TEST_TREE))))].

delete_test_() ->
    [?_assertError(function_clause, delete(delete(root(a)))),
     ?_assertEqual({[], {[], []}}, delete(root(a))),
     ?_assertEqual({[], {[], [{a, {[], []}}]}},
                   delete(insert(x, root(a)))),
     ?_assertMatch({[], {[], [{b, {[], [{f,{[], []}},
                                        {g,{[], []}}]}}]}},
                   parent(left(parent(delete(children(right(children( % clear k
                    left(delete(right(delete(?TEST_TREE)))) % clear a and c
                   ))))))))].

right_test() ->
    [?_assertEqual({[], {[{a, {[], []}}], []}}, right(root(a))),
     ?_assertError(function_clause, right(right(root(a))))].

left_test_() ->
    [?_assertError(function_clause, left(root(a))),
     ?_assertEqual(root(a), left(right(root(a))))].

children_test_() ->
    [?_assertEqual({[{[], [a]}], {[], []}}, children(root(a))),
     ?_assertError(function_clause, children(children(root(a)))),
     ?_assertEqual(a, value(parent(children(root(a))))),
     ?_assertEqual(k, value(children(right(children(right(?TEST_TREE))))))].

parent_test_() ->
    [?_assertError(function_clause, parent(root(a))),
     ?_assertEqual(?TEST_TREE, parent(children(?TEST_TREE))),
     %% no rewind test
     ?_assertEqual(e, value(children(parent(right(children(?TEST_TREE))))))].

rparent_test_() ->
    [?_assertError(function_clause, parent(root(a))),
     ?_assertEqual(?TEST_TREE, parent(children(?TEST_TREE))),
     %% rewind test
     ?_assertEqual(d, value(children(rparent(right(children(?TEST_TREE))))))].